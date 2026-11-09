#import "MCFlatControls.h"
#import "MCTheme.h"
#import "MCMotion.h"
#import <QuartzCore/QuartzCore.h>

@interface MCFlatSwitch ()
@property (nonatomic, strong) UIView *track;
@property (nonatomic, strong) UIView *thumb;
@end
@implementation MCFlatSwitch
- (id)initWithFrame:(CGRect)frame {
    if (CGRectIsEmpty(frame))
        frame = CGRectMake(0, 0, 50, 30);
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;
        self.track = [UIView new];
        self.track.userInteractionEnabled = NO;
        self.thumb = [UIView new];
        self.thumb.userInteractionEnabled = NO;
        [self addSubview:self.track];
        [self addSubview:self.thumb];
        [self addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(themeChanged)
                                                     name:MCThemeDidChangeNotification
                                                   object:nil];
        [self themeChanged];
    }
    return self;
}
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}
- (CGSize)sizeThatFits:(CGSize)size {
    (void)size;
    return CGSizeMake(50, 30);
}
- (CGSize)intrinsicContentSize {
    return CGSizeMake(50, 30);
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    (void)event;
    return CGRectContainsPoint(CGRectInset(self.bounds, -3, -7), point);
}
- (void)themeChanged {
    self.onTintColor = [MCTheme sharedTheme].primary;
}
- (void)setOnTintColor:(UIColor *)color {
    _onTintColor = color;
    [self setNeedsLayout];
}
- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    self.alpha = enabled ? 1 : .45;
}
- (void)setOn:(BOOL)on {
    [self setOn:on animated:NO];
}
- (void)setOn:(BOOL)on animated:(BOOL)animated {
    _on = on;
    self.accessibilityValue = on ? @"已开启" : @"已关闭";
    if (animated && MCMotionEnabled()) {
        MCAnimate(.16, UIViewAnimationOptionCurveEaseOut, ^{ [self layoutThumb]; });
    } else {
        MCFinishAnimations(self);
        [self setNeedsLayout];
    }
}
- (void)layoutThumb {
    CGFloat height = self.bounds.size.height;
    self.track.frame = self.bounds;
    self.track.layer.cornerRadius = height / 2;
    self.track.backgroundColor =
        self.on ? self.onTintColor : [[MCTheme sharedTheme].muted colorWithAlphaComponent:.22];
    self.thumb.backgroundColor = [UIColor whiteColor];
    self.thumb.layer.cornerRadius = (height - 4) / 2;
    self.thumb.frame =
        CGRectMake(self.on ? self.bounds.size.width - height + 2 : 2, 2, height - 4, height - 4);
}
- (void)layoutSubviews {
    [super layoutSubviews];
    [self layoutThumb];
}
- (void)toggle {
    [self setOn:!self.on animated:YES];
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}
- (BOOL)accessibilityActivate {
    if (!self.enabled)
        return NO;
    [self toggle];
    return YES;
}
@end

@interface MCFlatAccessory : UIView
@property (nonatomic) UITableViewCellAccessoryType kind;
@end
@implementation MCFlatAccessory
- (void)drawRect:(CGRect)rect {
    (void)rect;
    UIBezierPath *path = [UIBezierPath bezierPath];
    path.lineWidth = 1.8;
    path.lineCapStyle = kCGLineCapRound;
    path.lineJoinStyle = kCGLineJoinRound;
    if (self.kind == UITableViewCellAccessoryCheckmark) {
        [[MCTheme sharedTheme].primary setStroke];
        [path moveToPoint:CGPointMake(2, 13)];
        [path addLineToPoint:CGPointMake(7, 18)];
        [path addLineToPoint:CGPointMake(18, 6)];
    } else {
        [[MCTheme sharedTheme].muted setStroke];
        [path moveToPoint:CGPointMake(6, 6)];
        [path addLineToPoint:CGPointMake(12, 12)];
        [path addLineToPoint:CGPointMake(6, 18)];
    }
    [path stroke];
}
@end

@interface MCFlatTableCell ()
@property (nonatomic) UITableViewCellAccessoryType flatAccessoryType;
@property (nonatomic, strong) UIView *flatBackground;
@property (nonatomic, strong) UIView *flatSelection;
@end
@implementation MCFlatTableCell
- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    if ((self = [super initWithStyle:style reuseIdentifier:identifier])) {
        MCTheme *theme = [MCTheme sharedTheme];
        self.backgroundColor = theme.surface;
        self.flatBackground = [UIView new];
        self.backgroundView = self.flatBackground;
        self.backgroundView.backgroundColor = theme.surface;
        self.flatSelection = [UIView new];
        self.selectedBackgroundView = self.flatSelection;
        self.selectedBackgroundView.backgroundColor = [theme.primary colorWithAlphaComponent:.10];
    }
    return self;
}
- (void)clearLabelBackgrounds {
    self.textLabel.backgroundColor = self.detailTextLabel.backgroundColor = [UIColor clearColor];
    self.textLabel.opaque = self.detailTextLabel.opaque = NO;
    self.contentView.backgroundColor = [UIColor clearColor];
    if (self.backgroundView == self.flatBackground)
        self.flatBackground.backgroundColor = self.backgroundColor;
    if (self.selectedBackgroundView == self.flatSelection)
        self.flatSelection.backgroundColor = [[MCTheme sharedTheme].primary colorWithAlphaComponent:.10];
    self.textLabel.highlightedTextColor = self.textLabel.textColor;
    self.detailTextLabel.highlightedTextColor = self.detailTextLabel.textColor;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    [self clearLabelBackgrounds];
}
- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    [super setSelected:selected animated:animated && MCMotionEnabled()];
    [self clearLabelBackgrounds];
}
- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    [super setHighlighted:highlighted animated:animated && MCMotionEnabled()];
    [self clearLabelBackgrounds];
}
- (UITableViewCellAccessoryType)accessoryType {
    return self.flatAccessoryType;
}
- (void)setAccessoryType:(UITableViewCellAccessoryType)type {
    self.flatAccessoryType = type;
    [super setAccessoryType:UITableViewCellAccessoryNone];
    if (type == UITableViewCellAccessoryNone) {
        self.accessoryView = nil;
        return;
    }
    MCFlatAccessory *accessory = [[MCFlatAccessory alloc] initWithFrame:CGRectMake(0, 0, 20, 24)];
    accessory.backgroundColor = [UIColor clearColor];
    accessory.opaque = NO;
    accessory.userInteractionEnabled = NO;
    accessory.kind = type;
    self.accessoryView = accessory;
}
@end

