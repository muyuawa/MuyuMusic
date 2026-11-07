#import <Foundation/Foundation.h>
#import "MCMusicSources.h"
#import "MCSourceRepository.h"
#import "MCLXRuntime.h"
#import "MCHTTPClient.h"
#import "MCAPI.h"

static unsigned checks;
#define CHECK(...)                                                                                           \
    do {                                                                                                     \
        checks++;                                                                                            \
        if (!(__VA_ARGS__)) {                                                                                \
            fprintf(stderr, "repository line %d: %s\n", __LINE__, #__VA_ARGS__);                             \
            exit(1);                                                                                         \
        }                                                                                                    \
    } while (0)
static void Wait(BOOL (^done)(void)) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!done() && end.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
    CHECK(done());
}
static NSData *Bytes(NSString *text) {
    return [text dataUsingEncoding:NSUTF8StringEncoding];
}
static NSData *JSON(id object) {
    return [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
}
static NSString *Fixture(NSString *marker) {
    return [@"/**\n * @name Repository fixture\n * @version 1.0\n */\n" stringByAppendingString:marker];
}
static BOOL holdInitialization;
static void (^pendingInitialization)(void);
@interface MCLXRuntime ()
@property (nonatomic, copy) NSString *fixture;
@end
@implementation MCLXRuntime
- (instancetype)initWithScript:(NSString *)s information:(NSDictionary *)i {
    if ((self = [super init]))
        self.fixture = s;
    return self;
}
- (void)start:(void (^)(NSDictionary *, NSError *))completion {
    void (^reply)(void) = ^{
        if ([self.fixture containsString:@"fail-init"])
            completion(nil, [NSError errorWithDomain:@"fixture" code:1 userInfo:nil]);
        else
            completion(@{
                [self.fixture containsString:@"unsupported"]
                    ? @"tx"
                    : @"wy" : @{@"actions" : @[ @"musicUrl" ], @"qualitys" : @[ @"128k" ]}
            },
                       nil);
    };
    if (holdInitialization)
        pendingInitialization = reply;
    else
        reply();
}
- (MCSourceTask *)resolveTrack:(NSDictionary *)track
                       quality:(NSString *)quality
                    completion:(void (^)(NSDictionary *, NSError *))completion {
    completion(@{@"url" : @"https://fixture.test/media"}, nil);
    return [[MCSourceTask alloc] initWithCancellation:nil];
}
- (void)invalidate {
}
@end
@implementation MCAPI
+ (instancetype)sharedAPI {
    return [self new];
}
- (void)songURL:(NSString *)identifier quality:(NSString *)quality completion:(MCAPICompletion)completion {
    completion(@{@"url" : @"https://music.126.net/fixture"}, nil);
}
@end
@interface MCRequest ()
@property (nonatomic) BOOL fixtureCancelled;
@end
@implementation MCRequest
- (void)cancel {
    self.fixtureCancelled = YES;
}
@end
static NSMutableDictionary *replies;
static NSMutableArray *requested;
static BOOL holdNetwork;
static NSMutableArray *pendingNetwork;
static NSString *const TreeURL =
    @"https://api.github.com/repos/pdone/lx-music-source/git/trees/main?recursive=1";
static NSString *BlobURL(NSString *sha) {
    return [@"https://api.github.com/repos/pdone/lx-music-source/git/blobs/" stringByAppendingString:sha];
}
@implementation MCHTTPClient
+ (instancetype)sharedClient {
    return [self new];
}
- (MCRequest *)sourceRequestURL:(NSURL *)url
                         method:(NSString *)method
                           body:(NSData *)body
                        headers:(NSDictionary *)headers
                        timeout:(NSTimeInterval)timeout
                     completion:(void (^)(NSData *, NSDictionary *, NSError *))completion {
    CHECK([method isEqual:@"GET"] && !body && !headers[@"Cookie"] && !headers[@"Authorization"]);
    CHECK([url.absoluteString isEqual:TreeURL] || [url.absoluteString hasPrefix:BlobURL(@"")] ||
          [url.absoluteString
              hasPrefix:@"https://ghproxy.net/raw.githubusercontent.com/pdone/lx-music-source/main/"]);
    [requested addObject:url.absoluteString];
    NSDictionary *reply = replies[url.absoluteString] ?: @{@"status" : @503};
    MCRequest *request = [MCRequest new];
    void (^deliver)(void) = ^{
        if (!request.fixtureCancelled)
            completion(reply[@"data"], @{@"status" : reply[@"status"] ?: @200}, nil);
    };
    if (holdNetwork)
        [pendingNetwork addObject:[deliver copy]];
    else
        deliver();
    return request;
}
@end
static NSDictionary *Item(NSString *path, NSData *data) {
    return @{
        @"path" : path,
        @"sha" : MCSourceGitBlobSHA(data),
        @"size" : @(data.length),
        @"type" : @"blob",
        @"mode" : @"100644"
    };
}
static void SetTree(NSArray *items) {
    replies[TreeURL] = @{@"data" : JSON(@{@"truncated" : @NO, @"tree" : items}), @"status" : @200};
}
static void SetScript(NSString *path, NSString *script) {
    NSData *data = Bytes(script);
    NSString *sha = MCSourceGitBlobSHA(data);
    replies[BlobURL(sha)] = @{
        @"data" : JSON(@{
            @"encoding" : @"base64",
            @"sha" : sha,
            @"size" : @(data.length),
            @"content" : [data base64EncodedStringWithOptions:0]
        }),
        @"status" : @200
    };
}
static NSDictionary *Binding(NSString *path, NSData *data) {
    return @{@"provider" : @"pdone/lx-music-source", @"path" : path, @"blobSHA" : MCSourceGitBlobSHA(data)};
}
static NSDictionary *Import(MCMusicSources *sources, NSString *script, NSDictionary *binding,
                            NSString *identifier, BOOL ok) {
    __block BOOL done = NO;
    __block NSDictionary *entry;
    [sources importScript:script
               subscription:binding
        replacingIdentifier:identifier
                 completion:^(NSDictionary *e, NSError *error) {
                     CHECK([NSThread isMainThread]);
                     CHECK(ok ? e && !error : !e && error);
                     entry = e;
                     done = YES;
                 }];
    Wait(^BOOL {
        return done;
    });
    return entry;
}
static void DrainOne(void) {
    CHECK(pendingNetwork.count > 0);
    void (^reply)(void) = pendingNetwork[0];
    [pendingNetwork removeObjectAtIndex:0];
    reply();
}
int main(void) {
    @autoreleasepool {
        CHECK([MCSourceGitBlobSHA(Bytes(@"hello\n")) isEqual:@"ce013625030ba8dba906f756967f9e9ca394464a"]);
        NSString *v1 = Fixture(@"version-one"), *v2 = Fixture(@"version-two");
        NSDictionary *i1 = Item(@"flower/latest.js", Bytes(v1)), *i2 = Item(@"flower/latest.js", Bytes(v2));
        CHECK(MCValidatedSourceSubscription(Binding(@"flower/latest.js", Bytes(v1))) != nil);
        for (NSString *path in @[
                 @"../latest.js", @"flower/sub/latest.js", @"/flower/latest.js", @"flower%2Flatest.js",
                 @"flower/Latest.js"
             ])
            CHECK(!MCValidatedSourceSubscription(Binding(path, Bytes(v1))));
        NSArray *catalog = [MCSourceRepository catalogFromTree:@{
            @"truncated" : @NO,
            @"tree" : @[
                i1, Item(@"../latest.js", Bytes(v1)), Item(@"deep/a/latest.js", Bytes(v1)),
                @{
                    @"path" : @"symlink/latest.js",
                    @"sha" : i1[@"sha"],
                    @"size" : @10,
                    @"type" : @"blob",
                    @"mode" : @"120000"
                },
                @{
                    @"path" : @"big/latest.js",
                    @"sha" : i1[@"sha"],
                    @"size" : @(1024 * 1024 + 1),
                    @"type" : @"blob",
                    @"mode" : @"100644"
                },
                @"bad"
            ]
        }
                                                         error:NULL];
        CHECK(catalog.count == 1 && [catalog[0][@"path"] isEqual:@"flower/latest.js"] && !catalog[0][@"url"]);
        CHECK(![MCSourceRepository catalogFromTree:@{@"truncated" : @YES, @"tree" : @[ i1 ]} error:NULL]);
        CHECK(![MCSourceRepository catalogFromTree:@{@"tree" : @[ i1 ]} error:NULL]);
        CHECK(![MCSourceRepository catalogFromTree:@{@"truncated" : @NO, @"tree" : @[ i1, i1 ]} error:NULL]);
        CHECK(![MCSourceRepository catalogFromTree:@"invalid" error:NULL]);

        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSString *sourceDir = [root stringByAppendingPathComponent:@"sources"];
        MCMusicSources *sources = [[MCMusicSources alloc] initWithDirectory:sourceDir];
        for (NSString *prefix in @[ @"/*", @"/*!" ]) {
            NSString *variant = [v1 stringByReplacingOccurrencesOfString:@"/**" withString:prefix];
            NSDictionary *variantEntry = Import(sources, variant, nil, nil, YES);
            CHECK([variantEntry[@"information"][@"version"] isEqual:@"1.0"]);
            CHECK([sources removeIdentifier:variantEntry[@"identifier"] error:NULL]);
        }
        NSDictionary *local = Import(sources, v1, nil, nil, YES);
        NSDictionary *bound = Import(sources, v1, Binding(@"flower/latest.js", Bytes(v1)), nil, YES);
        CHECK(sources.entries.count == 2 && [bound[@"identifier"] isEqual:local[@"identifier"]]);
        CHECK([sources.selectedIdentifier isEqual:@"netease"]);
        CHECK([sources selectIdentifier:bound[@"identifier"] error:NULL]);
        NSDictionary *updated =
            Import(sources, v2, Binding(@"flower/latest.js", Bytes(v2)), bound[@"identifier"], YES);
        CHECK([updated[@"identifier"] isEqual:bound[@"identifier"]] &&
              ![updated[@"revision"] isEqual:bound[@"revision"]]);
        CHECK([updated[@"information"][@"version"] isEqual:bound[@"information"][@"version"]]);
        CHECK([sources.selectedIdentifier isEqual:bound[@"identifier"]]);
        CHECK(![[NSFileManager defaultManager]
            fileExistsAtPath:[sourceDir stringByAppendingPathComponent:bound[@"scriptFile"]]]);
        CHECK([[NSFileManager defaultManager]
            fileExistsAtPath:[sourceDir stringByAppendingPathComponent:updated[@"scriptFile"]]]);
        Import(sources, v2, Binding(@"flower/latest.js", Bytes(v1)), updated[@"identifier"], NO);
        NSString *bad = Fixture(@"unsupported"), *failure = Fixture(@"fail-init");
        Import(sources, bad, Binding(@"flower/latest.js", Bytes(bad)), updated[@"identifier"], NO);
        Import(sources, failure, Binding(@"flower/latest.js", Bytes(failure)), updated[@"identifier"], NO);
        CHECK([sources.selectedEntry isEqual:updated]);

        // An index commit failure leaves the old immutable script readable after restart.
        NSFileManager *files = [NSFileManager defaultManager];
        NSString *indexPath = [sourceDir stringByAppendingPathComponent:@"index.json"];
        NSData *savedIndex = [NSData dataWithContentsOfFile:indexPath];
        CHECK([files removeItemAtPath:indexPath error:NULL]);
        CHECK([files createDirectoryAtPath:indexPath
               withIntermediateDirectories:NO
                                attributes:nil
                                     error:NULL]);
        Import(sources, v1, Binding(@"flower/latest.js", Bytes(v1)), updated[@"identifier"], NO);
        CHECK([sources.selectedEntry isEqual:updated]);
        CHECK([files fileExistsAtPath:[sourceDir stringByAppendingPathComponent:updated[@"scriptFile"]]]);
        CHECK(![files fileExistsAtPath:[sourceDir stringByAppendingPathComponent:bound[@"scriptFile"]]]);
        CHECK([files removeItemAtPath:indexPath error:NULL]);
        CHECK([savedIndex writeToFile:indexPath atomically:YES]);
        sources = [[MCMusicSources alloc] initWithDirectory:sourceDir];
        CHECK([sources.selectedEntry[@"revision"] isEqual:updated[@"revision"]]);

        // Legacy 1.2.0 files remain readable and move to versioned files on update.
        NSMutableDictionary *index = [[NSJSONSerialization JSONObjectWithData:savedIndex
                                                                      options:NSJSONReadingMutableContainers
                                                                        error:NULL] mutableCopy];
        NSMutableDictionary *legacy = [index[@"entries"][1] mutableCopy];
        [legacy removeObjectForKey:@"scriptFile"];
        index[@"entries"] = @[ index[@"entries"][0], legacy ];
        NSString *legacyPath = [sourceDir
            stringByAppendingPathComponent:[legacy[@"identifier"] stringByAppendingPathExtension:@"js"]];
        CHECK([Bytes(v2) writeToFile:legacyPath atomically:YES]);
        CHECK([JSON(index) writeToFile:indexPath atomically:YES]);
        sources = [[MCMusicSources alloc] initWithDirectory:sourceDir];
        CHECK(!sources.selectedEntry[@"scriptFile"] &&
              [sources.selectedIdentifier isEqual:legacy[@"identifier"]]);
        __block BOOL resolved = NO;
        [sources resolveTrack:@{@"id" : @"1"}
                      quality:@"standard"
                   completion:^(NSDictionary *r, NSError *e) {
                       CHECK(r && !e);
                       resolved = YES;
                   }];
        Wait(^BOOL {
            return resolved;
        });
        updated = Import(sources, v1, Binding(@"flower/latest.js", Bytes(v1)), legacy[@"identifier"], YES);
        CHECK(![files fileExistsAtPath:legacyPath] && updated[@"scriptFile"]);

        // Raw bytes, including a UTF-8 BOM, determine both blob and content revision.
        NSMutableData *bom = [NSMutableData dataWithBytes:"\xef\xbb\xbf" length:3];
        [bom appendData:Bytes(v2)];
        __block BOOL bomDone = NO;
        [sources
               importScriptData:bom
                   subscription:Binding(@"bom/latest.js", bom)
            replacingIdentifier:nil
                     completion:^(NSDictionary *entry, NSError *error) {
                         CHECK(entry && !error);
                         CHECK([[NSData
                             dataWithContentsOfFile:[sourceDir
                                                        stringByAppendingPathComponent:entry[@"scriptFile"]]]
                             isEqual:bom]);
                         bomDone = YES;
                     }];
        Wait(^BOOL {
            return bomDone;
        });
        CHECK([sources removeIdentifier:sources.entries.lastObject[@"identifier"] error:NULL]);

        // Deletion/cancellation during validation cannot recreate the target.
        holdInitialization = YES;
        __block BOOL rejected = NO;
        [sources importScript:v2
                   subscription:Binding(@"flower/latest.js", Bytes(v2))
            replacingIdentifier:updated[@"identifier"]
                     completion:^(NSDictionary *entry, NSError *error) {
                         CHECK(!entry && error);
                         rejected = YES;
                     }];
        CHECK([sources removeIdentifier:updated[@"identifier"] error:NULL]);
        pendingInitialization();
        pendingInitialization = nil;
        CHECK(rejected && sources.entries.count == 1);
        __block BOOL cancelledCallback = NO;
        MCSourceTask *cancelled = [sources importScript:v1
                                           subscription:Binding(@"flower/latest.js", Bytes(v1))
                                    replacingIdentifier:nil
                                             completion:^(NSDictionary *entry, NSError *error) {
                                                 cancelledCallback = YES;
                                             }];
        [cancelled cancel];
        pendingInitialization();
        pendingInitialization = nil;
        CHECK(!cancelledCallback && sources.entries.count == 1);
        holdInitialization = NO;

        // Service fixture: cached directory, binding, serial updates and scheduling.
        replies = [NSMutableDictionary dictionary];
        requested = [NSMutableArray array];
        pendingNetwork = [NSMutableArray array];
        __block NSTimeInterval now = 1000000;
        NSString *repoDir = [root stringByAppendingPathComponent:@"repository"];
        MCSourceRepository *repository = [[MCSourceRepository alloc] initWithDirectory:repoDir
                                                                               sources:sources
                                                                                 clock:^{
                                                                                     return now;
                                                                                 }];
        CHECK(repository.autoSyncEnabled && !repository.catalog.count);
        CHECK([repository.downloadRoute isEqual:@"GitHub"]);
        repository.downloadRoute = @"evil.example";
        CHECK([repository.downloadRoute isEqual:@"GitHub"]);
        [repository applicationDidBecomeActive];
        CHECK(!requested.count);
        SetTree(@[ i1 ]);
        SetScript(@"flower/latest.js", v1);
        [repository refreshCatalog];
        [repository refreshCatalog];
        CHECK(requested.count == 1);
        Wait(^BOOL {
            return !repository.busy;
        });
        CHECK(repository.catalog.count == 1);
        Import(sources, v1, nil, nil, YES);
        now += 5;
        [repository importCatalogItem:repository.catalog[0]];
        Wait(^BOOL {
            return !repository.busy;
        });
        CHECK(sources.entries.count == 2 && [repository entryForPath:@"flower/latest.js"]);
        CHECK([sources.selectedIdentifier isEqual:@"netease"]);
        CHECK([[repository statusForItem:repository.catalog[0]] containsString:@"最新"]);
        bound = [repository entryForPath:@"flower/latest.js"];
        CHECK([sources selectIdentifier:bound[@"identifier"] error:NULL]);
        SetTree(@[ i2 ]);
        SetScript(@"flower/latest.js", v2);
        now += 5;
        holdNetwork = YES;
        [repository synchronize];
        DrainOne();
        Wait(^BOOL {
            return pendingNetwork.count == 1;
        });
        CHECK([sources selectIdentifier:@"netease" error:NULL]);
        holdNetwork = NO;
        DrainOne();
        Wait(^BOOL {
            return !repository.busy;
        });
        CHECK([sources.selectedIdentifier isEqual:@"netease"]);
        CHECK([[repository entryForPath:@"flower/latest.js"][@"identifier"] isEqual:bound[@"identifier"]]);
        CHECK(![[repository entryForPath:@"flower/latest.js"][@"revision"] isEqual:bound[@"revision"]]);
        CHECK(repository.lastSuccessfulCheck == now && !repository.errors.count);
        NSUInteger count = requested.count;
        now += 24 * 3600 - 1;
        [repository applicationDidBecomeActive];
        CHECK(requested.count == count);
        now += 1;
        [repository applicationDidBecomeActive];
        Wait(^BOOL {
            return !repository.busy;
        });
        CHECK(requested.count == count + 1); // Unchanged blob does not download again.

        // Failure throttles for 15 minutes, while manual sync can retry earlier.
        replies[TreeURL] = @{@"status" : @403};
        now += 24 * 3600;
        [repository applicationDidBecomeActive];
        Wait(^BOOL {
            return !repository.busy;
        });
        CHECK(repository.catalog.count == 1 && [repository.statusText containsString:@"限流"]);
        count = requested.count;
        now += 899;
        [repository applicationDidBecomeActive];
        CHECK(requested.count == count);
        now += 1;
        [repository applicationDidBecomeActive];
        Wait(^BOOL {
            return !repository.busy;
        });
        CHECK(requested.count == count + 1);
        repository = [[MCSourceRepository alloc] initWithDirectory:repoDir
                                                           sources:sources
                                                             clock:^{
                                                                 return now;
                                                             }];
        CHECK(repository.catalog.count == 1);
        count = requested.count;
        [repository applicationDidBecomeActive];
        CHECK(requested.count == count);
        SetTree(@[ i2 ]);
        now += 5;
        [repository synchronize];
        Wait(^BOOL {
            return !repository.busy;
        });
        CHECK(requested.count == count + 1);
        repository.autoSyncEnabled = NO;
        now += 24 * 3600;
        repository = [[MCSourceRepository alloc] initWithDirectory:repoDir
                                                           sources:sources
                                                             clock:^{
                                                                 return now;
                                                             }];
        CHECK(!repository.autoSyncEnabled);
        count = requested.count;
        [repository applicationDidBecomeActive];
        CHECK(requested.count == count);

        // Remote deletion, invalid blobs and incompatible updates preserve the old source.
        NSDictionary *stable = [repository entryForPath:@"flower/latest.js"];
        SetTree(@[]);
        now += 5;
        [repository synchronize];
        Wait(^BOOL {
            return !repository.busy;
        });
        CHECK([[repository entryForPath:@"flower/latest.js"] isEqual:stable] && repository.errors.count == 1);
        // Upstream accelerators use exact repository paths and the same blob validation.
        repository.downloadRoute = @"ghproxy.net";
        SetTree(@[ i1 ]);
        NSString *accelerated =
            @"https://ghproxy.net/raw.githubusercontent.com/pdone/lx-music-source/main/flower/latest.js";
        replies[accelerated] = @{@"status" : @200, @"data" : Bytes(v2)};
        now += 5;
        [repository synchronize];
        Wait(^BOOL {
            return !repository.busy;
        });
        CHECK([[repository entryForPath:@"flower/latest.js"] isEqual:stable] && repository.errors.count == 1);
        replies[accelerated] = @{@"status" : @200, @"data" : Bytes(v1)};
        now += 5;
        [repository synchronize];
        Wait(^BOOL {
            return !repository.busy;
        });
        CHECK(
            [[repository entryForPath:@"flower/latest.js"][@"subscription"][@"blobSHA"] isEqual:i1[@"sha"]]);
        repository = [[MCSourceRepository alloc] initWithDirectory:repoDir
                                                           sources:sources
                                                             clock:^{
                                                                 return now;
                                                             }];
        CHECK([repository.downloadRoute isEqual:@"ghproxy.net"]);
        stable = [repository entryForPath:@"flower/latest.js"];
        repository.downloadRoute = @"GitHub";
        SetTree(@[ Item(@"flower/latest.js", Bytes(bad)) ]);
        SetScript(@"flower/latest.js", bad);
        now += 5;
        [repository synchronize];
        Wait(^BOOL {
            return !repository.busy;
        });
        CHECK([[repository entryForPath:@"flower/latest.js"] isEqual:stable] && repository.errors.count == 1);
        SetTree(@[ i2 ]); // Valid envelope and byte length, mismatched actual blob content.
        replies[BlobURL(i2[@"sha"])] = @{
            @"status" : @200,
            @"data" : JSON(@{
                @"encoding" : @"base64",
                @"sha" : i2[@"sha"],
                @"size" : i2[@"size"],
                @"content" : [Bytes(v1) base64EncodedStringWithOptions:0]
            })
        };
        now += 5;
        [repository synchronize];
        Wait(^BOOL {
            return !repository.busy;
        });
        CHECK([[repository entryForPath:@"flower/latest.js"] isEqual:stable] && repository.errors.count == 1);
        replies[TreeURL] = @{@"status" : @200, @"data" : JSON(@{@"truncated" : @YES, @"tree" : @[]})};
        NSArray *cached = repository.catalog;
        now += 5;
        [repository refreshCatalog];
        Wait(^BOOL {
            return !repository.busy;
        });
        CHECK([repository.catalog isEqual:cached]);

        // Cancellation ignores stale callbacks; concurrent actions do not start more requests.
        SetTree(@[ i1 ]);
        now += 5;
        holdNetwork = YES;
        [repository refreshCatalog];
        count = requested.count;
        [repository synchronize];
        CHECK(requested.count == count);
        [repository cancel];
        CHECK(!repository.busy);
        holdNetwork = NO;
        DrainOne();
        CHECK([repository.statusText containsString:@"取消"]);
        now += 5;
        [repository refreshCatalog];
        Wait(^BOOL {
            return !repository.busy;
        });
        SetScript(@"flower/latest.js", v1);
        now += 5;
        holdNetwork = YES;
        [repository importCatalogItem:repository.catalog[0]];
        CHECK([sources removeIdentifier:stable[@"identifier"] error:NULL]);
        holdNetwork = NO;
        DrainOne();
        Wait(^BOOL {
            return !repository.busy;
        });
        CHECK(sources.entries.count == 1 && ![repository entryForPath:@"flower/latest.js"]);

        // Cache commit failure retains the previous catalog.
        NSString *cachePath = [repoDir stringByAppendingPathComponent:@"repository.json"];
        NSData *savedCache = [NSData dataWithContentsOfFile:cachePath];
        CHECK([files removeItemAtPath:cachePath error:NULL]);
        CHECK([files createDirectoryAtPath:cachePath
               withIntermediateDirectories:NO
                                attributes:nil
                                     error:NULL]);
        cached = repository.catalog;
        SetTree(@[]);
        now += 5;
        [repository refreshCatalog];
        Wait(^BOOL {
            return !repository.busy;
        });
        CHECK([repository.catalog isEqual:cached]);
        CHECK([files removeItemAtPath:cachePath error:NULL]);
        CHECK([savedCache writeToFile:cachePath atomically:YES]);
        repository = nil;
        sources = nil;
        CHECK([files removeItemAtPath:root error:NULL]);
        printf(
            "source repository: %u catalog, rollback, migration, cancellation and scheduling checks passed\n",
            checks);
    }
}
