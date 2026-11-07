#import "MCAudioPolicy.h"
#import "../Network/MCSourceSecurity.h"
BOOL MCIsAllowedAudioURL(NSURL *url, BOOL customSource) {
    NSString *host = url.host.lowercaseString;
    if (customSource)
        return MCSourceURLAllowed(url);
    if (![url.scheme.lowercaseString isEqualToString:@"https"] || !host.length || url.user || url.password)
        return NO;
    for (NSString *domain in @[ @"music.126.net", @"music.163.com", @"music.127.net" ])
        if ([host isEqualToString:domain] || [host hasSuffix:[@"." stringByAppendingString:domain]])
            return YES;
    return NO;
}

BOOL MCSourceSnapshotMatches(NSDictionary *snapshot, NSDictionary *selection) {
    if (![snapshot isKindOfClass:[NSDictionary class]] || ![selection isKindOfClass:[NSDictionary class]])
        return NO;
    for (NSString *key in @[ @"identifier", @"revision" ]) {
        id original = snapshot[key], current = selection[key];
        if (![original isKindOfClass:[NSString class]] || ![original length] || ![original isEqual:current])
            return NO;
    }
    return YES;
}
