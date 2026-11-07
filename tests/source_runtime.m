#import <Foundation/Foundation.h>
#import "MCMusicSources.h"
static unsigned checks;
#define CHECK(c)                                                                                             \
    do {                                                                                                     \
        checks++;                                                                                            \
        if (!(c)) {                                                                                          \
            fprintf(stderr, "source runtime line %d: %s\n", __LINE__, #c);                                   \
            exit(1);                                                                                         \
        }                                                                                                    \
    } while (0)
static void Wait(BOOL (^done)(void)) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:15];
    while (!done() && end.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
    CHECK(done());
}
int main(void) {
    @autoreleasepool {
        NSString *folder = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        MCMusicSources *sources = [[MCMusicSources alloc] initWithDirectory:folder];
        NSString *script =
            @"/**\n * @name Integration fixture\n * @version 1.0.0\n */\nconst lx=globalThis.lx; "
            @"lx.on(lx.EVENT_NAMES.request, async ({source,action,info}) => { if "
            @"(source!=='wy'||action!=='musicUrl') throw Error('bad request'); await new "
            @"Promise(r=>setTimeout(r,20)); return "
            @"'https://fixture.example.test/'+info.musicInfo.songmid+'/'+info.type+'.flac'; }); "
            @"setTimeout(()=>lx.send(lx.EVENT_NAMES.inited,{sources:{wy:{type:'music',actions:['musicUrl'],"
            @"qualitys:['128k','320k','flac']}}}),10);";
        __block BOOL done = NO;
        __block NSDictionary *entry;
        [sources importScript:script
                       origin:@"local"
                   completion:^(NSDictionary *e, NSError *error) {
                       CHECK([NSThread isMainThread]);
                       CHECK(!error);
                       entry = e;
                       done = YES;
                   }];
        Wait(^BOOL {
            return done;
        });
        CHECK(entry != nil);
        CHECK([sources.selectedIdentifier isEqual:@"netease"]);
        CHECK([sources selectIdentifier:entry[@"identifier"] error:NULL]);
        NSDictionary *track = @{
            @"id" : @"18446744073709551615",
            @"title" : @"Song",
            @"artist" : @"Artist",
            @"album" : @"Album",
            @"duration" : @30
        };
        done = NO;
        [sources resolveTrack:track
                      quality:@"lossless"
                   completion:^(NSDictionary *resource, NSError *error) {
                       CHECK(!error);
                       CHECK([resource[@"url"]
                           isEqual:@"https://fixture.example.test/18446744073709551615/flac.flac"]);
                       CHECK([resource[@"customSource"] boolValue]);
                       CHECK([resource[@"sourceIdentifier"] isEqual:entry[@"identifier"]]);
                       CHECK([resource[@"sourceRevision"] isEqual:entry[@"revision"]]);
                       CHECK(!resource[@"size"]);
                       done = YES;
                   }];
        Wait(^BOOL {
            return done;
        });
        done = NO;
        [sources resolveTrack:track
                      quality:@"standard"
                   completion:^(NSDictionary *resource, NSError *error) {
                       CHECK(!error);
                       CHECK([resource[@"url"] hasSuffix:@"/128k.flac"]);
                       done = YES;
                   }];
        Wait(^BOOL {
            return done;
        });
        // A validated update keeps the identifier and an outstanding old resolution.
        NSData *originalData = [script dataUsingEncoding:NSUTF8StringEncoding];
        done = NO;
        [sources importScript:script
                   subscription:@{
                       @"provider" : @"pdone/lx-music-source",
                       @"path" : @"fixture/latest.js",
                       @"blobSHA" : MCSourceGitBlobSHA(originalData)
                   }
            replacingIdentifier:nil
                     completion:^(NSDictionary *e, NSError *error) {
                         CHECK(e && !error);
                         CHECK([e[@"identifier"] isEqual:entry[@"identifier"]]);
                         entry = e;
                         done = YES;
                     }];
        Wait(^BOOL {
            return done;
        });
        NSString *slowScript = [script stringByReplacingOccurrencesOfString:@"setTimeout(r,20)"
                                                                 withString:@"setTimeout(r,500)"];
        done = NO;
        [sources importScript:slowScript
                   subscription:@{
                       @"provider" : @"pdone/lx-music-source",
                       @"path" : @"fixture/latest.js",
                       @"blobSHA" : MCSourceGitBlobSHA([slowScript dataUsingEncoding:NSUTF8StringEncoding])
                   }
            replacingIdentifier:entry[@"identifier"]
                     completion:^(NSDictionary *e, NSError *error) {
                         CHECK(e && !error);
                         entry = e;
                         done = YES;
                     }];
        Wait(^BOOL {
            return done;
        });
        NSDictionary *oldEntry = entry;
        __block BOOL oldDone = NO;
        [sources resolveTrack:track
                      quality:@"standard"
                   completion:^(NSDictionary *resource, NSError *error) {
                       CHECK(resource && !error);
                       CHECK([resource[@"sourceRevision"] isEqual:oldEntry[@"revision"]]);
                       CHECK([resource[@"url"] hasSuffix:@"/128k.flac"]);
                       oldDone = YES;
                   }];
        NSString *newScript = [script stringByReplacingOccurrencesOfString:@"+'.flac'"
                                                                withString:@"+'.flac?v=2'"];
        done = NO;
        [sources importScript:newScript
                   subscription:@{
                       @"provider" : @"pdone/lx-music-source",
                       @"path" : @"fixture/latest.js",
                       @"blobSHA" : MCSourceGitBlobSHA([newScript dataUsingEncoding:NSUTF8StringEncoding])
                   }
            replacingIdentifier:entry[@"identifier"]
                     completion:^(NSDictionary *e, NSError *error) {
                         CHECK(e && !error);
                         CHECK([e[@"identifier"] isEqual:oldEntry[@"identifier"]]);
                         CHECK(![e[@"revision"] isEqual:oldEntry[@"revision"]]);
                         entry = e;
                         done = YES;
                     }];
        Wait(^BOOL {
            return done;
        });
        CHECK(!oldDone);
        done = NO;
        [sources resolveTrack:track
                      quality:@"standard"
                   completion:^(NSDictionary *resource, NSError *error) {
                       CHECK(resource && !error);
                       CHECK([resource[@"sourceRevision"] isEqual:entry[@"revision"]]);
                       CHECK([resource[@"url"] hasSuffix:@"/128k.flac?v=2"]);
                       done = YES;
                   }];
        Wait(^BOOL {
            return done && oldDone;
        });
        // Deleting an active runtime must settle the outstanding resolution, not hang the player.
        done = NO;
        [sources resolveTrack:track
                      quality:@"standard"
                   completion:^(NSDictionary *resource, NSError *error) {
                       CHECK(resource != nil || error != nil);
                       done = YES;
                   }];
        CHECK([sources removeIdentifier:entry[@"identifier"] error:NULL]);
        Wait(^BOOL {
            return done;
        });
        CHECK([sources.selectedIdentifier isEqual:@"netease"]);
        CHECK(sources.entries.count == 1);
        sources = nil;
        [[NSFileManager defaultManager] removeItemAtPath:folder error:NULL];
        printf("source runtime: %u real registry/QuickJS integration checks passed\n", checks);
    }
}
