#import <Foundation/Foundation.h>
#import "MCLXRuntime.h"
#import "MCMusicSources.h"
#import "MCHTTPClient.h"
#import "MCSourceSecurity.h"
#include <assert.h>
#include <zlib.h>
#include <mach/mach.h>
// Isolated transport fixture: exercise the real runtime without external services.
@implementation MCSourceTask {
    void (^_cancellation)(void);
    BOOL _cancelled;
}
@synthesize cancellation = _cancellation;
- (instancetype)initWithCancellation:(void (^)(void))block {
    if ((self = [super init]))
        _cancellation = [block copy];
    return self;
}
- (void)cancel {
    if (!_cancelled) {
        _cancelled = YES;
        if (_cancellation)
            _cancellation();
        _cancellation = nil;
    }
}
@end
@implementation MCRequest
- (void)cancel {
}
@end
@implementation MCHTTPClient
+ (instancetype)sharedClient {
    static id c;
    if (!c)
        c = [self new];
    return c;
}
- (MCRequest *)sourceRequestURL:(NSURL *)url
                         method:(NSString *)method
                           body:(NSData *)body
                        headers:(NSDictionary *)headers
                        timeout:(NSTimeInterval)timeout
                     completion:(void (^)(NSData *, NSDictionary *, NSError *))completion {
    (void)url;
    (void)method;
    (void)body;
    (void)headers;
    (void)timeout;
    if ([url.path isEqual:@"/form"]) {
        assert([method isEqual:@"POST"]);
        assert([[[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] isEqual:@"a=x%20y"]);
        assert([headers[@"X-Fixture"] isEqual:@"secret"]);
        assert(timeout == 0.5);
    }
    if ([url.path isEqual:@"/multipart"]) {
        NSString *content = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
        assert([content containsString:@"name=\"a\""] && [content containsString:@"hello"]);
        assert([headers[@"Content-Type"] hasPrefix:@"multipart/form-data; boundary="]);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10000000), dispatch_get_main_queue(), ^{
        if ([url.path isEqual:@"/large"]) {
            completion([NSMutableData dataWithLength:2 * 1024 * 1024 + 1], @{}, nil);
            return;
        }
        completion(
            [@"{\"url\":\"https://music.example/song\"}" dataUsingEncoding:NSUTF8StringEncoding],
            @{@"status" : @200,
              @"headers" : @{@"x-test" : @"yes"}},
            nil);
    });
    return [MCRequest new];
}
@end
static void waitFor(BOOL *done) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:12];
    while (!*done && [end timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    assert(*done);
}
static NSString *setup = @"lx.on('request',async "
                         @"({source,info})=>{if(source!=='wy'||info.musicInfo.songmid!=='123456789012345678'|"
                         @"|info.musicInfo.albumId!=='987'||info.musicInfo.img!=='https://img.example/"
                         @"a'||info.musicInfo.interval!=='01:05'||!info.musicInfo.typeUrl)"
                         @"throw Error('mapping');await new Promise(r=>setTimeout(r,2));return "
                         @"'https://music.example/"
                         @"'+info.type});setTimeout(()=>lx.send('inited',{sources:{wy:{type:'music',actions:["
                         @"'musicUrl'],qualitys:['128k','320k']}}}),2);";
static MCLXRuntime *start(NSString *script, BOOL success) {
    MCLXRuntime *r = [[MCLXRuntime alloc] initWithScript:script information:@{}];
    __block BOOL done = NO;
    [r start:^(NSDictionary *sources, NSError *error) {
        assert([NSThread isMainThread]);
        assert(success ? sources != nil && error == nil : error != nil);
        assert(![error.localizedDescription containsString:@"secret"]);
        done = YES;
    }];
    waitFor(&done);
    return r;
}
static void resolve(MCLXRuntime *r, NSString *quality, NSString *suffix) {
    __block BOOL done = NO;
    [r resolveTrack:@{
        @"id" : @"123456789012345678",
        @"title" : @"title",
        @"artist" : @"artist",
        @"albumID" : @"987",
        @"artwork" : @"https://img.example/a",
        @"duration" : @65
    }
        quality:quality
        completion:^(NSDictionary *resource, NSError *error) {
            assert([NSThread isMainThread]);
            if (error)
                fprintf(stderr, "ERROR %s\n", error.description.UTF8String);
            assert(!error);
            assert([resource[@"url"] hasSuffix:suffix]);
            assert(!resource[@"format"]);
            done = YES;
        }];
    waitFor(&done);
}
static uint64_t residentBytes(void) {
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    assert(task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) == KERN_SUCCESS);
    return info.resident_size;
}
static void sourceSecurityRegression(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id saved = [defaults objectForKey:MCSourceHTTPSOnlyKey];
    [defaults removeObjectForKey:MCSourceHTTPSOnlyKey];
    NSString *declaration = @"lx.send('inited',{sources:{wy:{actions:['musicUrl'],qualitys:['128k']}}});";
    for (NSUInteger mode = 0; mode < 4; mode++) {
        MCSetSourceHTTPSOnly(mode != 1);
        NSString *handler = mode < 2    ? @"lx.on('request',()=> 'http://media.test/song');"
                            : mode == 2 ? @"lx.on('request',()=> {throw Error('额度用完 token=secret "
                                          @"https://host.test/?key=hidden')});"
                                        : @"lx.on('request',()=>new "
                                          @"Promise((resolve,reject)=>lx.request('http://test.example/"
                                          @"',{},(e,r,b)=>e?reject(e):resolve(b.url))));";
        MCLXRuntime *runtime = start([handler stringByAppendingString:declaration], YES);
        __block BOOL done = NO;
        [runtime resolveTrack:@{@"id" : @"1"}
                      quality:@"standard"
                   completion:^(NSDictionary *resource, NSError *error) {
                       if (mode == 1)
                           assert(resource && !error && [resource[@"url"] hasPrefix:@"http:"]);
                       else {
                           assert(!resource && error);
                           assert([error.localizedDescription
                               containsString:mode == 2 ? @"额度用完" : @"仅允许 HTTPS"]);
                           assert(![error.localizedDescription containsString:@"secret"]);
                           assert(![error.localizedDescription containsString:@"hidden"]);
                       }
                       done = YES;
                   }];
        waitFor(&done);
        [runtime invalidate];
    }
    MCSetSourceHTTPSOnly(NO);
    MCLXRuntime *runtime =
        start([@"lx.on('request',()=>new "
               @"Promise((resolve,reject)=>lx.request('http://test.example/"
               @"',{},(e,r,b)=>e?reject(e):resolve(b.url))));" stringByAppendingString:declaration],
              YES);
    resolve(runtime, @"standard", @"song");
    [runtime invalidate];
    if (saved)
        [defaults setObject:saved forKey:MCSourceHTTPSOnlyKey];
    else
        [defaults removeObjectForKey:MCSourceHTTPSOnlyKey];
}
static void timerMemoryRegression(void) {
    uint64_t before = residentBytes();
    __weak MCLXRuntime *weak;
    __weak MCLXRuntime *timerWeak;
    @autoreleasepool {
        MCLXRuntime *r =
            start(@"let round=0;function churn(){for(let "
                  @"i=0;i<1000;i++)clearTimeout(setTimeout(()=>{},40000));if(++round<80)setTimeout(churn,0);"
                  @"else lx.send('inited',{sources:{}})}setTimeout(churn,0);",
                  YES);
        timerWeak = r;
        uint64_t after = residentBytes();
        fprintf(stderr, "timer churn RSS growth: %llu KiB\n", (unsigned long long)((after - before) / 1024));
        assert(after < before + 64 * 1024 * 1024);
        [r invalidate];
        r = nil;
        uint64_t cryptoBefore = residentBytes();
        r = start(@"let n=0;function churn(){for(let "
                  @"i=0;i<1000;i++)lx.utils.crypto.md5('a');if(++n<80)setTimeout(churn,0);else "
                  @"lx.send('inited',{sources:{}})}setTimeout(churn,0);",
                  YES);
        uint64_t cryptoAfter = residentBytes();
        fprintf(stderr, "crypto churn RSS growth: %llu KiB\n",
                (unsigned long long)((cryptoAfter - cryptoBefore) / 1024));
        assert(cryptoAfter < cryptoBefore + 32 * 1024 * 1024);
        [r invalidate];
        r = nil;
        r = start(@"for(let i=0;i<128;i++)setTimeout(()=>{throw Error('cancelled timer "
                  @"ran')},40000);lx.send('inited',{sources:{}});",
                  YES);
        weak = r;
        [r invalidate];
        r = nil;
    }
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:2];
    BOOL released = NO;
    while (!released && [end timeIntervalSinceNow] > 0) {
        @autoreleasepool {
            released = (!weak && !timerWeak);
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
        }
    }
    assert(!weak && !timerWeak);
}
int main(void) {
    @autoreleasepool {
        timerMemoryRegression();
        sourceSecurityRegression();
        NSTimeInterval watchdogStart = [NSDate timeIntervalSinceReferenceDate];
        [start(@"void 0;", NO) invalidate];
        assert([NSDate timeIntervalSinceReferenceDate] - watchdogStart >= 9.9);
        [start(
            @"if(lx.utils.buffer.bufToString(lx.utils.crypto.rsaEncrypt(lx.utils.buffer.from('abc'),\"-----"
            @"BEGIN PUBLIC "
            @"KEY-----"
            @"\\nMIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDF5GaXMwXBzdcJxsMkTvITKBej\\n39VrcFtJtBwl9MRU1BJUmE4Di"
            @"jOxbU2Z20CO4U/"
            @"K97GMhqW4eJGEzhC+LhLom5Wi\\nN+YSiHpeGfwGBkeyZjBf8AAz0btPFV4g7W6CmgeabFL0ZkrkOAIOzAo11qVbj/"
            @"Fi\\neLePuMNgyv68lBXNdQIDAQAB\\n-----END PUBLIC "
            @"KEY-----\\n\"),'hex')!=="
            @"\"7d8911724a8e4c6626a359beced528940477e3a7f565944d30c05bb2dfe02ea288eaf0774ef26bdf02d4063c208f1"
            @"7f5cefc1ff7efa6b88c386877fb95a933eba55493f9e2bc0d0d95ed3c3c61028c5aa0d24bfbe21070bfed8de39cae1d"
            @"fb160be2d4cc1b65a62b73cd32dd1dace828f83253fb16d5c4872c9ebc6f09621070\")throw Error('RSA "
            @"vector');lx.send('inited',{sources:{wy:{actions:['musicUrl'],qualitys:['128k']}}});",
            YES) invalidate];
        MCLXRuntime *r = start(setup, YES);
        resolve(r, @"lossless", @"320k");
        resolve(r, @"standard", @"128k");
        [r invalidate];
        r = start(
            @"const u=lx.utils; if(u.crypto.md5('abc')!=='900150983cd24fb0d6963f7d28e17f72')throw "
            @"Error('md5');if(u.buffer.bufToString(u.buffer.from('YWJj','base64'),'hex')!=='616263')throw "
            @"Error('buffer');if(u.buffer.bufToString(u.crypto.aesEncrypt(u.buffer.from('abc'),'aes-128-cbc',"
            @"u.buffer.from('0123456789abcdef'),u.buffer.from('0123456789abcdef')),'hex')!=='"
            @"a0e69686d97ad28fde5a4f3d3eeb455b')throw Error('aes'); (async()=>{let "
            @"b=u.buffer.from('hello');let z=await u.zlib.deflate(b);if(u.buffer.bufToString(await "
            @"u.zlib.inflate(z))!=='hello')throw Error('zlib');lx.on('request',()=>new "
            @"Promise((res,rej)=>lx.request('https://test.example/"
            @"',{},(e,r,b)=>{if(e||r.statusCode!==200||r.headers['x-test']!=='yes'||b.url!==r.body.url)"
            @"return "
            @"rej(Error('http'));res(b.url)})));lx.send('inited',{sources:{wy:{actions:['musicUrl'],qualitys:"
            @"['128k']}}})})();",
            YES);
        resolve(r, @"standard", @"song");
        [r invalidate];
        [start(@"Promise.reject(Error('unhandled'));Promise.reject(Error('handled')).catch(()=>{});lx.send('"
               @"inited',{sources:{}});",
               NO) invalidate];
        [start(@"lx.send('inited',{sources:{}});throw Error('https://secret/token');", NO) invalidate];
        [start(@"Promise.resolve().then(function again(){return Promise.resolve().then(again)});", NO)
            invalidate];
        [start(@"function recurse(){return recurse()}recurse();", NO) invalidate];
        [start(@"let count=0;const abort=lx.request('https://test.example/',{},e=>{if(!e)throw "
               @"Error('cancel');count++});abort();abort();setTimeout(()=>{if(count!==1)throw Error('late "
               @"callback');lx.send('inited',{sources:{}})},30);",
               YES) invalidate];
        [start(@"let aborts=[];for(let "
               @"i=0;i<4;i++)aborts.push(lx.request('https://test.example/',{},()=>{}));let "
               @"bounded=false;try{lx.request('https://test.example/"
               @"',{},()=>{})}catch(e){bounded=true}aborts.forEach(a=>a());if(!bounded)throw "
               @"Error('concurrency');lx.send('inited',{sources:{}});",
               YES) invalidate];
        [start(
            @"let ran=false;const "
            @"t=setTimeout(()=>{ran=true},1);clearTimeout(t);setTimeout(()=>{if(ran)throw Error('clear');let "
            @"b=lx.utils.buffer;let c=lx.utils.crypto;if(c.randomBytes(32).length!==32)throw "
            @"Error('random');lx.utils.zlib.deflate(b.from('hello')).then(z=>{if(b.bufToString(z,'hex')!=='"
            @"789ccb48cdc9c90700062c0215')throw Error('deflate "
            @"vector');lx.send('inited',{sources:{}})})},3);",
            YES) invalidate];
        [start(@"const q=(path,options)=>new "
               @"Promise((resolve,reject)=>lx.request('https://test.example/"
               @"'+path,options,(e,r,b)=>e?reject(e):resolve(b)));(async()=>{await "
               @"q('form',{method:'POST',headers:{'X-Fixture':'secret'},form:{a:'x y'},timeout:500});await "
               @"q('multipart',{method:'POST',formData:{a:'hello'}});let bounded=false;try{await "
               @"q('large',{})}catch(e){bounded=true}if(!bounded)throw Error('large "
               @"response');lx.send('inited',{sources:{}})})();",
               YES) invalidate];
        [start(@"lx.on('request',async()=> "
               @"'https://test.example/"
               @"').then(()=>lx.send('inited',{sources:{wy:{type:'music',actions:['musicUrl'],qualitys:['"
               @"128k']}}}));",
               YES) invalidate];
        [start(@"lx.send('inited',{sources:{wy:'bad'}});", NO) invalidate];
        [start(@"lx.send('inited',{sources:{wy:{type:'process',actions:['musicUrl'],qualitys:['128k']}}});",
               NO) invalidate];
        [start(@"lx.send('inited',{sources:{wy:{actions:'musicUrl',qualitys:['128k']}}});", NO) invalidate];
        [start(@"let = ;", NO) invalidate];
        [start(@"while(true){}", NO) invalidate];
        [start(@"let a=[];while(true)a.push(new Uint8Array(1024*1024));", NO) invalidate];
        [start([@" " stringByPaddingToLength:1024 * 1024 + 1 withString:@" " startingAtIndex:0], NO)
            invalidate];
        [start(@"setTimeout(()=>{throw Error('https://secret/token')},1)", NO) invalidate];
        NSMutableData *expanded = [NSMutableData dataWithLength:2 * 1024 * 1024 + 1];
        uLongf compressedLength = compressBound((uLong)expanded.length);
        NSMutableData *compressed = [NSMutableData dataWithLength:compressedLength];
        assert(compress2(compressed.mutableBytes, &compressedLength, expanded.bytes, (uLong)expanded.length,
                         9) == Z_OK);
        compressed.length = compressedLength;
        NSString *bomb =
            [NSString stringWithFormat:@"lx.utils.zlib.inflate(lx.utils.buffer.from('%@','base64')).then(()=>"
                                       @"{throw Error('missing cap')},()=>lx.send('inited',{sources:{}}));",
                                       [compressed base64EncodedStringWithOptions:0]];
        [start(bomb, YES) invalidate];
        r = start(setup, YES);
        __block BOOL done = NO;
        MCSourceTask *task = [r resolveTrack:@{@"id" : @"123456789012345678"}
                                     quality:@"standard"
                                  completion:^(NSDictionary *resource, NSError *error) {
                                      assert(!resource && error);
                                      done = YES;
                                  }];
        [task cancel];
        waitFor(&done);
        [r invalidate];
        r = start(setup, YES);
        done = NO;
        [r resolveTrack:@{@"id" : @"123456789012345678"}
                quality:@"standard"
             completion:^(NSDictionary *resource, NSError *error) {
                 assert(!resource && error);
                 done = YES;
             }];
        [r invalidate];
        waitFor(&done);
        puts("lx runtime assertions passed");
    }
    return 0;
}
