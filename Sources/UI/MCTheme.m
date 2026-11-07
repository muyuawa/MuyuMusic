#import "MCTheme.h"
#import "MCColor.h"
#include <math.h>
NSString *const MCThemeDidChangeNotification = @"MCThemeDidChangeNotification";
static UIColor *MCUIColor(MCColor c) {
    return [UIColor colorWithRed:c.r green:c.g blue:c.b alpha:1];
}
static UIColor *MCRGB(unsigned x) {
    return [UIColor colorWithRed:(x >> 16) / 255.0
                           green:((x >> 8) & 255) / 255.0
                            blue:(x & 255) / 255.0
                           alpha:1];
}
@interface MCTheme ()
@property (nonatomic, copy) NSString *artworkHex;
@property (nonatomic) NSUInteger artworkGeneration;
- (MCColor)tintColor;
- (MCColor)themeBase:(BOOL)surface;
@end
@implementation MCTheme
+ (instancetype)sharedTheme {
    static MCTheme *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        t = [MCTheme new];
    });
    return t;
}
- (id)init {
    if ((self = [super init])) {
        _hex = [[[NSUserDefaults standardUserDefaults] stringForKey:@"theme.hex"] copy] ?: @"#365EA8";
        MCColor c;
        if (!MCColorParse(_hex.UTF8String, &c))
            _hex = @"#365EA8";
        _dark = [[NSUserDefaults standardUserDefaults] boolForKey:@"theme.dark"];
        _followArtwork = [[NSUserDefaults standardUserDefaults] boolForKey:@"theme.followArtwork"];
    }
    return self;
}
- (UIColor *)primary {
    MCColor c = [self tintColor];
    return MCUIColor(MCColorReadableAccent(c, self.dark, [self themeBase:self.dark]));
}
- (MCColor)tintColor {
    MCColor c;
    MCColorParse((self.followArtwork && self.artworkHex ? self.artworkHex : self.hex).UTF8String, &c);
    return c;
}
- (MCColor)themeBase:(BOOL)surface {
    MCColor base;
    MCColorParse(self.dark ? (surface ? "#242C3C" : "#171C29") : (surface ? "#FFFFFF" : "#F6F7FF"), &base);
    return self.followArtwork && self.artworkHex
               ? MCColorBlend(base, [self tintColor], surface ? (self.dark ? .12 : .06) : (self.dark ? .16 : .12))
               : base;
}
- (UIColor *)onPrimary {
    MCColor c = MCColorReadableAccent([self tintColor], self.dark, [self themeBase:self.dark]);
    return MCUIColor(MCColorForeground(c));
}
- (UIColor *)background {
    return MCUIColor([self themeBase:NO]);
}
- (UIColor *)surface {
    return MCUIColor([self themeBase:YES]);
}
- (UIColor *)text {
    return MCRGB(self.dark ? 0xF4F5FF : 0x19243B);
}
- (UIColor *)muted {
    return MCRGB(self.dark ? 0xB9C5DD : 0x526078);
}
- (UIColor *)accent {
    return MCRGB(self.dark ? 0xFFC0DB : 0xA63D6B);
}
- (BOOL)setValidatedHex:(NSString *)hex {
    MCColor c;
    NSString *value = [hex stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!MCColorParse(value.UTF8String, &c))
        return NO;
    self.hex = [value hasPrefix:@"#"] ? [value uppercaseString]
                                      : [@"#" stringByAppendingString:[value uppercaseString]];
    return YES;
}
- (void)setHex:(NSString *)hex {
    _hex = [hex copy];
    _followArtwork = NO;
    self.artworkHex = nil;
    self.artworkGeneration++;
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"theme.followArtwork"];
    [[NSUserDefaults standardUserDefaults] setObject:_hex forKey:@"theme.hex"];
    [self apply];
}
- (void)setFollowArtwork:(BOOL)followArtwork {
    _followArtwork = followArtwork;
    self.artworkGeneration++;
    if (!followArtwork) self.artworkHex = nil;
    [[NSUserDefaults standardUserDefaults] setBool:followArtwork forKey:@"theme.followArtwork"];
    [self apply];
}
- (void)updateArtwork:(UIImage *)image {
    NSUInteger generation = ++self.artworkGeneration;
    if (!self.followArtwork) return;
    if (!image.CGImage) {
        if (self.artworkHex) { self.artworkHex = nil; [self apply]; }
        return;
    }
    CGImageRef cover = CGImageRetain(image.CGImage);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        uint8_t pixels[16*16*4] = {0};
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(pixels,16,16,8,16*4,space,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
        MCColor color;
        BOOL found = NO;
        if (context) {
            CGContextSetInterpolationQuality(context,kCGInterpolationLow);
            CGContextDrawImage(context,CGRectMake(0,0,16,16),cover);
            found = MCColorArtwork(pixels,16,16,16*4,&color);
            CGContextRelease(context);
        }
        CGColorSpaceRelease(space);
        CGImageRelease(cover);
        NSString *hex = found ? [NSString stringWithFormat:@"#%02X%02X%02X",(unsigned)round(color.r*255),
                                 (unsigned)round(color.g*255),(unsigned)round(color.b*255)] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.followArtwork || generation != self.artworkGeneration) return;
            if (self.artworkHex == hex || [self.artworkHex isEqual:hex]) return;
            self.artworkHex = hex;
            [self apply];
        });
    });
}
- (void)setDark:(BOOL)dark {
    _dark = dark;
    [[NSUserDefaults standardUserDefaults] setBool:dark forKey:@"theme.dark"];
    [self apply];
}
- (void)apply {
    [[UINavigationBar appearance] setBarTintColor:self.surface];
    [[UINavigationBar appearance] setTintColor:self.primary];
    [[UINavigationBar appearance] setTitleTextAttributes:@{NSForegroundColorAttributeName : self.text}];
    [[UITabBar appearance] setBarTintColor:self.surface];
    [[UITabBar appearance] setTintColor:self.primary];
    [[NSNotificationCenter defaultCenter] postNotificationName:MCThemeDidChangeNotification object:self];
}
@end
