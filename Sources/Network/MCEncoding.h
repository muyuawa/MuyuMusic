#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

/* Foundation's replacement encoding APIs require iOS 7. These public legacy
   APIs are available on iOS 6; keep the same UTF-8 component/Base64 contracts. */
static inline NSString *MCURLComponent(NSString *text) {
    return CFBridgingRelease(CFURLCreateStringByAddingPercentEscapes(
               kCFAllocatorDefault, (__bridge CFStringRef)text, CFSTR("-._~"), CFSTR("!*'();:@&=+$,/?%#[]"),
               kCFStringEncodingUTF8))
               ?: @"";
}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static inline NSData *MCBase64Data(NSString *text) {
    return [[NSData alloc] initWithBase64Encoding:text];
}
static inline NSString *MCBase64String(NSData *data) {
    return [data base64Encoding];
}
#pragma clang diagnostic pop
