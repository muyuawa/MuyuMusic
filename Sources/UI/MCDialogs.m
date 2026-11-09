#import "MCDialogs.h"
#import "MCTheme.h"
#import "MCMotion.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>

typedef NS_ENUM(NSInteger, MCDialogKind) {
    MCDialogMessage,
    MCDialogInput,
    MCDialogChoices,
    MCDialogConfirmation
};

@interface MCDialogRequest : NSObject
@property (nonatomic) MCDialogKind kind;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *message;
@property (nonatomic, copy) NSString *value;
@property (nonatomic, copy) NSArray *choices;
@property (nonatomic, copy) NSString *cancelTitle;
@property (nonatomic, copy) NSString *acceptTitle;
@property (nonatomic, copy) void (^input)(NSString *);
@property (nonatomic, copy) void (^action)(void);
@property (nonatomic, copy) void (^choice)(NSInteger);
@end
@implementation MCDialogRequest
@end

/* Custom buttons never acquire the rounded/glossy iOS 6 UIButton artwork. */
@interface MCDialogButton : UIButton
@property (nonatomic) BOOL primary;
@property (nonatomic) BOOL cancel;
- (void)applyTheme;
@end
@implementation MCDialogButton
- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.layer.cornerRadius = 7;
        self.clipsToBounds = YES;
        self.titleLabel.font = [UIFont systemFontOfSize:16];
        self.titleLabel.numberOfLines = 0;
        self.titleLabel.textAlignment = NSTextAlignmentCenter;
        self.titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
        self.contentEdgeInsets = UIEdgeInsetsMake(8, 12, 8, 12);
        self.adjustsImageWhenHighlighted = NO;
    }
    return self;
}
- (void)applyTheme {
    MCTheme *theme = [MCTheme sharedTheme];
    UIColor *foreground = self.primary ? theme.onPrimary : (self.cancel ? theme.muted : theme.text);
    [self setTitleColor:foreground forState:UIControlStateNormal];
    [self setTitleColor:self.primary ? theme.surface : theme.primary forState:UIControlStateHighlighted];
    [self setTitleShadowColor:[UIColor clearColor] forState:UIControlStateNormal];
    self.backgroundColor = self.highlighted ? (self.primary ? theme.text : theme.background)
                                          : (self.primary ? theme.primary
                                                          : (self.cancel ? [UIColor clearColor] : theme.background));
}
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [self applyTheme];
}
@end

@interface MCDialogTextField : UITextField
@end
@implementation MCDialogTextField
- (CGRect)textRectForBounds:(CGRect)bounds { return CGRectInset(bounds, 12, 0); }
- (CGRect)editingRectForBounds:(CGRect)bounds { return [self textRectForBounds:bounds]; }
@end

@class MCDialogController;
@interface MCDialogCoordinator : NSObject
@property (nonatomic, strong) NSMutableArray *pending;
@property (nonatomic, strong) MCDialogRequest *active;
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIWindow *previousWindow;
@property (nonatomic) BOOL inactive;
@property (nonatomic) BOOL completing;
+ (instancetype)sharedCoordinator;
- (void)enqueue:(MCDialogRequest *)request;
- (void)completeController:(MCDialogController *)controller selection:(NSInteger)selection;
@end

@interface MCDialogController : UIViewController <UITextFieldDelegate>
@property (nonatomic, weak) MCDialogCoordinator *owner;
@property (nonatomic, strong) MCDialogRequest *request;
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UIScrollView *body;
@property (nonatomic, strong) UILabel *heading;
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) MCDialogTextField *field;
@property (nonatomic, strong) NSArray *choiceButtons;
@property (nonatomic, strong) MCDialogButton *cancelButton;
@property (nonatomic, strong) MCDialogButton *acceptButton;
@property (nonatomic) CGRect keyboardFrame;
- (void)invalidate;
@end

