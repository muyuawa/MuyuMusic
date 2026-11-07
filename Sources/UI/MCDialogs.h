#import <UIKit/UIKit.h>
void MCMessage(UIViewController *controller, NSString *title, NSString *message);
void MCInput(NSString *title, NSString *message, NSString *value, void (^completion)(NSString *));
void MCChoose(UIViewController *controller, NSString *title, NSArray *choices, void (^completion)(NSInteger));
void MCChooseMessage(NSString *title, NSString *message, NSArray *choices, void (^completion)(NSInteger));

void MCConfirm(NSString *title, NSString *message, NSString *button, void (^completion)(void));
