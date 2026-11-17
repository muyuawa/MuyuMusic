#import "MCPlaybackButton.h"
#import "MCMotion.h"
#include <math.h>

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
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(motionChanged)
            name:MCMotionDidChangeNotification object:nil];
    }
    return self;
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)motionChanged { if (!MCMotionEnabled()) MCFinishAnimations(self); }
- (void)setIcon:(MCPlaybackIcon)icon {
    if (_icon == icon) return;
    MCFadeChange(self, .12, ^{ self->_icon = icon; [self setNeedsDisplay]; });
}
- (void)setInk:(UIColor *)ink { _ink = ink; [self setNeedsDisplay]; }
- (void)setContrastOutline:(UIColor *)color { _contrastOutline = color; [self setNeedsDisplay]; }
- (void)setFill:(UIColor *)fill { _fill = fill; [self setNeedsDisplay]; }
- (void)setSelectionFill:(UIColor *)fill { _selectionFill = fill; [self setNeedsDisplay]; }
- (void)setHighlighted:(BOOL)value {
    [super setHighlighted:value];
    [self setNeedsDisplay];
    MCAnimate(.10, UIViewAnimationOptionCurveEaseOut, ^{ self.alpha = value ? .82 : 1; });
}
- (void)setSelected:(BOOL)value { [super setSelected:value]; [self setNeedsDisplay]; }
- (void)setEnabled:(BOOL)value { [super setEnabled:value]; [self setNeedsDisplay]; }
- (void)drawRect:(CGRect)rect {
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGContextSetAlpha(c, !self.enabled ? .35 : self.highlighted ? .65 : 1);
    if (self.fill) {
        [self.fill setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.bounds, 1, 1)
                                   cornerRadius:MIN(22, self.bounds.size.height / 2)] fill];
    } else if (self.selected || self.highlighted) {
        [(self.selected && self.selectionFill ? self.selectionFill
            : [self.ink colorWithAlphaComponent:self.selected ? .12 : .07]) setFill];
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
                [@"1" drawInRect:CGRectMake(9, 5, 8, 14) withFont:[UIFont boldSystemFontOfSize:11]];
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
            if (self.contrastOutline) {
                CGPathRef path = CGContextCopyPath(c);
                [self.contrastOutline setStroke];
                CGContextSetLineWidth(c, 3.2);
                CGContextStrokePath(c);
                CGContextAddPath(c, path);
                CGPathRelease(path);
                [self.ink setStroke];
                CGContextSetLineWidth(c, 1.8);
            }
            if (self.selected) CGContextFillPath(c); else CGContextStrokePath(c);
            break;
        case MCPlaybackIconDetails:
            for (unsigned i = 0; i < 3; i++) CGContextFillEllipseInRect(c, CGRectMake(3 + i * 7, 10, 4, 4));
            break;
        case MCPlaybackIconRecent:
            CGContextStrokeEllipseInRect(c, CGRectMake(3, 3, 18, 18));
            MCLine(c, 12, 6, 12, 12); MCLine(c, 12, 12, 16, 14); CGContextStrokePath(c); break;
        case MCPlaybackIconLocal:
            CGContextMoveToPoint(c, 2, 6); CGContextAddLineToPoint(c, 9, 6);
            CGContextAddLineToPoint(c, 11, 9); CGContextAddLineToPoint(c, 22, 9);
            CGContextAddLineToPoint(c, 22, 20); CGContextAddLineToPoint(c, 2, 20);
            CGContextClosePath(c); CGContextStrokePath(c); break;
        case MCPlaybackIconPlaylist:
        case MCPlaybackIconQueue:
            MCLine(c, 2, 5, 20, 5); MCLine(c, 2, 11, 15, 11); MCLine(c, 2, 17, 10, 17);
            MCLine(c, 18, 10, 18, 20); MCLine(c, 18, 10, 22, 9);
            CGContextStrokePath(c); CGContextFillEllipseInRect(c, CGRectMake(13, 18, 5, 4)); break;
        case MCPlaybackIconAccount:
            CGContextStrokeEllipseInRect(c, CGRectMake(8, 3, 8, 8));
            CGContextMoveToPoint(c, 4, 21); CGContextAddCurveToPoint(c, 4, 10, 20, 10, 20, 21);
            CGContextClosePath(c); CGContextStrokePath(c); break;
        case MCPlaybackIconSearch:
            CGContextStrokeEllipseInRect(c, CGRectMake(3, 3, 13, 13));
            MCLine(c, 15, 15, 22, 22); CGContextStrokePath(c); break;
        case MCPlaybackIconSettings:
            CGContextStrokeEllipseInRect(c, CGRectMake(5, 5, 14, 14));
            CGContextStrokeEllipseInRect(c, CGRectMake(9, 9, 6, 6));
            for (unsigned i=0;i<8;i++) {
                double a=i*M_PI/4;
                MCLine(c, 12+cos(a)*8, 12+sin(a)*8, 12+cos(a)*11, 12+sin(a)*11);
            }
            CGContextStrokePath(c); break;
    }
}
@end
UIImage *MCPlayerSliderTrack(UIColor *color) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(12, 5), NO, 0);
    [color setFill];
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 12, 5) cornerRadius:2.5] fill];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image resizableImageWithCapInsets:UIEdgeInsetsMake(0, 5, 0, 5)];
}
UIImage *MCPlayerSliderThumb(UIColor *color, BOOL highlighted) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(22, 22), NO, 0);
    CGFloat inset = highlighted ? 1 : 3;
    [color setFill];
    [[UIBezierPath bezierPathWithOvalInRect:CGRectInset(CGRectMake(0, 0, 22, 22), inset, inset)] fill];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}
