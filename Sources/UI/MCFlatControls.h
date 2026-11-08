#import <UIKit/UIKit.h>

/* Small UIKit controls drawn with flat colors on both iOS 6 and iOS 7. */
@interface MCFlatSwitch : UIControl
@property (nonatomic, getter=isOn) BOOL on;
@property (nonatomic, strong) UIColor *onTintColor;
- (void)setOn:(BOOL)on animated:(BOOL)animated;
@end

@interface MCFlatTableCell : UITableViewCell
@end

@interface MCFlatTableController : UITableViewController
@end

@interface MCFlatBackButton : UIButton
- (id)initWithTitle:(NSString *)title;
@end
