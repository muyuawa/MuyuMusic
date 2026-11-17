#import "MCMaterialControls.h"
#import "MCTheme.h"
#import "MCArtwork.h"
#import <QuartzCore/QuartzCore.h>

@implementation MCMaterialSegmentedControl
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    (void)event;
    CGFloat extra = MAX(0, (44 - self.bounds.size.height) / 2);
    return CGRectContainsPoint(CGRectInset(self.bounds, 0, -extra), point);
}
@end

@interface MCModeSegmentButton : UIButton
@end
@implementation MCModeSegmentButton
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    (void)event;
    return CGRectContainsPoint(CGRectInset(self.bounds, 0, -MAX(0, (44 - self.bounds.size.height) / 2)), point);
}
- (void)setSelected:(BOOL)value {
    [super setSelected:value];
    [self setNeedsLayout];
    [self setNeedsDisplay];
}
- (void)setHighlighted:(BOOL)value { [super setHighlighted:value]; [self setNeedsDisplay]; }
- (void)layoutSubviews {
    [super layoutSubviews];
    self.titleLabel.frame = CGRectInset(self.bounds, 4, 0);
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
}
- (void)drawRect:(CGRect)rect {
    (void)rect;
    MCTheme *t = [MCTheme sharedTheme];
    if (self.selected || self.highlighted) {
        [(self.selected ? t.primaryContainer : [t.onSurface colorWithAlphaComponent:.08]) setFill];
        [[UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:self.bounds.size.height / 2] fill];
    }
}
@end

@interface MCMaterialModeControl ()
@property (nonatomic, strong) NSArray *segments;
@end
@implementation MCMaterialModeControl
- (id)initWithItems:(NSArray *)items {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.opaque = NO;
        self.layer.cornerRadius = 20;
        NSMutableArray *segments = [NSMutableArray array];
        for (NSUInteger i = 0; i < items.count; i++) {
            MCModeSegmentButton *button = [[MCModeSegmentButton alloc] initWithFrame:CGRectZero];
            button.opaque = NO;
            button.backgroundColor = [UIColor clearColor];
            button.tag = i;
            button.accessibilityLabel = items[i];
            [button setTitle:items[i] forState:UIControlStateNormal];
            [button addTarget:self action:@selector(segmentTapped:) forControlEvents:UIControlEventTouchUpInside];
            [self addSubview:button];
            [segments addObject:button];
        }
        self.segments = segments;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(theme)
            name:MCThemeDidChangeNotification object:nil];
        [self theme];
    }
    return self;
}
- (void)theme {
    MCTheme *t = [MCTheme sharedTheme];
    self.backgroundColor = t.surfaceContainer;
    for (MCModeSegmentButton *button in self.segments) {
        button.titleLabel.font = [t fontForRole:MCTypeLabel];
        [button setTitleColor:t.text forState:UIControlStateNormal];
        [button setTitleColor:t.onPrimaryContainer forState:UIControlStateSelected];
        [button setTitleColor:t.onPrimaryContainer forState:UIControlStateSelected | UIControlStateHighlighted];
        button.selected = button.tag == self.selectedSegmentIndex;
        button.accessibilityTraits = UIAccessibilityTraitButton | (button.selected ? UIAccessibilityTraitSelected : 0);
        [button setNeedsDisplay];
    }
}
- (void)setSelectedSegmentIndex:(NSInteger)value {
    _selectedSegmentIndex = MAX(0, MIN((NSInteger)self.segments.count - 1, value));
    [self theme];
}
- (void)segmentTapped:(UIButton *)button {
    if (button.tag == self.selectedSegmentIndex) return;
    self.selectedSegmentIndex = button.tag;
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    (void)event;
    return CGRectContainsPoint(CGRectInset(self.bounds, 0, -MAX(0, (44 - self.bounds.size.height) / 2)), point);
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.cornerRadius = self.bounds.size.height / 2;
    CGFloat width = (self.bounds.size.width - 8) / MAX((NSUInteger)1, self.segments.count);
    for (UIButton *button in self.segments)
        button.frame = CGRectMake(4 + button.tag * width, 4, width, MAX(0, self.bounds.size.height - 8));
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
@end

@implementation MCMaterialChip
- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
        self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(theme)
            name:MCThemeDidChangeNotification object:nil];
        [self theme];
    }
    return self;
}
- (void)theme {
    MCTheme *t = [MCTheme sharedTheme];
    self.titleLabel.font = [t fontForRole:MCTypeCaption];
    [self setTitleColor:self.ink ?: t.onPrimaryContainer forState:UIControlStateNormal];
    [self setNeedsLayout];
    [self setNeedsDisplay];
}
- (CGRect)pillRect {
    CGFloat text = [(self.currentTitle ?: @"") sizeWithFont:self.titleLabel.font].width;
    CGFloat width = MIN(self.bounds.size.width, MAX(64, text + 24));
    CGFloat height = MIN(24, self.bounds.size.height);
    return CGRectMake(self.leading ? 0 : (self.bounds.size.width - width) / 2, (self.bounds.size.height - height) / 2, width, height);
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    (void)event;
    CGFloat extra = MAX(0, 44 - self.bounds.size.height);
    CGFloat room = self.superview ? MAX(0, CGRectGetMaxY(self.superview.bounds) - CGRectGetMaxY(self.frame)) : extra / 2;
    CGFloat bottom = MIN(extra / 2, room);
    CGRect hit = self.bounds;
    hit.origin.y -= extra - bottom;
    hit.size.height += extra;
    return CGRectContainsPoint(hit, point);
}
- (void)setLeading:(BOOL)value { _leading = value; [self setNeedsLayout]; [self setNeedsDisplay]; }
- (void)setFill:(UIColor *)value { _fill = value; [self setNeedsDisplay]; }
- (void)setInk:(UIColor *)value { _ink = value; [self theme]; }
- (void)setTitle:(NSString *)title forState:(UIControlState)state {
    [super setTitle:title forState:state];
    [self setNeedsLayout];
    [self setNeedsDisplay];
}
- (void)setHighlighted:(BOOL)value { [super setHighlighted:value]; [self setNeedsDisplay]; }
- (void)layoutSubviews {
    [super layoutSubviews];
    self.titleLabel.frame = CGRectInset([self pillRect], 12, 0);
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
}
- (void)drawRect:(CGRect)rect {
    (void)rect;
    MCTheme *t = [MCTheme sharedTheme];
    [(self.fill ?: t.primaryContainer) setFill];
    CGRect pill = [self pillRect];
    [[UIBezierPath bezierPathWithRoundedRect:pill cornerRadius:pill.size.height / 2] fill];
    if (self.highlighted) {
        [[(self.ink ?: t.onPrimaryContainer) colorWithAlphaComponent:.08] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:pill cornerRadius:pill.size.height / 2] fill];
    }
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
@end

