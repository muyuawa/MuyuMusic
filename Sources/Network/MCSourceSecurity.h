#ifndef MC_SOURCE_SECURITY_H
#define MC_SOURCE_SECURITY_H
#import <Foundation/Foundation.h>

static NSString *const MCSourceHTTPSOnlyKey = @"music.sources.httpsOnly";
static NSString *const MCSourceSecurityDidChangeNotification = @"MCSourceSecurityDidChangeNotification";
static inline BOOL MCSourceHTTPSOnly(void) {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:MCSourceHTTPSOnlyKey];
    return ![value isKindOfClass:[NSNumber class]] || [value boolValue];
}
static inline void MCSetSourceHTTPSOnly(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:MCSourceHTTPSOnlyKey];
    [[NSNotificationCenter defaultCenter] postNotificationName:MCSourceSecurityDidChangeNotification
                                                        object:nil];
}
static inline BOOL MCSourceURLAllowed(NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString;
    return url.host.length && !url.user && !url.password &&
           ([scheme isEqual:@"https"] || ([scheme isEqual:@"http"] && !MCSourceHTTPSOnly()));
}
static inline NSString *MCSourceURLFailure(NSURL *url) {
    if ([url.scheme.lowercaseString isEqual:@"http"] && MCSourceHTTPSOnly())
        return @"音源返回 HTTP 地址，已被“仅允许 HTTPS”拦截。可在设置 → 音源中关闭此选项后重试。";
    return @"音源未返回有效的 HTTP/HTTPS 地址，或地址包含无效凭据。";
}
/* Source error messages may include service URLs/tokens. Preserve the reason,
   but never display query strings, embedded credentials or authentication values. */
static inline NSString *MCSourceFailureText(id value, NSString *fallback) {
    if (![value isKindOfClass:[NSString class]] || ![value length])
        return fallback;
    NSString *text = [value substringToIndex:MIN((NSUInteger)512, [value length])];
    NSRegularExpression *urls =
        [NSRegularExpression regularExpressionWithPattern:@"https?://[^\\s'\"<>]+"
                                                  options:NSRegularExpressionCaseInsensitive
                                                    error:NULL];
    for (NSTextCheckingResult *match in
         [[urls matchesInString:text options:0 range:NSMakeRange(0, text.length)] reverseObjectEnumerator])
        text = [text stringByReplacingCharactersInRange:match.range withString:@"链接"];
    NSRegularExpression *secrets =
        [NSRegularExpression regularExpressionWithPattern:
                                 @"(?i)(?:bearer\\s+[^\\s,;]+|(?:token|api[_-]?key|authorization|cookie|"
                                 @"password)[\"']?\\s*[:=]\\s*(?:\"[^\"]*(?:\"|$)|'[^']*(?:'|$)|[^\\s,;]+))"
                                                  options:0
                                                    error:NULL];
    text = [secrets stringByReplacingMatchesInString:text
                                             options:0
                                               range:NSMakeRange(0, text.length)
                                        withTemplate:@"凭据已隐藏"];
    return [text substringToIndex:MIN((NSUInteger)200, text.length)];
}
#endif
