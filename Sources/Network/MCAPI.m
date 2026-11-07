#import "MCAPI.h"
#import "MCHTTPClient.h"
#import "MCEAPI.h"
#import <Security/Security.h>
#import <dispatch/dispatch.h>

static NSDictionary *MCObject(id value) {
    return [value isKindOfClass:[NSDictionary class]] ? value : @{};
}
static NSArray *MCList(id value) {
    return [value isKindOfClass:[NSArray class]] ? value : @[];
}
static BOOL MCBool(id value) {
    return [value respondsToSelector:@selector(boolValue)] && [value boolValue];
}
static unsigned long long MCCount(id value) {
    return [value respondsToSelector:@selector(unsignedLongLongValue)] ? [value unsignedLongLongValue] : 0;
}
static NSString *MCText(id value) {
    return [value isKindOfClass:[NSString class]] ? value : @"";
}
static NSError *MCAPIError(NSInteger code, NSString *text) {
    return [NSError errorWithDomain:MCAPIErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey : text}];
}
static void MCComplete(MCAPICompletion completion, id result, NSError *error) {
    if (completion)
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(result, error);
        });
}
static NSString *MCEncode(NSString *s) {
    NSMutableCharacterSet *allowed = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [allowed addCharactersInString:@"-._~"];
    return [s stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}
static NSArray *MCTracks(id songs) {
    NSMutableArray *result = [NSMutableArray array];
    for (id song in MCList(songs)) {
        NSDictionary *track = [MCEAPI track:song];
        if (track)
            [result addObject:track];
    }
    return result;
}
static NSArray *MCCatalog(id items) {
    NSMutableArray *result = [NSMutableArray array];
    for (id item in MCList(items)) {
        NSDictionary *value = [MCEAPI catalogItem:item];
        if (value)
            [result addObject:value];
    }
    return result;
}

@interface MCAPI () {
    NSMutableDictionary *_cookies;
    NSDictionary *_accountProfile;
    NSString *_deviceID;
    NSUInteger _sessionGeneration;
    NSUInteger _loginGeneration;
    dispatch_queue_t _parsingQueue;
}
@end
@implementation MCAPI
+ (instancetype)sharedAPI {
    static MCAPI *api;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        api = [[self alloc] init];
    });
    return api;
}
- (NSDictionary *)keychainQuery {
    return @{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService : @"com.muyu.cloudmusic.session",
        (__bridge id)kSecAttrAccount : @"netease"
    };
}
- (instancetype)init {
    if ((self = [super init])) {
        _parsingQueue = dispatch_queue_create("com.muyu.api.parse", DISPATCH_QUEUE_SERIAL);
        _cookies = [NSMutableDictionary dictionary];
        _accountProfile = @{};
        _deviceID = [[NSUserDefaults standardUserDefaults] stringForKey:@"MCNetworkDeviceID"];
        if (![_deviceID length]) {
            _deviceID = [[NSUUID UUID] UUIDString];
            [[NSUserDefaults standardUserDefaults] setObject:_deviceID forKey:@"MCNetworkDeviceID"];
        }
        NSMutableDictionary *q = [[self keychainQuery] mutableCopy];
        q[(__bridge id)kSecReturnData] = @YES;
        q[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
        CFTypeRef saved = NULL;
        if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &saved) == errSecSuccess) {
            NSData *data = CFBridgingRelease(saved);
            NSDictionary *session = MCObject([NSJSONSerialization JSONObjectWithData:data
                                                                             options:0
                                                                               error:NULL]);
            NSDictionary *cookies = MCObject(session[@"cookies"]);
            for (NSString *key in @[ @"MUSIC_U", @"MUSIC_A", @"__csrf", @"NMTID" ])
                if ([MCText(cookies[key]) length])
                    _cookies[key] = cookies[key];
            _accountProfile = [MCObject(session[@"profile"]) copy];
        }
    }
    return self;
}
- (NSDictionary *)profile {
    @synchronized(self) {
        return [_accountProfile copy];
    }
}
- (BOOL)loggedIn {
    @synchronized(self) {
        return [MCText(_cookies[@"MUSIC_U"]) length] > 0;
    }
}
- (BOOL)saveSession:(NSError **)error {
    @synchronized(self) {
        NSData *data = [NSJSONSerialization
            dataWithJSONObject:@{@"cookies" : [_cookies copy], @"profile" : _accountProfile ?: @{}}
                       options:0
                         error:error];
        if (!data)
            return NO;
        NSDictionary *query = [self keychainQuery];
        OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query,
                                        (__bridge CFDictionaryRef) @{(__bridge id)kSecValueData : data});
        if (status == errSecItemNotFound) {
            NSMutableDictionary *add = [query mutableCopy];
            add[(__bridge id)kSecValueData] = data;
            add[(__bridge id)kSecAttrAccessible] =
                (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
            status = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
        }
        if (status != errSecSuccess) {
            if (error)
                *error = MCAPIError(-30, @"无法将登录信息保存到钥匙串，请检查设备权限");
            return NO;
        }
        return YES;
    }
}
- (void)logout {
    @synchronized(self) {
        _sessionGeneration++;
        _loginGeneration++;
        [_cookies removeAllObjects];
        _accountProfile = @{};
        SecItemDelete((__bridge CFDictionaryRef)[self keychainQuery]);
    }
}
- (BOOL)requireID:(NSString *)identifier completion:(MCAPICompletion)completion {
    if ([MCEAPI identifier:identifier])
        return YES;
    MCComplete(completion, nil, MCAPIError(-31, @"无效的网易云编号"));
    return NO;
}
- (BOOL)requireAccount:(MCAPICompletion)completion {
    if (self.loggedIn)
        return YES;
    MCComplete(completion, nil, MCAPIError(301, @"请先使用网易云账号扫码登录"));
    return NO;
}
- (void)sendPath:(NSString *)path
      parameters:(NSDictionary *)parameters
      completion:(MCAPICompletion)completion {
    @synchronized(self) {
        NSDictionary *cookieSnapshot = [_cookies copy];
        NSUInteger generation = _sessionGeneration;
        NSUInteger loginGeneration = _loginGeneration;
        BOOL QR = [path isEqual:@"/api/login/qrcode/client/login"];
        dispatch_async(_parsingQueue, ^{
            @synchronized(self) {
                if (generation != self->_sessionGeneration ||
                    (QR && loginGeneration != self->_loginGeneration)) {
                    if (completion)
                        completion(nil, MCAPIError(NSURLErrorCancelled, @"请求已取消"));
                    return;
                }
            }
            NSMutableDictionary *header = [NSMutableDictionary dictionaryWithDictionary:@{
                @"os" : @"pc",
                @"osver" : @"Microsoft-Windows-10",
                @"appver" : @"3.1.17.204416",
                @"channel" : @"netease",
                @"deviceId" : self->_deviceID,
                @"resolution" : @"320x480",
                @"__csrf" : cookieSnapshot[@"__csrf"] ?: @"",
                @"requestId" :
                    [NSString stringWithFormat:@"%.0f_%04u", [[NSDate date] timeIntervalSince1970] * 1000,
                                               arc4random_uniform(10000)]
            }];
            for (NSString *key in @[ @"MUSIC_U", @"MUSIC_A", @"NMTID" ])
                if (cookieSnapshot[key])
                    header[key] = cookieSnapshot[key];
            NSMutableDictionary *payload = [parameters mutableCopy] ?: [NSMutableDictionary dictionary];
            payload[@"header"] = header;
            payload[@"e_r"] = @NO;
            NSError *error = nil;
            NSData *JSON = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
            NSString *encrypted =
                JSON ? [MCEAPI encryptedParamsForPath:path
                                                 JSON:[[NSString alloc] initWithData:JSON
                                                                            encoding:NSUTF8StringEncoding]
                                                error:&error]
                     : nil;
            if (!encrypted) {
                if (completion)
                    completion(nil, error ?: MCAPIError(-32, @"无法建立网易云请求"));
                return;
            }
            NSMutableArray *pairs = [NSMutableArray array];
            for (NSString *key in header)
                [pairs addObject:[NSString stringWithFormat:@"%@=%@", MCEncode(key),
                                                            MCEncode([header[key] description])]];
            NSDictionary *headers = @{
                @"Content-Type" : @"application/x-www-form-urlencoded",
                @"Referer" : @"https://music.163.com/",
                @"User-Agent" : @"NeteaseMusic/3.1.17.204416",
                @"Cookie" : [pairs componentsJoinedByString:@"; "]
            };
            NSURL *url = [NSURL URLWithString:[@"https://interface3.music.163.com/eapi/"
                                                  stringByAppendingString:[path substringFromIndex:5]]];
            [[MCHTTPClient sharedClient]
                requestURL:url
                    method:@"POST"
                      body:[[@"params=" stringByAppendingString:encrypted]
                               dataUsingEncoding:NSUTF8StringEncoding]
                   headers:headers
                completion:^(NSData *bytes, NSDictionary *response, NSError *transportError) {
                    dispatch_async(self->_parsingQueue, ^{
                        NSError *parseError = nil;
                        NSDictionary *object =
                            transportError ? nil : [MCEAPI decodeResponse:bytes error:&parseError];
                        NSError *failure = transportError ?: parseError;
                        NSInteger code = [object[@"code"] integerValue];
                        if (object && code != 200 && !(code >= 800 && code <= 803))
                            failure =
                                MCAPIError(code ?: -33, [MCText(object[@"message"] ?: object[@"msg"]) length]
                                                            ? MCText(object[@"message"] ?: object[@"msg"])
                                                            : @"网易云拒绝了请求，请检查登录或播放权限");
                        @synchronized(self) {
                            if (generation != self->_sessionGeneration ||
                                (QR && loginGeneration != self->_loginGeneration))
                                failure = MCAPIError(NSURLErrorCancelled, @"请求已取消");
                        }
                        if (!failure) {
                            NSArray *cookies = [response[@"set-cookie"] isKindOfClass:[NSArray class]]
                                                   ? response[@"set-cookie"]
                                                   : @[];
                            @synchronized(self) {
                                if (generation == self->_sessionGeneration &&
                                    (!QR || loginGeneration == self->_loginGeneration)) {
                                    for (NSString *line in cookies) {
                                        NSString *pair =
                                            [[line componentsSeparatedByString:@";"] firstObject];
                                        NSRange eq = [pair rangeOfString:@"="];
                                        if (eq.location == NSNotFound)
                                            continue;
                                        NSString *name = [[pair substringToIndex:eq.location]
                                            stringByTrimmingCharactersInSet:[NSCharacterSet
                                                                                whitespaceCharacterSet]];
                                        if (![@[ @"MUSIC_U", @"MUSIC_A", @"__csrf", @"NMTID" ]
                                                containsObject:name])
                                            continue;
                                        NSString *value = [pair substringFromIndex:eq.location + 1];
                                        if ([value length])
                                            self->_cookies[name] = value;
                                        else
                                            [self->_cookies removeObjectForKey:name];
                                    }
                                    if ([MCText(self->_cookies[@"MUSIC_U"]) length])
                                        [self saveSession:NULL];
                                }
                            }
                        }
                        if (completion)
                            completion(failure ? nil : object, failure);
                    });
                }];
        });
    }
}
- (void)search:(NSString *)query
          type:(NSInteger)type
        offset:(NSUInteger)offset
    completion:(MCAPICompletion)completion {
    if (![@[ @1, @10, @100, @1000 ] containsObject:@(type)] || ![query length] || [query length] > 512) {
        MCComplete(completion, nil, MCAPIError(-34, @"请输入有效的搜索词"));
        return;
    }
    [self sendPath:@"/api/cloudsearch/pc"
        parameters:@{@"s" : query, @"type" : @(type), @"limit" : @30, @"offset" : @(offset), @"total" : @YES}
        completion:^(id value, NSError *error) {
            if (error) {
                MCComplete(completion, nil, error);
                return;
            }
            NSDictionary *result = MCObject(value[@"result"]);
            NSString *key = type == 1     ? @"songs"
                            : type == 10  ? @"albums"
                            : type == 100 ? @"artists"
                                          : @"playlists";
            NSArray *items = type == 1 ? MCTracks(result[key]) : MCCatalog(result[key]);
            NSString *countKey = type == 1     ? @"songCount"
                                 : type == 10  ? @"albumCount"
                                 : type == 100 ? @"artistCount"
                                               : @"playlistCount";
            BOOL more = result[countKey] ? offset + [items count] < MCCount(result[countKey])
                                         : MCBool(result[@"hasMore"]);
            MCComplete(completion, @{@"items" : items, @"more" : @(more)}, nil);
        }];
}
- (void)discover:(MCAPICompletion)completion {
    [self sendPath:@"/api/personalized/playlist"
        parameters:@{@"limit" : @30, @"total" : @YES, @"n" : @1000}
        completion:^(id result, NSError *error) {
            MCComplete(completion, error ? nil : MCCatalog(result[@"result"]), error);
        }];
}
- (void)dailyRecommendations:(MCAPICompletion)completion {
    if (![self requireAccount:completion])
        return;
    [self sendPath:@"/api/v3/discovery/recommend/songs"
        parameters:@{}
        completion:^(id result, NSError *error) {
            if (error) {
                MCComplete(completion, nil, error);
                return;
            }
            id songs = MCObject(result[@"data"])[@"dailySongs"];
            if (![songs isKindOfClass:[NSArray class]] || [songs count] > 10000) {
                MCComplete(completion, nil, MCAPIError(-48, @"每日推荐数据无效，请重试"));
                return;
            }
            NSMutableArray *tracks = [NSMutableArray array];
            for (id song in songs) {
                NSDictionary *track = [MCEAPI track:song];
                if (!track || ![track[@"title"] length]) {
                    MCComplete(completion, nil, MCAPIError(-48, @"每日推荐歌曲信息无效，请重试"));
                    return;
                }
                [tracks addObject:track];
            }
            MCComplete(completion, @{@"tracks":tracks, @"totalCount":@(tracks.count),
                                     @"unavailableTrackIDs":@[]}, nil);
        }];
}
/* Batches are sequential: at most 100 detail records in one JSON response.
   A playlist too large for this device fails explicitly instead of truncating. */
