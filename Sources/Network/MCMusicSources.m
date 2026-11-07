#import "MCMusicSources.h"
#import "MCSourceAPI.h"
#import "MCLXRuntime.h"
#import "MCAPI.h"
#import "MCHTTPClient.h"
#import <CommonCrypto/CommonDigest.h>
NSString *const MCMusicSourcesDidChangeNotification = @"MCMusicSourcesDidChangeNotification";
static NSError *MCSR(NSString *s) {
    return [NSError errorWithDomain:@"MCMusicSources" code:1 userInfo:@{NSLocalizedDescriptionKey : s}];
}
static NSError *MCSRuntimeError(NSError *error, NSString *fallback) {
    NSString *text = error.localizedDescription;
    if ([error.domain isEqual:@"MCLXRuntime"] && text.length && text.length <= 200)
        return [NSError errorWithDomain:@"MCLXRuntime"
                                   code:error.code
                               userInfo:@{NSLocalizedDescriptionKey : text}];
    return MCSR(fallback);
}
static NSString *MCSDigest(NSData *data) {
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, bytes);
    NSMutableString *s = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(bytes); i++)
        [s appendFormat:@"%02x", bytes[i]];
    return s;
}
static BOOL MCSHex(id value, NSUInteger length) {
    return
        [value isKindOfClass:[NSString class]] && [value length] == length &&
        [value
            rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"]
                                        invertedSet]]
                .location == NSNotFound;
}
NSDictionary *MCValidatedSourceSubscription(id value) {
    if (![value isKindOfClass:[NSDictionary class]] ||
        ![value[@"provider"] isEqual:@"pdone/lx-music-source"] || !MCSHex(value[@"blobSHA"], 40) ||
        ![value[@"path"] isKindOfClass:[NSString class]])
        return nil;
    NSArray *parts = [value[@"path"] componentsSeparatedByString:@"/"];
    if (parts.count != 2 || ![parts[1] isEqual:@"latest.js"] || ![parts[0] length] ||
        [parts[0] length] > 64 ||
        [parts[0]
            rangeOfCharacterFromSet:
                [[NSCharacterSet characterSetWithCharactersInString:
                                     @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"]
                    invertedSet]]
                .location != NSNotFound)
        return nil;
    return
        @{@"provider" : @"pdone/lx-music-source", @"path" : value[@"path"], @"blobSHA" : value[@"blobSHA"]};
}
NSString *MCSourceGitBlobSHA(NSData *data) {
    NSData *header = [[NSString stringWithFormat:@"blob %lu", (unsigned long)data.length]
        dataUsingEncoding:NSUTF8StringEncoding];
    CC_SHA1_CTX context;
    CC_SHA1_Init(&context);
    CC_SHA1_Update(&context, header.bytes, (CC_LONG)header.length);
    const unsigned char zero = 0;
    CC_SHA1_Update(&context, &zero, 1);
    CC_SHA1_Update(&context, data.bytes, (CC_LONG)data.length);
    unsigned char bytes[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1_Final(bytes, &context);
    NSMutableString *result = [NSMutableString string];
    for (NSUInteger n = 0; n < sizeof(bytes); n++)
        [result appendFormat:@"%02x", bytes[n]];
    return result;
}
static BOOL MCSEligible(NSDictionary *sources) {
    NSDictionary *wy = sources[@"wy"];
    return [wy isKindOfClass:[NSDictionary class]] && [wy[@"actions"] isKindOfClass:[NSArray class]] &&
           [wy[@"actions"] containsObject:@"musicUrl"];
}
static NSString *MCSScriptFileName(NSDictionary *entry) {
    if (!MCSHex(entry[@"revision"], 64))
        return nil;
    return [NSString stringWithFormat:@"%@.%@.js", entry[@"identifier"], entry[@"revision"]];
}
static NSDictionary *MCSBuiltin(void) {
    return @{
        @"identifier" : @"netease",
        @"kind" : @"builtin",
        @"name" : @"网易云",
        @"revision" : @"1",
        @"selectable" : @YES
    };
}
static BOOL MCSIdentifier(id s) {
    if (![s isKindOfClass:[NSString class]] || [s length] != 36)
        return NO;
    return [[NSUUID alloc] initWithUUIDString:s] != nil;
}
/* Configuration filenames are derived exclusively from validated UUIDs.
   The index never controls a path used for reading or writing secrets. */
static NSString *MCSAPIFileName(NSDictionary *entry) {
    if (!MCSIdentifier(entry[@"identifier"]) || !MCSIdentifier(entry[@"revision"]))
        return nil;
    return [NSString stringWithFormat:@"%@.%@.api.json", entry[@"identifier"], entry[@"revision"]];
}
static BOOL MCSIsAPIFileName(NSString *name) {
    NSArray *parts = [name componentsSeparatedByString:@"."];
    return parts.count == 4 && MCSIdentifier(parts[0]) && MCSIdentifier(parts[1]) &&
           [parts[2] isEqual:@"api"] && [parts[3] isEqual:@"json"];
}
static void MCSMain(void (^b)(void)) {
    if ([NSThread isMainThread])
        b();
    else
        dispatch_async(dispatch_get_main_queue(), b);
}
@implementation MCSourceTask {
    BOOL _cancelled;
    void (^_cancellation)(void);
}
- (instancetype)initWithCancellation:(void (^)(void))block {
    if ((self = [super init]))
        _cancellation = [block copy];
    return self;
}
- (BOOL)isCancelled {
    @synchronized(self) {
        return _cancelled;
    }
}
- (void (^)(void))cancellation {
    @synchronized(self) {
        return [_cancellation copy];
    }
}
- (void)setCancellation:(void (^)(void))block {
    BOOL invoke = NO;
    @synchronized(self) {
        if (_cancelled)
            invoke = YES;
        else
            _cancellation = [block copy];
    }
    if (invoke && block)
        block();
}
- (void)cancel {
    void (^block)(void) = nil;
    @synchronized(self) {
        if (_cancelled)
            return;
        _cancelled = YES;
        block = _cancellation;
        _cancellation = nil;
    }
    if (block)
        block();
}
@end
@interface MCMusicSources ()
@property (nonatomic, copy) NSString *directory;
@property (nonatomic, copy, readwrite) NSArray *entries;
@property (nonatomic, copy, readwrite) NSString *selectedIdentifier;
@property (nonatomic, strong) MCLXRuntime *runtime;
@property (nonatomic, copy) NSString *runtimeKey;
@property (nonatomic) BOOL runtimeReady;
@property (nonatomic, copy) NSString *recoveryNotice;
@end
@implementation MCMusicSources
+ (instancetype)sharedSources {
    static MCMusicSources *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *base = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask,
                                                              YES) firstObject];
        s = [[self alloc] initWithDirectory:[base stringByAppendingPathComponent:@"MusicSources"]];
    });
    return s;
}
- (instancetype)initWithDirectory:(NSString *)directory {
    if ((self = [super init])) {
        _directory = [directory copy];
        _entries = @[ MCSBuiltin() ];
        _selectedIdentifier = @"netease";
        [[NSFileManager defaultManager]
                  createDirectoryAtPath:directory
            withIntermediateDirectories:YES
                             attributes:@{
                                 NSFileProtectionKey : NSFileProtectionCompleteUntilFirstUserAuthentication
                             }
                                  error:NULL];
        NSData *d = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"index.json"]
                                           options:NSDataReadingMappedIfSafe
                                             error:NULL];
        if ([[NSFileManager defaultManager]
                fileExistsAtPath:[directory stringByAppendingPathComponent:@"index.json"]])
            _recoveryNotice = @"已恢复可用的音源配置；失效的当前音源已切回网易云";
        id index = d.length <= 2 * 1024 * 1024 && d.length
                       ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL]
                       : nil;
        BOOL needsMigration = NO;
        if ([index isKindOfClass:[NSDictionary class]] && [index[@"version"] isEqual:@1] &&
            [index[@"entries"] isKindOfClass:[NSArray class]] && [index[@"entries"] count] <= 100) {
            NSMutableArray *valid = [NSMutableArray arrayWithObject:MCSBuiltin()];
            NSMutableSet *seen = [NSMutableSet setWithObject:@"netease"];
            for (id item in index[@"entries"]) {
                if (![item isKindOfClass:[NSDictionary class]] || !MCSIdentifier(item[@"identifier"]) ||
                    [seen containsObject:item[@"identifier"]] ||
                    ![item[@"name"] isKindOfClass:[NSString class]] ||
                    ![item[@"revision"] isKindOfClass:[NSString class]])
                    continue;
                NSMutableDictionary *entry = [item mutableCopy];
                if ([item[@"kind"] isEqual:@"api"]) {
                    NSString *fileName = MCSAPIFileName(item);
                    if (!fileName)
                        continue;
                    NSDictionary *c = nil;
                    if (item[@"configuration"]) {
                        c = [MCSourceAPI validateConfiguration:item[@"configuration"] error:NULL];
                        needsMigration = YES;
                    } else if ([item[@"configurationFile"] isEqual:fileName]) {
                        NSString *path = [directory stringByAppendingPathComponent:fileName];
                        NSDictionary *attributes =
                            [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
                        if ([attributes[NSFileType] isEqual:NSFileTypeRegular] &&
                            [attributes[NSFileSize] unsignedLongLongValue] <= 65536) {
                            NSData *privateData = [NSData dataWithContentsOfFile:path];
                            id object = privateData.length
                                            ? [NSJSONSerialization JSONObjectWithData:privateData
                                                                              options:0
                                                                                error:NULL]
                                            : nil;
                            c = [MCSourceAPI validateConfiguration:object error:NULL];
                        }
                    }
                    if (!c)
                        continue;
                    /* Whitelist metadata rather than forwarding arbitrary saved fields. */
                    entry = [@{
                        @"identifier" : item[@"identifier"],
                        @"revision" : item[@"revision"],
                        @"kind" : @"api",
                        @"name" : c[@"name"],
                        @"configuration" : c,
                        @"selectable" : @YES
                    } mutableCopy];
                } else if ([item[@"kind"] isEqual:@"script"]) {
                    NSString *fileName = MCSScriptFileName(item);
                    if (!fileName || (item[@"scriptFile"] && ![item[@"scriptFile"] isEqual:fileName]))
                        continue;
                    NSString *p = [directory
                        stringByAppendingPathComponent:item[@"scriptFile"]
                                                           ?: [item[@"identifier"]
                                                                  stringByAppendingPathExtension:@"js"]];
                    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:p
                                                                                           error:NULL];
                    if (![attrs[NSFileType] isEqual:NSFileTypeRegular] ||
                        [attrs[NSFileSize] unsignedLongLongValue] > 1024 * 1024)
                        continue;
                    NSData *script = [NSData dataWithContentsOfFile:p];
                    if (!script.length || ![MCSDigest(script) isEqual:item[@"revision"]] ||
                        ![item[@"information"] isKindOfClass:[NSDictionary class]] ||
                        ![item[@"sources"] isKindOfClass:[NSDictionary class]])
                        continue;
                    BOOL eligible = MCSEligible(item[@"sources"]);
                    entry[@"selectable"] = @(eligible);
                    entry[@"reason"] = eligible ? @"" : @"脚本未声明网易云 wy 的 musicUrl 动作";
                    [entry removeObjectForKey:@"subscription"];
                    NSDictionary *subscription = MCValidatedSourceSubscription(item[@"subscription"]);
                    if (subscription)
                        entry[@"subscription"] = subscription;
                } else
                    continue;
                [valid addObject:entry];
                [seen addObject:item[@"identifier"]];
            }
            _entries = [valid copy];
            for (NSDictionary *entry in valid)
                if ([entry[@"identifier"] isEqual:index[@"selectedIdentifier"]] &&
                    [entry[@"selectable"] boolValue])
                    _selectedIdentifier = entry[@"identifier"];
            if (valid.count == [index[@"entries"] count] &&
                [_selectedIdentifier isEqual:index[@"selectedIdentifier"]])
                _recoveryNotice = nil;
        }
        if ((needsMigration || _recoveryNotice) && ![self persistEntries:_entries
                                                               selection:_selectedIdentifier
                                                                   error:NULL])
            _recoveryNotice = @"音源已恢复，但无法保存恢复结果，请检查存储空间";
    }
    return self;
}
- (NSString *)consumeRecoveryNotice {
    NSString *notice = self.recoveryNotice;
    self.recoveryNotice = nil;
    return notice;
}
- (NSDictionary *)selectedEntry {
    for (NSDictionary *e in self.entries)
        if ([e[@"identifier"] isEqual:self.selectedIdentifier])
            return e;
    return MCSBuiltin();
}
- (BOOL)persistEntries:(NSArray *)entries selection:(NSString *)selection error:(NSError **)error {
    NSFileManager *files = [NSFileManager defaultManager];
    NSMutableArray *metadata = [NSMutableArray array];
    NSMutableArray *created = [NSMutableArray array];
    NSMutableSet *retained = [NSMutableSet set];
    BOOL ok = YES;
    for (NSDictionary *entry in entries) {
        if (![entry[@"kind"] isEqual:@"api"]) {
            [metadata addObject:entry];
            if ([entry[@"kind"] isEqual:@"script"])
                [retained addObject:entry[@"scriptFile"]
                                        ?: [entry[@"identifier"] stringByAppendingPathExtension:@"js"]];
            continue;
        }
        NSString *name = MCSAPIFileName(entry);
        if (!name) {
            ok = NO;
            break;
        }
        NSString *path = [self.directory stringByAppendingPathComponent:name];
        NSData *configuration = [NSJSONSerialization dataWithJSONObject:entry[@"configuration"]
                                                                options:0
                                                                  error:NULL];
        if (!configuration || configuration.length > 65536) {
            ok = NO;
            break;
        }
        NSDictionary *attributes = [files attributesOfItemAtPath:path error:NULL];
        if (attributes) {
            /* Existing revisions are immutable; never overwrite a prior secret file. */
            if (![attributes[NSFileType] isEqual:NSFileTypeRegular] ||
                [attributes[NSFileSize] unsignedLongLongValue] > 65536) {
                ok = NO;
                break;
            }
            NSData *oldData = [NSData dataWithContentsOfFile:path];
            id old =
                oldData.length ? [NSJSONSerialization JSONObjectWithData:oldData options:0 error:NULL] : nil;
            if (![old isEqual:entry[@"configuration"]]) {
                ok = NO;
                break;
            }
        } else {
            if (![configuration writeToFile:path
                                    options:NSDataWritingAtomic |
                                            NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication
                                      error:NULL]) {
                ok = NO;
                break;
            }
            [created addObject:path];
        }
        [retained addObject:name];
        [metadata addObject:@{
            @"identifier" : entry[@"identifier"],
            @"kind" : @"api",
            @"name" : entry[@"name"],
            @"revision" : entry[@"revision"],
            @"configurationFile" : name,
            @"selectable" : @YES
        }];
    }
    NSData *data = ok ? [NSJSONSerialization dataWithJSONObject:@{
        @"version" : @1,
        @"entries" : metadata,
        @"selectedIdentifier" : selection
    }
                                                        options:0
                                                          error:NULL]
                      : nil;
    ok = ok && data && data.length <= 2 * 1024 * 1024 &&
         [data
             writeToFile:[self.directory stringByAppendingPathComponent:@"index.json"]
                 options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication
                   error:NULL];
    if (!ok) {
        for (NSString *path in created)
            [files removeItemAtPath:path error:NULL];
        if (error)
            *error = MCSR(@"无法保存音源配置");
        return NO;
    }
    /* Only after committing the new index may obsolete secret revisions go away. */
    for (NSString *name in [files contentsOfDirectoryAtPath:self.directory error:NULL])
        if ((MCSIsAPIFileName(name) || [self isManagedScriptFileName:name]) &&
            ![retained containsObject:name])
            [files removeItemAtPath:[self.directory stringByAppendingPathComponent:name] error:NULL];
    return YES;
}
- (BOOL)isManagedScriptFileName:(NSString *)name {
    NSArray *parts = [name componentsSeparatedByString:@"."];
    return (parts.count == 2 && MCSIdentifier(parts[0]) && [parts[1] isEqual:@"js"]) ||
           (parts.count == 3 && MCSIdentifier(parts[0]) && MCSHex(parts[1], 64) && [parts[2] isEqual:@"js"]);
}
- (void)notify:(NSDictionary *)info {
    MCSMain(^{
        [[NSNotificationCenter defaultCenter] postNotificationName:MCMusicSourcesDidChangeNotification
                                                            object:self
                                                          userInfo:info];
    });
}
- (BOOL)selectIdentifier:(NSString *)identifier error:(NSError **)error {
    NSDictionary *entry = nil;
    for (NSDictionary *e in self.entries)
        if ([e[@"identifier"] isEqual:identifier])
            entry = e;
    if (!entry || ![entry[@"selectable"] boolValue]) {
        if (error)
            *error = MCSR(@"该音源不可选用");
        return NO;
    }
    if (![self persistEntries:self.entries selection:identifier error:error])
        return NO;
    self.selectedIdentifier = identifier;
    [self.runtime invalidate];
    self.runtime = nil;
    self.runtimeKey = nil;
    [self notify:nil];
    return YES;
}
- (BOOL)removeIdentifier:(NSString *)identifier error:(NSError **)error {
    if ([identifier isEqual:@"netease"]) {
        if (error)
            *error = MCSR(@"内置网易云音源不能删除");
        return NO;
    }
    NSMutableArray *next = [self.entries mutableCopy];
    NSDictionary *removed = nil;
    for (NSDictionary *e in self.entries)
        if ([e[@"identifier"] isEqual:identifier])
            removed = e;
    if (!removed) {
        if (error)
            *error = MCSR(@"音源不存在");
        return NO;
    }
    [next removeObject:removed];
    NSString *selection = [self.selectedIdentifier isEqual:identifier] ? @"netease" : self.selectedIdentifier;
    if (![self persistEntries:next selection:selection error:error])
        return NO;
    self.entries = next;
    self.selectedIdentifier = selection;
    if ([self.runtimeKey hasPrefix:[identifier stringByAppendingString:@":"]]) {
        [self.runtime invalidate];
        self.runtime = nil;
        self.runtimeKey = nil;
    }
    [[NSFileManager defaultManager]
        removeItemAtPath:[self.directory
                             stringByAppendingPathComponent:[identifier stringByAppendingPathExtension:@"js"]]
                   error:NULL];
    [self notify:@{@"removedIdentifier" : identifier}];
    return YES;
}
- (NSDictionary *)saveAPIConfiguration:(NSDictionary *)configuration
                            identifier:(NSString *)identifier
                                 error:(NSError **)error {
    NSDictionary *c = [MCSourceAPI validateConfiguration:configuration error:error];
    if (!c)
        return nil;
    NSMutableArray *next = [self.entries mutableCopy];
    NSDictionary *old = nil;
    if (identifier) {
        for (NSDictionary *e in next)
            if ([e[@"identifier"] isEqual:identifier])
                old = e;
        if (![old[@"kind"] isEqual:@"api"]) {
            if (error)
                *error = MCSR(@"API 音源不存在");
            return nil;
        }
        [next removeObject:old];
    } else
        identifier = [[NSUUID UUID] UUIDString];
    if (next.count >= 100) {
        if (error)
            *error = MCSR(@"音源数量超过限制");
        return nil;
    }
    NSDictionary *entry = @{
        @"identifier" : identifier,
        @"kind" : @"api",
        @"name" : c[@"name"],
        @"revision" : [[NSUUID UUID] UUIDString],
        @"configuration" : c,
        @"selectable" : @YES
    };
    [next addObject:entry];
    if (![self persistEntries:next selection:self.selectedIdentifier error:error])
        return nil;
    self.entries = next;
    [self notify:nil];
    return entry;
}
- (MCSourceTask *)importScript:(NSString *)script
                        origin:(NSString *)origin
                    completion:(void (^)(NSDictionary *, NSError *))completion {
    (void)origin;
    return [self importScript:script subscription:nil replacingIdentifier:nil completion:completion];
}
- (MCSourceTask *)importScript:(NSString *)script
                  subscription:(NSDictionary *)subscription
           replacingIdentifier:(NSString *)identifier
                    completion:(void (^)(NSDictionary *, NSError *))completion {
    NSData *data =
        [script isKindOfClass:[NSString class]] ? [script dataUsingEncoding:NSUTF8StringEncoding] : nil;
    return [self importScriptData:data
                     subscription:subscription
              replacingIdentifier:identifier
                       completion:completion];
}
- (MCSourceTask *)importScriptData:(NSData *)data
                      subscription:(NSDictionary *)subscription
               replacingIdentifier:(NSString *)identifier
                        completion:(void (^)(NSDictionary *, NSError *))completion {
    data = [data isKindOfClass:[NSData class]] ? [data copy] : nil;
    MCSourceTask *task = [[MCSourceTask alloc] initWithCancellation:nil];
    MCSMain(^{
        NSDictionary *binding = subscription ? MCValidatedSourceSubscription(subscription) : nil;
        NSDictionary *original = nil;
        for (NSDictionary *entry in self.entries)
            if ([entry[@"identifier"] isEqual:identifier])
                original = entry;
        if ((subscription && !binding) ||
            (identifier && (![original[@"kind"] isEqual:@"script"] || !binding ||
                            ![original[@"subscription"][@"path"] isEqual:binding[@"path"]]))) {
            completion(nil, MCSR(@"订阅无效或原音源已删除"));
            return;
        }
        NSString *script = [data isKindOfClass:[NSData class]] && data.length <= 1024 * 1024
                               ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                               : nil;
        if (!script.length || !data.length || data.length > 1024 * 1024) {
            completion(nil, MCSR(@"脚本必须为不超过 1 MiB 的 UTF-8 文件"));
            return;
        }
        if (binding && ![MCSourceGitBlobSHA(data) isEqual:binding[@"blobSHA"]]) {
            completion(nil, MCSR(@"仓库内容已变化，请刷新目录后重试"));
            return;
        }
        NSString *revision = MCSDigest(data);
        for (NSDictionary *e in self.entries)
            if (!binding && [e[@"kind"] isEqual:@"script"] && [e[@"revision"] isEqual:revision]) {
                if (!task.cancelled)
                    completion(e, nil);
                return;
            }
        NSRange begin = [script rangeOfString:@"/*"];
        NSRange end = begin.location != NSNotFound
                          ? [script rangeOfString:@"*/"
                                          options:0
                                            range:NSMakeRange(begin.location,
                                                              MIN(script.length - begin.location, 16384))]
                          : NSMakeRange(NSNotFound, 0);
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        if (begin.location == NSNotFound || begin.location > 1024 || end.location == NSNotFound) {
            completion(nil, MCSR(@"缺少有效脚本信息头"));
            return;
        }
        NSString *head =
            [script substringWithRange:NSMakeRange(begin.location, end.location - begin.location)];
        for (NSString *line in
             [head componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
            NSRange at = [line rangeOfString:@"@"];
            if (at.location == NSNotFound)
                continue;
            NSString *field = [line substringFromIndex:at.location + 1];
            NSRange space = [field rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]];
            if (space.location == NSNotFound)
                continue;
            NSString *k = [field substringToIndex:space.location];
            NSString *v = [[field substringFromIndex:space.location + 1]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([@[ @"name", @"description", @"version", @"author", @"homepage" ] containsObject:k] &&
                v.length <= 2048)
                info[k] = v;
        }
        if (![info[@"name"] length]) {
            completion(nil, MCSR(@"脚本信息头缺少名称"));
            return;
        }
        if (task.cancelled)
            return;
        MCLXRuntime *runtime = [[MCLXRuntime alloc] initWithScript:script information:info];
        task.cancellation = ^{
            [runtime invalidate];
        };
        [runtime start:^(NSDictionary *sources, NSError *err) {
            MCSMain(^{
                if (task.cancelled) {
                    [runtime invalidate];
                    return;
                }
                task.cancellation = nil;
                [runtime invalidate];
                if (err || ![sources isKindOfClass:[NSDictionary class]]) {
                    completion(nil, MCSRuntimeError(err, @"脚本初始化失败，请检查兼容性"));
                    return;
                }
                NSDictionary *target = nil;
                for (NSDictionary *existing in self.entries) {
                    if (identifier && [existing[@"identifier"] isEqual:identifier])
                        target = existing;
                    if (!identifier && binding &&
                        [existing[@"subscription"][@"path"] isEqual:binding[@"path"]])
                        target = existing;
                }
                if (identifier && (!target || ![target[@"revision"] isEqual:original[@"revision"]] ||
                                   ![target[@"subscription"] isEqual:original[@"subscription"]])) {
                    completion(nil, MCSR(@"原音源已删除或更改，本次更新未应用"));
                    return;
                }
                if (!target)
                    for (NSDictionary *existing in self.entries)
                        if ([existing[@"kind"] isEqual:@"script"] &&
                            [existing[@"revision"] isEqual:revision] &&
                            (!binding || !existing[@"subscription"] ||
                             [existing[@"subscription"][@"path"] isEqual:binding[@"path"]])) {
                            target = existing;
                            break;
                        }
                if (!binding && target) {
                    completion(target, nil);
                    return;
                }
                if (!target && self.entries.count >= 100) {
                    completion(nil, MCSR(@"音源数量超过限制"));
                    return;
                }
                BOOL eligible = MCSEligible(sources);
                if (target && [target[@"selectable"] boolValue] && !eligible) {
                    completion(nil, MCSR(@"新版不再支持当前网易云曲库，已保留旧版"));
                    return;
                }
                NSString *sourceID = target[@"identifier"] ?: [[NSUUID UUID] UUIDString];
                NSMutableDictionary *entry = [@{
                    @"identifier" : sourceID,
                    @"kind" : @"script",
                    @"name" : info[@"name"],
                    @"revision" : revision,
                    @"information" : info,
                    @"sources" : sources,
                    @"selectable" : @(eligible),
                    @"reason" : eligible ? @"" : @"脚本未声明网易云 wy 的 musicUrl 动作"
                } mutableCopy];
                entry[@"scriptFile"] = MCSScriptFileName(entry);
                if (binding)
                    entry[@"subscription"] = binding;
                NSString *path = [self.directory stringByAppendingPathComponent:entry[@"scriptFile"]];
                NSMutableArray *next = [self.entries mutableCopy];
                if (target)
                    [next replaceObjectAtIndex:[next indexOfObject:target] withObject:entry];
                else
                    [next addObject:entry];
                NSError *saveError = nil;
                BOOL existed = [[NSFileManager defaultManager] fileExistsAtPath:path];
                BOOL stored =
                    existed
                        ? [[NSData dataWithContentsOfFile:path] isEqual:data]
                        : [data writeToFile:path
                                    options:NSDataWritingAtomic |
                                            NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication
                                      error:NULL];
                if (!stored || ![self persistEntries:next
                                           selection:self.selectedIdentifier
                                               error:&saveError]) {
                    if (!existed)
                        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
                    completion(nil, saveError ?: MCSR(@"无法保存脚本"));
                    return;
                }
                self.entries = next;
                [self notify:nil];
                completion(entry, nil);
            });
        }];
    });
    return task;
}
- (MCSourceTask *)importScriptURL:(NSURL *)url completion:(void (^)(NSDictionary *, NSError *))completion {
    MCSourceTask *task = [[MCSourceTask alloc] initWithCancellation:nil];
    __block void (^fetch)(NSURL *, NSUInteger);
    __weak MCSourceTask *weakTask = task;
    fetch = ^(NSURL *target, NSUInteger count) {
        MCSourceTask *strongTask = weakTask;
        if (!strongTask || strongTask.cancelled) {
            fetch = nil;
            return;
        }
        if (![target.scheme.lowercaseString isEqual:@"https"] || !target.host.length || target.user ||
            target.password || count > 4) {
            MCSMain(^{
                if (!strongTask.cancelled)
                    completion(nil, MCSR(@"脚本地址必须为 HTTPS，最多允许四次重定向"));
            });
            fetch = nil;
            return;
        }
        MCRequest *request = [[MCHTTPClient sharedClient]
            sourceRequestURL:target
                      method:@"GET"
                        body:nil
                     headers:@{}
                     timeout:40
                  completion:^(NSData *data, NSDictionary *response, NSError *error) {
                      MCSMain(^{
                          if (strongTask.cancelled) {
                              fetch = nil;
                              return;
                          }
                          NSInteger status = [response[@"status"] integerValue];
                          if (!error && status >= 300 && status < 400) {
                              NSString *location = nil;
                              for (NSString *k in response[@"headers"])
                                  if ([k.lowercaseString isEqual:@"location"])
                                      location = response[@"headers"][k];
                              NSURL *relativeURL = [NSURL URLWithString:location ?: @"" relativeToURL:target];
                              NSURL *next = relativeURL.absoluteURL;
                              if (fetch)
                                  fetch(next, count + 1);
                              return;
                          }
                          fetch = nil;
                          if (error || status < 200 || status >= 300 || !data.length ||
                              data.length > 1024 * 1024) {
                              completion(nil, MCSR(@"脚本下载失败或超过 1 MiB 限制"));
                              return;
                          }
                          NSString *script = [[NSString alloc] initWithData:data
                                                                   encoding:NSUTF8StringEncoding];
                          MCSourceTask *inner = [self importScript:script origin:nil completion:completion];
                          strongTask.cancellation = ^{
                              [inner cancel];
                          };
                      });
                  }];
        strongTask.cancellation = ^{
            [request cancel];
        };
    };
    fetch(url, 0);
    return task;
}
- (MCSourceTask *)resolveTrack:(NSDictionary *)track
                       quality:(NSString *)quality
                    completion:(void (^)(NSDictionary *, NSError *))completion {
    MCSourceTask *task = [[MCSourceTask alloc] initWithCancellation:nil];
    NSDictionary *entry = self.selectedEntry;
    void (^finish)(NSDictionary *, NSError *) = ^(NSDictionary *r, NSError *e) {
        MCSMain(^{
            if (task.cancelled)
                return;
            if (r && ![entry[@"kind"] isEqual:@"builtin"]) {
                NSMutableDictionary *resource = [r mutableCopy];
                resource[@"customSource"] = @YES;
                resource[@"sourceIdentifier"] = entry[@"identifier"];
                resource[@"sourceRevision"] = entry[@"revision"];
                completion(resource, e);
            } else
                completion(r, e);
        });
    };
    if ([entry[@"kind"] isEqual:@"builtin"]) {
        [[MCAPI sharedAPI] songURL:track[@"id"] quality:quality completion:finish];
        return task;
    }
    if ([entry[@"kind"] isEqual:@"api"]) {
        MCSourceTask *inner = [MCSourceAPI resolveConfiguration:entry[@"configuration"]
                                                          track:track
                                                        quality:quality
                                                     completion:finish];
        task.cancellation = ^{
            [inner cancel];
        };
        return task;
    }
    NSString *key = [NSString stringWithFormat:@"%@:%@", entry[@"identifier"], entry[@"revision"]];
    MCLXRuntime *runtime = self.runtime;
    BOOL ready = self.runtimeReady && [key isEqual:self.runtimeKey];
    if (!ready) {
        /* Retain an old runtime through its pending callbacks. An update changes
           future resolutions without cancelling the original revision's request. */
        NSString *script = [NSString
            stringWithContentsOfFile:[self.directory stringByAppendingPathComponent:
                                                         entry[@"scriptFile"]
                                                             ?: [entry[@"identifier"]
                                                                    stringByAppendingPathExtension:@"js"]]
                            encoding:NSUTF8StringEncoding
                               error:NULL];
        runtime = [[MCLXRuntime alloc] initWithScript:script ?: @"" information:entry[@"information"]];
        self.runtime = runtime;
        self.runtimeKey = key;
        self.runtimeReady = NO;
    }
    void (^discard)(void) = ^{
        [runtime invalidate];
        MCSMain(^{
            if (self.runtime == runtime) {
                self.runtime = nil;
                self.runtimeKey = nil;
                self.runtimeReady = NO;
            }
        });
    };
    void (^resolve)(void) = ^{
        if (task.cancelled)
            return;
        MCSourceTask *inner =
            [runtime resolveTrack:track
                          quality:quality
                       completion:^(NSDictionary *r, NSError *e) {
                           if (e)
                               discard();
                           task.cancellation = nil;
                           finish(r, e ? MCSRuntimeError(e, @"脚本解析失败，请检查音源兼容性") : nil);
                       }];
        task.cancellation = ^{
            [inner cancel];
            discard();
        };
    };
    task.cancellation = discard;
    if (ready)
        resolve();
    else
        [runtime start:^(NSDictionary *sources, NSError *error) {
            (void)sources;
            if (task.cancelled)
                return;
            if (error) {
                discard();
                task.cancellation = nil;
                finish(nil, MCSRuntimeError(error, @"脚本初始化失败"));
                return;
            }
            if (self.runtime == runtime)
                self.runtimeReady = YES;
            resolve();
        }];
    return task;
}
- (void)dealloc {
    [_runtime invalidate];
}
@end
