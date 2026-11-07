#import "MCPlaybackButton.h"

static void MCLine(CGContextRef c, CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2) {
    CGContextMoveToPoint(c, x1, y1);
    CGContextAddLineToPoint(c, x2, y2);
}
static void MCTriangle(CGContextRef c, CGFloat x, CGFloat direction) {
    CGContextMoveToPoint(c, x, 4);
    CGContextAddLineToPoint(c, x + direction * 14, 12);
    CGContextAddLineToPoint(c, x, 20);
    CGContextClosePath(c);
    CGContextFillPath(c);
}
@implementation MCPlaybackButton
- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
    }
    return self;
}
- (void)setIcon:(MCPlaybackIcon)icon { _icon = icon; [self setNeedsDisplay]; }
- (void)setInk:(UIColor *)ink { _ink = ink; [self setNeedsDisplay]; }
- (void)setFill:(UIColor *)fill { _fill = fill; [self setNeedsDisplay]; }
- (void)setHighlighted:(BOOL)value { [super setHighlighted:value]; [self setNeedsDisplay]; }
- (void)setSelected:(BOOL)value { [super setSelected:value]; [self setNeedsDisplay]; }
- (void)setEnabled:(BOOL)value { [super setEnabled:value]; [self setNeedsDisplay]; }
- (void)drawRect:(CGRect)rect {
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGContextSetAlpha(c, !self.enabled ? .35 : self.highlighted ? .65 : 1);
    if (self.fill) {
        [self.fill setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectInset(self.bounds, 1, 1)] fill];
    } else if (self.selected || self.highlighted) {
        [[self.ink colorWithAlphaComponent:self.selected ? .12 : .07] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.bounds, 2, 2) cornerRadius:20] fill];
    }
    [self.ink setFill];
    [self.ink setStroke];
    CGContextTranslateCTM(c, (rect.size.width - 24) / 2, (rect.size.height - 24) / 2);
    CGContextSetLineWidth(c, 1.8);
    CGContextSetLineCap(c, kCGLineCapRound);
    CGContextSetLineJoin(c, kCGLineJoinRound);
    switch (self.icon) {
        case MCPlaybackIconPlay: MCTriangle(c, 7, 1); break;
        case MCPlaybackIconPause:
            CGContextFillRect(c, CGRectMake(6, 4, 4, 16));
            CGContextFillRect(c, CGRectMake(14, 4, 4, 16));
            break;
        case MCPlaybackIconPrevious:
            MCTriangle(c, 20, -1); CGContextFillRect(c, CGRectMake(3, 4, 3, 16)); break;
        case MCPlaybackIconNext:
            MCTriangle(c, 4, 1); CGContextFillRect(c, CGRectMake(18, 4, 3, 16)); break;
        case MCPlaybackIconSequence:
            MCLine(c, 3, 6, 13, 6); MCLine(c, 3, 12, 10, 12); MCLine(c, 3, 18, 13, 18);
            MCLine(c, 13, 12, 22, 12); MCLine(c, 18, 8, 22, 12); MCLine(c, 22, 12, 18, 16);
            CGContextStrokePath(c); break;
        case MCPlaybackIconRepeat:
        case MCPlaybackIconRepeatOne:
            CGContextMoveToPoint(c, 3, 11); CGContextAddLineToPoint(c, 3, 9);
            CGContextAddQuadCurveToPoint(c, 3, 5, 7, 5); CGContextAddLineToPoint(c, 21, 5);
            MCLine(c, 17, 1, 21, 5); MCLine(c, 21, 5, 17, 9);
            CGContextMoveToPoint(c, 21, 13); CGContextAddLineToPoint(c, 21, 15);
            CGContextAddQuadCurveToPoint(c, 21, 19, 17, 19); CGContextAddLineToPoint(c, 3, 19);
            MCLine(c, 7, 15, 3, 19); MCLine(c, 3, 19, 7, 23); CGContextStrokePath(c);
            if (self.icon == MCPlaybackIconRepeatOne)
                [@"1" drawInRect:CGRectMake(9, 5, 8, 14) withAttributes:@{
                    NSFontAttributeName:[UIFont boldSystemFontOfSize:11], NSForegroundColorAttributeName:self.ink}];
            break;
        case MCPlaybackIconShuffle:
            CGContextMoveToPoint(c, 2, 5); CGContextAddLineToPoint(c, 5, 5);
            CGContextAddCurveToPoint(c, 10, 5, 14, 19, 19, 19); CGContextAddLineToPoint(c, 22, 19);
            CGContextMoveToPoint(c, 2, 19); CGContextAddLineToPoint(c, 5, 19);
            CGContextAddCurveToPoint(c, 10, 19, 14, 5, 19, 5); CGContextAddLineToPoint(c, 22, 5);
            MCLine(c, 18, 1, 22, 5); MCLine(c, 22, 5, 18, 9);
            MCLine(c, 18, 15, 22, 19); MCLine(c, 22, 19, 18, 23); CGContextStrokePath(c); break;
        case MCPlaybackIconFavorite:
            CGContextMoveToPoint(c, 12, 21);
            CGContextAddCurveToPoint(c, -5, 10, 4, -2, 12, 6);
            CGContextAddCurveToPoint(c, 20, -2, 29, 10, 12, 21);
            CGContextClosePath(c);
            if (self.selected) CGContextFillPath(c); else CGContextStrokePath(c);
            break;
        case MCPlaybackIconDetails:
            for (unsigned i = 0; i < 3; i++) CGContextFillEllipseInRect(c, CGRectMake(3 + i * 7, 10, 4, 4));
            break;
    }
}
@end
UIImage *MCPlayerSliderTrack(UIColor *color) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(8, 4), NO, 0);
    [color setFill];
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 8, 4) cornerRadius:2] fill];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image resizableImageWithCapInsets:UIEdgeInsetsMake(0, 3, 0, 3)];
}
UIImage *MCPlayerSliderThumb(UIColor *color, BOOL highlighted) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(22, 22), NO, 0);
    CGFloat inset = highlighted ? 2 : 3;
    [color setFill];
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(inset, inset, 22 - 2 * inset, 22 - 2 * inset)] fill];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}