@implementation MCFlatTableController
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIView *tray = [self.tabBarController.view viewWithTag:8080];
    if (!tray || tray.hidden) return;
    // The tray overlays the navigation content, so reserve it in every list.
    CGFloat bottom = MAX(52, tray.bounds.size.height) + 8;
    UIEdgeInsets content = self.tableView.contentInset;
    UIEdgeInsets indicator = self.tableView.scrollIndicatorInsets;
    if (content.bottom < bottom) { content.bottom = bottom; self.tableView.contentInset = content; }
    if (indicator.bottom < bottom) { indicator.bottom = bottom; self.tableView.scrollIndicatorInsets = indicator; }
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return nil;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return nil;
}
- (CGFloat)heightForText:(NSString *)text table:(UITableView *)table header:(BOOL)header {
    if (!text.length)
        return table.style == UITableViewStyleGrouped ? 10 : 0;
    UIFont *font = header ? [UIFont boldSystemFontOfSize:13] : [UIFont systemFontOfSize:13];
    CGSize size = [text sizeWithFont:font
                   constrainedToSize:CGSizeMake(MAX(1, table.bounds.size.width - 32), CGFLOAT_MAX)
                       lineBreakMode:NSLineBreakByWordWrapping];
    return ceil(size.height) + 20;
}
- (UIView *)sectionText:(NSString *)text table:(UITableView *)table header:(BOOL)header {
    if (!text.length)
        return nil;
    CGFloat height = [self heightForText:text table:table header:header];
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, table.bounds.size.width, height)];
    container.backgroundColor = [UIColor clearColor];
    container.opaque = NO;
    UILabel *label =
        [[UILabel alloc] initWithFrame:CGRectMake(16, 10, MAX(1, table.bounds.size.width - 32), height - 20)];
    label.backgroundColor = [UIColor clearColor];
    label.opaque = NO;
    label.numberOfLines = 0;
    label.lineBreakMode = NSLineBreakByWordWrapping;
    label.font = header ? [UIFont boldSystemFontOfSize:13] : [UIFont systemFontOfSize:13];
    label.textColor = [MCTheme sharedTheme].muted;
    label.text = text;
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [container addSubview:label];
    return container;
}
- (UIView *)tableView:(UITableView *)table viewForHeaderInSection:(NSInteger)section {
    return [self sectionText:[self tableView:table titleForHeaderInSection:section] table:table header:YES];
}
- (UIView *)tableView:(UITableView *)table viewForFooterInSection:(NSInteger)section {
    return [self sectionText:[self tableView:table titleForFooterInSection:section] table:table header:NO];
}
- (CGFloat)tableView:(UITableView *)table heightForHeaderInSection:(NSInteger)section {
    return [self heightForText:[self tableView:table titleForHeaderInSection:section] table:table header:YES];
}
- (CGFloat)tableView:(UITableView *)table heightForFooterInSection:(NSInteger)section {
    return [self heightForText:[self tableView:table titleForFooterInSection:section] table:table header:NO];
}
@end

@interface MCFlatBackButton ()
@property (nonatomic, strong) UILabel *caption;
@end
@implementation MCFlatBackButton
- (id)initWithTitle:(NSString *)title {
    CGFloat width = MIN(74, ceil([title sizeWithFont:[UIFont systemFontOfSize:15]].width) + 22);
    if ((self = [super initWithFrame:CGRectMake(0, 0, MAX(44, width), 44)])) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.clipsToBounds = YES;
        self.caption = [[UILabel alloc] initWithFrame:CGRectMake(20, 0, self.bounds.size.width - 20, 44)];
        self.caption.backgroundColor = [UIColor clearColor];
        self.caption.opaque = NO;
        self.caption.font = [UIFont systemFontOfSize:15];
        self.caption.lineBreakMode = NSLineBreakByTruncatingTail;
        self.caption.text = title;
        self.caption.userInteractionEnabled = NO;
        [self addSubview:self.caption];
        self.accessibilityLabel = [@"返回 " stringByAppendingString:title ?: @""];
        self.accessibilityTraits = UIAccessibilityTraitButton;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(themeChanged)
                                                     name:MCThemeDidChangeNotification
                                                   object:nil];
        [self themeChanged];
    }
    return self;
}
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}
- (void)themeChanged {
    self.caption.textColor = [MCTheme sharedTheme].primary;
    [self setNeedsDisplay];
}
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? .65 : 1;
}
- (void)drawRect:(CGRect)rect {
    (void)rect;
    [[MCTheme sharedTheme].primary setStroke];
    UIBezierPath *path = [UIBezierPath bezierPath];
    path.lineWidth = 2;
    path.lineCapStyle = kCGLineCapRound;
    path.lineJoinStyle = kCGLineJoinRound;
    [path moveToPoint:CGPointMake(12, 14)];
    [path addLineToPoint:CGPointMake(4, 22)];
    [path addLineToPoint:CGPointMake(12, 30)];
    [path stroke];
}
@end
