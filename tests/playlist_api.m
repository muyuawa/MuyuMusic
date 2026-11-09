#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <dispatch/dispatch.h>
#import "MCAPI.h"
#import "MCEAPI.h"

// Replace only the remote boundary; ownership, pagination and mutations use MCAPI.
@interface PlaylistFixtureAPI : MCAPI
@property (nonatomic) BOOL hasAccount;
@property (nonatomic) NSUInteger calls;
@property (nonatomic, copy) NSString *lastPath;
@property (nonatomic, copy) NSDictionary *lastParameters;
@property (nonatomic, strong) NSError *failure;
@end
@implementation PlaylistFixtureAPI
- (BOOL)loggedIn { return self.hasAccount; }
- (NSDictionary *)profile { return self.hasAccount ? @{@"userId":@5000000000LL} : @{}; }
- (NSDictionary *)keychainQuery {
    return @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService:@"com.muyu.network.tests.only", (__bridge id)kSecAttrAccount:@"playlists"};
}
- (void)sendPath:(NSString *)path parameters:(NSDictionary *)parameters completion:(MCAPICompletion)completion {
    self.calls++;
    self.lastPath = path;
    self.lastParameters = parameters;
    NSError *failure = self.failure;
    NSDictionary *response = @{@"code":@200};
    if ([path isEqual:@"/api/user/playlist"]) {
        NSCAssert([parameters[@"uid"] isEqual:@"5000000000"], @"full account ID");
        BOOL first = [parameters[@"offset"] unsignedIntegerValue] == 0;
        response = @{@"code":@200, @"more":@(first), @"playlist": first ? @[
            @{@"id":@6000000000LL, @"name":@"我的歌单", @"creator":@{@"userId":@5000000000LL}},
            @{@"id":@6000000001LL, @"name":@"收藏的歌单", @"creator":@{@"userId":@7}},
            @{@"id":@6000000002LL, @"name":@"未知创建者"}] : @[
            @{@"id":@6000000003LL, @"name":@"第二页歌单", @"creator":@{@"userId":@"5000000000"}}]};
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        completion(failure ? nil : response, failure);
    });
}
@end

static void check(void (^request)(MCAPICompletion), NSInteger expectedError, void (^verify)(id)) {
    __block BOOL done = NO;
    request(^(id result, NSError *error) {
        NSCAssert([NSThread isMainThread], @"main completion");
        NSCAssert(error.code == expectedError, @"original error preserved");
        if (expectedError) NSCAssert(result == nil, @"no invented success");
        else if (verify) verify(result);
        done = YES;
    });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!done && [deadline timeIntervalSinceNow] > 0)
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    NSCAssert(done, @"completion delivered");
}
int main(void) { @autoreleasepool {
    PlaylistFixtureAPI *api = [PlaylistFixtureAPI new];
    check(^(MCAPICompletion c) { [api editablePlaylists:c]; }, 301, nil);
    check(^(MCAPICompletion c) { [api addTrack:@"5000000001" toPlaylist:@"6000000000" completion:c]; }, 301, nil);
    check(^(MCAPICompletion c) { [api subscribePlaylist:@"6000000001" completion:c]; }, 301, nil);
    NSCAssert(api.calls == 0, @"unauthenticated requests never sent");
    api.hasAccount = YES;
    check(^(MCAPICompletion c) { [api editablePlaylists:c]; }, 0, ^(NSArray *lists) {
        NSCAssert(lists.count == 2, @"only owned playlists across all pages");
        NSCAssert([lists[0][@"id"] isEqual:@"6000000000"], @"full playlist ID");
        NSCAssert([lists[1][@"id"] isEqual:@"6000000003"], @"second page preserved");
    });
    NSCAssert(api.calls == 2, @"pagination completed");
    check(^(MCAPICompletion c) { [api addTrack:@"5000000001" toPlaylist:@"6000000000" completion:c]; }, 0, nil);
    NSCAssert([api.lastPath isEqual:@"/api/playlist/manipulate/tracks"], @"add endpoint");
    NSCAssert([api.lastParameters[@"op"] isEqual:@"add"] && [api.lastParameters[@"pid"] isEqual:@"6000000000"], @"selected target");
    NSArray *ids = [NSJSONSerialization JSONObjectWithData:[api.lastParameters[@"trackIds"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
    NSCAssert([ids isEqual:@[@"5000000001"]], @"one complete string ID, no duplicated tracks");
    check(^(MCAPICompletion c) { [api subscribePlaylist:@"6000000001" completion:c]; }, 0, nil);
    NSCAssert([api.lastPath isEqual:@"/api/playlist/subscribe"] && [api.lastParameters[@"id"] isEqual:@"6000000001"], @"subscribe contract");
    NSUInteger calls = api.calls;
    check(^(MCAPICompletion c) { [api addTrack:@"local:12" toPlaylist:@"6000000000" completion:c]; }, -31, nil);
    check(^(MCAPICompletion c) { [api addTrack:@"12" toPlaylist:@"12/injection" completion:c]; }, -31, nil);
    check(^(MCAPICompletion c) { [api subscribePlaylist:@"local:12" completion:c]; }, -31, nil);
    NSCAssert(api.calls == calls, @"invalid IDs never sent");
    api.failure = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil];
    check(^(MCAPICompletion c) { [api editablePlaylists:c]; }, NSURLErrorTimedOut, nil);
    check(^(MCAPICompletion c) { [api addTrack:@"12" toPlaylist:@"13" completion:c]; }, NSURLErrorTimedOut, nil);
    api.failure = [NSError errorWithDomain:MCAPIErrorDomain code:512 userInfo:@{NSLocalizedDescriptionKey:@"歌单已有此歌曲"}];
    check(^(MCAPICompletion c) { [api addTrack:@"12" toPlaylist:@"13" completion:c]; }, 512, nil);
    check(^(MCAPICompletion c) { [api subscribePlaylist:@"13" completion:c]; }, 512, nil);
    puts("playlist_api: login, owned pagination, exact target/IDs, invalid IDs and service/network errors passed");
    return 0;
} }