@implementation MCMaterialCard
- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(theme)
            name:MCThemeDidChangeNotification object:nil];
        [self theme];
    }
    return self;
}
- (void)setEmphasized:(BOOL)value { _emphasized = value; [self theme]; }
- (void)theme {
    MCTheme *t = [MCTheme sharedTheme];
    self.backgroundColor = self.emphasized ? t.primaryContainer : t.surfaceContainer;
    self.layer.cornerRadius = t.cardRadius;
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
@end

@interface MCMaterialButton ()
@property (nonatomic, strong) MCPlaybackButton *glyph;
@end
@implementation MCMaterialButton
- (id)initWithTitle:(NSString *)title icon:(MCPlaybackIcon)icon filled:(BOOL)filled {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
        _filled = filled;
        self.glyph = [MCPlaybackButton new];
        self.glyph.icon = icon;
        self.glyph.userInteractionEnabled = NO;
        self.glyph.isAccessibilityElement = NO;
        [self addSubview:self.glyph];
        [self setTitle:title forState:UIControlStateNormal];
        self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        self.accessibilityLabel = title;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(theme)
            name:MCThemeDidChangeNotification object:nil];
        [self theme];
    }
    return self;
}
- (void)theme {
    MCTheme *t = [MCTheme sharedTheme];
    self.titleLabel.font = [t fontForRole:self.vertical ? MCTypeCaption : MCTypeLabel];
    UIColor *ink = self.filled ? t.onPrimary : t.text;
    self.glyph.ink = ink;
    [self setTitleColor:ink forState:UIControlStateNormal];
    [self setNeedsDisplay];
}
- (void)setFilled:(BOOL)value { _filled = value; [self theme]; }
- (void)setVertical:(BOOL)value { _vertical = value; [self theme]; [self setNeedsLayout]; }
- (void)setHighlighted:(BOOL)value { [super setHighlighted:value]; [self setNeedsDisplay]; }
- (void)setEnabled:(BOOL)value { [super setEnabled:value]; self.alpha = value ? 1 : .45; }
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    self.glyph.frame = self.vertical ? CGRectMake((w - 32) / 2, 3, 32, 32) : CGRectMake(4, (h - 44) / 2, 44, 44);
    self.titleLabel.frame = self.vertical ? CGRectMake(2, 35, w - 4, h - 37) : CGRectMake(44, 0, w - 52, h);
    self.titleLabel.textAlignment = self.vertical ? NSTextAlignmentCenter : NSTextAlignmentLeft;
}
- (void)drawRect:(CGRect)rect {
    (void)rect;
    MCTheme *t = [MCTheme sharedTheme];
    UIColor *color = self.filled ? t.primary : t.surfaceContainer;
    [color setFill];
    [[UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:self.vertical ? t.smallRadius : 22] fill];
    if (self.highlighted) {
        [[(self.filled ? t.onPrimary : t.text) colorWithAlphaComponent:.10] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:self.vertical ? t.smallRadius : 22] fill];
    }
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
@end

@interface MCCatalogTile ()
@property (nonatomic, strong) UIImageView *cover;
@property (nonatomic, strong) UILabel *caption;
@end
@implementation MCCatalogTile
- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.opaque = NO;
        self.cover = [UIImageView new];
        self.cover.contentMode = UIViewContentModeScaleAspectFill;
        self.cover.clipsToBounds = YES;
        self.cover.layer.cornerRadius = 12;
        [self addSubview:self.cover];
        self.caption = [UILabel new];
        self.caption.numberOfLines = 2;
        self.caption.backgroundColor = [UIColor clearColor];
        self.caption.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:self.caption];
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(theme)
            name:MCThemeDidChangeNotification object:nil];
        [self theme];
    }
    return self;
}
- (void)showItem:(NSDictionary *)item {
    self.caption.text = [item[@"title"] isKindOfClass:[NSString class]] ? item[@"title"] : @"";
    self.accessibilityLabel = self.caption.text;
    self.accessibilityHint = @"点按打开，长按显示操作";
    [[MCArtwork sharedCache] load:item[@"artwork"] into:self.cover];
}
- (void)theme {
    MCTheme *t = [MCTheme sharedTheme];
    self.cover.backgroundColor = t.surfaceContainer;
    self.caption.textColor = t.text;
    self.caption.font = [t fontForRole:MCTypeCaption];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat side = MIN(w, self.bounds.size.height - 38);
    self.cover.frame = CGRectMake(0, 0, w, side);
    self.caption.frame = CGRectMake(0, side + 5, w, 32);
}
- (void)setHighlighted:(BOOL)value { [super setHighlighted:value]; self.alpha = value ? .72 : 1; }
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
@end
