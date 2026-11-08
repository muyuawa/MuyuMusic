#import "MCUI.h"
#import "MCTheme.h"
#import "MCDialogs.h"
#import "MCAPI.h"
#import "MCQRCode.h"
@interface MCAccountController ()
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) UILabel *instructions;
@property (nonatomic, strong) UIImageView *qr;
@property (nonatomic, strong) UIButton *login;
@property (nonatomic, strong) UIButton *logout;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, copy) NSString *key;
@property (nonatomic) NSUInteger generation;
@property (nonatomic) BOOL polling;
@end
@implementation MCAccountController
- (UIButton *)button:(NSString *)text action:(SEL)action {
    UIButton *b = MCTextButton();
    [b setTitle:text forState:UIControlStateNormal];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.scroll addSubview:b];
    return b;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"网易云账号";
    self.scroll = [UIScrollView new];
    [self.view addSubview:self.scroll];
    self.status = [UILabel new];
    self.status.backgroundColor = [UIColor clearColor];
    self.status.opaque = NO;
    self.status.numberOfLines = 0;
    self.status.textAlignment = NSTextAlignmentCenter;
    self.status.font = [UIFont systemFontOfSize:15];
    [self.scroll addSubview:self.status];
    self.qr = [UIImageView new];
    self.qr.contentMode = UIViewContentModeScaleAspectFit;
    self.qr.backgroundColor = [UIColor whiteColor];
    [self.scroll addSubview:self.qr];
    self.instructions = [UILabel new];
    self.instructions.backgroundColor = [UIColor clearColor];
    self.instructions.opaque = NO;
    self.instructions.numberOfLines = 0;
    self.instructions.font = [UIFont systemFontOfSize:13];
    self.instructions.textAlignment = NSTextAlignmentCenter;
    self.instructions.text = @"使用另一台手机的网易云音乐扫码，并确认登录。";
    [self.scroll addSubview:self.instructions];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeChanged)
                                                 name:MCThemeDidChangeNotification object:nil];
    self.login = [self button:@"生成登录二维码" action:@selector(startLogin)];
    self.logout = [self button:@"退出当前账号" action:@selector(signOut)];
}
- (void)viewWillAppear:(BOOL)a {
    [super viewWillAppear:a];
    [self themeChanged];
    [self updateProfile];
}
- (void)themeChanged {
    MCTheme *t = [MCTheme sharedTheme];
    self.view.backgroundColor = t.background;
    self.status.textColor = t.text;
    self.instructions.textColor = t.muted;

}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; [self.timer invalidate]; }
- (void)viewWillDisappear:(BOOL)a {
    [super viewWillDisappear:a];
    [self.timer invalidate];
    self.timer = nil;
    self.generation++;
    self.polling = NO;
    self.login.enabled = YES;
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.scroll.frame = self.view.bounds;
    CGFloat w = self.view.bounds.size.width;
    self.status.frame = CGRectMake(16, 8, w - 32, 60);
    self.qr.frame = CGRectMake((w - 176) / 2, 76, 176, 176);
    self.instructions.frame = CGRectMake(16, 260, w - 32, 76);
    self.login.frame = CGRectMake(24, 340, w - 48, 44);
    self.logout.frame = CGRectMake(24, 388, w - 48, 44);
    self.scroll.contentSize = CGSizeMake(w, 484);
}
- (void)updateProfile {
    MCAPI *api = [MCAPI sharedAPI];
    self.logout.enabled = api.loggedIn;
    self.status.text =
        api.loggedIn ? [NSString stringWithFormat:@"已登录：%@", api.profile[@"nickname"] ?: @"网易云用户"]
                     : @"尚未登录 · 本地音乐可随时使用";
}
- (void)startLogin {
    [self.timer invalidate];
    self.timer = nil;
    self.key = nil;
    self.polling = NO;
    self.qr.image = nil;
    self.login.enabled = NO;
    self.status.text = @"正在向网易云获取二维码…";
    NSUInteger gen = ++self.generation;
    __weak MCAccountController *w = self;
    [[MCAPI sharedAPI] createLoginKey:^(id result, NSError *error) {
        MCAccountController *s = w;
        if (!s || s.generation != gen)
            return;
        s.login.enabled = YES;
        if (error) {
            s.status.text = error.localizedDescription;
            return;
        }
        s.key = result[@"key"];
        CGImageRef cg = MCCreateLoginQRCode(result[@"url"]);
        if (!cg) {
            s.status.text = @"无法生成二维码，请重试。";
            return;
        }
        if (cg) {
            UIGraphicsBeginImageContextWithOptions(CGSizeMake(176, 176), YES, 0);
            CGContextRef ctx = UIGraphicsGetCurrentContext();
            [[UIColor whiteColor] setFill];
            UIRectFill(CGRectMake(0, 0, 176, 176));
            CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
            UIImage *source = [UIImage imageWithCGImage:cg];
            [source drawInRect:CGRectMake(8, 8, 160, 160)];
            s.qr.image = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
            CGImageRelease(cg);
        }
        s.status.text = @"请扫码，并在手机上确认登录";
        s.timer = [NSTimer scheduledTimerWithTimeInterval:2.5
                                                   target:s
                                                 selector:@selector(poll)
                                                 userInfo:nil
                                                  repeats:YES];
        [s poll];
    }];
}
- (void)poll {
    if (self.polling || !self.key.length)
        return;
    self.polling = YES;
    NSUInteger gen = self.generation;
    __weak MCAccountController *w = self;
    [[MCAPI sharedAPI] pollLoginKey:self.key
                         completion:^(id result, NSError *error) {
                             MCAccountController *s = w;
                             if (!s || gen != s.generation)
                                 return;
                             s.polling = NO;
                             if (error) {
                                 s.status.text = [NSString stringWithFormat:@"%@\n可重新生成二维码重试。",
                                                                            error.localizedDescription];
                                 [s.timer invalidate];
                                 s.timer = nil;
                                 return;
                             }
                             NSInteger status = [result[@"status"] integerValue];
                             if (status == 800) {
                                 s.status.text = @"二维码已过期，请重新生成。";
                                 [s.timer invalidate];
                                 s.timer = nil;
                             } else if (status == 802)
                                 s.status.text = @"已扫码 · 请在手机上确认";
                             else if (status == 803) {
                                 [s.timer invalidate];
                                 s.timer = nil;
                                 s.qr.image = nil;
                                 [[MCAPI sharedAPI] refreshLogin:^(id r, NSError *e) {
                                     (void)r;
                                     if (w.generation != gen)
                                         return;
                                     if (e)
                                         w.status.text = e.localizedDescription;
                                     else
                                         [w updateProfile];
                                 }];
                             }
                         }];
}
- (void)signOut {
    __weak MCAccountController *w = self;
    MCChoose(self, @"退出后将移除本机保存的网易云会话", @[ @"确认退出" ], ^(NSInteger i) {
        (void)i;
        [[MCAPI sharedAPI] logout];
        [w.timer invalidate];
        w.timer = nil;
        w.qr.image = nil;
        w.key = nil;
        w.generation++;
        w.polling = NO;
        [w updateProfile];
    });
}
@end
