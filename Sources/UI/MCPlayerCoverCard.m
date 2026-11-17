#import "MCPlayerCoverCard.h"
#import "MCNowPlayingLayout.h"
#import "MCTheme.h"
#import "MCMotion.h"
#import "MCCoverAppearance.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static char MCCoverAppearanceCacheKey;
static UIColor *MCCoverUIColor(MCColor color) {
    return [UIColor colorWithRed:color.r green:color.g blue:color.b alpha:1];
}
static MCColor MCCoverRGB(UIColor *color) {
    CGFloat r = 0, g = 0, b = 0, alpha = 1;
    [color getRed:&r green:&g blue:&b alpha:&alpha];
    return (MCColor){r, g, b};
}
static dispatch_queue_t MCCoverAnalysisQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("com.muyu.cover-appearance", DISPATCH_QUEUE_SERIAL); });
    return queue;
}
static NSData *MCCoverPixels(UIImage *image, double aspect) {
    uint8_t pixels[48 * 48 * 4] = {0};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, 48, 48, 8, 48 * 4, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!context) return nil;
    /* UIImage drawing applies EXIF orientation. Crop before reducing, just
       like the displayed Aspect Fill view, with row zero at the top. */
    CGContextTranslateCTM(context, 0, 48);
    CGContextScaleCTM(context, 1, -1);
    CGContextSetInterpolationQuality(context, kCGInterpolationLow);
    double cardHeight = 48 / aspect;
    double scale = MAX(48 / image.size.width, cardHeight / image.size.height);
    CGRect draw = CGRectMake((48 - image.size.width * scale) / 2,
        (cardHeight - image.size.height * scale) / 2, image.size.width * scale, image.size.height * scale);
    CGContextScaleCTM(context, 1, aspect);
    UIGraphicsPushContext(context);
    [image drawInRect:draw];
    UIGraphicsPopContext();
    CGContextRelease(context);
    return [NSData dataWithBytes:pixels length:sizeof pixels];
}

@interface MCCoverAppearanceCache : NSObject
@property (nonatomic, strong) NSCache *samples;
@property (nonatomic, strong) NSCache *appearances;
@end
@implementation MCCoverAppearanceCache
- (id)init {
    if ((self = [super init])) {
        _samples = [NSCache new]; _samples.countLimit = 2;
        _appearances = [NSCache new]; _appearances.countLimit = 6;
    }
    return self;
}
@end

static CGRect MCCardRect(MCPlayerRect r) { return CGRectMake(r.x, r.y, r.width, r.height); }
static CGRect MCPanelRect(MCPlayerRect r, MCPlayerRect panel) {
    return CGRectOffset(MCCardRect(r), -panel.x, -panel.y);
}

@interface MCCoverTitleButton : UIButton
@property (nonatomic, strong) UILabel *displayLabel;
@end
@implementation MCCoverTitleButton
- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.displayLabel = [UILabel new];
        self.displayLabel.backgroundColor = [UIColor clearColor];
        self.displayLabel.font = [UIFont boldSystemFontOfSize:16];
        self.displayLabel.numberOfLines = 1;
        self.displayLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        self.displayLabel.adjustsFontSizeToFitWidth = NO;
        self.displayLabel.isAccessibilityElement = NO;
        [self addSubview:self.displayLabel];
        self.titleLabel.hidden = YES;
        self.titleLabel.isAccessibilityElement = NO;
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    /* iOS 6 UIButton's attributed-title layout can retain an undersized
       text rect. Keep its title for accessibility, but render in an owned
       label whose frame always fills the allocated title button. */
    self.titleLabel.hidden = YES;
    self.displayLabel.frame = self.bounds;
}
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    MCAnimate(.10, UIViewAnimationOptionCurveEaseOut, ^{ self.displayLabel.alpha = highlighted ? .78 : 1; });
}
@end

@interface MCCoverArtworkView : UIImageView
@property (nonatomic, copy) void (^toggleInformation)(void);
@end
@implementation MCCoverArtworkView
- (BOOL)accessibilityActivate {
    if (!self.toggleInformation) return NO;
    self.toggleInformation();
    return YES;
}
@end

