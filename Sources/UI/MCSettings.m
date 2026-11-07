#import "MCUI.h"
#import "MCTheme.h"
#import "MCSourcesController.h"
#import "MCMusicSources.h"
#import "MCDialogs.h"
#import "MCArtwork.h"
#import "MCPlayer.h"
#import "MCAudioCache.h"
static NSString *MCCacheSize(unsigned long long bytes) {
    return bytes >= 1024 * 1024 ? [NSString stringWithFormat:@"%.1f MB", bytes / (1024.0 * 1024)]
                                : [NSString stringWithFormat:@"%.0f KB", bytes / 1024.0];
}
@interface MCSettingsController ()
@property (nonatomic, copy) NSDictionary *cacheStats;
@end
@implementation MCSettingsController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"设置";
    self.tableView.rowHeight = 56;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(themeChanged)
                                                 name:MCThemeDidChangeNotification
                                               object:nil];
}
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}
- (void)themeChanged {
    self.tableView.backgroundColor = [MCTheme sharedTheme].background;
    [self.tableView reloadData];
}
- (void)viewWillAppear:(BOOL)a {
    [super viewWillAppear:a];
    self.tableView.backgroundColor = [MCTheme sharedTheme].background;
    [self.tableView reloadData];
    [self refreshCache];
}
- (void)refreshCache {
    __weak MCSettingsController *weakSelf = self;
    [[MCAudioCache sharedCache] snapshot:^(NSDictionary *stats) {
        weakSelf.cacheStats = stats;
        [weakSelf.tableView reloadData];
    }];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t {
    (void)t;
    return 3;
}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    (void)t;
    return s == 0 ? 4 : s == 1 ? 5 : 1;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    return section == 1 ? @"播放中的缓存会在播放结束后清理。" : nil;
}
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    (void)t;
    return @[ @"外观", @"播放与缓存", @"关于" ][s];
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)p {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                                reuseIdentifier:nil];
    MCTheme *theme = [MCTheme sharedTheme];
    c.backgroundColor = theme.surface;
    c.textLabel.textColor = theme.text;
    c.detailTextLabel.textColor = theme.muted;
    c.textLabel.font = [UIFont systemFontOfSize:15];
    if (p.section == 0) {
        c.textLabel.text = @[ @"深色模式", @"跟随封面配色", @"主题色", @"自定义 HEX" ][p.row];
        if (p.row <= 1) {
            UISwitch *s = [UISwitch new];
            s.on = p.row == 0 ? theme.dark : theme.followArtwork;
            [s addTarget:self
                          action:p.row == 0 ? @selector(darkChanged:) : @selector(followChanged:)
                forControlEvents:UIControlEventValueChanged];
            c.accessoryView = s;
        } else
            c.detailTextLabel.text = theme.hex;
    } else if (p.section == 1) {
        c.textLabel.text =
            @[ @"在线音质", @"歌曲缓存上限", @"清理歌曲缓存", @"清理封面缓存", @"音源" ][p.row];
        if (p.row == 0) {
            NSString *quality = [MCPlayer sharedPlayer].preferredQuality;
            c.detailTextLabel.text = [quality isEqual:@"lossless"] ? @"无损优先"
                                     : [quality isEqual:@"exhigh"] ? @"高品质"
                                                                   : @"标准";
        } else if (p.row == 1) {
            unsigned long long limit = [MCAudioCache sharedCache].maximumBytes;
            c.detailTextLabel.text = limit ? MCCacheSize(limit) : @"关闭";
        } else if (p.row == 2) {
            c.detailTextLabel.text = self.cacheStats[@"error"] ? @"读取失败"
                                     : self.cacheStats
                                         ? MCCacheSize([self.cacheStats[@"usedBytes"] unsignedLongLongValue])
                                         : @"读取中";
        } else if (p.row == 4) {
            c.detailTextLabel.text = [MCMusicSources sharedSources].selectedEntry[@"name"];
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else
        c.textLabel.text = [@"Muyu Cloud Music "
            stringByAppendingString:[[NSBundle mainBundle]
                                        objectForInfoDictionaryKey:@"CFBundleShortVersionString"]
                                        ?: @""];
    return c;
}
- (void)darkChanged:(UISwitch *)s {
    [MCTheme sharedTheme].dark = s.on;
    self.tableView.backgroundColor = [MCTheme sharedTheme].background;
    [self.tableView reloadData];
}
- (void)followChanged:(UISwitch *)s {
    [MCTheme sharedTheme].followArtwork = s.on;
    self.tableView.backgroundColor = [MCTheme sharedTheme].background;
    [self.tableView reloadData];
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)p {
    [t deselectRowAtIndexPath:p animated:YES];
    __weak MCSettingsController *w = self;
    if (p.section == 0 && p.row == 2) {
        MCChoose(self, @"选择主题主色", @[ @"暮雨蓝", @"蔷薇粉", @"森林绿", @"鸢尾紫" ], ^(NSInteger i) {
            [[MCTheme sharedTheme] setValidatedHex:@[ @"#365EA8", @"#A63D6B", @"#176A57", @"#6B48A3" ][i]];
            [w.tableView reloadData];
        });
    } else if (p.section == 0 && p.row == 3) {
        MCInput(@"自定义颜色", @"输入 6 位 HEX，例如 #365EA8", [MCTheme sharedTheme].hex, ^(NSString *value) {
            if (![[MCTheme sharedTheme] setValidatedHex:value])
                MCMessage(w, @"颜色无效", @"请输入六位十六进制颜色，例如 #365EA8。");
            [w.tableView reloadData];
        });
    } else if (p.section == 1 && p.row == 0) {
        MCChoose(self, @"在线音质", @[ @"标准", @"高品质", @"无损优先" ], ^(NSInteger i) {
            [MCPlayer sharedPlayer].preferredQuality = @[ @"standard", @"exhigh", @"lossless" ][i];
            [w.tableView reloadData];
        });
    } else if (p.section == 1 && p.row == 1) {
        NSArray *limits = @[ @0, @64, @128, @256, @512, @1024 ];
        MCChoose(self, @"歌曲缓存上限", @[ @"关闭", @"64 MB", @"128 MB", @"256 MB", @"512 MB", @"1 GB" ],
                 ^(NSInteger i) {
                     [MCAudioCache sharedCache].maximumBytes =
                         [limits[i] unsignedLongLongValue] * 1024 * 1024;
                     [w refreshCache];
                 });
    } else if (p.section == 1 && p.row == 2) {
        [[MCAudioCache sharedCache] clear:^(NSDictionary *stats, NSError *error) {
            w.cacheStats = stats;
            [w.tableView reloadData];
            unsigned long long pending = [stats[@"pendingBytes"] unsignedLongLongValue];
            MCMessage(w, error ? @"清理未全部完成" : @"已清理歌曲缓存",
                      error.localizedDescription
                          ?: (pending ? @"正在使用的缓存会在播放结束后移除。" : @"歌曲缓存已清理。"));
        }];
    } else if (p.section == 1 && p.row == 3) {
        [[MCArtwork sharedCache] clearDisk:^{
            MCMessage(w, @"已清理", @"封面缓存已清理。");
        }];
    } else if (p.section == 1 && p.row == 4) {
        [self.navigationController pushViewController:[MCSourcesController new] animated:YES];
    } else if (p.section == 2)
        MCMessage(self, @"暮雨音乐",
                  @"支持 iOS 7.0 及以上（ARMv7）\n本地音乐 · 网易云音乐\n\n"
                  @"开源组件：FLAC（BSD）、curl、Mbed TLS（Apache 2.0）。完整许可证随应用提供。");
}
@end