- (void)fetchTrackIDs:(NSArray *)ids
               offset:(NSUInteger)offset
          accumulated:(NSMutableArray *)tracks
          unavailable:(NSMutableArray *)unavailable
             fallback:(NSDictionary *)fallback
           completion:(MCAPICompletion)completion {
    if ([ids count] > 10000) {
        MCComplete(completion, nil, MCAPIError(-35, @"此歌单超过设备支持的 10000 首歌曲限制"));
        return;
    }
    if (offset >= [ids count]) {
        MCComplete(completion, @{
            @"tracks" : [tracks copy],
            @"unavailableTrackIDs" : [unavailable copy],
            @"totalCount" : @([ids count])
        },
                   nil);
        return;
    }
    NSArray *batch = [ids subarrayWithRange:NSMakeRange(offset, MIN((NSUInteger)100, [ids count] - offset))];
    NSMutableArray *objects = [NSMutableArray array];
    for (id value in batch) {
        NSString *identifier = [MCEAPI identifier:value];
        if (!identifier) {
            MCComplete(completion, nil, MCAPIError(-36, @"歌单包含无效的歌曲编号"));
            return;
        }
        [objects addObject:[NSString stringWithFormat:@"{\"id\":%@}", identifier]];
    }
    NSString *c = [NSString stringWithFormat:@"[%@]", [objects componentsJoinedByString:@","]];
    [self sendPath:@"/api/v3/song/detail"
        parameters:@{@"c" : c}
        completion:^(id result, NSError *error) {
            if (error) {
                MCComplete(completion, nil, error);
                return;
            }
            if (![result[@"songs"] isKindOfClass:[NSArray class]]) {
                MCComplete(completion, nil, MCAPIError(-47, @"网易云返回的歌曲详情格式无效，请重试"));
                return;
            }
            NSMutableDictionary *map = [fallback mutableCopy] ?: [NSMutableDictionary dictionary];
            for (NSDictionary *track in MCTracks(result[@"songs"]))
                map[track[@"id"]] = track;
            for (id value in batch) {
                NSDictionary *track = map[[MCEAPI identifier:value]];
                if (!track) {
                    [unavailable addObject:[MCEAPI identifier:value]];
                } else
                    [tracks addObject:track];
            }
            [self fetchTrackIDs:ids
                         offset:offset + [batch count]
                    accumulated:tracks
                    unavailable:unavailable
                       fallback:fallback
                     completion:completion];
        }];
}
- (void)playlist:(NSString *)identifier completion:(MCAPICompletion)completion {
    if (![self requireID:identifier completion:completion])
        return;
    [self sendPath:@"/api/v6/playlist/detail"
        parameters:@{@"id" : identifier, @"n" : @100000, @"s" : @0}
        completion:^(id result, NSError *error) {
            if (error) {
                MCComplete(completion, nil, error);
                return;
            }
            NSDictionary *playlist = MCObject(result[@"playlist"]);
            NSMutableArray *ids = [NSMutableArray array];
            for (id entry in MCList(playlist[@"trackIds"])) {
                NSString *trackID = [MCEAPI identifier:MCObject(entry)[@"id"]];
                if (!trackID) {
                    MCComplete(completion, nil, MCAPIError(-36, @"歌单包含无效的歌曲编号"));
                    return;
                }
                [ids addObject:trackID];
            }
            if (MCCount(playlist[@"trackCount"]) > [ids count] ||
                (![ids count] && [MCList(playlist[@"tracks"]) count])) {
                MCComplete(completion, nil, MCAPIError(-38, @"网易云未提供完整歌单编号列表"));
                return;
            }
            NSMutableDictionary *fallback = [NSMutableDictionary dictionary];
            for (NSDictionary *track in MCTracks(playlist[@"tracks"]))
                fallback[track[@"id"]] = track;
            [self fetchTrackIDs:ids
                         offset:0
                    accumulated:[NSMutableArray array]
                    unavailable:[NSMutableArray array]
                       fallback:fallback
                     completion:^(id collection, NSError *failure) {
                         NSMutableDictionary *value = failure ? nil : [collection mutableCopy];
                         value[@"title"] = MCText(playlist[@"name"]);
                         MCComplete(completion, value, failure);
                     }];
        }];
}
- (void)album:(NSString *)identifier completion:(MCAPICompletion)completion {
    if (![self requireID:identifier completion:completion])
        return;
    [self sendPath:[@"/api/v1/album/" stringByAppendingString:identifier]
        parameters:@{}
        completion:^(id result, NSError *error) {
            MCComplete(completion, error ? nil : @{
                @"title" : MCText(MCObject(result[@"album"])[@"name"]),
                @"tracks" : MCTracks(result[@"songs"])
            },
                       error);
        }];
}
- (void)fetchArtistAlbums:(NSString *)identifier
                   offset:(NSUInteger)offset
              accumulated:(NSMutableArray *)items
               completion:(MCAPICompletion)completion {
    if (offset >= 2000) {
        MCComplete(completion, nil, MCAPIError(-43, @"此歌手的专辑超过设备支持的 2000 张限制"));
        return;
    }
    [self sendPath:[@"/api/artist/albums/" stringByAppendingString:identifier]
        parameters:@{@"offset" : @(offset), @"limit" : @100, @"total" : @YES}
        completion:^(id result, NSError *error) {
            if (error) {
                MCComplete(completion, nil, error);
                return;
            }
            NSArray *batch = MCList(result[@"hotAlbums"]);
            [items addObjectsFromArray:MCCatalog(batch)];
            if (MCBool(result[@"more"])) {
                if (![batch count]) {
                    MCComplete(completion, nil, MCAPIError(-44, @"网易云返回了不完整的专辑列表"));
                    return;
                }
                [self fetchArtistAlbums:identifier
                                 offset:offset + [batch count]
                            accumulated:items
                             completion:completion];
            } else
                MCComplete(completion, [items copy], nil);
        }];
}
- (void)artist:(NSString *)identifier completion:(MCAPICompletion)completion {
    if (![self requireID:identifier completion:completion])
        return;
    [self sendPath:[@"/api/v1/artist/" stringByAppendingString:identifier]
        parameters:@{}
        completion:^(id result, NSError *error) {
            if (error) {
                MCComplete(completion, nil, error);
                return;
            }
            [self fetchArtistAlbums:identifier
                             offset:0
                        accumulated:[NSMutableArray array]
                         completion:^(id albums, NSError *failure) {
                             MCComplete(completion, failure ? nil : @{
                                 @"title" : MCText(MCObject(result[@"artist"])[@"name"]),
                                 @"tracks" : MCTracks(result[@"hotSongs"]),
                                 @"albums" : albums
                             },
                                        failure);
                         }];
        }];
}
- (void)fetchUserPlaylists:(NSString *)uid
                    offset:(NSUInteger)offset
               accumulated:(NSMutableArray *)items
                completion:(MCAPICompletion)completion {
    if (offset >= 10000) {
        MCComplete(completion, nil, MCAPIError(-39, @"账号歌单超过设备支持的数量限制"));
        return;
    }
    [self sendPath:@"/api/user/playlist"
        parameters:@{@"uid" : uid, @"offset" : @(offset), @"limit" : @100, @"includeVideo" : @NO}
        completion:^(id result, NSError *error) {
            if (error) {
                MCComplete(completion, nil, error);
                return;
            }
            NSArray *batch = MCList(result[@"playlist"]);
            [items addObjectsFromArray:MCCatalog(batch)];
            if (MCBool(result[@"more"])) {
                if (![batch count]) {
                    MCComplete(completion, nil, MCAPIError(-45, @"网易云返回了不完整的用户歌单列表"));
                    return;
                }
                [self fetchUserPlaylists:uid
                                  offset:offset + [batch count]
                             accumulated:items
                              completion:completion];
            } else
                MCComplete(completion, [items copy], nil);
        }];
}
- (void)withUID:(void (^)(NSString *, NSError *))block {
    NSString *uid = [MCEAPI identifier:self.profile[@"userId"]];
    if (uid) {
        block(uid, nil);
        return;
    }
    [self fetchProfile:^(id profile, NSError *error) {
        block([MCEAPI identifier:profile[@"userId"]], error);
    }];
}
- (void)userPlaylists:(MCAPICompletion)completion {
    if (![self requireAccount:completion])
        return;
    [self withUID:^(NSString *uid, NSError *error) {
        if (!uid) {
            MCComplete(completion, nil, error ?: MCAPIError(301, @"登录已失效，请重新扫码"));
            return;
        }
        [self fetchUserPlaylists:uid offset:0 accumulated:[NSMutableArray array] completion:completion];
    }];
}
- (void)likedTracks:(MCAPICompletion)completion {
    if (![self requireAccount:completion])
        return;
    [self withUID:^(NSString *uid, NSError *error) {
        if (!uid) {
            MCComplete(completion, nil, error ?: MCAPIError(301, @"登录已失效，请重新扫码"));
            return;
        }
        [self sendPath:@"/api/song/like/get"
            parameters:@{@"uid" : uid}
            completion:^(id result, NSError *failure) {
                if (failure) {
                    MCComplete(completion, nil, failure);
                    return;
                }
                [self fetchTrackIDs:MCList(result[@"ids"])
                             offset:0
                        accumulated:[NSMutableArray array]
                        unavailable:[NSMutableArray array]
                           fallback:nil
                         completion:completion];
            }];
    }];
}
- (void)likeTrack:(NSString *)identifier liked:(BOOL)liked completion:(MCAPICompletion)completion {
    if (![self requireID:identifier completion:completion] || ![self requireAccount:completion])
        return;
    [self sendPath:@"/api/radio/like"
        parameters:@{@"trackId" : identifier, @"like" : @(liked), @"alg" : @"itembased", @"time" : @"3"}
        completion:^(id result, NSError *error) {
            MCComplete(completion, result, error);
        }];
}
- (void)songURL:(NSString *)identifier quality:(NSString *)quality completion:(MCAPICompletion)completion {
    if (![self requireID:identifier completion:completion])
        return;
    if (![@[ @"standard", @"exhigh", @"lossless" ] containsObject:quality])
        quality = @"standard";
    [self sendPath:@"/api/song/enhance/player/url/v1"
        parameters:@{
            @"ids" : [NSString stringWithFormat:@"[%@]", identifier],
            @"level" : quality,
            @"encodeType" : @"flac"
        }
        completion:^(id result, NSError *error) {
            if (error) {
                MCComplete(completion, nil, error);
                return;
            }
            NSArray *data = MCList(result[@"data"]);
            NSDictionary *entry = [data count] ? MCObject(data[0]) : @{};
            NSError *rightsError = nil;
            NSDictionary *playable = [MCEAPI playableURL:entry error:&rightsError];
            MCComplete(completion, playable, rightsError);
        }];
}
- (void)lyrics:(NSString *)identifier completion:(MCAPICompletion)completion {
    if (![self requireID:identifier completion:completion])
        return;
    [self sendPath:@"/api/song/lyric"
        parameters:@{@"id" : identifier, @"tv" : @-1, @"lv" : @-1, @"rv" : @-1, @"kv" : @-1, @"_nmclfl" : @1}
        completion:^(id result, NSError *error) {
            MCComplete(completion, error ? nil : MCText(MCObject(result[@"lrc"])[@"lyric"]), error);
        }];
}
- (void)createLoginKey:(MCAPICompletion)completion {
    NSUInteger loginGeneration;
    @synchronized(self) {
        loginGeneration = ++_loginGeneration;
    }
    [self sendPath:@"/api/login/qrcode/unikey"
        parameters:@{@"type" : @3}
        completion:^(id result, NSError *error) {
            NSString *key = MCText(result[@"unikey"]);
            @synchronized(self) {
                if (loginGeneration != self->_loginGeneration)
                    error = MCAPIError(NSURLErrorCancelled, @"登录请求已取消");
            }
            if (!error && ![key length])
                error = MCAPIError(-40, @"网易云未返回二维码密钥");
            MCComplete(completion, error ? nil : @{
                @"key" : key,
                @"url" : [@"https://music.163.com/login?codekey=" stringByAppendingString:MCEncode(key)]
            },
                       error);
        }];
}
- (void)pollLoginKey:(NSString *)key completion:(MCAPICompletion)completion {
    if (![key length] || [key length] > 1024) {
        MCComplete(completion, nil, MCAPIError(-41, @"无效的二维码密钥"));
        return;
    }
    __block NSUInteger generation;
    NSUInteger loginGeneration;
    @synchronized(self) {
        generation = _sessionGeneration;
        loginGeneration = _loginGeneration;
    }
    [self sendPath:@"/api/login/qrcode/client/login"
        parameters:@{@"key" : key, @"type" : @3}
        completion:^(id result, NSError *error) {
            NSInteger status = [result[@"code"] integerValue];
            if (!error && (status < 800 || status > 803))
                error = MCAPIError(-46, @"网易云返回了无效的扫码状态");
            @synchronized(self) {
                if (generation != self->_sessionGeneration || loginGeneration != self->_loginGeneration) {
                    MCComplete(completion, nil, MCAPIError(NSURLErrorCancelled, @"登录请求已取消"));
                    return;
                }
                if (!error && status == 803) {
                    if (!self.loggedIn)
                        error = MCAPIError(-42, @"授权响应缺少有效会话，请重新扫码");
                    else {
                        generation = ++self->_sessionGeneration;
                        self->_accountProfile = @{};
                        if (![self saveSession:&error])
                            [self logout];
                    }
                }
            }
            if (error) {
                MCComplete(completion, nil, error);
                return;
            }
            if (status == 803)
                [self fetchProfile:^(id profile, NSError *ignored) {
                    (void)profile;
                    (void)ignored;
                    @synchronized(self) {
                        if (generation != self->_sessionGeneration ||
                            loginGeneration != self->_loginGeneration) {
                            MCComplete(completion, nil, MCAPIError(NSURLErrorCancelled, @"登录请求已取消"));
                            return;
                        }
                    }
                    MCComplete(completion, @{@"status" : @(status)}, nil);
                }];
            else
                MCComplete(completion, @{@"status" : @(status)}, nil);
        }];
}
- (void)fetchProfile:(MCAPICompletion)completion {
    NSUInteger generation;
    @synchronized(self) {
        generation = _sessionGeneration;
    }
    [self sendPath:@"/api/w/nuser/account/get"
        parameters:@{}
        completion:^(id result, NSError *error) {
            NSDictionary *profile = MCObject(result[@"profile"]);
            NSString *uid = [MCEAPI identifier:profile[@"userId"]];
            if (!error && !uid)
                error = MCAPIError(301, @"登录已失效，请重新扫码");
            @synchronized(self) {
                if (generation != self->_sessionGeneration)
                    error = MCAPIError(NSURLErrorCancelled, @"登录请求已取消");
                else if (!error) {
                    NSMutableDictionary *normalized = [profile mutableCopy];
                    normalized[@"userId"] = uid;
                    self->_accountProfile = [normalized copy];
                    [self saveSession:&error];
                }
            }
            MCComplete(completion, error ? nil : self.profile, error);
        }];
}
- (void)refreshLogin:(MCAPICompletion)completion {
    if (![self requireAccount:completion])
        return;
    NSUInteger generation;
    @synchronized(self) {
        generation = _sessionGeneration;
    }
    [self sendPath:@"/api/login/token/refresh"
        parameters:@{}
        completion:^(id result, NSError *error) {
            (void)result;
            @synchronized(self) {
                if (generation != self->_sessionGeneration) {
                    MCComplete(completion, nil, MCAPIError(NSURLErrorCancelled, @"登录请求已取消"));
                    return;
                }
                if (error) {
                    if ([error.domain isEqual:MCAPIErrorDomain] && error.code == 301)
                        [self logout];
                    MCComplete(completion, nil, error);
                    return;
                }
                [self fetchProfile:completion];
            }
        }];
}
@end
