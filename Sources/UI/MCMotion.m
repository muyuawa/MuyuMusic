#import "MCMotion.h"
#import <QuartzCore/QuartzCore.h>

NSString *const MCMotionDidChangeNotification = @"MCMotionDidChangeNotification";
static NSString *const MCMotionPreference = @"ui.animations.enabled";
BOOL MCMotionEnabled(void) {
    id saved = [[NSUserDefaults standardUserDefaults] objectForKey:MCMotionPreference];
    return saved ? [saved boolValue] : YES;
}
void MCSetMotionEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:MCMotionPreference];
    [[NSNotificationCenter defaultCenter] postNotificationName:MCMotionDidChangeNotification object:nil];
}
void MCAnimate(NSTimeInterval duration, UIViewAnimationOptions options, void (^changes)(void)) {
    if (!changes) return;
    if (!MCMotionEnabled() || [UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        changes();
        return;
    }
    [UIView animateWithDuration:duration delay:0
        options:options | UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
        animations:changes completion:nil];
}
void MCFadeChange(UIView *view, NSTimeInterval duration, void (^changes)(void)) {
    if (!changes) return;
    if (!view.window || view.hidden || !MCMotionEnabled() ||
        [UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        changes();
        return;
    }
    [UIView transitionWithView:view duration:duration
        options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionBeginFromCurrentState |
                UIViewAnimationOptionAllowUserInteraction animations:changes completion:nil];
}
void MCFinishAnimations(UIView *view) {
    [view.layer removeAllAnimations];
    for (UIView *child in view.subviews) MCFinishAnimations(child);
}
