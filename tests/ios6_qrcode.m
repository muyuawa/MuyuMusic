#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import "../Sources/Core/MCQRCode.h"
#include <assert.h>
int main(void) {
    @autoreleasepool {
        NSString *url = @"https://music.163.com/login?codekey=0123456789abcdef0123456789abcdef";
        CGImageRef image = MCCreateLoginQRCode(url);
        assert(image);
        CIImage *ci = [CIImage imageWithCGImage:image];
        CIDetector *detector = [CIDetector detectorOfType:CIDetectorTypeQRCode
                                                  context:nil
                                                  options:@{CIDetectorAccuracy : CIDetectorAccuracyHigh}];
        NSArray *features = [detector featuresInImage:ci];
        assert(features.count == 1);
        assert([[(CIQRCodeFeature *)features[0] messageString] isEqual:url]);
        CGImageRelease(image);
        assert(!MCCreateLoginQRCode(nil));
        assert(!MCCreateLoginQRCode(@""));
        assert(!MCCreateLoginQRCode([@"x" stringByPaddingToLength:5000 withString:@"x" startingAtIndex:0]));
        puts("iOS 6 QR login: scan roundtrip and invalid/oversized input passed");
    }
}
