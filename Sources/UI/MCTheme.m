#import "MCTheme.h"
#import "MCColor.h"
#import <QuartzCore/QuartzCore.h>
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
static UIImage *MCThemeBarImage(UIColor *color) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(1, 32), NO, 0);
    [color setFill];
    UIRectFill(CGRectMake(0, 0, 1, 32));
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image resizableImageWithCapInsets:UIEdgeInsetsZero];
}
static UIImage *MCThemeFieldImage(UIColor *color) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(20, 36), NO, 0);
    [color setFill];
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 20, 36) cornerRadius:8] fill];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image resizableImageWithCapInsets:UIEdgeInsetsMake(9, 9, 9, 9)];
}
static UIImage *MCThemeIcon(UIImage *source, UIColor *color) {
    if (!source) return nil;
    UIGraphicsBeginImageContextWithOptions(source.size, NO, 0);
    CGRect rect = (CGRect){CGPointZero, source.size};
    [source drawInRect:rect];
    [color setFill];
    UIRectFillUsingBlendMode(rect, kCGBlendModeSourceIn);
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}
static void MCThemeSearchText(UIView *view, MCTheme *theme) {
    if ([view isKindOfClass:[UITextField class]]) {
        UITextField *field = (UITextField *)view;
        field.textColor = theme.text;
        field.font = [UIFont systemFontOfSize:15];
        field.borderStyle = UITextBorderStyleNone;
        field.backgroundColor = [UIColor clearColor];
        if (field.placeholder.length)
            field.attributedPlaceholder = [[NSAttributedString alloc] initWithString:field.placeholder
                attributes:@{NSForegroundColorAttributeName:theme.muted}];
    }
    for (UIView *child in view.subviews) MCThemeSearchText(child, theme);
}
static UIImage *MCThemeBackImage(UIColor *color) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(26, 30), NO, 0);
    [color setStroke];
    UIBezierPath *arrow = [UIBezierPath bezierPath];
    arrow.lineWidth = 2;
    [arrow moveToPoint:CGPointMake(12, 7)];
    [arrow addLineToPoint:CGPointMake(4, 15)];
    [arrow addLineToPoint:CGPointMake(12, 23)];
    [arrow stroke];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image resizableImageWithCapInsets:UIEdgeInsetsMake(0, 18, 0, 2)];
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
- (void)applyToNavigationBar:(UINavigationBar *)bar {
    bar.translucent = NO;
    bar.shadowImage = MCThemeBarImage([UIColor clearColor]);
    [bar setBackgroundImage:MCThemeBarImage(self.surface) forBarMetrics:UIBarMetricsDefault];
    if (@available(iOS 7.0, *)) {
        bar.barTintColor = self.surface;
        bar.tintColor = self.primary;
    } else {
        bar.tintColor = self.surface;
        bar.barStyle = self.dark ? UIBarStyleBlack : UIBarStyleDefault;
    }
    bar.titleTextAttributes = @{UITextAttributeTextColor:self.text,
                               UITextAttributeTextShadowColor:[UIColor clearColor]};
    // UIAppearance only initializes new buttons. Refresh existing/back items
    // after a cover-color change and whenever a controller is pushed.
    for (UINavigationItem *navigation in bar.items) {
        if (!navigation.backBarButtonItem && navigation.title.length)
            navigation.backBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:navigation.title
                style:UIBarButtonItemStylePlain target:nil action:NULL];
        NSMutableArray *items = [NSMutableArray arrayWithArray:navigation.leftBarButtonItems ?: @[]];
        [items addObjectsFromArray:navigation.rightBarButtonItems ?: @[]];
        if (navigation.backBarButtonItem) [items addObject:navigation.backBarButtonItem];
        for (UIBarButtonItem *item in items) {
            for (NSNumber *state in @[@(UIControlStateNormal), @(UIControlStateHighlighted)]) {
                [item setTitleTextAttributes:@{UITextAttributeTextColor:self.primary,
                    UITextAttributeTextShadowColor:[UIColor clearColor]} forState:state.unsignedIntegerValue];
                [item setBackgroundImage:MCThemeBarImage([UIColor clearColor])
                               forState:state.unsignedIntegerValue barMetrics:UIBarMetricsDefault];
                [item setBackButtonBackgroundImage:MCThemeBackImage(self.primary)
                                         forState:state.unsignedIntegerValue barMetrics:UIBarMetricsDefault];
            }
        }
    }
}
- (void)applyToTabBar:(UITabBar *)bar {
    if (!bar) return;
    UIImage *clear = MCThemeBarImage([UIColor clearColor]);
    bar.backgroundImage = MCThemeBarImage(self.surface);
    bar.shadowImage = clear;
    bar.selectionIndicatorImage = clear;
    bar.selectedImageTintColor = self.primary;
    if (@available(iOS 7.0, *)) {
        bar.barTintColor = self.surface;
        bar.tintColor = self.primary;
        bar.translucent = NO;
    } else bar.tintColor = self.surface;
    for (UITabBarItem *item in bar.items) {
        [item setFinishedSelectedImage:MCThemeIcon(item.image, self.primary)
          withFinishedUnselectedImage:MCThemeIcon(item.image, self.muted)];
        for (NSNumber *value in @[@(UIControlStateNormal), @(UIControlStateHighlighted),
                                  @(UIControlStateSelected), @(UIControlStateSelected | UIControlStateHighlighted)]) {
            UIControlState state = value.unsignedIntegerValue;
            BOOL active = state & (UIControlStateSelected | UIControlStateHighlighted);
            [item setTitleTextAttributes:@{UITextAttributeFont:[UIFont systemFontOfSize:11],
                UITextAttributeTextColor:active ? self.primary : self.muted,
                UITextAttributeTextShadowColor:[UIColor clearColor],
                UITextAttributeTextShadowOffset:[NSValue valueWithUIOffset:UIOffsetZero]} forState:state];
        }
    }
}
- (void)applyToSearchBar:(UISearchBar *)bar {
    if (!bar) return;
    UIColor *surface = self.dark ? self.surface : [UIColor whiteColor];
    UIColor *field = self.dark ? MCRGB(0x343D4D) : MCRGB(0xF0F2F5);
    bar.backgroundColor = surface;
    bar.backgroundImage = MCThemeBarImage(surface);
    bar.translucent = NO;
    [bar setSearchFieldBackgroundImage:MCThemeFieldImage(field) forState:UIControlStateNormal];
    [bar setSearchFieldBackgroundImage:MCThemeFieldImage(field) forState:UIControlStateDisabled];
    if (@available(iOS 7.0, *)) {
        bar.barTintColor = surface;
        bar.tintColor = self.primary;
    } else bar.tintColor = surface;
    MCThemeSearchText(bar, self);
}
- (void)applyToSegmentedControl:(UISegmentedControl *)control {
    if (!control) return;
    // Supplying every divider is essential on iOS 6: the native selected
    // divider otherwise contributes its blue glossy edge to custom images.
    UIColor *surface = self.dark ? self.surface : [UIColor whiteColor];
    UIImage *normal = MCThemeBarImage(surface);
    UIImage *selected = MCThemeBarImage(self.primary);
    UIImage *pressed = MCThemeBarImage(self.dark ? MCRGB(0x3A4355) : MCRGB(0xE8ECF2));
    UIImage *divider = MCThemeBarImage([UIColor clearColor]);
    NSArray *states = @[@(UIControlStateNormal), @(UIControlStateSelected),
                        @(UIControlStateHighlighted), @(UIControlStateSelected | UIControlStateHighlighted),
                        @(UIControlStateDisabled), @(UIControlStateSelected | UIControlStateDisabled)];
    control.tintColor = self.muted;
    for (NSNumber *value in states) {
        UIControlState state = value.unsignedIntegerValue;
        BOOL active = state & UIControlStateSelected;
        [control setBackgroundImage:active ? selected : (state & UIControlStateHighlighted) ? pressed : normal
                          forState:state barMetrics:UIBarMetricsDefault];
        [control setTitleTextAttributes:@{UITextAttributeFont:active ? [UIFont boldSystemFontOfSize:13] : [UIFont systemFontOfSize:13],
            UITextAttributeTextColor:active ? self.onPrimary : self.text,
            UITextAttributeTextShadowColor:[UIColor clearColor],
            UITextAttributeTextShadowOffset:[NSValue valueWithUIOffset:UIOffsetZero]} forState:state];
        for (NSNumber *right in states)
            [control setDividerImage:divider forLeftSegmentState:state
                  rightSegmentState:right.unsignedIntegerValue barMetrics:UIBarMetricsDefault];
    }
    control.layer.cornerRadius = 7;
    control.layer.borderWidth = 0;
    control.layer.shadowOpacity = 0;
    control.clipsToBounds = YES;
}
- (void)apply {
    if (@available(iOS 7.0, *)) {
        [[UINavigationBar appearance] setBarTintColor:self.surface];
        [[UITabBar appearance] setBarTintColor:self.surface];
    }
    [[UINavigationBar appearance] setTitleTextAttributes:@{UITextAttributeTextColor:self.text,
        UITextAttributeTextShadowColor:[UIColor clearColor]}];
    // iOS 6 bars use tintColor for their background. Bar items need their own
    // text attributes instead of inheriting UIView's iOS 7 tint behavior.
    UIImage *clear = MCThemeBarImage([UIColor clearColor]);
    for (NSNumber *state in @[@(UIControlStateNormal), @(UIControlStateHighlighted)]) {
        [[UIBarButtonItem appearance] setBackgroundImage:clear forState:state.unsignedIntegerValue barMetrics:UIBarMetricsDefault];
        [[UIBarButtonItem appearance] setBackButtonBackgroundImage:MCThemeBackImage(self.primary)
            forState:state.unsignedIntegerValue barMetrics:UIBarMetricsDefault];
    }
    [[UIBarButtonItem appearance] setTitleTextAttributes:@{UITextAttributeTextColor:self.primary,
        UITextAttributeTextShadowColor:[UIColor clearColor]} forState:UIControlStateNormal];
    [[UIApplication sharedApplication] setStatusBarStyle:self.dark ? UIStatusBarStyleBlackOpaque : UIStatusBarStyleDefault];
    [[NSNotificationCenter defaultCenter] postNotificationName:MCThemeDidChangeNotification object:self];
}
@end

@interface MCThemedTextButton : UIButton
@end
@implementation MCThemedTextButton
- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
        self.titleLabel.font = [UIFont systemFontOfSize:15];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateColors)
            name:MCThemeDidChangeNotification object:nil];
        [self updateColors];
    }
    return self;
}
- (void)updateColors {
    MCTheme *theme = [MCTheme sharedTheme];
    [self setTitleColor:theme.primary forState:UIControlStateNormal];
    [self setTitleColor:[theme.primary colorWithAlphaComponent:.6] forState:UIControlStateHighlighted];
    [self setTitleColor:theme.muted forState:UIControlStateDisabled];
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
@end
UIButton *MCTextButton(void) { return [[MCThemedTextButton alloc] initWithFrame:CGRectZero]; }
