#import <UIKit/UIKit.h>
@interface MCLyricCell : UITableViewCell
+ (CGFloat)heightForText:(NSString *)text translation:(NSString *)translation width:(CGFloat)width;
- (void)showText:(NSString *)text translation:(NSString *)translation active:(BOOL)active;
@end
