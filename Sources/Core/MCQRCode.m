#import "MCQRCode.h"
#include "qrcodegen.h"
#include <string.h>
CGImageRef MCCreateLoginQRCode(NSString *text) {
    if (!text.length || [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 2048)
        return NULL;
    uint8_t scratch[qrcodegen_BUFFER_LEN_MAX], qr[qrcodegen_BUFFER_LEN_MAX];
    if (!qrcodegen_encodeText(text.UTF8String, scratch, qr, qrcodegen_Ecc_MEDIUM, qrcodegen_VERSION_MIN,
                              qrcodegen_VERSION_MAX, qrcodegen_Mask_AUTO, true))
        return NULL;
    int size = qrcodegen_getSize(qr), width = size + 8;
    NSMutableData *pixels = [NSMutableData dataWithLength:(NSUInteger)width * width];
    uint8_t *bytes = pixels.mutableBytes;
    memset(bytes, 255, pixels.length);
    for (int y = 0; y < size; y++)
        for (int x = 0; x < size; x++)
            if (qrcodegen_getModule(qr, x, y))
                bytes[(y + 4) * width + x + 4] = 0;
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceGray();
    CGImageRef image = CGImageCreate(width, width, 8, 8, width, space, (CGBitmapInfo)kCGImageAlphaNone,
                                     provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(space);
    CGDataProviderRelease(provider);
    return image;
}
