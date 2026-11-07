#import <Foundation/Foundation.h>
#import "../Sources/Network/MCMusicSources.h"
#import "../Sources/Network/MCSourceAPI.h"
#import "../Sources/Network/MCAPI.h"
#import "../Sources/Network/MCLXRuntime.h"
#import "../Sources/Network/MCHTTPClient.h"
#import "../Sources/Network/MCSourceSecurity.h"
static NSUInteger runtimeStarts;
static BOOL delayResolution;
static NSError *fixtureResolveError;
@interface MCLXRuntime ()
@property (nonatomic, copy) NSString *fixtureScript;
@property (nonatomic) BOOL fixtureStarted;
@property (nonatomic, copy) void (^pending)(NSDictionary *, NSError *);
@end
@implementation MCLXRuntime
- (instancetype)initWithScript:(NSString *)s information:(NSDictionary *)i {
    (void)i;
    if ((self = [super init]))
        self.fixtureScript = s;
    return self;
}
- (NSDictionary *)sources {
    if ([self.fixtureScript containsString:@"unsupported"])
        return @{@"qq" : @{@"actions" : @[ @"musicUrl" ]}};
    return @{@"wy" : @{@"actions" : @[ @"musicUrl" ], @"qualitys" : @[ @"128k" ]}};
}
- (void)start:(void (^)(NSDictionary *, NSError *))c {
    runtimeStarts++;
    if (self.fixtureStarted) {
        c(nil, [NSError errorWithDomain:@"fixture" code:1 userInfo:nil]);
        return;
    }
    self.fixtureStarted = YES;
    c(self.sources, nil);
}
- (MCSourceTask *)resolveTrack:(NSDictionary *)t
                       quality:(NSString *)q
                    completion:(void (^)(NSDictionary *, NSError *))c {
    (void)t;
    (void)q;
    if (delayResolution)
        self.pending = c;
    else
        c(fixtureResolveError ? nil : @{@"url" : @"https://media.test/a"}, fixtureResolveError);
    return [[MCSourceTask alloc] initWithCancellation:nil];
}
- (void)invalidate {
    if (self.pending) {
        void (^c)(NSDictionary *, NSError *) = self.pending;
        self.pending = nil;
        c(nil, [NSError errorWithDomain:@"fixture" code:1 userInfo:nil]);
    }
}
@end
@implementation MCRequest
- (void)cancel {
}
@end
static NSURL *lastURL;
static NSData *lastBody;
static NSDictionary *lastHeaders;
static NSDictionary *fixtureResponse;
@implementation MCHTTPClient
+ (instancetype)sharedClient {
    return [self new];
}
- (MCRequest *)sourceRequestURL:(NSURL *)u
                         method:(NSString *)m
                           body:(NSData *)b
                        headers:(NSDictionary *)h
                        timeout:(NSTimeInterval)t
                     completion:(void (^)(NSData *, NSDictionary *, NSError *))c {
    lastURL = u;
    lastBody = b;
    lastHeaders = h;
    (void)m;
    (void)t;
    c([@"https://media.test/a" dataUsingEncoding:NSUTF8StringEncoding],
      fixtureResponse ?: @{@"status" : @200}, nil);
    return [MCRequest new];
}
@end
@implementation MCAPI
+ (instancetype)sharedAPI {
    return [self new];
}
- (void)songURL:(NSString *)i quality:(NSString *)q completion:(MCAPICompletion)c {
    (void)i;
    (void)q;
    c(@{@"url" : @"https://music.126.net/a"}, nil);
}
@end
static void check(BOOL b, NSString *s) {
    if (!b) {
        NSLog(@"FAIL %@", s);
        exit(1);
    }
}
static NSData *bytes(NSString *s) {
    return [s dataUsingEncoding:NSUTF8StringEncoding];
}
int main(void) {
    @autoreleasepool {
        id savedPolicy = [[NSUserDefaults standardUserDefaults] objectForKey:MCSourceHTTPSOnlyKey];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:MCSourceHTTPSOnlyKey];
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
        MCMusicSources *r = [[MCMusicSources alloc] initWithDirectory:dir];
        check([r.selectedIdentifier isEqual:@"netease"] && r.entries.count == 1, @"builtin default");
        check([r consumeRecoveryNotice] == nil, @"fresh install has no recovery warning");
        NSError *e = nil;
        check(![r removeIdentifier:@"netease" error:&e], @"builtin immutable");
        check(![r selectIdentifier:@"missing" error:&e], @"missing selection rejected");
        NSDictionary *cfg =
            @{@"name" : @"Fixture", @"url" : @"https://example.test/get?id={id}", @"urlPath" : @"data.0.url"};
        NSDictionary *a = [r saveAPIConfiguration:cfg identifier:nil error:&e];
        check(a != nil, @"save valid API");
        check([r selectIdentifier:a[@"identifier"] error:&e], @"select API");
        check([[[[MCMusicSources alloc] initWithDirectory:dir] selectedIdentifier] isEqual:a[@"identifier"]],
              @"persist selection");
        check(![r saveAPIConfiguration:cfg identifier:@"absent" error:&e],
              @"editing missing source cannot create/overwrite");
        check(![MCSourceAPI validateConfiguration:(id) @[] error:&e],
              @"nonobject configuration rejected without exception");
        NSDictionary *httpConfig =
            [MCSourceAPI validateConfiguration:@{@"name" : @"x", @"url" : @"http://example.test/token=secret"}
                                         error:&e];
        check(httpConfig != nil, @"HTTP configuration syntax is retained with HTTPS restriction");
        NSDictionary *httpEntry = [r saveAPIConfiguration:httpConfig identifier:nil error:&e];
        check(httpEntry && [r selectIdentifier:httpEntry[@"identifier"] error:&e] &&
                  [[[[MCMusicSources alloc] initWithDirectory:dir] selectedEntry][@"identifier"]
                      isEqual:httpEntry[@"identifier"]],
              @"HTTP configuration survives restart with restriction enabled");
        check([r removeIdentifier:httpEntry[@"identifier"] error:&e], @"HTTP fixture removed");
        check([r selectIdentifier:a[@"identifier"] error:&e], @"restore API fixture selection");
        __block BOOL httpDone = NO;
        lastURL = nil;
        [MCSourceAPI
            resolveConfiguration:httpConfig
                           track:@{@"id" : @"1"}
                         quality:@"standard"
                      completion:^(NSDictionary *resource, NSError *error) {
                          check(!resource && [error.localizedDescription containsString:@"仅允许 HTTPS"],
                                @"HTTP request blocked with actionable reason");
                          check(!lastURL, @"blocked HTTP request never reaches transport");
                          httpDone = YES;
                      }];
        while (!httpDone)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
        check(![e.localizedDescription containsString:@"secret"], @"safe error");
        check(![MCSourceAPI
                  validateConfiguration:@{@"name" : @"x", @"url" : @"https://user:pass@example.test"}
                                  error:&e],
              @"reject URL credentials");
        NSMutableDictionary *mutableHeaders = [@{@"Authorization" : @"first"} mutableCopy];
        NSDictionary *normalized = [MCSourceAPI validateConfiguration:@{
            @"name" : @"Snapshot",
            @"url" : @"https://example.test",
            @"headers" : mutableHeaders
        }
                                                                error:&e];
        mutableHeaders[@"Authorization"] = @"changed";
        check([normalized[@"headers"][@"Authorization"] isEqual:@"first"],
              @"normalized configuration is an immutable snapshot");
        check(![MCSourceAPI validateConfiguration:@{@"name" : @"x", @"url" : @"https://@example.test"}
                                            error:&e],
              @"empty embedded URL credentials rejected");
        NSDictionary *res =
            [MCSourceAPI resourceFromData:bytes(@"{\"data\":[{\"url\":\"https://media.test/a\"}]}")
                                 response:@{
                                     @"status" : @200
                                 }
                            configuration:cfg
                                    error:&e];
        check([res[@"url"] isEqual:@"https://media.test/a"] && !res[@"size"],
              @"nested extraction unknown metadata");
        check([MCSourceAPI resourceFromData:nil
                                   response:@{
                                       @"status" : @302,
                                       @"headers" : @{@"location" : @"https://media.test/r"}
                                   }
                              configuration:cfg
                                      error:&e] != nil,
              @"redirect is media result");
        check(![MCSourceAPI resourceFromData:bytes(@"http://media.test/a")
                  response:@{
                      @"status" : @200
                  }
                  configuration:@{}
                  error:&e],
              @"HTTP result rejected");
        check([e.localizedDescription containsString:@"仅允许 HTTPS"], @"HTTP result explains restriction");
        MCSetSourceHTTPSOnly(NO);
        check([MCSourceAPI resourceFromData:bytes(@"http://media.test/a")
                  response:@{
                      @"status" : @200
                  }
                  configuration:@{}
                  error:&e] != nil,
              @"HTTP result permitted when restriction disabled");
        httpDone = NO;
        [MCSourceAPI resolveConfiguration:httpConfig
                                    track:@{@"id" : @"1"}
                                  quality:@"standard"
                               completion:^(NSDictionary *resource, NSError *error) {
                                   check(resource && !error && [lastURL.scheme isEqual:@"http"],
                                         @"HTTP API request permitted when disabled");
                                   httpDone = YES;
                               }];
        while (!httpDone)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
        MCSetSourceHTTPSOnly(YES);
        check(![MCSourceAPI
                  resourceFromData:bytes(@"{\"url\":\"https://media.test/a\",\"error\":\"token=secret\"}")
                  response:@{
                      @"status" : @200
                  }
                  configuration:@{}
                  error:&e],
              @"error marked result rejected");
        check(![e.localizedDescription containsString:@"secret"], @"service credentials redacted");
        check(
            ![MCSourceAPI
                resourceFromData:
                    bytes(
                        @"{\"code\":403,\"message\":\"额度用完 token=secret https://host.test/?key=hidden\"}")
                response:@{
                    @"status" : @200
                }
                configuration:@{}
                error:&e],
            @"service error rejected");
        check([e.localizedDescription containsString:@"额度用完"] &&
                  [e.localizedDescription containsString:@"403"] &&
                  ![e.localizedDescription containsString:@"secret"] &&
                  ![e.localizedDescription containsString:@"hidden"],
              @"service reason and code preserved safely");
        check(
            ![MCSourceAPI
                resourceFromData:
                    bytes(@"{\"data\":[{\"url\":\"https://media.test/a\",\"freeTrialInfo\":{\"start\":0}}]}")
                response:@{
                    @"status" : @200
                }
                configuration:@{}
                error:&e],
            @"nested trial result rejected");
        check(![MCSourceAPI resourceFromData:nil response:@{
            @"status" : @200
        }
                  configuration:@{}
                  error:&e],
              @"empty response rejected without exception");
        for (NSString *location in @[ @"/media/a", @"//cdn.test/a", @"http://media.test/a" ]) {
            NSDictionary *redirect = [MCSourceAPI resourceFromData:nil
                response:@{
                    @"status" : @302,
                    @"headers" : @{@"Location" : location},
                    @"requestURL" : @"https://api.test/music/123/resolve"
                }
                configuration:@{}
                error:&e];
            if ([location hasPrefix:@"http:"])
                check(redirect == nil, @"relative redirect HTTPS policy");
            else
                check([redirect[@"url"] isEqual:[location hasPrefix:@"//"] ? @"https://cdn.test/a"
                                                                           : @"https://api.test/media/a"],
                      @"relative and scheme-relative media redirects resolve against actual request");
        }
        __block int cancels = 0;
        MCSourceTask *t = [[MCSourceTask alloc] initWithCancellation:^{
            cancels++;
        }];
        [t cancel];
        [t cancel];
        t.cancellation = ^{
            cancels++;
        };
        check(cancels == 2, @"idempotent cancellation replacement");
        __block BOOL done = NO;
        [MCSourceAPI resolveConfiguration:@{
            @"name" : @"x",
            @"url" : @"https://example.test/a?id={id}&title={title}",
            @"method" : @"POST",
            @"headers" : @{@"Authorization" : @"Bearer private"},
            @"bodyTemplate" : @{@"text" : @"{title}", @"artist" : @"{artist}"}
        }
            track:@{@"id" : @"9007199254740993", @"title" : @"{artist}&中\"", @"artist" : @"other"}
            quality:@"lossless"
            completion:^(NSDictionary *v, NSError *err) {
                check(v != nil && !err, @"API resolution completes");
                done = YES;
            }];
        while (!done)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        check([lastURL.absoluteString containsString:@"9007199254740993"] &&
                  [lastURL.absoluteString containsString:@"%7Bartist%7D%26"],
              @"URL values encoded once and large IDs preserved");
        NSDictionary *body = [NSJSONSerialization JSONObjectWithData:lastBody options:0 error:NULL];
        check([body[@"text"] isEqual:@"{artist}&中\""] &&
                  [lastHeaders[@"Authorization"] isEqual:@"Bearer private"],
              @"JSON escaped once and explicit headers forwarded");
        fixtureResponse = @{@"status" : @302, @"headers" : @{@"location" : @"media/a"}};
        done = NO;
        [MCSourceAPI
            resolveConfiguration:@{@"name" : @"redirect", @"url" : @"https://api.test/music/{id}/resolve"}
                           track:@{@"id" : @"9007199254740993"}
                         quality:@"standard"
                      completion:^(NSDictionary *v, NSError *err) {
                          check([v[@"url"] isEqual:@"https://api.test/music/9007199254740993/media/a"] &&
                                    !err,
                                @"resolver uses expanded request URL for redirect base");
                          done = YES;
                      }];
        while (!done)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        fixtureResponse = nil;
        NSString *script = @"/**\n * @name Fixture Script\n * @version 1\n */\nlx.send('inited', {})";
        __block NSDictionary *imported = nil;
        done = NO;
        [r importScript:script
                 origin:nil
             completion:^(NSDictionary *v, NSError *err) {
                 check(v != nil && !err, @"import validated script");
                 imported = v;
                 done = YES;
             }];
        while (!done)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        NSUInteger count = r.entries.count;
        done = NO;
        [r importScript:script
                 origin:nil
             completion:^(NSDictionary *v, NSError *err) {
                 check([v[@"identifier"] isEqual:imported[@"identifier"]] && !err,
                       @"duplicate returns same entry");
                 done = YES;
             }];
        while (!done)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        check(r.entries.count == count, @"duplicate does not create source");
        done = NO;
        [r importScript:[script stringByAppendingString:@"; // revised"]
                 origin:nil
             completion:^(NSDictionary *v, NSError *err) {
                 check(![v[@"identifier"] isEqual:imported[@"identifier"]] && !err,
                       @"same name revised script preserves original");
                 done = YES;
             }];
        while (!done)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        check(r.entries.count == count + 1, @"same name never overwrites");
        check([r selectIdentifier:imported[@"identifier"] error:&e], @"select script");
        for (int n = 0; n < 2; n++) {
            done = NO;
            [r resolveTrack:@{@"id" : @"1"}
                    quality:@"standard"
                 completion:^(NSDictionary *v, NSError *err) {
                     check([v[@"sourceIdentifier"] isEqual:imported[@"identifier"]] &&
                               [v[@"customSource"] boolValue] && !err,
                           @"cached script resolves with source identity");
                     done = YES;
                 }];
            while (!done)
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        for (NSString *domain in @[ @"MCLXRuntime", @"foreign" ]) {
            fixtureResolveError =
                [NSError errorWithDomain:domain
                                    code:1
                                userInfo:@{
                                    NSLocalizedDescriptionKey : [domain isEqual:@"MCLXRuntime"]
                                        ? @"音源解析超时"
                                        : @"secret=https://token.test/private"
                                }];
            done = NO;
            [r resolveTrack:@{@"id" : @"1"}
                    quality:@"standard"
                 completion:^(NSDictionary *v, NSError *err) {
                     check(!v && err &&
                               ([domain isEqual:@"MCLXRuntime"]
                                    ? [err.localizedDescription isEqual:@"音源解析超时"]
                                    : ![err.localizedDescription containsString:@"secret"]),
                           @"preserve short trusted runtime error and redact other domains");
                     done = YES;
                 }];
            while (!done)
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        fixtureResolveError = nil;
        delayResolution = YES;
        done = NO;
        [r resolveTrack:@{@"id" : @"1"}
                quality:@"standard"
             completion:^(NSDictionary *v, NSError *err) {
                 check(!v && err, @"deleting pending runtime settles resolver with retryable error");
                 done = YES;
             }];
        check([r removeIdentifier:imported[@"identifier"] error:&e] &&
                  [r.selectedIdentifier isEqual:@"netease"],
              @"deleting selected source restores builtin");
        check(done, @"deleting source does not leave resolver buffering");
        delayResolution = NO;
        done = NO;
        __block NSDictionary *unsupported = nil;
        [r importScript:[script stringByAppendingString:@"; // unsupported"]
                 origin:nil
             completion:^(NSDictionary *v, NSError *err) {
                 check(v != nil && !err && ![v[@"selectable"] boolValue] && [v[@"reason"] length] > 0,
                       @"non-wy scripts preserved with explicit reason");
                 unsupported = v;
                 done = YES;
             }];
        while (!done)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        check(![r selectIdentifier:unsupported[@"identifier"] error:&e],
              @"unsupported script cannot be selected");
        NSString *privateDir = [dir stringByAppendingPathComponent:@"private-fixture"];
        MCMusicSources *privateRegistry = [[MCMusicSources alloc] initWithDirectory:privateDir];
        NSDictionary *secretConfig = @{
            @"name" : @"Private API",
            @"url" : @"https://api.test/path?sentinel_query=private",
            @"method" : @"POST",
            @"headers" : @{@"Authorization" : @"sentinel_token"},
            @"bodyTemplate" : @{@"secret" : @"sentinel_body"}
        };
        NSDictionary *privateEntry = [privateRegistry saveAPIConfiguration:secretConfig
                                                                identifier:nil
                                                                     error:&e];
        NSString *indexPath = [privateDir stringByAppendingPathComponent:@"index.json"];
        NSString *indexText = [NSString stringWithContentsOfFile:indexPath
                                                        encoding:NSUTF8StringEncoding
                                                           error:NULL];
        check(privateEntry && ![indexText containsString:@"sentinel_"] &&
                  ![indexText containsString:@"configuration\""],
              @"index excludes query token and body secrets");
        NSString *privatePath =
            [privateDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@.api.json",
                                                                                  privateEntry[@"identifier"],
                                                                                  privateEntry[@"revision"]]];
        check([[NSFileManager defaultManager] fileExistsAtPath:privatePath],
              @"private configuration stored separately");
        check([privateRegistry selectIdentifier:privateEntry[@"identifier"] error:&e], @"select private API");
        MCMusicSources *reopened = [[MCMusicSources alloc] initWithDirectory:privateDir];
        check([reopened.selectedEntry[@"configuration"][@"headers"][@"Authorization"]
                  isEqual:@"sentinel_token"],
              @"private config survives restart");
        NSDictionary *edited = [privateRegistry saveAPIConfiguration:secretConfig
                                                          identifier:privateEntry[@"identifier"]
                                                               error:&e];
        check(edited && ![[NSFileManager defaultManager] fileExistsAtPath:privatePath],
              @"edit removes obsolete private revision after index commit");
        NSString *editedPath =
            [privateDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@.api.json",
                                                                                  edited[@"identifier"],
                                                                                  edited[@"revision"]]];
        [[NSFileManager defaultManager] removeItemAtPath:indexPath error:NULL];
        [[NSFileManager defaultManager] createDirectoryAtPath:indexPath
                                  withIntermediateDirectories:NO
                                                   attributes:nil
                                                        error:NULL];
        check(![privateRegistry saveAPIConfiguration:secretConfig
                                          identifier:privateEntry[@"identifier"]
                                               error:&e] &&
                  [[NSFileManager defaultManager] fileExistsAtPath:editedPath] &&
                  [privateRegistry.selectedEntry[@"revision"] isEqual:edited[@"revision"]],
              @"failed index replacement preserves old private configuration");
        NSArray *privateFiles = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:privateDir
                                                                                    error:NULL];
        check(privateFiles.count == 2, @"failed update removes newly created orphan configuration");
        [[NSFileManager defaultManager] removeItemAtPath:indexPath error:NULL];
        check([privateRegistry removeIdentifier:privateEntry[@"identifier"] error:&e] &&
                  ![[NSFileManager defaultManager] fileExistsAtPath:editedPath],
              @"delete removes private configuration");
        NSDictionary *legacy = @{
            @"version" : @1,
            @"selectedIdentifier" : privateEntry[@"identifier"],
            @"entries" : @[ privateRegistry.entries[0], privateEntry ]
        };
        [[NSJSONSerialization dataWithJSONObject:legacy options:0
                                           error:NULL] writeToFile:indexPath atomically:YES];
        MCMusicSources *migrated = [[MCMusicSources alloc] initWithDirectory:privateDir];
        indexText = [NSString stringWithContentsOfFile:indexPath encoding:NSUTF8StringEncoding error:NULL];
        check([migrated.selectedEntry[@"configuration"][@"headers"][@"Authorization"]
                  isEqual:@"sentinel_token"] &&
                  ![indexText containsString:@"sentinel_"],
              @"legacy inline secrets migrate to private file");
        MCMusicSources *migrationRestart = [[MCMusicSources alloc] initWithDirectory:privateDir];
        check([migrationRestart.selectedEntry[@"configuration"][@"bodyTemplate"][@"secret"]
                  isEqual:@"sentinel_body"],
              @"migrated private layout survives second restart");
        NSMutableDictionary *tampered =
            [[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:indexPath]
                                             options:NSJSONReadingMutableContainers
                                               error:NULL] mutableCopy];
        for (NSMutableDictionary *entry in tampered[@"entries"])
            if ([entry[@"kind"] isEqual:@"api"])
                entry[@"configurationFile"] = @"../../outside.api.json";
        NSString *outside = [dir stringByAppendingPathComponent:@"outside.api.json"];
        [@"preserve outside" writeToFile:outside atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        [[NSJSONSerialization dataWithJSONObject:tampered options:0
                                           error:NULL] writeToFile:indexPath atomically:YES];
        MCMusicSources *rejectTraversal = [[MCMusicSources alloc] initWithDirectory:privateDir];
        check(rejectTraversal.entries.count == 1 && [rejectTraversal.selectedIdentifier isEqual:@"netease"] &&
                  [[NSString stringWithContentsOfFile:outside encoding:NSUTF8StringEncoding
                                                error:NULL] isEqual:@"preserve outside"],
              @"index cannot redirect private config paths or mutate files outside registry");
        check([rejectTraversal consumeRecoveryNotice].length > 0 &&
                  [[[MCMusicSources alloc] initWithDirectory:privateDir] consumeRecoveryNotice] == nil,
              @"invalid source recovery written once");
        NSDictionary *missingSelection =
            @{@"version" : @1,
              @"entries" : rejectTraversal.entries,
              @"selectedIdentifier" : @"missing"};
        [[NSJSONSerialization dataWithJSONObject:missingSelection options:0
                                           error:NULL] writeToFile:indexPath atomically:YES];
        MCMusicSources *missingRecovery = [[MCMusicSources alloc] initWithDirectory:privateDir];
        check([missingRecovery.selectedIdentifier isEqual:@"netease"] &&
                  [missingRecovery consumeRecoveryNotice].length > 0 &&
                  [[[MCMusicSources alloc] initWithDirectory:privateDir] consumeRecoveryNotice] == nil,
              @"missing selected identifier recovers persistently once");
        [@"bad" writeToFile:[dir stringByAppendingPathComponent:@"index.json"]
                 atomically:YES
                   encoding:NSUTF8StringEncoding
                      error:NULL];
        MCMusicSources *recovered = [[MCMusicSources alloc] initWithDirectory:dir];
        check([recovered.selectedIdentifier isEqual:@"netease"], @"malformed index recovery");
        check([recovered consumeRecoveryNotice].length > 0 && [recovered consumeRecoveryNotice] == nil,
              @"malformed index recovery notice consumed once");
        check([[[MCMusicSources alloc] initWithDirectory:dir] consumeRecoveryNotice] == nil,
              @"recovered valid index persists and second restart has no warning");
        [[NSFileManager defaultManager] removeItemAtPath:dir error:NULL];
        if (savedPolicy)
            [[NSUserDefaults standardUserDefaults] setObject:savedPolicy forKey:MCSourceHTTPSOnlyKey];
        else
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:MCSourceHTTPSOnlyKey];
        NSLog(@"music sources assertions passed");
    }
    return 0;
}
