#import <UIKit/UIKit.h>

FOUNDATION_EXPORT NSString *const MCMotionDidChangeNotification;
BOOL MCMotionEnabled(void);
void MCSetMotionEnabled(BOOL enabled);
void MCAnimate(NSTimeInterval duration, UIViewAnimationOptions options, void (^changes)(void));
void MCFadeChange(UIView *view, NSTimeInterval duration, void (^changes)(void));
void MCFinishAnimations(UIView *view);
