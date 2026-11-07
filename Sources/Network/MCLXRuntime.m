#import "MCLXRuntime.h"
#import "MCMusicSources.h"
#import "MCHTTPClient.h"
#import "MCSourceSecurity.h"
#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonCryptor.h>
#import <Security/Security.h>
#include "quickjs.h"
#include <zlib.h>
#include <mbedtls/pk.h>
#include <mbedtls/rsa.h>
#include <math.h>
#include <mach/mach_time.h>

static NSTimeInterval LXNow(void) {
    static double scale;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        mach_timebase_info_data_t info;
        mach_timebase_info(&info);
        scale = (double)info.numer / info.denom / 1e9;
    });
    return mach_absolute_time() * scale;
}
static const NSUInteger MCLXCap = 2 * 1024 * 1024;
static NSError *LXError(NSString *text) {
    return [NSError errorWithDomain:@"MCLXRuntime" code:1 userInfo:@{NSLocalizedDescriptionKey : text}];
}
static NSData *LXBytes(id value) {
    if (![value isKindOfClass:[NSArray class]] || [value count] > MCLXCap)
        return nil;
    NSMutableData *d = [NSMutableData dataWithLength:[value count]];
    uint8_t *p = d.mutableBytes;
    for (id n in value) {
        if (![n isKindOfClass:[NSNumber class]])
            return nil;
        *p++ = [n unsignedCharValue];
    }
    return d;
}
static NSArray *LXArray(NSData *data) {
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:data.length];
    const uint8_t *p = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++)
        [a addObject:@(p[i])];
    return a;
}
@interface MCLXRuntime () {
  @public
    dispatch_queue_t _queue;
    JSRuntime *_vm;
    JSContext *_ctx;
    NSTimeInterval _deadline;
    NSString *_script;
    NSDictionary *_information;
    NSDictionary *_sources;
    NSDictionary *_candidate;
    NSMutableDictionary *_timers, *_requests, *_resolutions, *_rejections;
    void (^_starting)(NSDictionary *, NSError *);
    BOOL _invalid, _started, _updateShown;
    dispatch_source_t _clock;
    NSTimeInterval _initializationLimit, _resolutionLimit;
}
- (id)native:(NSString *)op value:(id)value;
- (void)fail:(NSError *)error;
- (void)invoke:(NSString *)function arguments:(NSArray *)arguments;
- (void)reschedule;
- (void)wake;
@end
static int LXInterrupt(JSRuntime *rt, void *opaque) {
    MCLXRuntime *self = (__bridge MCLXRuntime *)opaque;
    return LXNow() > self->_deadline;
}
static void LXRejection(JSContext *ctx, JSValueConst promise, JSValueConst reason, JS_BOOL handled,
                        void *opaque) {
    @autoreleasepool {
        MCLXRuntime *self = (__bridge MCLXRuntime *)opaque;
        NSValue *key = [NSValue valueWithPointer:JS_VALUE_GET_PTR(promise)];
        NSValue *stored = self->_rejections[key];
        if (handled && stored) {
            JSValue held;
            [stored getValue:&held];
            [self->_rejections removeObjectForKey:key];
            JS_FreeValue(ctx, held);
        } else if (!handled && !stored) {
            JSValue held = JS_DupValue(ctx, promise);
            self->_rejections[key] = [NSValue valueWithBytes:&held objCType:@encode(JSValue)];
        }
    }
}
static JSValue LXNative(JSContext *ctx, JSValueConst thisValue, int argc, JSValueConst *argv) {
    @autoreleasepool {
        MCLXRuntime *self = (__bridge MCLXRuntime *)JS_GetContextOpaque(ctx);
        const char *op = argc > 0 ? JS_ToCString(ctx, argv[0]) : NULL,
                   *json = argc > 1 ? JS_ToCString(ctx, argv[1]) : NULL;
        id result = nil;
        @try {
            if (op && json) {
                NSData *data = [[NSString stringWithUTF8String:json] dataUsingEncoding:NSUTF8StringEncoding];
                id value = [NSJSONSerialization JSONObjectWithData:data
                                                           options:NSJSONReadingAllowFragments
                                                             error:NULL];
                result = [self native:[NSString stringWithUTF8String:op] value:value];
            }
        } @catch (NSException *e) {
            result = @{@"__error" : @"Invalid source operation"};
        }
        JS_FreeCString(ctx, op);
        JS_FreeCString(ctx, json);
        NSData *out = [NSJSONSerialization dataWithJSONObject:@[ result ?: [NSNull null] ]
                                                      options:0
                                                        error:NULL];
        if (out.length < 2)
            return JS_NewString(ctx, "null");
        return JS_NewStringLen(ctx, (const char *)out.bytes + 1, out.length - 2);
    }
}
@implementation MCLXRuntime
- (instancetype)initWithScript:(NSString *)script information:(NSDictionary *)information {
    if ((self = [super init])) {
        _script = [script copy];
        _information = [information copy] ?: @{};
        _queue = dispatch_queue_create("com.muyu.lx", DISPATCH_QUEUE_SERIAL);
        _timers = [NSMutableDictionary new];
        _requests = [NSMutableDictionary new];
        _resolutions = [NSMutableDictionary new];
        _rejections = [NSMutableDictionary new];
        _clock = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
        __weak MCLXRuntime *weak = self;
        dispatch_source_set_event_handler(_clock, ^{
            @autoreleasepool {
                MCLXRuntime *r = weak;
                if (r && !r->_invalid)
                    [r wake];
            }
        });
        dispatch_source_set_timer(_clock, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
        dispatch_resume(_clock);
    }
    return self;
}
- (NSDictionary *)sources {
    @synchronized(self) {
        return _sources;
    }
}
- (void)deliver:(void (^)(NSDictionary *, NSError *))completion
          value:(NSDictionary *)value
          error:(NSError *)error {
    if (completion)
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(value, error);
        });
}
// The only host timer belongs to this runtime. All JS timers and operation
// deadlines share this bounded queue; removing a timer leaves no delayed block.
- (void)reschedule {
    if (!_clock || _invalid)
        return;
    NSTimeInterval earliest = INFINITY;
    if (_initializationLimit > 0)
        earliest = MIN(earliest, _initializationLimit);
    if (_resolutionLimit > 0)
        earliest = MIN(earliest, _resolutionLimit);
    for (NSNumber *deadline in _timers.allValues)
        earliest = MIN(earliest, deadline.doubleValue);
    dispatch_time_t target =
        isfinite(earliest)
            ? dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(0, earliest - LXNow()) * NSEC_PER_SEC))
            : DISPATCH_TIME_FOREVER;
    dispatch_source_set_timer(_clock, target, DISPATCH_TIME_FOREVER, 0);
}
- (void)wake {
    NSTimeInterval now = LXNow();
    if (_initializationLimit > 0 && now >= _initializationLimit) {
        [self fail:LXError(@"脚本初始化超时")];
        return;
    }
    if (_resolutionLimit > 0 && now >= _resolutionLimit) {
        [self fail:LXError(@"音源解析超时")];
        return;
    }
    // Run one due timer per host event. This permits cancellation and checks
    // operation deadlines between callbacks, even when 128 timers are ready.
    NSArray *identifiers =
        [_timers keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
            return [a compare:b];
        }];
    for (NSNumber *identifier in identifiers) {
        NSNumber *deadline = _timers[identifier];
        if (!deadline || deadline.doubleValue > now)
            continue;
        [_timers removeObjectForKey:identifier];
        [self invoke:@"__lxTimer" arguments:@[ identifier ]];
        if (_invalid)
            return;
        break;
    }
    [self reschedule];
}
- (void)fail:(NSError *)error {
    void (^starting)(NSDictionary *, NSError *) = _starting;
    _starting = nil;
    [self deliver:starting value:nil error:error];
    NSArray *callbacks = _resolutions.allValues;
    [_resolutions removeAllObjects];
    for (id callback in callbacks)
        [self deliver:callback value:nil error:error];
    _invalid = YES;
    _initializationLimit = 0;
    _resolutionLimit = 0;
    if (_clock) {
        dispatch_source_cancel(_clock);
        _clock = nil;
    }
    for (MCRequest *r in _requests.allValues)
        [r cancel];
    [_requests removeAllObjects];
    [_timers removeAllObjects];
    for (NSValue *stored in _rejections.allValues) {
        JSValue held;
        [stored getValue:&held];
        JS_FreeValue(_ctx, held);
    }
    [_rejections removeAllObjects];
    if (_ctx) {
        JS_FreeContext(_ctx);
        _ctx = NULL;
    }
    if (_vm) {
        JS_FreeRuntime(_vm);
        _vm = NULL;
    }
}
- (BOOL)finishEntry:(JSValue)result {
    BOOL bad = JS_IsException(result);
    JS_FreeValue(_ctx, result);
    if (bad) {
        JSValue e = JS_GetException(_ctx);
        JS_FreeValue(_ctx, e);
        [self fail:LXError(@"脚本执行失败（语法、异常或运行限额）")];
        return NO;
    }
    while (JS_IsJobPending(_vm)) {
        JSContext *job = NULL;
        if (LXNow() > _deadline || JS_ExecutePendingJob(_vm, &job) < 0) {
            if (job) {
                JSValue e = JS_GetException(job);
                JS_FreeValue(job, e);
            }
            [self fail:LXError(@"脚本异步执行失败或超出限额")];
            return NO;
        }
    }
    if (_rejections.count) {
        [self fail:LXError(@"脚本 Promise 未处理的错误")];
        return NO;
    }
    if (_candidate && _starting) {
        @synchronized(self) {
            _sources = _candidate;
        }
        _candidate = nil;
        id completion = _starting;
        _starting = nil;
        _initializationLimit = 0;
        [self reschedule];
        [self deliver:completion value:_sources error:nil];
    }
    return YES;
}
- (BOOL)evaluate:(NSString *)code {
    @autoreleasepool {
        JS_UpdateStackTop(_vm);
        _deadline = LXNow() + 0.5;
        const char *bytes = code.UTF8String;
        return [self finishEntry:JS_Eval(_ctx, bytes, strlen(bytes), "source.js", JS_EVAL_TYPE_GLOBAL)];
    }
}
- (void)invoke:(NSString *)function arguments:(NSArray *)arguments {
    @autoreleasepool {
        if (!_ctx || _invalid)
            return;
        JS_UpdateStackTop(_vm);
        _deadline = LXNow() + 0.5;
        JSValue global = JS_GetGlobalObject(_ctx), fn = JS_GetPropertyStr(_ctx, global, function.UTF8String);
        NSUInteger count = arguments.count;
        JSValue args[count ?: 1];
        for (NSUInteger i = 0; i < count; i++) {
            NSData *d = [NSJSONSerialization dataWithJSONObject:@[ arguments[i] ] options:0 error:NULL];
            NSString *json = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
            JSValue a = JS_ParseJSON(_ctx, json.UTF8String, d.length, "argument");
            args[i] = JS_GetPropertyUint32(_ctx, a, 0);
            JS_FreeValue(_ctx, a);
        }
        JSValue result = JS_Call(_ctx, fn, global, (int)count, args);
        for (NSUInteger i = 0; i < count; i++)
            JS_FreeValue(_ctx, args[i]);
        JS_FreeValue(_ctx, fn);
        JS_FreeValue(_ctx, global);
        [self finishEntry:result];
    }
}
- (void)start:(void (^)(NSDictionary *, NSError *))completion {
    dispatch_async(_queue, ^{
        @autoreleasepool {
            if (self->_started || self->_invalid) {
                [self deliver:completion value:nil error:LXError(@"脚本实例不可重复初始化")];
                return;
            }
            self->_started = YES;
            self->_starting = [completion copy];
            self->_initializationLimit = LXNow() + 10;
            [self reschedule];
            if (!self->_script ||
                [self->_script lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 1024 * 1024) {
                [self fail:LXError(@"脚本超过 1 MiB 限制")];
                return;
            }
            self->_vm = JS_NewRuntime();
            if (!self->_vm) {
                [self fail:LXError(@"无法创建脚本引擎")];
                return;
            }
            JS_SetMemoryLimit(self->_vm, 16 * 1024 * 1024);
            // GCD workers have a 512 KiB native stack. Reserve half for bridge,
            // exception unwinding and the interpreter's native frames.
            JS_SetMaxStackSize(self->_vm, 256 * 1024);
            JS_SetInterruptHandler(self->_vm, LXInterrupt, (__bridge void *)self);
            JS_SetHostPromiseRejectionTracker(self->_vm, LXRejection, (__bridge void *)self);
            self->_ctx = JS_NewContext(self->_vm);
            if (!self->_ctx) {
                [self fail:LXError(@"脚本内存不足")];
                return;
            }
            JS_SetContextOpaque(self->_ctx, (__bridge void *)self);
            JSValue global = JS_GetGlobalObject(self->_ctx);
            JS_SetPropertyStr(self->_ctx, global, "__lxNative",
                              JS_NewCFunction(self->_ctx, LXNative, "__lxNative", 2));
            JS_FreeValue(self->_ctx, global);
            NSString *path = [[NSBundle mainBundle] pathForResource:@"LXPrelude" ofType:@"js"];
            if (!path)
                path = @"Resources/LXPrelude.js";
            NSString *prelude = [NSString stringWithContentsOfFile:path
                                                          encoding:NSUTF8StringEncoding
                                                             error:NULL];
            if (!prelude) {
                [self fail:LXError(@"脚本运行环境缺失")];
                return;
            }
            if (![self evaluate:prelude] || ![self evaluate:self->_script])
                return;
        }
    });
}
- (MCSourceTask *)resolveTrack:(NSDictionary *)track
                       quality:(NSString *)quality
                    completion:(void (^)(NSDictionary *, NSError *))completion {
    NSString *identifier = [[NSUUID UUID] UUIDString];
    __weak MCLXRuntime *weak = self;
    MCSourceTask *task = [[MCSourceTask alloc] initWithCancellation:^{
        MCLXRuntime *r = weak;
        if (!r)
            return;
        dispatch_async(r->_queue, ^{
            @autoreleasepool {
                id callback = r->_resolutions[identifier];
                if (callback) {
                    [r fail:LXError(@"音源解析已取消")];
                }
            }
        });
    }];
    dispatch_async(_queue, ^{
        @autoreleasepool {
            if (self->_invalid || !self->_sources || self->_resolutions.count) {
                [self deliver:completion value:nil error:LXError(@"脚本未就绪或正在解析")];
                return;
            }
            NSDictionary *wy =
                [self->_sources[@"wy"] isKindOfClass:[NSDictionary class]] ? self->_sources[@"wy"] : @{};
            NSArray *supported = [wy[@"qualitys"] isKindOfClass:[NSArray class]] ? wy[@"qualitys"] : @[];
            NSArray *preference = [quality isEqual:@"lossless"]
                                      ? @[ @"flac", @"320k", @"128k" ]
                                      : ([quality isEqual:@"exhigh"] ? @[ @"320k", @"128k" ] : @[ @"128k" ]);
            NSString *type = nil;
            for (NSString *q in preference)
                if ([supported containsObject:q]) {
                    type = q;
                    break;
                }
            if (!type || ![wy[@"actions"] isKindOfClass:[NSArray class]] ||
                ![wy[@"actions"] containsObject:@"musicUrl"]) {
                [self deliver:completion value:nil error:LXError(@"脚本不支持网易云或当前音质")];
                return;
            }
            NSMutableDictionary *info = [NSMutableDictionary dictionaryWithDictionary:@{
                @"source" : @"wy",
                @"songmid" : [track[@"id"] description] ?: @"",
                @"types" : @[],
                @"_types" : @{},
                @"typeUrl" : @{}
            }];
            NSDictionary *mapping = @{
                @"name" : @"name",
                @"title" : @"name",
                @"artist" : @"singer",
                @"album" : @"albumName",
                @"albumId" : @"albumId",
                @"albumID" : @"albumId",
                @"duration" : @"duration",
                @"cover" : @"img",
                @"artwork" : @"img"
            };
            for (NSString *key in mapping) {
                id v = track[key];
                if (v && v != [NSNull null])
                    info[mapping[key]] = v;
            }
            id duration = track[@"duration"];
            if ([duration respondsToSelector:@selector(doubleValue)] && isfinite([duration doubleValue]) &&
                [duration doubleValue] >= 0) {
                NSUInteger seconds = (NSUInteger)MIN([duration doubleValue], 360000000.0);
                info[@"interval"] = [NSString stringWithFormat:@"%02lu:%02lu", (unsigned long)(seconds / 60),
                                                               (unsigned long)(seconds % 60)];
            }
            self->_resolutions[identifier] = [completion copy];
            self->_resolutionLimit = LXNow() + 40;
            [self reschedule];
            [self invoke:@"__lxResolve"
                arguments:@[
                    identifier, @{
                        @"source" : @"wy",
                        @"action" : @"musicUrl",
                        @"info" : @{@"type" : type, @"musicInfo" : info}
                    }
                ]];
        }
    });
    return task;
}
- (void)invalidate {
    dispatch_async(_queue, ^{
        @autoreleasepool {
            [self fail:LXError(@"音源已停用")];
        }
    });
}
- (void)dealloc {
    if (_clock)
        dispatch_source_cancel(_clock);
    for (NSValue *stored in _rejections.allValues) {
        JSValue held;
        [stored getValue:&held];
        JS_FreeValue(_ctx, held);
    }
    if (_ctx)
        JS_FreeContext(_ctx);
    if (_vm)
        JS_FreeRuntime(_vm);
    for (MCRequest *r in _requests.allValues)
        [r cancel];
}
- (id)native:(NSString *)op value:(id)v {
    id bad = @{@"__error" : @"脚本参数无效或超过限额"};
    if ([op isEqual:@"information"]) {
        NSMutableDictionary *i = [_information mutableCopy];
        i[@"rawScript"] = _script;
        return i;
    }
    if ([op isEqual:@"send"]) {
        if ([v[@"event"] isEqual:@"inited"]) {
            id sources = v[@"data"][@"sources"];
            if (![sources isKindOfClass:[NSDictionary class]] || [sources count] > 16)
                return bad;
            NSMutableDictionary *normalized = [NSMutableDictionary new];
            NSArray *platforms = @[ @"wy", @"kw", @"kg", @"tx", @"mg", @"local" ];
            NSArray *qualities = @[ @"128k", @"320k", @"flac", @"flac24bit" ];
            for (NSString *platform in sources) {
                if (![platforms containsObject:platform])
                    continue;
                id descriptor = sources[platform];
                if (![descriptor isKindOfClass:[NSDictionary class]])
                    return bad;
                id type = descriptor[@"type"], actions = descriptor[@"actions"],
                   qualitys = descriptor[@"qualitys"];
                if ((type && ![type isEqual:@"music"]) ||
                    (actions && ![actions isKindOfClass:[NSArray class]]) ||
                    (qualitys && ![qualitys isKindOfClass:[NSArray class]]) || [actions count] > 16 ||
                    [qualitys count] > 16)
                    return bad;
                NSMutableArray *validActions = [NSMutableArray new], *validQualities = [NSMutableArray new];
                for (id action in actions) {
                    if (![action isKindOfClass:[NSString class]])
                        return bad;
                    if (([action isEqual:@"musicUrl"] ||
                         ([platform isEqual:@"local"] && [@[ @"pic", @"lyric" ] containsObject:action])) &&
                        ![validActions containsObject:action])
                        [validActions addObject:action];
                }
                for (id quality in qualitys) {
                    if (![quality isKindOfClass:[NSString class]])
                        return bad;
                    if ([qualities containsObject:quality] && ![validQualities containsObject:quality])
                        [validQualities addObject:quality];
                }
                NSMutableDictionary *item =
                    [@{@"type" : @"music", @"actions" : validActions, @"qualitys" : validQualities}
                        mutableCopy];
                if ([descriptor[@"name"] isKindOfClass:[NSString class]])
                    item[@"name"] = descriptor[@"name"];
                normalized[platform] = item;
            }
            if (!_sources && !_candidate)
                _candidate = [normalized copy];
        } else if ([v[@"event"] isEqual:@"updateAlert"] && !_updateShown) {
            _updateShown = YES;
            id log = v[@"data"][@"log"], url = v[@"data"][@"updateUrl"];
            if ([log isKindOfClass:[NSString class]]) {
                NSString *text = [log substringToIndex:MIN((NSUInteger)1024, [log length])];
                NSURL *u = [url isKindOfClass:[NSString class]] ? [NSURL URLWithString:url] : nil;
                NSMutableDictionary *notice = [@{@"log" : text} mutableCopy];
                if ([u.scheme.lowercaseString isEqual:@"https"] && u.host.length && ![u user] &&
                    ![u password] && [url length] <= 1024)
                    notice[@"updateUrl"] = url;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"MCLXRuntimeUpdateAlert"
                                                                        object:self
                                                                      userInfo:notice];
                });
            }
        }
        return nil;
    }
    if ([op isEqual:@"timer"]) {
        if (_timers.count >= 128)
            return bad;
        NSNumber *identifier = v[@"id"];
        double delay = [v[@"delay"] doubleValue];
        if (!isfinite(delay) || delay > 40000)
            delay = 40000;
        _timers[identifier] = @(LXNow() + MAX(0, delay) / 1000);
        [self reschedule];
        return nil;
    }
    if ([op isEqual:@"clearTimer"]) {
        [_timers removeObjectForKey:v];
        [self reschedule];
        return nil;
    }
    if ([op isEqual:@"resolved"] || [op isEqual:@"rejected"]) {
        id callback = _resolutions[v[@"id"]];
        if (!callback)
            return nil;
        [_resolutions removeObjectForKey:v[@"id"]];
        _resolutionLimit = 0;
        [self reschedule];
        id url = v[@"value"];
        NSURL *u = [url isKindOfClass:[NSString class]] ? [NSURL URLWithString:url] : nil;
        if ([op isEqual:@"resolved"] && MCSourceURLAllowed(u)) {
            [self deliver:callback value:@{@"url" : url} error:nil];
        } else
            [self deliver:callback
                    value:nil
                    error:LXError([op isEqual:@"rejected"]
                                      ? MCSourceFailureText(v[@"message"], @"脚本解析失败，未返回播放地址")
                                      : MCSourceURLFailure(u))];
        return nil;
    }
    if ([op isEqual:@"abort"]) {
        [_requests[v] cancel];
        [_requests removeObjectForKey:v];
        return nil;
    }
    if ([op isEqual:@"http"]) {
        if (_requests.count >= 4)
            return @{@"__error" : @"脚本 HTTP 并发上限为 4"};
        NSString *url = v[@"url"];
        NSDictionary *options = v[@"options"];
        if (![url isKindOfClass:[NSString class]] || ![options isKindOfClass:[NSDictionary class]])
            return bad;
        NSURL *u = [NSURL URLWithString:url];
        if (!MCSourceURLAllowed(u))
            return @{@"__error" : MCSourceURLFailure(u)};
        NSMutableDictionary *headers = [NSMutableDictionary new];
        id hs = options[@"headers"];
        if (hs && ![hs isKindOfClass:[NSDictionary class]])
            return bad;
        for (id key in hs) {
            if (![key isKindOfClass:[NSString class]] || ![hs[key] isKindOfClass:[NSString class]])
                return bad;
            headers[key] = hs[key];
        }
        NSString *method = [options[@"method"] isKindOfClass:[NSString class]]
                               ? [options[@"method"] uppercaseString]
                               : @"GET";
        NSData *body = nil;
        if (options[@"form"]) {
            id form = options[@"form"];
            if (![form isKindOfClass:[NSDictionary class]])
                return bad;
            NSMutableArray *pairs = [NSMutableArray new];
            NSCharacterSet *allowed =
                [NSCharacterSet characterSetWithCharactersInString:
                                    @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
            for (id key in form) {
                if (![key isKindOfClass:[NSString class]])
                    return bad;
                NSString *value = [form[key] description];
                [pairs addObject:[NSString
                                     stringWithFormat:
                                         @"%@=%@",
                                         [key stringByAddingPercentEncodingWithAllowedCharacters:allowed],
                                         [value stringByAddingPercentEncodingWithAllowedCharacters:allowed]]];
            }
            body = [[pairs componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];
            headers[@"Content-Type"] = @"application/x-www-form-urlencoded";
        } else if (options[@"formData"]) {
            id form = options[@"formData"];
            if (![form isKindOfClass:[NSDictionary class]])
                return bad;
            NSString *boundary = [@"MuyuLX" stringByAppendingString:[[NSUUID UUID] UUIDString]];
            NSMutableData *multipart = [NSMutableData new];
            for (id key in form) {
                if (![key isKindOfClass:[NSString class]] ||
                    [key
                        rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\r\n\""]]
                            .location != NSNotFound)
                    return bad;
                id value = form[key];
                NSData *part = nil;
                NSString *filename = nil, *contentType = @"application/octet-stream";
                if ([value isKindOfClass:[NSDictionary class]]) {
                    id content = value[@"value"];
                    part = [content isKindOfClass:[NSArray class]]
                               ? LXBytes(content)
                               : [[content description] dataUsingEncoding:NSUTF8StringEncoding];
                    filename = value[@"options"][@"filename"];
                    if (value[@"options"][@"contentType"])
                        contentType = value[@"options"][@"contentType"];
                } else
                    part = [[value description] dataUsingEncoding:NSUTF8StringEncoding];
                if ((filename &&
                     (![filename isKindOfClass:[NSString class]] ||
                      [filename rangeOfCharacterFromSet:[NSCharacterSet
                                                            characterSetWithCharactersInString:@"\r\n\""]]
                              .location != NSNotFound)) ||
                    ![contentType isKindOfClass:[NSString class]] ||
                    [contentType rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]].location !=
                        NSNotFound ||
                    !part)
                    return bad;
                NSString *head = [NSString
                    stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"%@\"%@\r\n%@\r\n",
                                     boundary, key,
                                     filename ? [NSString stringWithFormat:@"; filename=\"%@\"", filename]
                                              : @"",
                                     filename
                                         ? [@"Content-Type: " stringByAppendingFormat:@"%@\r\n", contentType]
                                         : @""];
                [multipart appendData:[head dataUsingEncoding:NSUTF8StringEncoding]];
                [multipart appendData:part];
                [multipart appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
                if (multipart.length > MCLXCap)
                    return bad;
            }
            [multipart appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary]
                                      dataUsingEncoding:NSUTF8StringEncoding]];
            body = multipart;
            headers[@"Content-Type"] = [@"multipart/form-data; boundary=" stringByAppendingString:boundary];
        } else if (options[@"body"]) {
            id b = options[@"body"];
            if ([b isKindOfClass:[NSString class]])
                body = [b dataUsingEncoding:NSUTF8StringEncoding];
            else if ([b isKindOfClass:[NSDictionary class]] && b[@"__bytes"])
                body = LXBytes(b[@"__bytes"]);
            else {
                body = [NSJSONSerialization dataWithJSONObject:b options:0 error:NULL];
                headers[@"Content-Type"] = @"application/json";
            }
        }
        if (body.length > MCLXCap)
            return bad;
        double timeout = [options[@"timeout"] respondsToSelector:@selector(doubleValue)]
                             ? [options[@"timeout"] doubleValue] / 1000
                             : 30;
        if (!isfinite(timeout) || timeout <= 0)
            timeout = 30;
        timeout = MIN(timeout, 40);
        NSNumber *identifier = v[@"id"];
        __weak MCLXRuntime *weak = self;
        MCRequest *request = [[MCHTTPClient sharedClient]
            sourceRequestURL:u
                      method:method
                        body:body
                     headers:headers
                     timeout:timeout
                  completion:^(NSData *data, NSDictionary *response, NSError *error) {
                      MCLXRuntime *r = weak;
                      if (!r)
                          return;
                      dispatch_async(r->_queue, ^{
                          @autoreleasepool {
                              if (r->_invalid || !r->_requests[identifier])
                                  return;
                              [r->_requests removeObjectForKey:identifier];
                              if (error || data.length > MCLXCap) {
                                  [r invoke:@"__lxHTTP"
                                      arguments:@[
                                          identifier,
                                          MCSourceFailureText(error.localizedDescription,
                                                              @"音源请求失败或响应超过大小限制"),
                                          [NSNull null], [NSNull null]
                                      ]];
                                  return;
                              }
                              id content = [NSJSONSerialization JSONObjectWithData:data
                                                                           options:NSJSONReadingAllowFragments
                                                                             error:NULL];
                              if (!content)
                                  content = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                                                ?: @"";
                              NSMutableDictionary *resp = [response mutableCopy] ?: [NSMutableDictionary new];
                              resp[@"statusCode"] = response[@"status"] ?: @0;
                              resp[@"headers"] = response[@"headers"] ?: @{};
                              resp[@"body"] = content;
                              resp[@"raw"] = LXArray(data);
                              [r invoke:@"__lxHTTP" arguments:@[ identifier, [NSNull null], resp, content ]];
                          }
                      });
                  }];
        if (request)
            _requests[identifier] = request;
        return nil;
    }
    if ([op isEqual:@"bufferFrom"]) {
        NSString *str = v[@"value"], *encoding = [v[@"encoding"] lowercaseString];
        if (![str isKindOfClass:[NSString class]])
            return bad;
        NSData *d = nil;
        if ([encoding isEqual:@"base64"])
            d = [[NSData alloc] initWithBase64EncodedString:str
                                                    options:NSDataBase64DecodingIgnoreUnknownCharacters];
        else if ([encoding isEqual:@"hex"]) {
            NSMutableData *hex = [NSMutableData new];
            for (NSUInteger i = 0; i + 1 < str.length; i += 2) {
                unsigned byte = 0;
                NSString *piece = [str substringWithRange:NSMakeRange(i, 2)];
                NSScanner *scanner = [NSScanner scannerWithString:piece];
                if (![scanner scanHexInt:&byte])
                    break;
                uint8_t b = byte;
                [hex appendBytes:&b length:1];
            }
            d = hex;
        } else
            d = [str dataUsingEncoding:([encoding isEqual:@"latin1"] || [encoding isEqual:@"binary"])
                                           ? NSISOLatin1StringEncoding
                                           : NSUTF8StringEncoding];
        return d && d.length <= MCLXCap ? LXArray(d) : bad;
    }
    if ([op isEqual:@"bufferString"]) {
        NSData *d = LXBytes(v[@"value"]);
        if (!d)
            return bad;
        NSString *enc = [v[@"encoding"] lowercaseString];
        if ([enc isEqual:@"base64"])
            return [d base64EncodedStringWithOptions:0];
        if ([enc isEqual:@"hex"]) {
            NSMutableString *s = [NSMutableString new];
            const uint8_t *p = d.bytes;
            for (NSUInteger i = 0; i < d.length; i++)
                [s appendFormat:@"%02x", p[i]];
            return s;
        }
        return [[NSString alloc] initWithData:d
                                     encoding:([enc isEqual:@"latin1"] || [enc isEqual:@"binary"])
                                                  ? NSISOLatin1StringEncoding
                                                  : NSUTF8StringEncoding]
                   ?: @"";
    }
    if ([op isEqual:@"md5"]) {
        if (![v isKindOfClass:[NSString class]])
            return bad;
        NSData *d = [v dataUsingEncoding:NSUTF8StringEncoding];
        unsigned char md[CC_MD5_DIGEST_LENGTH];
        CC_MD5(d.bytes, (CC_LONG)d.length, md);
        NSMutableString *s = [NSMutableString new];
        for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++)
            [s appendFormat:@"%02x", md[i]];
        return s;
    }
    if ([op isEqual:@"random"]) {
        NSInteger n = [v integerValue];
        if (n < 0 || n > 65536)
            return bad;
        NSMutableData *d = [NSMutableData dataWithLength:n];
        if (SecRandomCopyBytes(kSecRandomDefault, n, d.mutableBytes))
            return bad;
        return LXArray(d);
    }
    if ([op isEqual:@"aes"]) {
        NSData *data = LXBytes(v[@"value"]), *key = LXBytes(v[@"key"]), *iv = LXBytes(v[@"iv"]);
        NSString *mode = [v[@"mode"] lowercaseString];
        BOOL ecb = [mode hasSuffix:@"-ecb"];
        if (!data || !(key.length == 16 || key.length == 24 || key.length == 32) ||
            (!ecb && iv.length != 16) || !([mode hasSuffix:@"-cbc"] || ecb))
            return bad;
        NSMutableData *out = [NSMutableData dataWithLength:data.length + 16];
        size_t length = 0;
        CCCryptorStatus result =
            CCCrypt(kCCEncrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding | (ecb ? kCCOptionECBMode : 0),
                    key.bytes, key.length, ecb ? NULL : iv.bytes, data.bytes, data.length, out.mutableBytes,
                    out.length, &length);
        if (result != kCCSuccess)
            return bad;
        out.length = length;
        return LXArray(out);
    }
    if ([op isEqual:@"rsa"]) {
        NSData *data = LXBytes(v[@"value"]);
        NSString *key = v[@"key"];
        if (!data || ![key isKindOfClass:[NSString class]] || key.length > 16384)
            return bad;
        mbedtls_pk_context pk;
        mbedtls_pk_init(&pk);
        int rc = mbedtls_pk_parse_public_key(&pk, (const unsigned char *)key.UTF8String,
                                             strlen(key.UTF8String) + 1);
        unsigned char output[1024];
        size_t length = 0;
        if (!rc && mbedtls_pk_get_type(&pk) == MBEDTLS_PK_RSA &&
            (length = mbedtls_pk_get_len(&pk)) <= sizeof(output) && data.length <= length) {
            // LX's public RSA utility performs raw public-key exponentiation,
            // left-padding the input with zeros, rather than PKCS#1 encryption.
            unsigned char input[1024] = {0};
            memcpy(input + length - data.length, data.bytes, data.length);
            rc = mbedtls_rsa_public(mbedtls_pk_rsa(pk), input, output);
        } else
            rc = -1;
        mbedtls_pk_free(&pk);
        return rc ? bad : LXArray([NSData dataWithBytes:output length:length]);
    }
    if ([op isEqual:@"deflate"] || [op isEqual:@"inflate"]) {
        NSData *data = LXBytes(v);
        if (!data)
            return bad;
        BOOL deflateMode = [op isEqual:@"deflate"];
        z_stream stream = {0};
        int rc = deflateMode ? deflateInit(&stream, Z_DEFAULT_COMPRESSION) : inflateInit2(&stream, 15 + 32);
        if (rc != Z_OK)
            return bad;
        stream.next_in = (Bytef *)data.bytes;
        stream.avail_in = (uInt)data.length;
        NSMutableData *result = [NSMutableData new];
        unsigned char out[16384];
        do {
            stream.next_out = out;
            stream.avail_out = sizeof(out);
            rc = deflateMode ? deflate(&stream, Z_FINISH) : inflate(&stream, Z_NO_FLUSH);
            NSUInteger amount = sizeof(out) - stream.avail_out;
            if (result.length + amount > MCLXCap) {
                rc = Z_MEM_ERROR;
                break;
            }
            [result appendBytes:out length:amount];
        } while (rc == Z_OK);
        if (deflateMode)
            deflateEnd(&stream);
        else
            inflateEnd(&stream);
        return rc == Z_STREAM_END ? LXArray(result) : bad;
    }
    return bad;
}
@end