@interface MCPlayerCoverCard () <UIGestureRecognizerDelegate>
@property (nonatomic, strong, readwrite) UIImageView *artworkView;
@property (nonatomic, strong, readwrite) UIButton *titleButton;
@property (nonatomic, strong, readwrite) MCMaterialChip *qualityButton;
@property (nonatomic, strong, readwrite) MCPlaybackButton *favoriteButton;
@property (nonatomic, strong) UILabel *artistLabel;
@property (nonatomic, readonly) UILabel *titleTextLabel;
@property (nonatomic, strong) UIView *informationPanel;
@property (nonatomic, strong) CAGradientLayer *informationGradient;
@property (nonatomic) BOOL informationHidden;
@property (nonatomic) NSUInteger informationGeneration, appearanceGeneration;
@property (nonatomic, strong) UIImage *analyzedArtwork;
@property (nonatomic, copy) NSString *requestedAppearanceKey;
@property (nonatomic, copy) NSString *coverTitle, *coverArtist;
@property (nonatomic) MCCoverAppearance appearance;
@property (nonatomic) BOOL hasArtworkAppearance;
@property (nonatomic, copy) NSString *fullQuality;
- (void)toggleInformation;
- (void)applyAppearance:(MCCoverAppearance)appearance;
- (void)applyTextAppearance;
- (void)requestAppearance:(MCPlayerCoverLayout)layout;
@end

