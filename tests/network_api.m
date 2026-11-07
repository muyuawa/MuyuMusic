#import <Foundation/Foundation.h>
#import "MCAPI.h"
#import <Security/Security.h>
#import <dispatch/dispatch.h>
/* Only the remote boundary is replaced; batching/order/normalization/completions
   execute the real MCAPI implementation. No fixture data is linked into app. */
@interface CatalogFixtureAPI : MCAPI
@property (nonatomic) NSUInteger detailCalls;
@property (nonatomic) BOOL omitTrack;
@property (nonatomic) NSUInteger albumCalls;
@property (nonatomic) BOOL omitAllTracks;
@property (nonatomic) BOOL provideFallback;
@property (nonatomic) BOOL malformedDetails;
@property (nonatomic) BOOL failDetails;
@property (nonatomic) BOOL emptyPlaylist;
@property (nonatomic) BOOL hasAccount;
@end
@implementation CatalogFixtureAPI
- (BOOL)loggedIn {
    return self.hasAccount;
}
- (NSDictionary *)profile {
    return self.hasAccount ? @{@"userId" : @7} : @{};
}
- (NSDictionary *)keychainQuery {
    return @{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService : @"com.muyu.network.tests.only",
        (__bridge id)kSecAttrAccount : @"catalog"
    };
}
- (void)sendPath:(NSString *)path
      parameters:(NSDictionary *)parameters
      completion:(MCAPICompletion)completion {
    if ([path isEqual:@"/api/v6/playlist/detail"]) {
        NSMutableArray *ids = [NSMutableArray array];
        for (long long i = 0; i < (self.emptyPlaylist ? 0 : 205); i++)
            [ids addObject:@{@"id" : @(5000000000LL + i)}];
        completion(@{
            @"code" : @200,
            @"playlist" : @{
                @"name" : @"Fixture",
                @"trackIds" : ids,
                @"tracks" : self.provideFallback ? @[ @{@"id" : @5000000000LL, @"name" : @"Original title"} ]
                                                 : @[],
                @"trackCount" : @(ids.count)
            }
        },
                   nil);
    } else if ([path isEqual:@"/api/v3/song/detail"]) {
        self.detailCalls++;
        if (self.failDetails) {
            completion(nil, [NSError errorWithDomain:@"MCHTTPErrorDomain" code:503 userInfo:nil]);
            return;
        }
        if (self.malformedDetails) {
            completion(@{@"code" : @200, @"songs" : @"invalid"}, nil);
            return;
        }
        NSArray *ids =
            [NSJSONSerialization JSONObjectWithData:[parameters[@"c"] dataUsingEncoding:NSUTF8StringEncoding]
                                            options:0
                                              error:NULL];
        if ([ids count] > 100)
            abort();
        NSMutableArray *songs = [NSMutableArray array];
        for (NSDictionary *item in [ids reverseObjectEnumerator])
            if (!self.omitAllTracks && !(self.omitTrack && [item[@"id"] longLongValue] == 5000000000LL))
                [songs addObject:@{@"id" : item[@"id"], @"name" : @"Song"}];
        completion(@{@"code" : @200, @"songs" : songs}, nil);
    } else if ([path isEqual:@"/api/song/like/get"]) {
        NSMutableArray *ids = [NSMutableArray array];
        for (long long i = 0; i < 205; i++)
            [ids addObject:@(5000000000LL + i)];
        completion(@{@"code" : @200, @"ids" : ids}, nil);
    } else if ([path isEqual:@"/api/v1/artist/12"]) {
        completion(@{@"code" : @200, @"artist" : @{@"name" : @"Artist"}, @"hotSongs" : @[]}, nil);
    } else if ([path isEqual:@"/api/artist/albums/12"]) {
        self.albumCalls++;
        BOOL first = [parameters[@"offset"] unsignedIntegerValue] == 0;
        completion(@{
            @"code" : @200,
            @"hotAlbums" : @[ @{@"id" : first ? @1 : @2, @"name" : @"Album"} ],
            @"more" : @(first)
        },
                   nil);
    } else {
        completion(nil, [NSError errorWithDomain:@"fixture" code:1 userInfo:nil]);
    }
}
@end
@interface SessionFixtureAPI : MCAPI
@property (nonatomic, copy) MCAPICompletion pendingCompletion;
@property (nonatomic) NSUInteger logoutCalls;
@end
@implementation SessionFixtureAPI
- (NSDictionary *)keychainQuery {
    return @{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService : @"com.muyu.network.tests.only",
        (__bridge id)kSecAttrAccount : @"fixture"
    };
}
- (BOOL)loggedIn {
    return YES;
}
- (void)sendPath:(NSString *)path
      parameters:(NSDictionary *)parameters
      completion:(MCAPICompletion)completion {
    (void)path;
    (void)parameters;
    self.pendingCompletion = completion;
}
- (void)logout {
    self.logoutCalls++;
    [super logout];
}
@end
static unsigned failures = 0, pending = 14;
#define CHECK(...)                                                                                           \
    do {                                                                                                     \
        if (!(__VA_ARGS__)) {                                                                                \
            fprintf(stderr, "FAIL API line %d: %s\n", __LINE__, #__VA_ARGS__);                               \
            failures++;                                                                                      \
        }                                                                                                    \
    } while (0)
static void finish(void) {
    if (--pending == 0) {
        fprintf(stdout, "network_api: %u failures\n", failures);
        exit(failures ? 1 : 0);
    }
}
int main(void) {
    @autoreleasepool {
        CatalogFixtureAPI *api = [[CatalogFixtureAPI alloc] init];
        [api playlist:@"123"
            completion:^(id result, NSError *error) {
                CHECK([NSThread isMainThread]);
                CHECK(error == nil);
                NSArray *tracks = result[@"tracks"];
                CHECK([tracks count] == 205);
                CHECK(api.detailCalls == 3);
                CHECK([result[@"unavailableTrackIDs"] count] == 0);
                CHECK([result[@"totalCount"] unsignedIntegerValue] == 205);
                for (NSUInteger i = 0; i < [tracks count]; i++)
                    CHECK([tracks[i][@"id"] isEqual:[NSString stringWithFormat:@"%llu", 5000000000ULL + i]]);
                finish();
            }];
        CatalogFixtureAPI *missing = [[CatalogFixtureAPI alloc] init];
        missing.omitTrack = YES;
        [missing playlist:@"123"
               completion:^(id result, NSError *error) {
                   CHECK([NSThread isMainThread]);
                   CHECK(error == nil);
                   CHECK([result[@"tracks"] count] == 204);
                   CHECK(missing.detailCalls == 3);
                   CHECK([result[@"unavailableTrackIDs"] isEqual:@[ @"5000000000" ]]);
                   CHECK([result[@"totalCount"] unsignedIntegerValue] == 205);
                   for (NSUInteger i = 0; i < 204; i++)
                       CHECK([result[@"tracks"][i][@"id"]
                           isEqual:[NSString stringWithFormat:@"%llu", 5000000001ULL + i]]);
                   finish();
               }];
        CatalogFixtureAPI *allMissing = [CatalogFixtureAPI new];
        allMissing.omitAllTracks = YES;
        [allMissing playlist:@"123"
                  completion:^(id result, NSError *error) {
                      CHECK(error == nil);
                      CHECK([result[@"tracks"] count] == 0);
                      CHECK([result[@"unavailableTrackIDs"] count] == 205);
                      CHECK([result[@"totalCount"] unsignedIntegerValue] == 205);
                      CHECK(allMissing.detailCalls == 3);
                      finish();
                  }];
        CatalogFixtureAPI *fallback = [CatalogFixtureAPI new];
        fallback.omitTrack = YES;
        fallback.provideFallback = YES;
        [fallback playlist:@"123"
                completion:^(id result, NSError *error) {
                    CHECK(error == nil);
                    CHECK([result[@"tracks"] count] == 205);
                    CHECK([result[@"tracks"][0][@"title"] isEqual:@"Original title"]);
                    CHECK([result[@"unavailableTrackIDs"] count] == 0);
                    finish();
                }];
        CatalogFixtureAPI *malformed = [CatalogFixtureAPI new];
        malformed.malformedDetails = YES;
        [malformed playlist:@"123"
                 completion:^(id result, NSError *error) {
                     CHECK(result == nil && error.code == -47);
                     finish();
                 }];
        CatalogFixtureAPI *offline = [CatalogFixtureAPI new];
        offline.failDetails = YES;
        [offline playlist:@"123"
               completion:^(id result, NSError *error) {
                   CHECK(result == nil && error.code == 503);
                   finish();
               }];
        CatalogFixtureAPI *empty = [CatalogFixtureAPI new];
        empty.emptyPlaylist = YES;
        [empty playlist:@"123"
             completion:^(id result, NSError *error) {
                 CHECK(error == nil);
                 CHECK([result[@"tracks"] count] == 0);
                 CHECK([result[@"unavailableTrackIDs"] count] == 0);
                 CHECK([result[@"totalCount"] unsignedIntegerValue] == 0);
                 CHECK(empty.detailCalls == 0);
                 finish();
             }];
        CatalogFixtureAPI *liked = [CatalogFixtureAPI new];
        liked.hasAccount = YES;
        liked.omitTrack = YES;
        [liked likedTracks:^(id result, NSError *error) {
            CHECK([NSThread isMainThread]);
            CHECK(error == nil);
            CHECK([result[@"tracks"] count] == 204);
            CHECK([result[@"unavailableTrackIDs"] isEqual:@[ @"5000000000" ]]);
            CHECK([result[@"totalCount"] unsignedIntegerValue] == 205);
            CHECK(liked.detailCalls == 3);
            finish();
        }];
        [api album:@"1/injection"
            completion:^(id result, NSError *error) {
                CHECK([NSThread isMainThread]);
                CHECK(result == nil && error != nil);
                finish();
            }];
        [api likedTracks:^(id result, NSError *error) {
            CHECK([NSThread isMainThread]);
            CHECK(result == nil && error.code == 301);
            finish();
        }];
        [api artist:@"12"
            completion:^(id result, NSError *error) {
                CHECK(error == nil);
                CHECK([result[@"albums"] count] == 2);
                CHECK(api.albumCalls == 2);
                finish();
            }];
        SessionFixtureAPI *session = [[SessionFixtureAPI alloc] init];
        [session refreshLogin:^(id result, NSError *error) {
            CHECK(result == nil);
            CHECK(error.code == NSURLErrorCancelled);
            CHECK(session.logoutCalls == 1);
            finish();
        }];
        [session logout];
        session.pendingCompletion(nil, [NSError errorWithDomain:@"MCAPIErrorDomain" code:301 userInfo:nil]);
        SessionFixtureAPI *qr = [[SessionFixtureAPI alloc] init];
        [qr pollLoginKey:@"old-key"
              completion:^(id result, NSError *error) {
                  CHECK(result == nil && error.code == NSURLErrorCancelled);
                  finish();
              }];
        MCAPICompletion oldPoll = qr.pendingCompletion;
        [qr createLoginKey:^(id result, NSError *error) {
            (void)result;
            (void)error;
        }];
        qr.pendingCompletion = nil;
        oldPoll(@{@"code" : @801}, nil);
        SessionFixtureAPI *like = [[SessionFixtureAPI alloc] init];
        [like likeTrack:@"5000000000"
                  liked:YES
             completion:^(id result, NSError *error) {
                 BOOL main = [NSThread isMainThread];
                 dispatch_async(dispatch_get_main_queue(), ^{
                     CHECK(main);
                     CHECK(error == nil && [result[@"code"] integerValue] == 200);
                     finish();
                 });
             }];
        MCAPICompletion likeResponse = like.pendingCompletion;
        like.pendingCompletion = nil;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            likeResponse(@{@"code" : @200}, nil);
        });
        CFRunLoopRun();
    }
}