static CGFloat MCDialogTextHeight(NSString *text, UIFont *font, CGFloat width) {
    if (!text.length) return 0;
    return ceil([text sizeWithFont:font constrainedToSize:CGSizeMake(width, CGFLOAT_MAX)
                    lineBreakMode:NSLineBreakByWordWrapping].height);
}

@implementation MCDialogController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.opaque = NO;
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:.55];
    self.view.accessibilityViewIsModal = YES;
    self.card = [UIView new];
    self.card.layer.cornerRadius = 12;
    self.card.clipsToBounds = YES;
    [self.view addSubview:self.card];
    self.body = [UIScrollView new];
    self.body.alwaysBounceVertical = NO;
    self.body.showsHorizontalScrollIndicator = NO;
    [self.card addSubview:self.body];
    self.heading = [UILabel new];
    self.heading.text = self.request.title;
    self.heading.font = [UIFont boldSystemFontOfSize:20];
    self.heading.numberOfLines = 0;
    self.heading.lineBreakMode = NSLineBreakByWordWrapping;
    self.heading.backgroundColor = [UIColor clearColor];
    [self.body addSubview:self.heading];
    self.messageLabel = [UILabel new];
    self.messageLabel.text = self.request.message;
    self.messageLabel.font = [UIFont systemFontOfSize:15];
    self.messageLabel.numberOfLines = 0;
    self.messageLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.messageLabel.backgroundColor = [UIColor clearColor];
    [self.body addSubview:self.messageLabel];
    NSMutableArray *buttons = [NSMutableArray array];
    for (NSUInteger index = 0; index < self.request.choices.count; index++) {
        MCDialogButton *button = [[MCDialogButton alloc] initWithFrame:CGRectZero];
        [button setTitle:self.request.choices[index] forState:UIControlStateNormal];
        button.tag = (NSInteger)index;
        [button addTarget:self action:@selector(choose:) forControlEvents:UIControlEventTouchUpInside];
        [self.body addSubview:button];
        [buttons addObject:button];
    }
    self.choiceButtons = buttons;
    self.cancelButton = [[MCDialogButton alloc] initWithFrame:CGRectZero];
    self.cancelButton.cancel = YES;
    self.cancelButton.primary = self.request.kind == MCDialogMessage;
    [self.cancelButton setTitle:self.request.cancelTitle forState:UIControlStateNormal];
    [self.cancelButton addTarget:self action:@selector(cancel:) forControlEvents:UIControlEventTouchUpInside];
    [self.card addSubview:self.cancelButton];
    if (self.request.acceptTitle.length) {
        self.acceptButton = [[MCDialogButton alloc] initWithFrame:CGRectZero];
        self.acceptButton.primary = YES;
        [self.acceptButton setTitle:self.request.acceptTitle forState:UIControlStateNormal];
        [self.acceptButton addTarget:self action:@selector(accept:) forControlEvents:UIControlEventTouchUpInside];
        [self.card addSubview:self.acceptButton];
    }
    if (self.request.kind == MCDialogInput) {
        self.field = [[MCDialogTextField alloc] initWithFrame:CGRectZero];
        self.field.borderStyle = UITextBorderStyleNone;
        self.field.layer.cornerRadius = 7;
        self.field.layer.borderWidth = 1;
        self.field.font = [UIFont systemFontOfSize:16];
        self.field.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
        self.field.text = self.request.value ?: @"";
        self.request.value = nil;
        self.field.accessibilityLabel = self.request.title;
        self.field.autocorrectionType = UITextAutocorrectionTypeNo;
        self.field.spellCheckingType = UITextSpellCheckingTypeNo;
        self.field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        self.field.returnKeyType = UIReturnKeyDone;
        self.field.delegate = self;
        [self.card addSubview:self.field];
    }
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(keyboardChanged:) name:UIKeyboardWillChangeFrameNotification object:nil];
    [center addObserver:self selector:@selector(keyboardHidden:) name:UIKeyboardWillHideNotification object:nil];
    [center addObserver:self selector:@selector(themeChanged:) name:MCThemeDidChangeNotification object:nil];
    [self applyTheme];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (MCMotionEnabled()) {
        self.card.alpha = 0;
    }
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (MCMotionEnabled()) self.card.transform = CGAffineTransformMakeScale(.97, .97);
    MCAnimate(.18, UIViewAnimationOptionCurveEaseOut, ^{
        self.card.alpha = 1;
        self.card.transform = CGAffineTransformIdentity;
    });
    if (!self.owner.inactive) [self.field becomeFirstResponder];
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, self.heading);
}
- (BOOL)shouldAutorotate { return NO; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }
- (void)themeChanged:(NSNotification *)notification {
    (void)notification;
    [self applyTheme];
}
- (void)applyTheme {
    MCTheme *theme = [MCTheme sharedTheme];
    self.card.backgroundColor = theme.surface;
    self.heading.textColor = theme.text;
    self.messageLabel.textColor = theme.muted;
    self.body.indicatorStyle = theme.dark ? UIScrollViewIndicatorStyleWhite : UIScrollViewIndicatorStyleBlack;
    self.field.backgroundColor = theme.background;
    self.field.textColor = theme.text;
    self.field.layer.borderColor = [theme.primary colorWithAlphaComponent:.45].CGColor;
    self.field.keyboardAppearance = theme.dark ? UIKeyboardAppearanceAlert : UIKeyboardAppearanceDefault;
    for (MCDialogButton *button in self.choiceButtons) [button applyTheme];
    [self.cancelButton applyTheme];
    [self.acceptButton applyTheme];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    CGFloat bottom = CGRectGetMaxY(bounds);
    if (!CGRectIsEmpty(self.keyboardFrame)) {
        CGRect keyboard = [self.view convertRect:self.keyboardFrame fromView:nil];
        CGRect covered = CGRectIntersection(bounds, keyboard);
        if (!CGRectIsNull(covered) && !CGRectIsEmpty(covered)) bottom = CGRectGetMinY(covered);
    }
    CGFloat width = MIN(360, CGRectGetWidth(bounds) - 32);
    CGFloat inner = width - 32;
    CGFloat y = 0;
    CGFloat height = MCDialogTextHeight(self.heading.text, self.heading.font, inner);
    self.heading.frame = CGRectMake(0, y, inner, height);
    if (height) y += height + 12;
    height = MCDialogTextHeight(self.messageLabel.text, self.messageLabel.font, inner);
    self.messageLabel.frame = CGRectMake(0, y, inner, height);
    if (height) y += height + 12;
    for (MCDialogButton *button in self.choiceButtons) {
        height = MAX(44, MCDialogTextHeight(button.currentTitle, button.titleLabel.font, inner - 24) + 16);
        button.frame = CGRectMake(0, y, inner, height);
        y += height + 8;
    }
    CGFloat naturalBodyHeight = MAX(0, y - (self.choiceButtons.count ? 8 : 12));
    self.body.contentSize = CGSizeMake(inner, naturalBodyHeight);
    // The field and footer stay visible even on a 320x480 screen with a keyboard.
    CGFloat fieldHeight = self.field ? 56 : 0;
    CGFloat footerHeight = MAX(44, MAX(MCDialogTextHeight(self.cancelButton.currentTitle,
        self.cancelButton.titleLabel.font, self.acceptButton ? (inner - 12) / 2 - 24 : inner - 24),
        MCDialogTextHeight(self.acceptButton.currentTitle, self.acceptButton.titleLabel.font,
            (inner - 12) / 2 - 24)) + 16);
    CGFloat bodyHeight = MIN(naturalBodyHeight, MAX(0, bottom - CGRectGetMinY(bounds) - 76 - fieldHeight - footerHeight));
    CGFloat cardHeight = 32 + bodyHeight + fieldHeight + footerHeight + (bodyHeight ? 12 : 0);
    self.card.frame = CGRectMake(floor((CGRectGetWidth(bounds) - width) / 2),
        floor(CGRectGetMinY(bounds) + (bottom - CGRectGetMinY(bounds) - cardHeight) / 2), width, cardHeight);
    self.body.frame = CGRectMake(16, 16, inner, bodyHeight);
    y = 16 + bodyHeight + (bodyHeight ? 12 : 0);
    if (self.field) {
        self.field.frame = CGRectMake(16, y, inner, 44);
        y += fieldHeight;
    }
    if (self.acceptButton) {
        CGFloat half = (inner - 12) / 2;
        self.cancelButton.frame = CGRectMake(16, y, half, footerHeight);
        self.acceptButton.frame = CGRectMake(28 + half, y, half, footerHeight);
    } else self.cancelButton.frame = CGRectMake(16, y, inner, footerHeight);
}
- (void)keyboardChanged:(NSNotification *)notification {
    self.keyboardFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
}
- (void)keyboardHidden:(NSNotification *)notification {
    (void)notification;
    self.keyboardFrame = CGRectZero;
    [self.view setNeedsLayout];
}
- (void)cancel:(id)sender {
    (void)sender;
    [self.owner completeController:self selection:-1];
}
- (void)accept:(id)sender {
    (void)sender;
    [self.owner completeController:self selection:0];
}
- (void)choose:(UIButton *)sender { [self.owner completeController:self selection:sender.tag]; }
- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    (void)textField;
    [self accept:nil];
    return NO;
}
- (void)invalidate {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    self.field.delegate = nil;
    self.field.text = @"";
    [self.view endEditing:YES];
    self.request = nil;
    self.owner = nil;
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
@end

@implementation MCDialogCoordinator
+ (instancetype)sharedCoordinator {
    static MCDialogCoordinator *coordinator;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ coordinator = [MCDialogCoordinator new]; });
    return coordinator;
}
- (id)init {
    if ((self = [super init])) {
        _pending = [NSMutableArray array];
        _inactive = [UIApplication sharedApplication].applicationState != UIApplicationStateActive;
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:self selector:@selector(willResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
        [center addObserver:self selector:@selector(didBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    }
    return self;
}
- (void)enqueue:(MCDialogRequest *)request {
    [self.pending addObject:request];
    [self showNext];
}
- (void)showNext {
    if (self.active || self.completing || self.inactive || !self.pending.count) return;
    self.active = self.pending[0];
    [self.pending removeObjectAtIndex:0];
    self.previousWindow = [UIApplication sharedApplication].keyWindow;
    [self.previousWindow endEditing:YES];
    MCDialogController *controller = [MCDialogController new];
    controller.owner = self;
    controller.request = self.active;
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.opaque = NO;
    self.window.backgroundColor = [UIColor clearColor];
    // iOS 6 hosts its keyboard in a separate window above normal app windows.
    self.window.windowLevel = UIWindowLevelNormal + .5;
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
}
- (void)restorePreviousWindow {
    UIWindow *restore = self.previousWindow;
    if (!restore || restore.hidden) {
        for (UIWindow *candidate in [UIApplication sharedApplication].windows) {
            if (candidate != self.window && !candidate.hidden && candidate.windowLevel == UIWindowLevelNormal) {
                restore = candidate;
                break;
            }
        }
    }
    [restore makeKeyWindow];
    self.previousWindow = nil;
}
- (void)completeController:(MCDialogController *)controller selection:(NSInteger)selection {
    if (!self.active || controller != self.window.rootViewController || self.completing) return;
    BOOL accepted = selection >= 0 && !self.inactive;
    MCDialogRequest *request = self.active;
    NSString *text = accepted && request.kind == MCDialogInput ? [controller.field.text copy] ?: @"" : nil;
    void (^input)(NSString *) = accepted ? request.input : nil;
    void (^action)(void) = accepted ? request.action : nil;
    void (^choice)(NSInteger) = accepted && selection < (NSInteger)request.choices.count ? request.choice : nil;
    self.completing = YES;
    [controller invalidate];
    self.window.hidden = YES;
    [self restorePreviousWindow];
    self.window.rootViewController = nil;
    self.window = nil;
    self.active = nil;
    request.value = nil;
    request.input = nil;
    request.action = nil;
    request.choice = nil;
    // Tear down the entire window before callbacks: a completion may open another dialog.
    if (input) input(text);
    if (action) action();
    if (choice) choice(selection);
    self.completing = NO;
    [self showNext];
}
- (void)willResignActive:(NSNotification *)notification {
    (void)notification;
    self.inactive = YES;
    // Cancel input without a callback, clearing entered text before the app snapshot.
    for (MCDialogRequest *request in [self.pending copy]) {
        if (request.kind == MCDialogInput) {
            request.value = nil;
            [self.pending removeObjectIdenticalTo:request];
        }
    }
    if (self.active && self.active.kind == MCDialogInput) {
        [self completeController:(MCDialogController *)self.window.rootViewController selection:-1];
    } else if (self.window) {
        self.window.hidden = YES;
        [self restorePreviousWindow];
    }
}
- (void)didBecomeActive:(NSNotification *)notification {
    (void)notification;
    self.inactive = NO;
    if (self.window) {
        self.previousWindow = [UIApplication sharedApplication].keyWindow;
        [self.window makeKeyAndVisible];
    } else [self showNext];
}
@end

static MCDialogRequest *MCDialogMake(MCDialogKind kind, NSString *title, NSString *message) {
    MCDialogRequest *request = [MCDialogRequest new];
    request.kind = kind;
    request.title = title;
    request.message = message;
    return request;
}
static void MCDialogEnqueue(MCDialogRequest *request) {
    if ([NSThread isMainThread]) [[MCDialogCoordinator sharedCoordinator] enqueue:request];
    else dispatch_async(dispatch_get_main_queue(), ^{ [[MCDialogCoordinator sharedCoordinator] enqueue:request]; });
}

void MCMessage(UIViewController *controller, NSString *title, NSString *message) {
    (void)controller;
    MCDialogRequest *request = MCDialogMake(MCDialogMessage, title, message);
    request.cancelTitle = @"好";
    MCDialogEnqueue(request);
}
void MCInput(NSString *title, NSString *message, NSString *value, void (^completion)(NSString *)) {
    MCDialogRequest *request = MCDialogMake(MCDialogInput, title, message);
    request.value = value;
    request.input = completion;
    request.cancelTitle = @"取消";
    request.acceptTitle = @"保存";
    MCDialogEnqueue(request);
}
void MCChoose(UIViewController *controller, NSString *title, NSArray *choices, void (^completion)(NSInteger)) {
    (void)controller;
    MCDialogRequest *request = MCDialogMake(MCDialogChoices, title, nil);
    request.choices = choices;
    request.choice = completion;
    request.cancelTitle = @"取消";
    MCDialogEnqueue(request);
}
void MCChooseMessage(NSString *title, NSString *message, NSArray *choices, void (^completion)(NSInteger)) {
    MCDialogRequest *request = MCDialogMake(MCDialogChoices, title, message);
    request.choices = choices;
    request.choice = completion;
    request.cancelTitle = @"关闭";
    MCDialogEnqueue(request);
}
void MCConfirm(NSString *title, NSString *message, NSString *button, void (^completion)(void)) {
    MCDialogRequest *request = MCDialogMake(MCDialogConfirmation, title, message);
    request.action = completion;
    request.cancelTitle = @"关闭";
    request.acceptTitle = button;
    MCDialogEnqueue(request);
}
