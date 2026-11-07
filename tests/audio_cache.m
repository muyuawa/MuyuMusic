#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import "../Sources/Playback/MCAudioCache.h"
static unsigned checks;
#define CHECK(c, m)                                                                                          \
    do {                                                                                                     \
        checks++;                                                                                            \
        if (!(c)) {                                                                                          \
            fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, m);                                       \
            exit(1);                                                                                         \
        }                                                                                                    \
    } while (0)
static void Wait(BOOL (^done)(void)) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:10];
    while (!done() && end.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
    CHECK(done(), "async callback completes");
}
static void Store(MCAudioCache *cache, NSString *path, NSString *key) {
    __block BOOL done = NO;
    [cache storeFile:path
                 key:key
          completion:^{
              CHECK([NSThread isMainThread], "store callback on main");
              done = YES;
          }];
    CHECK(!done, "store asynchronous");
    Wait(^BOOL {
        return done;
    });
}
// Return an owned lease so temporary autoreleases cannot extend test pin lifetimes.
static MCAudioCacheLease *Lease(MCAudioCache *cache, NSString *key) __attribute__((ns_returns_retained));
static MCAudioCacheLease *Lease(MCAudioCache *cache, NSString *key) {
    __block BOOL done = NO;
    __block MCAudioCacheLease *result = nil;
    [cache leaseForKey:key
            completion:^(MCAudioCacheLease *lease) {
                CHECK([NSThread isMainThread], "lease callback on main");
                result = lease;
                done = YES;
            }];
    Wait(^BOOL {
        return done;
    });
    return result;
}
static NSDictionary *Stats(MCAudioCache *cache) {
    __block NSDictionary *result = nil;
    [cache snapshot:^(NSDictionary *stats) {
        result = stats;
    }];
    Wait(^BOOL {
        return result != nil;
    });
    return result;
}
int main(void) {
    @autoreleasepool {
        Class cls = NSClassFromString(@"MCAudioCache");
        CHECK(cls != Nil, "audio cache implementation exists");
        NSDictionary *resource = @{
            @"url" : @"https://cdn.example.org/music/track.flac?token=secret",
            @"format" : @"flac",
            @"bitrate" : @1411200,
            @"size" : @8
        };
        NSString *key = [cls keyForTrackID:@"18446744073709551615" resource:resource account:@"guest"];
        CHECK(key.length == 64 && [key rangeOfString:@"secret"].location == NSNotFound,
              "cache key is a safe digest");
        NSMutableDictionary *renewed = [resource mutableCopy];
        renewed[@"url"] = @"https://cdn.example.org/music/track.flac?token=renewed";
        CHECK([key isEqual:[cls keyForTrackID:@"18446744073709551615" resource:renewed account:@"guest"]],
              "URL credential refresh reuses key");
        CHECK(![key isEqual:[cls keyForTrackID:@"18446744073709551614" resource:resource account:@"guest"]] &&
                  ![key isEqual:[cls keyForTrackID:@"18446744073709551615"
                                          resource:resource
                                           account:@"other"]],
              "full track ID and account separate keys");
        CHECK([cls keyForTrackID:nil resource:resource account:nil] == nil, "invalid key input rejected");
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]],
                 *directory = [root stringByAppendingPathComponent:@"Audio"],
                 *source = [root stringByAppendingPathComponent:@"source"];
        [[NSFileManager defaultManager] createDirectoryAtPath:root
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
        CHECK([[@"12345678" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:source atomically:YES],
              "source fixture");
        MCAudioCache *cache = [[cls alloc] initWithDirectory:directory maximumBytes:16];
        Store(cache, source, @"a");
        Store(cache, source, @"b");
        MCAudioCacheLease *a = Lease(cache, @"a");
        CHECK(a != nil, "stored file leased");
        a = nil;
        Stats(cache);
        Store(cache, source, @"c");
        CHECK(Lease(cache, @"b") == nil, "least recently used entry evicted");
        CHECK([Stats(cache)[@"usedBytes"] unsignedLongLongValue] == 16, "cache stays within limit");
        cache = nil;
        cache = [[cls alloc] initWithDirectory:directory maximumBytes:16];
        CHECK(Lease(cache, @"a") != nil && Lease(cache, @"c") != nil, "completed cache survives restart");
        CHECK(Lease(cache, @"b") == nil, "eviction survives restart");
        cache.maximumBytes = 8;
        CHECK(cache.maximumBytes == 8, "limit getter updates immediately");
        CHECK([Stats(cache)[@"usedBytes"] unsignedLongLongValue] <= 8, "lower limit trims cache");
        cache.maximumBytes = 0;
        Store(cache, source, @"off");
        CHECK(Lease(cache, @"off") == nil && [Stats(cache)[@"usedBytes"] unsignedLongLongValue] == 0,
              "disabled cache stores nothing");
        cache.maximumBytes = 16;
        NSString *large = [root stringByAppendingPathComponent:@"large"];
        CHECK([[@"12345678901234567" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:large
                                                                              atomically:YES],
              "oversize fixture");
        Store(cache, large, @"large");
        CHECK(Lease(cache, @"large") == nil, "oversize source skipped");
        Store(cache, source, @"active");
        MCAudioCacheLease *active = Lease(cache, @"active");
        NSString *leasedPath = [active.path copy];
        __block NSDictionary *cleared = nil;
        [cache clear:^(NSDictionary *stats, NSError *error) {
            CHECK([NSThread isMainThread] && !error, "clear reports success on main");
            cleared = stats;
        }];
        Wait(^BOOL {
            return cleared != nil;
        });
        CHECK([cleared[@"usedBytes"] unsignedLongLongValue] == 8 &&
                  [cleared[@"pendingBytes"] unsignedLongLongValue] == 8,
              "clear counts active deferred bytes");
        CHECK(Lease(cache, @"active") == nil && [[NSFileManager defaultManager] fileExistsAtPath:leasedPath],
              "clear hides entry while preserving active file");
        active = nil;
        CHECK([Stats(cache)[@"usedBytes"] unsignedLongLongValue] == 0 &&
                  ![[NSFileManager defaultManager] fileExistsAtPath:leasedPath],
              "last lease release deletes cleared file");
        __block BOOL stored = NO, clearDone = NO;
        [cache storeFile:source
                     key:@"racing"
              completion:^{
                  stored = YES;
              }];
        [cache clear:^(NSDictionary *stats, NSError *error) {
            (void)stats;
            CHECK(!error, "racing clear succeeds");
            clearDone = YES;
        }];
        Wait(^BOOL {
            return stored && clearDone;
        });
        CHECK(Lease(cache, @"racing") == nil, "clear prevents earlier store from refilling cache");
        Store(cache, source, @"invalidate");
        MCAudioCacheLease *invalid = Lease(cache, @"invalidate");
        NSString *invalidPath = [invalid.path copy];
        [cache invalidateKey:@"invalidate"];
        CHECK(Lease(cache, @"invalidate") == nil &&
                  [[NSFileManager defaultManager] fileExistsAtPath:invalidPath],
              "invalidation prevents leases without breaking current pin");
        invalid = nil;
        CHECK([Stats(cache)[@"pendingBytes"] unsignedLongLongValue] == 0 &&
                  ![[NSFileManager defaultManager] fileExistsAtPath:invalidPath],
              "invalidated pin removed on release"); // A download started before clear must not refill the
                                                     // cache when it completes later.
        NSUInteger oldGeneration = cache.generation;
        __block BOOL epochCleared = NO;
        [cache clear:^(NSDictionary *stats, NSError *error) {
            (void)stats;
            CHECK(!error, "epoch clear succeeds");
            epochCleared = YES;
        }];
        Wait(^BOOL {
            return epochCleared;
        });
        __block BOOL staleStored = NO;
        [cache storeFile:source
                     key:@"late-download"
              generation:oldGeneration
              completion:^{
                  staleStored = YES;
              }];
        Wait(^BOOL {
            return staleStored;
        });
        CHECK(Lease(cache, @"late-download") == nil, "late completion of cleared download skipped");
        Store(cache, source, @"fresh-download");
        CHECK(Lease(cache, @"fresh-download") != nil, "new downloads can cache after clear");
        // Lowering a limit keeps active bytes readable, but queues their eviction.
        MCAudioCacheLease *bounded = Lease(cache, @"fresh-download");
        NSString *boundedPath = bounded.path;
        cache.maximumBytes = 4;
        NSDictionary *boundedStats = Stats(cache);
        CHECK([boundedStats[@"pendingBytes"] unsignedLongLongValue] == 8 &&
                  [[NSFileManager defaultManager] fileExistsAtPath:boundedPath],
              "active file survives smaller limit");
        CHECK(Lease(cache, @"fresh-download") == nil, "oversize pinned entry hidden from new readers");
        bounded = nil;
        CHECK([Stats(cache)[@"usedBytes"] unsignedLongLongValue] == 0,
              "limit enforced when active reader closes");
        // A zero-byte or size-changed cached file must fall back to a fresh download.
        cache.maximumBytes = 16;
        Store(cache, source, @"damaged");
        MCAudioCacheLease *damaged = Lease(cache, @"damaged");
        NSString *damagedPath = damaged.path;
        damaged = nil;
        CHECK([[@"x" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:damagedPath atomically:YES],
              "damage fixture");
        CHECK(Lease(cache, @"damaged") == nil && [Stats(cache)[@"usedBytes"] unsignedLongLongValue] == 0,
              "changed cached size rejected");
        // Fixtures left by an interrupted copy/clear are removed during startup.
        Store(cache, source, @"crash-clear");
        MCAudioCacheLease *crash = Lease(cache, @"crash-clear");
        NSString *crashPath = crash.path;
        crash = nil;
        Stats(cache);
        cache = nil;
        CHECK([[NSData data] writeToFile:[crashPath stringByAppendingString:@".invalid"] atomically:YES],
              "crash marker fixture");
        NSString *staging = [directory stringByAppendingPathComponent:@".store-interrupted"];
        CHECK([[@"incomplete" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:staging atomically:YES],
              "incomplete copy fixture");
        cache = [[cls alloc] initWithDirectory:directory maximumBytes:16];
        CHECK(Lease(cache, @"crash-clear") == nil &&
                  ![[NSFileManager defaultManager] fileExistsAtPath:crashPath] &&
                  ![[NSFileManager defaultManager] fileExistsAtPath:staging],
              "startup discards cleared audio and partial store");
        // File errors are visible in stats and clear, without affecting playback.
        MCAudioCache *unwritable = [[cls alloc] initWithDirectory:source maximumBytes:16];
        CHECK(Stats(unwritable)[@"error"] != nil, "cache directory failure reported");
        __block BOOL failedClear = NO;
        [unwritable clear:^(NSDictionary *stats, NSError *error) {
            CHECK(error != nil && stats[@"error"] != nil, "clear reports storage failure");
            failedClear = YES;
        }];
        Wait(^BOOL {
            return failedClear;
        });
        unwritable = nil;
        cache.maximumBytes = ~0ULL;
        CHECK(cache.maximumBytes == 1024ULL * 1024 * 1024, "maximum clamped to one GiB");
        cache = nil;
        [[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
        fprintf(stdout, "PASS audio_cache: %u checks\n", checks);
    }
    return 0;
}
