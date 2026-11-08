#import "MCEncoding.h"
#import "MCSourceRepository.h"
#import "MCMusicSources.h"
#import "MCHTTPClient.h"
#include <math.h>

NSString *const MCSourceRepositoryDidChangeNotification = @"MCSourceRepositoryDidChangeNotification";
static NSError *MCRFailure(NSString *text) {
    return [NSError errorWithDomain:@"MCSourceRepository"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey : text}];
}
static NSTimeInterval MCRTime(id value) {
    double time = [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : 0;
    return isfinite(time) && time > 0 ? time : 0;
}
static NSDictionary *MCRItem(id value) {
    if (![value isKindOfClass:[NSDictionary class]])
        return nil;
    NSDictionary *subscription = MCValidatedSourceSubscription(@{
        @"provider" : @"pdone/lx-music-source",
        @"path" : value[@"path"] ?: @"",
        @"blobSHA" : value[@"sha"] ?: @""
    });
    id size = value[@"size"];
    if (!subscription || ![size isKindOfClass:[NSNumber class]] || !isfinite([size doubleValue]) ||
        [size doubleValue] <= 0 || [size doubleValue] > 1024 * 1024 ||
        [size doubleValue] != [size unsignedLongLongValue])
        return nil;
    return @{
        @"path" : subscription[@"path"],
        @"sha" : subscription[@"blobSHA"],
        @"size" : size,
        @"name" : [subscription[@"path"] componentsSeparatedByString:@"/"][0]
    };
}
@interface MCSourceRepository ()
@property (nonatomic, copy) NSString *directory;
@property (nonatomic, strong) MCMusicSources *sources;
@property (nonatomic, copy) NSTimeInterval (^clock)(void);
@property (nonatomic, readwrite, copy) NSArray *catalog;
@property (nonatomic, readwrite, copy) NSString *statusText;
@property (nonatomic, readwrite, copy) NSDictionary *errors;
@property (nonatomic, readwrite) NSTimeInterval lastSuccessfulCheck;
@property (nonatomic) NSTimeInterval lastAttempt;
@property (nonatomic) NSTimeInterval lastManual;
@property (nonatomic, strong) MCSourceTask *operation;
@end
@implementation MCSourceRepository
+ (NSArray *)downloadRoutes {
    return @[
        @"GitHub", @"ghproxy.net", @"gh.llkk.cc", @"github.moeyy.xyz", @"ghproxy.cn", @"gh.api.99988866.xyz",
        @"ghp.ci", @"gh-proxy.org"
    ];
}
+ (instancetype)sharedRepository {
    static MCSourceRepository *repository;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *base = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask,
                                                              YES) firstObject];
        repository = [[self alloc] initWithDirectory:[base stringByAppendingPathComponent:@"SourceRepository"]
                                             sources:[MCMusicSources sharedSources]
                                               clock:^{
                                                   return [[NSDate date] timeIntervalSince1970];
                                               }];
    });
    return repository;
}
- (instancetype)initWithDirectory:(NSString *)directory
                          sources:(MCMusicSources *)sources
                            clock:(NSTimeInterval (^)(void))clock {
    if ((self = [super init])) {
        _directory = [directory copy];
        _sources = sources;
        _clock = [clock copy];
        _autoSyncEnabled = YES;
        _downloadRoute = @"GitHub";
        _catalog = @[];
        _errors = @{};
        _statusText = @"尚未同步仓库音源";
        NSFileManager *files = [NSFileManager defaultManager];
        [files createDirectoryAtPath:directory
            withIntermediateDirectories:YES
                             attributes:@{
                                 NSFileProtectionKey : NSFileProtectionCompleteUntilFirstUserAuthentication
                             }
                                  error:NULL];
        NSString *path = [directory stringByAppendingPathComponent:@"repository.json"];
        NSDictionary *attrs = [files attributesOfItemAtPath:path error:NULL];
        NSData *data = [attrs[NSFileType] isEqual:NSFileTypeRegular] &&
                               [attrs[NSFileSize] unsignedLongLongValue] <= 2 * 1024 * 1024
                           ? [NSData dataWithContentsOfFile:path]
                           : nil;
        id state = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if ([state isKindOfClass:[NSDictionary class]] && [state[@"version"] isEqual:@1]) {
            if ([state[@"automatic"] isKindOfClass:[NSNumber class]])
                _autoSyncEnabled = [state[@"automatic"] boolValue];
            if ([[[self class] downloadRoutes] containsObject:state[@"downloadRoute"] ?: @""])
                _downloadRoute = [state[@"downloadRoute"] copy];
            _lastSuccessfulCheck = MCRTime(state[@"success"]);
            _lastAttempt = MCRTime(state[@"attempt"]);
            NSMutableArray *items = [NSMutableArray array];
            NSMutableSet *seen = [NSMutableSet set];
            if ([state[@"catalog"] isKindOfClass:[NSArray class]] && [state[@"catalog"] count] <= 100)
                for (id value in state[@"catalog"]) {
                    NSDictionary *item = MCRItem(value);
                    if (item && ![seen containsObject:item[@"path"]]) {
                        [items addObject:item];
                        [seen addObject:item[@"path"]];
                    }
                }
            _catalog = [items copy];
            if ([state[@"summary"] isKindOfClass:[NSString class]] && [state[@"summary"] length] <= 200)
                _statusText = state[@"summary"];
            NSMutableDictionary *errors = [NSMutableDictionary dictionary];
            if ([state[@"errors"] isKindOfClass:[NSDictionary class]] && [state[@"errors"] count] <= 100)
                for (id key in state[@"errors"]) {
                    id message = state[@"errors"][key];
                    if ([key isKindOfClass:[NSString class]] && [key length] <= 80 &&
                        [message isKindOfClass:[NSString class]] && [message length] <= 200)
                        errors[key] = message;
                }
            _errors = [errors copy];
        }
    }
    return self;
}
- (BOOL)save {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{
        @"version" : @1,
        @"automatic" : @(self.autoSyncEnabled),
        @"downloadRoute" : self.downloadRoute,
        @"catalog" : self.catalog,
        @"success" : @(self.lastSuccessfulCheck),
        @"attempt" : @(self.lastAttempt),
        @"summary" : self.statusText,
        @"errors" : self.errors
    }
                                                   options:0
                                                     error:NULL];
    return data.length && data.length <= 2 * 1024 * 1024 &&
           [data writeToFile:[self.directory stringByAppendingPathComponent:@"repository.json"]
                     options:NSDataWritingAtomic |
                             NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication
                       error:NULL];
}
- (void)notify {
    [[NSNotificationCenter defaultCenter] postNotificationName:MCSourceRepositoryDidChangeNotification
                                                        object:self];
}
- (BOOL)busy {
    return self.operation != nil;
}
- (void)setAutoSyncEnabled:(BOOL)enabled {
    BOOL old = _autoSyncEnabled;
    _autoSyncEnabled = enabled;
    if (![self save]) {
        _autoSyncEnabled = old;
        self.statusText = @"无法保存自动同步设置，请检查存储空间";
    }
    [self notify];
}
- (void)setDownloadRoute:(NSString *)route {
    if (![[[self class] downloadRoutes] containsObject:route ?: @""])
        return;
    NSString *old = _downloadRoute;
    _downloadRoute = [route copy];
    if (![self save]) {
        _downloadRoute = old;
        self.statusText = @"无法保存下载方式，请检查存储空间";
    }
    [self notify];
}
+ (NSArray *)catalogFromTree:(id)tree error:(NSError **)error {
    if (![tree isKindOfClass:[NSDictionary class]] || ![tree[@"truncated"] isKindOfClass:[NSNumber class]] ||
        [tree[@"truncated"] boolValue] || ![tree[@"tree"] isKindOfClass:[NSArray class]] ||
        [tree[@"tree"] count] > 10000) {
        if (error)
            *error = MCRFailure(@"仓库目录不完整或无效，已保留缓存目录");
        return nil;
    }
    NSMutableArray *items = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (id value in tree[@"tree"]) {
        if (![value isKindOfClass:[NSDictionary class]] || ![value[@"type"] isEqual:@"blob"] ||
            ![value[@"mode"] isEqual:@"100644"])
            continue;
        NSDictionary *item = MCRItem(value);
        if (!item)
            continue;
        if ([seen containsObject:item[@"path"]] || items.count >= 100) {
            if (error)
                *error = MCRFailure(@"仓库目录重复或超过限制，已保留缓存目录");
            return nil;
        }
        [items addObject:item];
        [seen addObject:item[@"path"]];
    }
    return [items sortedArrayUsingDescriptors:@[ [NSSortDescriptor sortDescriptorWithKey:@"name"
                                                                               ascending:YES] ]];
}
- (NSDictionary *)entryForPath:(NSString *)path {
    for (NSDictionary *entry in self.sources.entries)
        if ([entry[@"subscription"][@"path"] isEqual:path])
            return entry;
    return nil;
}
- (NSString *)statusForItem:(NSDictionary *)item {
    NSString *error = self.errors[item[@"path"]];
    if (error)
        return error;
    NSDictionary *entry = [self entryForPath:item[@"path"]];
    if (!entry)
        return @"轻点导入";
    if (![entry[@"subscription"][@"blobSHA"] isEqual:item[@"sha"]])
        return @"有更新 · 轻点更新";
    return [entry[@"selectable"] boolValue] ? @"已导入 · 最新" : @"已导入 · 不支持当前曲库";
}
- (MCSourceTask *)begin:(NSString *)text manual:(BOOL)manual {
    if (self.busy)
        return nil;
    NSTimeInterval now = self.clock();
    if (manual && self.lastManual > 0 && now - self.lastManual < 5 && now >= self.lastManual) {
        self.statusText = @"操作过于频繁，请稍后重试";
        [self notify];
        return nil;
    }
    if (manual)
        self.lastManual = now;
    self.operation = [[MCSourceTask alloc] initWithCancellation:nil];
    self.statusText = text;
    [self notify];
    return self.operation;
}
- (BOOL)current:(MCSourceTask *)task {
    return task && self.operation == task && !task.cancelled;
}
- (void)finish:(MCSourceTask *)task text:(NSString *)text {
    if (![self current:task])
        return;
    task.cancellation = nil;
    self.operation = nil;
    self.statusText = text;
    if (![self save])
        self.statusText = [text stringByAppendingString:@"；同步记录未能保存"];
    [self notify];
}
- (void)fetchCatalog:(MCSourceTask *)task completion:(void (^)(NSError *))completion {
    MCRequest *request = [[MCHTTPClient sharedClient]
        sourceRequestURL:[NSURL URLWithString:@"https://api.github.com/repos/pdone/lx-music-source/git/trees/"
                                              @"main?recursive=1"]
                  method:@"GET"
                    body:nil
                 headers:@{@"Accept" : @"application/vnd.github+json"}
                 timeout:40
              completion:^(NSData *data, NSDictionary *response, NSError *error) {
                  dispatch_async(dispatch_get_main_queue(), ^{
                      if (![self current:task])
                          return;
                      if (error || [response[@"status"] integerValue] != 200 || !data.length ||
                          data.length > 2 * 1024 * 1024) {
                          NSInteger status = [response[@"status"] integerValue];
                          completion(MCRFailure(status == 403 || status == 429
                                                    ? @"GitHub 限流，已保留缓存目录，请稍后重试"
                                                    : @"仓库连接失败，已保留缓存目录"));
                          return;
                      }
                      id tree = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
                      NSError *failure = nil;
                      NSArray *catalog = [[self class] catalogFromTree:tree error:&failure];
                      if (!catalog) {
                          completion(failure);
                          return;
                      }
                      NSArray *old = self.catalog;
                      self.catalog = catalog;
                      if (![self save]) {
                          self.catalog = old;
                          completion(MCRFailure(@"无法保存目录，已保留缓存目录"));
                          return;
                      }
                      [self notify];
                      completion(nil);
                  });
              }];
    task.cancellation = ^{
        [request cancel];
    };
}
- (void)refreshCatalog {
    MCSourceTask *task = [self begin:@"正在刷新仓库目录…" manual:YES];
    if (!task)
        return;
    [self fetchCatalog:task
            completion:^(NSError *error) {
                [self finish:task
                        text:error.localizedDescription
                                 ?: [NSString stringWithFormat:@"目录已刷新 · %lu 个音源",
                                                               (unsigned long)self.catalog.count]];
            }];
}
- (void)fetchItem:(NSDictionary *)item
           target:(NSDictionary *)target
             task:(MCSourceTask *)task
       completion:(void (^)(NSDictionary *, NSError *))completion {
    /* The immutable Git blob API belongs to the same fixed repository. Its base64
       envelope fits the 2 MiB control limit for a maximum 1 MiB script. */
    BOOL official = [self.downloadRoute isEqual:@"GitHub"];
    NSString *url =
        official ? [@"https://api.github.com/repos/pdone/lx-music-source/git/blobs/"
                       stringByAppendingString:item[@"sha"]]
                 : [NSString
                       stringWithFormat:@"https://%@/raw.githubusercontent.com/pdone/lx-music-source/main/%@",
                                        self.downloadRoute, item[@"path"]];
    MCRequest *request = [[MCHTTPClient sharedClient]
        sourceRequestURL:[NSURL URLWithString:url]
                  method:@"GET"
                    body:nil
                 headers:@{@"Accept" : @"application/vnd.github+json"}
                 timeout:40
              completion:^(NSData *data, NSDictionary *response, NSError *error) {
                  dispatch_async(dispatch_get_main_queue(), ^{
                      if (![self current:task])
                          return;
                      NSInteger status = [response[@"status"] integerValue];
                      if (error || status != 200 || !data.length || data.length > 2 * 1024 * 1024) {
                          completion(nil, MCRFailure(status == 403 || status == 429
                                                         ? @"GitHub 限流，请稍后重试"
                                                         : @"音源下载失败，已保留原配置"));
                          return;
                      }
                      NSData *scriptData = data;
                      if (official) {
                          id blob = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
                          scriptData =
                              [blob isKindOfClass:[NSDictionary class]] &&
                                      [blob[@"encoding"] isEqual:@"base64"] &&
                                      [blob[@"content"] isKindOfClass:[NSString class]] &&
                                      [blob[@"sha"] isEqual:item[@"sha"]] &&
                                      [blob[@"size"] isEqual:item[@"size"]]
                                  ? MCBase64Data(blob[@"content"])
                                  : nil;
                      }
                      if (!scriptData.length || scriptData.length > 1024 * 1024 ||
                          scriptData.length != [item[@"size"] unsignedLongLongValue]) {
                          completion(nil, MCRFailure(@"仓库文件无效或大小变化，请刷新后重试"));
                          return;
                      }
                      if (target) {
                          NSDictionary *current = [self entryForPath:item[@"path"]];
                          if (![current[@"identifier"] isEqual:target[@"identifier"]] ||
                              ![current[@"revision"] isEqual:target[@"revision"]] ||
                              ![current[@"subscription"] isEqual:target[@"subscription"]]) {
                              completion(nil, MCRFailure(@"原音源已删除或更改，本次更新未应用"));
                              return;
                          }
                      }
                      MCSourceTask *inner = [self.sources importScriptData:scriptData
                                                              subscription:@{
                                                                  @"provider" : @"pdone/lx-music-source",
                                                                  @"path" : item[@"path"],
                                                                  @"blobSHA" : item[@"sha"]
                                                              }
                                                       replacingIdentifier:target[@"identifier"]
                                                                completion:completion];
                      if ([self current:task])
                          task.cancellation = ^{
                              [inner cancel];
                          };
                  });
              }];
    task.cancellation = ^{
        [request cancel];
    };
}
- (void)importCatalogItem:(NSDictionary *)item {
    NSDictionary *found = nil;
    for (NSDictionary *value in self.catalog)
        if ([value[@"path"] isEqual:item[@"path"]])
            found = value;
    if (!found)
        return;
    NSDictionary *target = [self entryForPath:found[@"path"]];
    MCSourceTask *task =
        [self begin:[NSString stringWithFormat:@"正在%@ %@…", target ? @"更新" : @"导入", found[@"name"]]
             manual:YES];
    if (!task)
        return;
    [self fetchItem:found
             target:target
               task:task
         completion:^(NSDictionary *entry, NSError *error) {
             if (![self current:task])
                 return;
             NSMutableDictionary *errors = [self.errors mutableCopy];
             if (error)
                 errors[found[@"path"]] = error.localizedDescription;
             else
                 [errors removeObjectForKey:found[@"path"]];
             self.errors = errors;
             [self finish:task
                     text:error ? error.localizedDescription
                                : ([entry[@"selectable"] boolValue] ? @"导入完成，可在音源列表手动选择"
                                                                    : @"已导入，但不支持当前网易云曲库")];
         }];
}
- (void)synchronize {
    [self synchronizeAutomatically:NO];
}
- (void)synchronizeAutomatically:(BOOL)automatic {
    NSMutableArray *targets = [NSMutableArray array];
    for (NSDictionary *entry in self.sources.entries)
        if (entry[@"subscription"])
            [targets addObject:entry];
    if (!targets.count) {
        if (!automatic && !self.busy) {
            self.statusText = @"请先从仓库目录选择并导入音源";
            [self notify];
        }
        return;
    }
    MCSourceTask *task = [self begin:@"正在检查仓库音源更新…" manual:!automatic];
    if (!task)
        return;
    self.lastAttempt = self.clock();
    [self save];
    [self fetchCatalog:task
            completion:^(NSError *error) {
                if (error) {
                    [self finish:task text:error.localizedDescription];
                    return;
                }
                [self syncTargets:targets
                            index:0
                          updated:0
                           errors:[NSMutableDictionary dictionary]
                             task:task];
            }];
}
- (void)syncTargets:(NSArray *)targets
              index:(NSUInteger)index
            updated:(NSUInteger)updated
             errors:(NSMutableDictionary *)errors
               task:(MCSourceTask *)task {
    if (![self current:task])
        return;
    if (index == targets.count) {
        self.errors = errors;
        if (!errors.count)
            self.lastSuccessfulCheck = self.clock();
        [self finish:task
                text:[NSString stringWithFormat:@"同步完成 · 更新 %lu 个 · 失败 %lu 个",
                                                (unsigned long)updated, (unsigned long)errors.count]];
        return;
    }
    NSDictionary *target = targets[index];
    NSString *path = target[@"subscription"][@"path"];
    NSDictionary *item = nil;
    for (NSDictionary *value in self.catalog)
        if ([value[@"path"] isEqual:path])
            item = value;
    NSDictionary *current = [self entryForPath:path];
    NSError *failure = nil;
    if (![current[@"identifier"] isEqual:target[@"identifier"]] ||
        ![current[@"revision"] isEqual:target[@"revision"]] ||
        ![current[@"subscription"] isEqual:target[@"subscription"]])
        failure = MCRFailure(@"原音源已删除或更改，已跳过");
    else if (!item)
        failure = MCRFailure(@"仓库已移除此源，已保留本地旧版");
    BOOL unchanged = [item[@"sha"] isEqual:target[@"subscription"][@"blobSHA"]];
    if (failure || unchanged) {
        if (failure)
            errors[path] = failure.localizedDescription;
        [self syncTargets:targets index:index + 1 updated:updated errors:errors task:task];
        return;
    }
    self.statusText = [NSString stringWithFormat:@"正在更新 %@（%lu/%lu）…", item[@"name"],
                                                 (unsigned long)(index + 1), (unsigned long)targets.count];
    [self notify];
    [self fetchItem:item
             target:target
               task:task
         completion:^(NSDictionary *entry, NSError *error) {
             if (![self current:task])
                 return;
             if (error)
                 errors[path] = error.localizedDescription;
             NSUInteger changed = entry && ![entry[@"revision"] isEqual:target[@"revision"]] ? 1 : 0;
             dispatch_async(dispatch_get_main_queue(), ^{
                 [self syncTargets:targets index:index + 1 updated:updated + changed errors:errors task:task];
             });
         }];
}
- (void)cancel {
    if (!self.operation)
        return;
    [self.operation cancel];
    self.operation = nil;
    self.statusText = @"已取消，已完成的更新已保存";
    [self save];
    [self notify];
}
- (void)applicationDidBecomeActive {
    NSTimeInterval now = self.clock();
    if (!self.autoSyncEnabled || self.busy ||
        (self.lastSuccessfulCheck > 0 && now - self.lastSuccessfulCheck < 24 * 3600) ||
        (self.lastAttempt > 0 && now - self.lastAttempt < 15 * 60))
        return;
    [self synchronizeAutomatically:YES];
}
- (void)dealloc {
    [_operation cancel];
}
@end
