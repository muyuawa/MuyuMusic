#import <UIKit/UIKit.h>
#import "MCUI.h"
#import "MCTheme.h"
#import "MCLibrary.h"
#import "MCAPI.h"
#import "MCPlayer.h"
#import "MCDialogs.h"
#import "MCSourceRepository.h"
@interface MCAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, copy) NSDictionary *sourceUpdate;
@end
@implementation MCAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application;
    (void)options;
    [[MCTheme sharedTheme] apply];
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [MCRootController new];
    self.window.tintColor = [MCTheme sharedTheme].primary;
    [self.window makeKeyAndVisible];
    [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
    [self becomeFirstResponder];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(sourceUpdateReceived:)
                                                 name:@"MCLXRuntimeUpdateAlert"
                                               object:nil];
    [[MCLibrary sharedLibrary] scan:nil];
    [[MCAPI sharedAPI] refreshLogin:^(id result, NSError *error) {
        (void)result;
        (void)error;
    }];
    return YES;
}
- (void)sourceUpdateReceived:(NSNotification *)notification {
    self.sourceUpdate = notification.userInfo;
    [self showSourceUpdate];
}
- (void)showSourceUpdate {
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive || !self.sourceUpdate)
        return;
    NSDictionary *info = self.sourceUpdate;
    self.sourceUpdate = nil;
    NSString *log = [info[@"log"] isKindOfClass:[NSString class]] ? info[@"log"] : @"";
    if (log.length > 1024)
        log = [log substringToIndex:1024];
    NSURL *url =
        [info[@"updateUrl"] isKindOfClass:[NSString class]] ? [NSURL URLWithString:info[@"updateUrl"]] : nil;
    if ([url.scheme.lowercaseString isEqualToString:@"https"] && url.host.length && !url.user &&
        !url.password)
        MCConfirm(@"音源更新", log, @"打开更新页", ^{
            [[UIApplication sharedApplication] openURL:url];
        });
    else
        MCMessage(self.window.rootViewController, @"音源更新", log);
}
- (BOOL)canBecomeFirstResponder {
    return YES;
}
- (void)remoteControlReceivedWithEvent:(UIEvent *)event {
    [[MCPlayer sharedPlayer] handleRemoteEvent:event];
}
- (void)applicationDidBecomeActive:(UIApplication *)application {
    (void)application;
    [[MCLibrary sharedLibrary] scan:nil];
    [self showSourceUpdate];
    [[MCSourceRepository sharedRepository] applicationDidBecomeActive];
}
@end
int main(int argc, char **argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([MCAppDelegate class]));
    }
}
