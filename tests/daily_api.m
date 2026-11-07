#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import "MCAPI.h"
#import "MCEAPI.h"
#import <dispatch/dispatch.h>
@interface DailyFixtureAPI : MCAPI
@property (nonatomic) BOOL hasAccount;
@property (nonatomic) NSUInteger calls;
@property (nonatomic, strong) NSDictionary *response;
@property (nonatomic, strong) NSError *failure;
@end
@implementation DailyFixtureAPI
- (BOOL)loggedIn { return self.hasAccount; }
- (NSDictionary *)keychainQuery {
    return @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
             (__bridge id)kSecAttrService:@"com.muyu.network.tests.only",
             (__bridge id)kSecAttrAccount:@"daily"};
}
- (void)sendPath:(NSString *)path parameters:(NSDictionary *)parameters completion:(MCAPICompletion)completion {
    NSCAssert([path isEqual:@"/api/v3/discovery/recommend/songs"], @"daily endpoint");
    NSCAssert(parameters.count == 0, @"no fabricated recommendation parameters");
    self.calls++;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        completion(self.response, self.failure);
    });
}
@end
static void check(DailyFixtureAPI *api, NSInteger expectedError, NSArray *ids) {
    __block BOOL done = NO;
    [api dailyRecommendations:^(id result, NSError *error) {
        NSCAssert([NSThread isMainThread], @"main callback");
        NSCAssert(error.code == expectedError, @"error preserved");
        if (expectedError) NSCAssert(result == nil, @"no fallback results");
        else {
            NSArray *tracks = result[@"tracks"];
            NSCAssert(tracks.count == ids.count, @"count");
            NSCAssert([result[@"totalCount"] unsignedIntegerValue] == ids.count, @"total");
            for (NSUInteger i = 0; i < ids.count; i++)
                NSCAssert([tracks[i][@"id"] isEqual:ids[i]], @"ordered 64-bit IDs");
            if (ids.count == 2) {
                NSCAssert([tracks[0][@"title"] isEqual:@"每日歌曲"], @"real title retained");
                NSCAssert([tracks[0][@"artist"] isEqual:@"歌手"], @"real artist retained");
                NSCAssert([tracks[0][@"duration"] doubleValue] == 180, @"duration normalized");
            }
            NSCAssert([result[@"unavailableTrackIDs"] count] == 0, @"complete actual records");
        }
        done = YES;
    }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!done && [deadline timeIntervalSinceNow] > 0)
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    NSCAssert(done, @"request completion");
}
int main(void) { @autoreleasepool {
    DailyFixtureAPI *api = [DailyFixtureAPI new];
    check(api, 301, nil);
    NSCAssert(api.calls == 0, @"not logged in: no network request");
    api.hasAccount = YES;
    api.response = @{@"code":@200, @"data":@{@"dailySongs":@[
        @{@"id":@5000000001LL,@"name":@"每日歌曲",@"ar":@[@{@"name":@"歌手"}],@"dt":@180000},
        @{@"id":@5000000000LL,@"name":@"Second"}]}};
    check(api, 0, @[@"5000000001",@"5000000000"]);
    api.response = @{@"data":@{@"dailySongs":@[]}};
    check(api, 0, @[]);
    for (NSDictionary *bad in @[@{}, @{@"data":@{@"dailySongs":@"bad"}},
                                @{@"recommend":@[]},
                                @{@"data":@{@"dailySongs":@[@{@"id":@1}]}},
                                @{@"data":@{@"dailySongs":@[@{@"id":@"oops",@"name":@"Bad"}]}}]) {
        api.response = bad;
        check(api, -48, nil);
    }
    api.failure = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil];
    check(api, NSURLErrorTimedOut, nil);
    api.failure = [NSError errorWithDomain:MCAPIErrorDomain code:301 userInfo:nil];
    check(api, 301, nil);
    puts("daily_api: login, actual order/metadata, empty/malformed data and errors passed");
    return 0;
} }
