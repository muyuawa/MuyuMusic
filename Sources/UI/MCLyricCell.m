#import "MCLyricCell.h"
#import "MCTheme.h"
#include <math.h>

static CGFloat MCTextHeight(NSString *text, UIFont *font, CGFloat width) {
    CGSize size = [(text ?: @"") sizeWithFont:font constrainedToSize:CGSizeMake(MAX(1, width), CGFLOAT_MAX)
                             lineBreakMode:NSLineBreakByWordWrapping];
    return MIN(ceil(font.lineHeight * 2), MAX(ceil(font.lineHeight), ceil(size.height)));
}
@interface MCLyricCell ()
@property (nonatomic, strong) UILabel *mainLine, *translatedLine;
@property (nonatomic, copy) NSString *words, *translatedWords;
@end
@implementation MCLyricCell
+ (CGFloat)heightForText:(NSString *)text translation:(NSString *)translation width:(CGFloat)width {
    CGFloat main = MCTextHeight(text, [UIFont boldSystemFontOfSize:20], width - 24);
    CGFloat extra = translation.length ? 4 + MCTextHeight(translation, [UIFont systemFontOfSize:12], width - 24) : 0;
    return MAX(44, main + extra + 12);
}
- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    if ((self = [super initWithStyle:style reuseIdentifier:identifier])) {
        self.mainLine = [UILabel new];
        self.translatedLine = [UILabel new];
        for (UILabel *label in @[self.mainLine, self.translatedLine]) {
            label.backgroundColor = [UIColor clearColor];
            label.numberOfLines = 2;
            label.textAlignment = NSTextAlignmentCenter;
            label.lineBreakMode = NSLineBreakByTruncatingTail;
            label.isAccessibilityElement = NO;
            [self.contentView addSubview:label];
        }
        self.translatedLine.font = [UIFont systemFontOfSize:12];
        self.selectedBackgroundView = [UIView new];
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;
        self.accessibilityHint = @"点按从这一句开始播放";
    }
    return self;
}
- (void)showText:(NSString *)text translation:(NSString *)translation active:(BOOL)active {
    self.words = text ?: @"";
    self.translatedWords = translation ?: @"";
    self.mainLine.text = self.words;
    self.translatedLine.text = self.translatedWords;
    self.translatedLine.hidden = !translation.length;
    self.mainLine.font = active ? [UIFont boldSystemFontOfSize:20] : [UIFont boldSystemFontOfSize:17];
    MCTheme *theme = [MCTheme sharedTheme];
    self.mainLine.textColor = active ? theme.primary : theme.muted;
    self.translatedLine.textColor = active ? theme.text : theme.muted;
    self.backgroundColor = self.contentView.backgroundColor = [UIColor clearColor];
    self.selectedBackgroundView.backgroundColor = theme.primaryContainer;
    self.accessibilityLabel = translation.length ? [NSString stringWithFormat:@"%@，%@", text, translation] : text;
    self.accessibilityValue = active ? @"当前歌词" : nil;
    [self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.contentView.bounds.size.width;
    CGFloat main = MCTextHeight(self.words, [UIFont boldSystemFontOfSize:20], width - 24);
    CGFloat extra = self.translatedWords.length ? MCTextHeight(self.translatedWords, self.translatedLine.font, width - 24) : 0;
    CGFloat top = (self.contentView.bounds.size.height - main - (extra ? extra + 4 : 0)) / 2;
    self.mainLine.frame = CGRectMake(12, top, MAX(0, width - 24), main);
    self.translatedLine.frame = CGRectMake(12, top + main + 4, MAX(0, width - 24), extra);
}
@end