@implementation MCPlayerCoverCard
- (UILabel *)titleTextLabel { return ((MCCoverTitleButton *)self.titleButton).displayLabel; }
- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.clipsToBounds = YES;
        self.layer.cornerRadius = 24;
        MCCoverArtworkView *artwork = [MCCoverArtworkView new];
        __weak MCPlayerCoverCard *weakSelf = self;
        artwork.toggleInformation = ^{ [weakSelf toggleInformation]; };
        self.artworkView = artwork;
        self.artworkView.contentMode = UIViewContentModeScaleAspectFill;
        self.artworkView.isAccessibilityElement = YES;
        self.artworkView.accessibilityLabel = @"专辑封面";
        self.artworkView.accessibilityTraits = UIAccessibilityTraitImage | UIAccessibilityTraitButton;
        self.artworkView.accessibilityHint = @"点按两次隐藏封面信息";
        [self addSubview:self.artworkView];
        self.informationPanel = [UIView new];
        self.informationPanel.opaque = NO;
        self.informationPanel.backgroundColor = [UIColor clearColor];
        self.informationGradient = [CAGradientLayer layer];
        self.informationGradient.startPoint = CGPointMake(.5, 0);
        self.informationGradient.endPoint = CGPointMake(.5, 1);
        NSMutableArray *locations = [NSMutableArray array];
        for (unsigned i = 0; i < MCCoverGradientStops; i++)
            [locations addObject:@(i / (double)(MCCoverGradientStops - 1))];
        self.informationGradient.locations = locations;
        [self.informationPanel.layer addSublayer:self.informationGradient];
        [self addSubview:self.informationPanel];
        self.titleButton = [MCCoverTitleButton new];
        self.titleButton.backgroundColor = [UIColor clearColor];
        self.titleButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        self.titleTextLabel.textAlignment = NSTextAlignmentLeft;
        self.titleButton.accessibilityHint = @"点按查看完整歌名与歌曲信息";
        [self.informationPanel addSubview:self.titleButton];
        self.artistLabel = [UILabel new];
        self.artistLabel.backgroundColor = [UIColor clearColor];
        self.artistLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.informationPanel addSubview:self.artistLabel];
        self.qualityButton = [MCMaterialChip new];
        self.qualityButton.leading = YES;
        self.qualityButton.accessibilityLabel = @"实际音质";
        self.qualityButton.accessibilityHint = @"点按查看完整音频参数";
        [self.informationPanel addSubview:self.qualityButton];
        self.favoriteButton = [MCPlaybackButton new];
        self.favoriteButton.icon = MCPlaybackIconFavorite;
        [self.informationPanel addSubview:self.favoriteButton];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleInformation)];
        tap.delegate = self;
        tap.cancelsTouchesInView = NO;
        [self addGestureRecognizer:tap];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(theme)
            name:MCThemeDidChangeNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(motionChanged)
            name:MCMotionDidChangeNotification object:nil];
        [self theme];
    }
    return self;
}
- (void)theme {
    MCTheme *t = [MCTheme sharedTheme];
    self.backgroundColor = t.surfaceContainerHigh;
    [self applyAppearance:self.hasArtworkAppearance ? self.appearance : MCCoverAppearanceFallback(MCCoverRGB(t.surfaceContainerHigh))];
    [self setNeedsLayout];
}
- (void)applyAppearance:(MCCoverAppearance)appearance {
    self.appearance = appearance;
    NSMutableArray *colors = [NSMutableArray array];
    NSMutableArray *locations = [NSMutableArray array];
    UIColor *tint = MCCoverUIColor(appearance.tint);
    for (unsigned i = 0; i < MCCoverGradientStops; i++) {
        [colors addObject:(__bridge id)[tint colorWithAlphaComponent:appearance.opacity[i]].CGColor];
        [locations addObject:@(MCCoverGradientPosition(appearance, i))];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.informationGradient.colors = colors;
    self.informationGradient.locations = locations;
    [CATransaction commit];
    MCColor chip = MCColorBlend(appearance.tint, MCCoverRGB([MCTheme sharedTheme].primary), .12);
    self.qualityButton.fill = MCCoverUIColor(chip);
    self.qualityButton.ink = MCCoverUIColor(MCColorForeground(chip));
    self.favoriteButton.ink = MCCoverUIColor(appearance.foreground);
    UIColor *edge = appearance.foreground.r == 0 ? [UIColor whiteColor] : [UIColor blackColor];
    self.favoriteButton.contrastOutline = appearance.needsTextOutline ? [edge colorWithAlphaComponent:.78] : nil;
    self.favoriteButton.selectionFill = self.qualityButton.fill;
    [self applyTextAppearance];
}
- (void)applyTextAppearance {
    UIColor *text = MCCoverUIColor(self.appearance.foreground);
    UIColor *edge = self.appearance.foreground.r == 0 ? [UIColor whiteColor] : [UIColor blackColor];
    NSMutableDictionary *title = [NSMutableDictionary dictionaryWithDictionary:@{
        NSFontAttributeName:self.titleTextLabel.font, NSForegroundColorAttributeName:text}];
    NSMutableDictionary *artist = [NSMutableDictionary dictionaryWithDictionary:@{
        NSFontAttributeName:self.artistLabel.font, NSForegroundColorAttributeName:text}];
    if (self.appearance.needsTextOutline) {
        title[NSStrokeColorAttributeName] = artist[NSStrokeColorAttributeName] = [edge colorWithAlphaComponent:.78];
        title[NSStrokeWidthAttributeName] = artist[NSStrokeWidthAttributeName] = @(-2.5);
    }
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.alignment = NSTextAlignmentLeft;
    paragraph.lineBreakMode = NSLineBreakByTruncatingTail;
    title[NSParagraphStyleAttributeName] = paragraph;
    self.titleTextLabel.attributedText = [[NSAttributedString alloc] initWithString:self.coverTitle ?: @"" attributes:title];
    self.artistLabel.attributedText = [[NSAttributedString alloc] initWithString:self.coverArtist ?: @"" attributes:artist];
    self.titleTextLabel.shadowColor = self.artistLabel.shadowColor = nil;
    [self.titleButton setTitleColor:text forState:UIControlStateNormal];
    [self.titleButton setTitleColor:[text colorWithAlphaComponent:.78] forState:UIControlStateHighlighted];
}
- (void)updateArtwork:(UIImage *)image {
    self.analyzedArtwork = image;
    self.appearanceGeneration++;
    self.requestedAppearanceKey = nil;
    self.hasArtworkAppearance = NO;
    if (!image) self.artworkView.image = nil;
    [self theme];
}
- (void)requestAppearance:(MCPlayerCoverLayout)layout {
    UIImage *image = self.analyzedArtwork;
    if (!image.CGImage || image.size.width <= 0 || image.size.height <= 0 ||
        self.bounds.size.width <= 0 || self.bounds.size.height <= 0) return;
    double width = self.bounds.size.width, height = self.bounds.size.height;
    MCColor fallback = MCCoverRGB([MCTheme sharedTheme].surfaceContainerHigh);
    NSString *sampleKey = [NSString stringWithFormat:@"%.4f", width / height];
    /* Sample the actual single-line label widths. */
    layout.title.width = MIN(layout.title.width, [self.coverTitle ?: @"" sizeWithFont:self.titleTextLabel.font].width);
    layout.artist.width = MIN(layout.artist.width, [self.coverArtist ?: @"" sizeWithFont:self.artistLabel.font].width);
    layout.title.y += 2; layout.title.height -= 4;
    layout.artist.y += 1; layout.artist.height -= 2;
    NSString *key = [NSString stringWithFormat:@"v2:%@:%gx%g:%u:%.1f:%.1f:%g,%g,%g", sampleKey, width, height,
        layout.titleLines, layout.title.width, layout.artist.width, fallback.r, fallback.g, fallback.b];
    if ([self.requestedAppearanceKey isEqual:key]) return;
    self.requestedAppearanceKey = key;
    NSUInteger generation = ++self.appearanceGeneration;
    MCCoverAppearanceCache *cache = objc_getAssociatedObject(image, &MCCoverAppearanceCacheKey);
    if (!cache) {
        cache = [MCCoverAppearanceCache new];
        objc_setAssociatedObject(image, &MCCoverAppearanceCacheKey, cache, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSData *saved = [cache.appearances objectForKey:key];
    if (saved.length == sizeof(MCCoverAppearance)) {
        MCCoverAppearance appearance; [saved getBytes:&appearance length:sizeof appearance];
        self.hasArtworkAppearance = YES;
        [self applyAppearance:appearance];
        return;
    }
    NSData *samples = [cache.samples objectForKey:sampleKey];
    __weak MCPlayerCoverCard *weakSelf = self;
    dispatch_async(MCCoverAnalysisQueue(), ^{
        @autoreleasepool {
            NSData *pixels = samples ?: MCCoverPixels(image, width / height);
            MCCoverAppearance appearance = MCCoverAppearanceFallback(fallback);
            if (pixels.length == 48 * 48 * 4)
                MCCoverAppearanceMake(pixels.bytes, 48, 48, 48 * 4, width, height, layout, fallback, &appearance);
            NSData *result = [NSData dataWithBytes:&appearance length:sizeof appearance];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (pixels) [cache.samples setObject:pixels forKey:sampleKey];
                [cache.appearances setObject:result forKey:key];
                MCPlayerCoverCard *card = weakSelf;
                if (!card || card.analyzedArtwork != image || card.appearanceGeneration != generation) return;
                card.hasArtworkAppearance = YES;
                [card applyAppearance:appearance];
            });
        }
    });
}
- (void)toggleInformation {
    BOOL hidden = !self.informationHidden;
    self.informationHidden = hidden;
    NSUInteger generation = ++self.informationGeneration;
    self.informationPanel.hidden = NO;
    self.informationPanel.userInteractionEnabled = !hidden;
    self.informationPanel.accessibilityElementsHidden = hidden;
    self.artworkView.accessibilityHint = hidden ? @"点按两次显示封面信息" : @"点按两次隐藏封面信息";
    MCAnimateCompletion(.22, UIViewAnimationOptionCurveEaseInOut, ^{
        self.informationPanel.alpha = hidden ? 0 : 1;
    }, ^(BOOL finished) {
        if (finished && self.informationGeneration == generation) self.informationPanel.hidden = hidden;
    });
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    (void)gesture;
    /* Preserve the title, quality and favorite actions, including the
       quality chip's expanded hit area. Blank artwork toggles the overlay. */
    for (UIView *view = touch.view; view && view != self; view = view.superview)
        if ([view isKindOfClass:[UIControl class]]) return NO;
    return YES;
}
- (void)motionChanged {
    if (!MCMotionEnabled()) {
        MCFinishAnimations(self.informationPanel);
        self.informationPanel.alpha = self.informationHidden ? 0 : 1;
        self.informationPanel.hidden = self.informationHidden;
    }
}
- (void)showTitle:(NSString *)title artist:(NSString *)artist quality:(NSString *)quality {
    self.coverTitle = [[title componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" "];
    self.coverArtist = artist;
    [self.titleButton setTitle:title forState:UIControlStateNormal];
    self.titleButton.accessibilityLabel = title;
    self.artistLabel.text = artist;
    self.fullQuality = quality;
    self.qualityButton.accessibilityValue = quality;
    [self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    MCPlayerCoverLayout l = MCPlayerCoverMakeLayout(self.bounds.size.width, self.bounds.size.height, 1);
    UIFont *titleFont = [UIFont boldSystemFontOfSize:l.titleFontSize];
    self.artworkView.frame = self.bounds;
    self.informationPanel.frame = MCCardRect(l.panel);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.informationGradient.frame = self.informationPanel.bounds;
    [CATransaction commit];
    self.titleButton.frame = MCPanelRect(l.title, l.panel);
    self.titleTextLabel.font = titleFont;
    self.titleTextLabel.numberOfLines = 1;
    self.artistLabel.frame = MCPanelRect(l.artist, l.panel);
    self.artistLabel.font = [UIFont systemFontOfSize:l.artistFontSize];
    self.qualityButton.frame = MCPanelRect(l.quality, l.panel);
    self.favoriteButton.frame = MCPanelRect(l.favorite, l.panel);
    [self applyTextAppearance];
    [self requestAppearance:l];
    NSString *text = self.fullQuality ?: @"音质待加载";
    text = [text stringByReplacingOccurrencesOfString:@" · " withString:@" "];
    text = [text stringByReplacingOccurrencesOfString:@"-bit" withString:@""];
    text = [text stringByReplacingOccurrencesOfString:@" / " withString:@"/"];
    text = [text stringByReplacingOccurrencesOfString:@" kHz" withString:@""];
    if (![self.qualityButton.currentTitle isEqual:text])
        [self.qualityButton setTitle:text forState:UIControlStateNormal];
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
@end
