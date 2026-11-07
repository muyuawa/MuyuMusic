#import "MCDialogs.h"
#import <objc/runtime.h>
@interface MCDialogDelegate : NSObject <UIAlertViewDelegate, UIActionSheetDelegate>
@property (nonatomic, copy) void (^input)(NSString *);
@property (nonatomic, copy) void (^action)(void);
@property (nonatomic, copy) void (^choice)(NSInteger);
@end
@implementation MCDialogDelegate
- (void)alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)index {
    if (index != alert.cancelButtonIndex && self.input)
        self.input([alert textFieldAtIndex:0].text);
    if (index != alert.cancelButtonIndex && self.action)
        self.action();
    if (index != alert.cancelButtonIndex && self.choice)
        self.choice(index - 1);
}
- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)index {
    if (index != sheet.cancelButtonIndex && self.choice)
        self.choice(index);
}
@end
void MCMessage(UIViewController *controller, NSString *title, NSString *message) {
    (void)controller;
    [[[UIAlertView alloc] initWithTitle:title
                                message:message
                               delegate:nil
                      cancelButtonTitle:@"好"
                      otherButtonTitles:nil] show];
}
void MCInput(NSString *title, NSString *message, NSString *value, void (^completion)(NSString *)) {
    MCDialogDelegate *d = [MCDialogDelegate new];
    d.input = completion;
    UIAlertView *a = [[UIAlertView alloc] initWithTitle:title
                                                message:message
                                               delegate:d
                                      cancelButtonTitle:@"取消"
                                      otherButtonTitles:@"保存", nil];
    a.alertViewStyle = UIAlertViewStylePlainTextInput;
    [a textFieldAtIndex:0].text = value;
    [a textFieldAtIndex:0].autocorrectionType = UITextAutocorrectionTypeNo;
    objc_setAssociatedObject(a, @selector(input), d, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [a show];
}
void MCChoose(UIViewController *controller, NSString *title, NSArray *choices,
              void (^completion)(NSInteger)) {
    MCDialogDelegate *d = [MCDialogDelegate new];
    d.choice = completion;
    UIActionSheet *a = [[UIActionSheet alloc] initWithTitle:title
                                                   delegate:d
                                          cancelButtonTitle:nil
                                     destructiveButtonTitle:nil
                                          otherButtonTitles:nil];
    for (NSString *s in choices)
        [a addButtonWithTitle:s];
    a.cancelButtonIndex = [a addButtonWithTitle:@"取消"];
    objc_setAssociatedObject(a, @selector(choice), d, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [a showInView:controller.view.window ?: controller.view];
}

void MCConfirm(NSString *title, NSString *message, NSString *button, void (^completion)(void)) {
    MCDialogDelegate *delegate = [MCDialogDelegate new];
    delegate.action = completion;
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:title
                                                    message:message
                                                   delegate:delegate
                                          cancelButtonTitle:@"关闭"
                                          otherButtonTitles:button, nil];
    objc_setAssociatedObject(alert, @selector(action), delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [alert show];
}
void MCChooseMessage(NSString *title, NSString *message, NSArray *choices, void (^completion)(NSInteger)) {
    MCDialogDelegate *delegate = [MCDialogDelegate new];
    delegate.choice = completion;
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:title
                                                    message:message
                                                   delegate:delegate
                                          cancelButtonTitle:@"关闭"
                                          otherButtonTitles:nil];
    for (NSString *choice in choices)
        [alert addButtonWithTitle:choice];
    objc_setAssociatedObject(alert, @selector(choice), delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [alert show];
}
