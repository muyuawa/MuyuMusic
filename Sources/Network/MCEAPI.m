#import "MCEAPI.h"
#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonDigest.h>

NSString *const MCAPIErrorDomain = @"MCAPIErrorDomain";
static NSString *MCString(id value) {
    return [value isKindOfClass:[NSString class]] ? value : @"";
}
static NSDictionary *MCDict(id value) {
    return [value isKindOfClass:[NSDictionary class]] ? value : @{};
}
static NSArray *MCArray(id value) {
    return [value isKindOfClass:[NSArray class]] ? value : @[];
}
static NSError *MCError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:MCAPIErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}
static NSString *MCHex(NSData *data, BOOL upper) {
    const unsigned char *bytes = [data bytes];
    const char *digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    NSMutableData *out = [NSMutableData dataWithLength:[data length] * 2];
    char *p = [out mutableBytes];
    for (NSUInteger i = 0; i < [data length]; i++) {
        p[2 * i] = digits[bytes[i] >> 4];
        p[2 * i + 1] = digits[bytes[i] & 15];
    }
    return [[NSString alloc] initWithData:out encoding:NSASCIIStringEncoding];
}
static NSData *MCAES(NSData *data, CCOperation operation, NSError **error) {
    NSMutableData *out = [NSMutableData dataWithLength:[data length] + kCCBlockSizeAES128];
    size_t length = 0;
    CCCryptorStatus status = CCCrypt(operation, kCCAlgorithmAES128, kCCOptionPKCS7Padding | kCCOptionECBMode,
                                     "e82ckenh8dichen8", kCCKeySizeAES128, NULL, [data bytes], [data length],
                                     [out mutableBytes], [out length], &length);
    if (status != kCCSuccess) {
        if (error)
            *error = MCError(-10, @"网易云协议加密失败");
        return nil;
    }
    [out setLength:length];
    return out;
}
static NSString *MCHTTPSArtwork(id value) {
    NSString *s = MCString(value);
    NSURL *url = [NSURL URLWithString:s];
    NSString *scheme = [[url scheme] lowercaseString];
    if ([scheme isEqual:@"http"] &&
        ([[url host] hasSuffix:@".music.126.net"] || [[url host] hasSuffix:@".music.163.com"]))
        return [@"https" stringByAppendingString:[s substringFromIndex:4]];
    return [scheme isEqual:@"https"] ? s : @"";
}
@implementation MCEAPI
+ (NSString *)encryptedParamsForPath:(NSString *)path JSON:(NSString *)JSON error:(NSError **)error {
    if (![path hasPrefix:@"/api/"] || !JSON || [JSON length] > 4 * 1024 * 1024) {
        if (error)
            *error = MCError(-11, @"无效的网易云请求");
        return nil;
    }
    NSData *message = [[NSString stringWithFormat:@"nobody%@use%@md5forencrypt", path, JSON]
        dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5([message bytes], (CC_LONG)[message length], digest);
    NSString *hash = MCHex([NSData dataWithBytes:digest length:sizeof(digest)], NO);
    NSData *plain = [[NSString stringWithFormat:@"%@-36cd479b6b5-%@-36cd479b6b5-%@", path, JSON, hash]
        dataUsingEncoding:NSUTF8StringEncoding];
    NSData *encrypted = MCAES(plain, kCCEncrypt, error);
    return encrypted ? MCHex(encrypted, YES) : nil;
}
+ (NSDictionary *)decodeResponse:(NSData *)data error:(NSError **)error {
    if (![data length] || [data length] > 8 * 1024 * 1024) {
        if (error)
            *error = MCError(-12, @"网易云响应为空或超过 8 MB 限制");
        return nil;
    }
    NSError *parseError = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError];
    if (!object) {
        NSData *plain = MCAES(data, kCCDecrypt, NULL);
        if (plain)
            object = [NSJSONSerialization JSONObjectWithData:plain options:0 error:NULL];
    }
    if (![object isKindOfClass:[NSDictionary class]] || ![object[@"code"] isKindOfClass:[NSNumber class]]) {
        if (error)
            *error = MCError(-13, @"网易云返回了无法识别的数据");
        return nil;
    }
    return object;
}
+ (NSString *)identifier:(id)value {
    NSString *s = [value isKindOfClass:[NSNumber class]] ? [value stringValue] : MCString(value);
    if (![s length] || [s length] > 20 ||
        [s rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location !=
            NSNotFound)
        return nil;
    /* NSCharacterSet also accepts non-ASCII decimal characters; requests require ASCII digits. */
    for (NSUInteger i = 0; i < [s length]; i++)
        if ([s characterAtIndex:i] < '0' || [s characterAtIndex:i] > '9')
            return nil;
    return s;
}
+ (NSDictionary *)track:(NSDictionary *)song {
    song = MCDict(song);
    NSString *identifier = [self identifier:song[@"id"]];
    if (!identifier)
        return nil;
    NSArray *artists = MCArray(song[@"ar"] ?: song[@"artists"]);
    NSMutableArray *names = [NSMutableArray array];
    for (id artist in artists) {
        NSString *name = MCString(MCDict(artist)[@"name"]);
        if ([name length])
            [names addObject:name];
    }
    NSDictionary *album = MCDict(song[@"al"] ?: song[@"album"]);
    id duration = song[@"dt"] ?: song[@"duration"];
    NSMutableDictionary *track = [NSMutableDictionary dictionaryWithDictionary:@{
        @"id" : identifier,
        @"title" : MCString(song[@"name"]),
        @"artist" : [names componentsJoinedByString:@" / "],
        @"album" : MCString(album[@"name"]),
        @"artwork" : MCHTTPSArtwork(album[@"picUrl"] ?: song[@"picUrl"]),
        @"duration" :
            @([duration respondsToSelector:@selector(doubleValue)] ? MAX(0, [duration doubleValue] / 1000.0)
                                                                   : 0)
    }];
    NSString *albumID = [self identifier:album[@"id"]],
             *artistID = [self identifier:MCDict([artists count] ? artists[0] : nil)[@"id"]];
    if (albumID)
        track[@"albumID"] = albumID;
    if (artistID)
        track[@"artistID"] = artistID;
    return track;
}
+ (NSDictionary *)catalogItem:(NSDictionary *)item {
    item = MCDict(item);
    NSString *identifier = [self identifier:item[@"id"]];
    if (!identifier)
        return nil;
    NSString *subtitle = MCString(MCDict(item[@"creator"])[@"nickname"]);
    if (![subtitle length])
        subtitle = MCString(MCDict(item[@"artist"])[@"name"]);
    if (![subtitle length])
        subtitle = MCString(item[@"copywriter"]);
    return @{@"id":identifier,@"title":MCString(item[@"name"]),@"artwork":MCHTTPSArtwork(item[@"picUrl"] ?: item[@"coverImgUrl"] ?: item[@"img1v1Url"]),@"subtitle":subtitle};
}
+ (NSDictionary *)playableURL:(NSDictionary *)entry error:(NSError **)error {
    entry = MCDict(entry);
    id trial = entry[@"freeTrialInfo"];
    if ((trial && trial != [NSNull null]) ||
        ([entry[@"freeTrialPrivilege"] isKindOfClass:[NSDictionary class]] &&
         [MCDict(entry[@"freeTrialPrivilege"])[@"resConsumable"] isEqual:@YES])) {
        if (error)
            *error = MCError(-20, @"此歌曲仅提供试听，请登录有播放权限的网易云账号");
        return nil;
    }
    NSString *s = MCString(entry[@"url"]);
    NSURL *url = [NSURL URLWithString:s];
    NSString *host = [[url host] lowercaseString];
    BOOL hostOK = [host hasSuffix:@".music.126.net"] || [host hasSuffix:@".music.163.com"] ||
                  [host isEqual:@"music.163.com"];
    if (!hostOK || [url user] || [url password] || ![[url scheme] length] ||
        !([[[url scheme] lowercaseString] isEqual:@"https"] ||
          [[[url scheme] lowercaseString] isEqual:@"http"]) ||
        (![entry[@"code"] isKindOfClass:[NSNumber class]] || [entry[@"code"] integerValue] != 200)) {
        if (error)
            *error = MCError(-21, @"此歌曲暂无可播放的完整音源，可能需要会员或受地区限制");
        return nil;
    }
    if ([[[url scheme] lowercaseString] isEqual:@"http"])
        s = [@"https" stringByAppendingString:[s substringFromIndex:4]];
    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithDictionary:@{
        @"url" : s,
        @"format" : [MCString(entry[@"type"]) lowercaseString],
        @"bitrate" : [entry[@"br"] isKindOfClass:[NSNumber class]] ? entry[@"br"] : @0
    }];
    for (NSString *key in @[ @"size", @"bitDepth", @"sampleRate" ])
        if ([entry[key] isKindOfClass:[NSNumber class]])
            result[key] = entry[key];
    if ([entry[@"expi"] respondsToSelector:@selector(doubleValue)] && [entry[@"expi"] doubleValue] > 0)
        result[@"expires"] = @([[NSDate date] timeIntervalSince1970] + [entry[@"expi"] doubleValue]);
    return result;
}
+ (BOOL)isAPIHost:(NSString *)host {
    host = [host lowercaseString];
    return [host isEqual:@"music.163.com"] || [host isEqual:@"interface.music.163.com"] ||
           [host isEqual:@"interface3.music.163.com"];
}
@end
