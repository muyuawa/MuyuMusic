#import <Foundation/Foundation.h>
#import "../Sources/Network/MCEncoding.h"
#include <assert.h>
int main(void) {
    @autoreleasepool {
        assert([MCURLComponent(@"中文 a&=+/?#%[]!*'()~._-")
            isEqual:@"%E4%B8%AD%E6%96%87%20a%26%3D%2B%2F%3F%23%25%5B%5D%21%2A%27%28%29~._-"]);
        assert([MCURLComponent(@"") isEqual:@""]);
        const unsigned char bytes[] = {0, 255, 16, 128};
        NSData *binary = [NSData dataWithBytes:bytes length:sizeof bytes];
        assert([MCBase64String(binary) isEqual:@"AP8QgA=="]);
        assert([MCBase64Data(@"AP8Q\ngA==\n") isEqual:binary]);
        assert([MCBase64String([NSData data]) isEqual:@""]);
        assert([MCBase64Data(@"YQ==") isEqual:[@"a" dataUsingEncoding:NSUTF8StringEncoding]]);
        NSMutableData *large = [NSMutableData dataWithLength:1024];
        for (NSUInteger i = 0; i < large.length; i++)
            ((unsigned char *)large.mutableBytes)[i] = (unsigned char)i;
        assert([MCBase64Data(MCBase64String(large)) isEqual:large]);
        puts("iOS 6 encoding: URL UTF-8/reserved characters and binary Base64 passed");
    }
}
