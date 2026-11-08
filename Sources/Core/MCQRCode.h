#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
/* Local QR generation, including a four-module quiet zone. Caller owns image. */
CGImageRef MCCreateLoginQRCode(NSString *text) CF_RETURNS_RETAINED;
