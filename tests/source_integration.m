#import <Foundation/Foundation.h>
#import "MCAudioPolicy.h"
#import "MCAudioCache.h"
#import "../Sources/Network/MCSourceSecurity.h"
static unsigned checks;
#define CHECK(c)                                                                                             \
    do {                                                                                                     \
        checks++;                                                                                            \
        if (!(c)) {                                                                                          \
            fprintf(stderr, "source integration line %d: %s\n", __LINE__, #c);                               \
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
static MCAudioCacheLease *Lease(MCAudioCache *cache, NSString *key) __attribute__((ns_returns_retained));
static MCAudioCacheLease *Lease(MCAudioCache *cache, NSString *key) {
    __block BOOL done = NO;
    __block MCAudioCacheLease *lease;
    [cache leaseForKey:key
            completion:^(MCAudioCacheLease *value) {
                lease = value;
                done = YES;
            }];
    Wait(^BOOL {
        return done;
    });
    return lease;
}
int main(void) {
    @autoreleasepool {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        id savedPolicy = [defaults objectForKey:MCSourceHTTPSOnlyKey];
        [defaults removeObjectForKey:MCSourceHTTPSOnlyKey];
        CHECK(MCSourceHTTPSOnly());
        NSString *safeReason = MCSourceFailureText(
            @"额度用完 {\"token\":\"secret value\"} password='hidden value' https://host.test/?key=private",
            @"失败");
        CHECK([safeReason containsString:@"额度用完"] && ![safeReason containsString:@"secret"] &&
              ![safeReason containsString:@"hidden"] && ![safeReason containsString:@"private"]);
        CHECK([MCSourceFailureText(@42, @"失败") isEqual:@"失败"]);
        CHECK([MCSourceFailureText([@"原因" stringByPaddingToLength:512 withString:@"原因" startingAtIndex:0],
                                   @"失败") length] <= 200);
        CHECK(MCIsAllowedAudioURL([NSURL URLWithString:@"https://m7.music.126.net/song.flac"], NO));
        CHECK(!MCIsAllowedAudioURL([NSURL URLWithString:@"https://cdn.example.com/song.flac"], NO));
        CHECK(!MCIsAllowedAudioURL([NSURL URLWithString:@"https://music.126.net.evil.org/song"], NO));
        CHECK(MCIsAllowedAudioURL([NSURL URLWithString:@"https://cdn.example.com/song.flac"], YES));
        for (NSString *value in @[
                 @"http://cdn.example.com/song", @"file:///tmp/song", @"https://user:pass@example.com/song",
                 @"https:///song", @"data:audio/mp3,abc"
             ]) {
            CHECK(!MCIsAllowedAudioURL([NSURL URLWithString:value], YES));
            CHECK(!MCIsAllowedAudioURL([NSURL URLWithString:value], NO));
        }
        NSDictionary *sourceA = @{@"identifier" : @"a", @"revision" : @"r1"};
        MCSetSourceHTTPSOnly(NO);
        CHECK(MCIsAllowedAudioURL([NSURL URLWithString:@"http://cdn.example.com/song"], YES));
        CHECK(!MCIsAllowedAudioURL([NSURL URLWithString:@"http://m7.music.126.net/song"], NO));
        for (NSString *value in
             @[ @"file:///tmp/song", @"http://user:pass@example.com/song", @"data:audio/mp3,abc" ])
            CHECK(!MCIsAllowedAudioURL([NSURL URLWithString:value], YES));
        MCSetSourceHTTPSOnly(YES);
        CHECK(!MCIsAllowedAudioURL([NSURL URLWithString:@"http://cdn.example.com/song"], YES));
        CHECK([MCSourceURLFailure([NSURL URLWithString:@"http://cdn.example.com/song"])
            containsString:@"设置"]);
        if (savedPolicy)
            [defaults setObject:savedPolicy forKey:MCSourceHTTPSOnlyKey];
        else
            [defaults removeObjectForKey:MCSourceHTTPSOnlyKey];
        CHECK(MCSourceSnapshotMatches(sourceA, sourceA));
        CHECK(!MCSourceSnapshotMatches(sourceA, @{@"identifier" : @"b", @"revision" : @"r1"}));
        CHECK(!MCSourceSnapshotMatches(sourceA, @{@"identifier" : @"a", @"revision" : @"r2"}));
        CHECK(!MCSourceSnapshotMatches(sourceA, nil));
        CHECK(!MCSourceSnapshotMatches(nil, sourceA));
        // Re-evaluate at delayed execution: a source that matched at scheduling can change.
        NSDictionary *delayedSelection = @{@"identifier" : @"a", @"revision" : @"r2"};
        CHECK(!MCSourceSnapshotMatches(sourceA, delayedSelection));
        NSDictionary *original = @{
            @"url" : @"https://cdn.example.org/same.flac?token=one",
            @"format" : @"flac",
            @"size" : @100,
            @"bitrate" : @1411200
        };
        NSMutableDictionary *custom = [original mutableCopy];
        custom[@"customSource"] = @YES;
        custom[@"sourceIdentifier"] = @"a";
        custom[@"sourceRevision"] = @"r1";
        NSString * (^key)(NSDictionary *) = ^NSString *(NSDictionary *r) {
            return [MCAudioCache keyForTrackID:@"123" resource:r account:@"guest"];
        };
        NSString *builtinKey = key(original), *customKey = key(custom);
        CHECK(customKey.length == 64);
        CHECK(![builtinKey isEqual:customKey]);
        custom[@"sourceIdentifier"] = @"b";
        CHECK(![customKey isEqual:key(custom)]);
        custom[@"sourceIdentifier"] = @"a";
        custom[@"sourceRevision"] = @"r2";
        CHECK(![customKey isEqual:key(custom)]);
        custom[@"sourceRevision"] = @"r1";
        custom[@"url"] = @"https://different.example.org/same.flac?token=one";
        CHECK(![customKey isEqual:key(custom)]);
        custom[@"url"] = @"https://cdn.example.org:8443/same.flac?token=one";
        NSString *port8443 = key(custom);
        custom[@"url"] = @"https://cdn.example.org:9443/same.flac?token=one";
        CHECK(![port8443 isEqual:key(custom)]);
        custom[@"url"] = @"https://cdn.example.org:443/same.flac?token=one";
        CHECK([customKey isEqual:key(custom)]);
        custom[@"url"] = @"https://cdn.example.org/same.flac?token=two";
        CHECK([customKey isEqual:key(custom)]);
        [custom removeObjectForKey:@"sourceRevision"];
        CHECK(key(custom) == nil);
        custom[@"sourceRevision"] = @"r1";
        [custom removeObjectForKey:@"size"];
        CHECK(key(custom) == nil);
        NSString *folder = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [[NSFileManager defaultManager] createDirectoryAtPath:folder
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
        NSString *fixture = [folder stringByAppendingPathComponent:@"fixture"];
        [[@"abcdefgh" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:fixture atomically:YES];
        NSString *directory = [folder stringByAppendingPathComponent:@"cache"];
        MCAudioCache *cache = [[MCAudioCache alloc] initWithDirectory:directory maximumBytes:1024];
        __block BOOL stored = NO;
        [cache storeFile:fixture
                         key:@"source-a"
            sourceIdentifier:@"a"
                  generation:cache.generation
                  completion:^{
                      stored = YES;
                  }];
        Wait(^BOOL {
            return stored;
        });
        stored = NO;
        [cache storeFile:fixture
                     key:@"builtin"
              generation:cache.generation
              completion:^{
                  stored = YES;
              }];
        Wait(^BOOL {
            return stored;
        });
        CHECK(Lease(cache, @"source-a") != nil);
        CHECK(Lease(cache, @"builtin") != nil);
        cache = nil;
        cache = [[MCAudioCache alloc] initWithDirectory:directory maximumBytes:1024];
        MCAudioCacheLease *active = Lease(cache, @"source-a");
        CHECK(active != nil);
        [cache invalidateSourceIdentifier:@"a"];
        CHECK(Lease(cache, @"source-a") == nil);
        CHECK(Lease(cache, @"builtin") != nil);
        CHECK([[NSFileManager defaultManager] fileExistsAtPath:active.path]);
        NSString *activePath = active.path;
        active = nil;
        (void)Lease(cache, @"missing");
        CHECK(![[NSFileManager defaultManager] fileExistsAtPath:activePath]);
        cache = nil;
        [[NSFileManager defaultManager] removeItemAtPath:folder error:NULL];
        printf("source integration: %u policy/cache checks passed\n", checks);
    }
}
