#import "MCUI.h"
#import "MCTheme.h"
#import "MCFlatControls.h"
#import "MCArtwork.h"
#import "MCDialogs.h"
#import "MCAPI.h"
#import "MCLibrary.h"
#import "MCPlayer.h"
#import "MCPlaybackButton.h"
#import "MCMotion.h"
#import "MCMaterialControls.h"
#import "MCNowPlayingLayout.h"
#import "MCDiscoverLayout.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <math.h>

static NSString *MCS(id v) {
    return [v isKindOfClass:[NSString class]]
               ? v
               : ([v respondsToSelector:@selector(stringValue)] ? [v stringValue] : @"");
}
static NSString *MCTime(double t) {
    if (!isfinite(t) || t < 0)
        t = 0;
    return [NSString stringWithFormat:@"%u:%02u", (unsigned)t / 60, (unsigned)t % 60];
}

@interface MCMusicCell : MCFlatTableCell
@end
@implementation MCMusicCell
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.contentView.bounds.size.width;
    self.backgroundView.frame = self.bounds;
    self.selectedBackgroundView.frame = self.bounds;
    self.imageView.frame = CGRectMake(16, 10, 40, 40);
    self.textLabel.frame = CGRectMake(68, 9, MAX(0, width - 80), 23);
    self.detailTextLabel.frame = CGRectMake(68, 33, MAX(0, width - 80), 17);
}
@end

@interface MCListController : MCFlatTableController <UISearchBarDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, copy) NSString *kind;
@property (nonatomic, copy) NSString *playlistID;
@property (nonatomic, strong) NSArray *items;
@property (nonatomic, strong) NSArray *unfilteredItems;
@property (nonatomic) BOOL searchesLoadedTracks;
@property (nonatomic) BOOL loadedSearchFailed;
@property (nonatomic, copy) void (^loader)(MCListController *);
@property (nonatomic, copy) NSString *query;
@property (nonatomic) BOOL busy;
@property (nonatomic) BOOL pendingReload;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) UISearchBar *search;
@property (nonatomic, strong) UISegmentedControl *categories;
@property (nonatomic) NSUInteger offset;
@property (nonatomic) BOOL more;
@property (nonatomic, copy) NSString *catalogNotice;
@property (nonatomic) BOOL loginRequired;
@property (nonatomic) BOOL flatEditing;
@property (nonatomic, strong) UILabel *pullHint;
- (void)reload;
- (void)received:(NSArray *)items error:(NSError *)error;
- (void)receivedCatalog:(NSDictionary *)result error:(NSError *)error;
@end

static MCListController *MCNewList(NSString *title, NSString *kind, void (^loader)(MCListController *)) {
    MCListController *v = [[MCListController alloc] initWithStyle:UITableViewStylePlain];
    v.title = title;
    v.kind = kind;
    v.loader = loader;
    return v;
}
static void MCPushNow(UIViewController *v) {
    UINavigationController *nav = [v isKindOfClass:[UINavigationController class]]
                                      ? (UINavigationController *)v
                                      : v.navigationController;
    [nav pushViewController:[MCNowPlayingController new] animated:YES];
}
static void MCOpenCatalog(UIViewController *controller, NSDictionary *item, NSString *kind) {
    MCListController *v = MCNewList(MCS(item[@"title"]), @"tracks", nil);
    NSString *identifier = MCS(item[@"id"]);
    v.loader = ^(MCListController *target) {
        __weak MCListController *w = target;
        MCAPICompletion completion = ^(id result, NSError *error) {
            [w receivedCatalog:result error:error];
            if ([kind isEqual:@"artists"] && [result[@"albums"] count]) {
                NSArray *albums = result[@"albums"];
                UIButton *b = MCTextButton();
                [b setTitle:[NSString stringWithFormat:@"%lu 张专辑 →", (unsigned long)albums.count]
                    forState:UIControlStateNormal];
                b.frame = CGRectMake(0, 0, w.tableView.bounds.size.width, 48);
                b.autoresizingMask = UIViewAutoresizingFlexibleWidth;
                [b addTarget:w
                              action:@selector(showArtistAlbums:)
                    forControlEvents:UIControlEventTouchUpInside];
                w.tableView.tableHeaderView = b;
                objc_setAssociatedObject(b, @selector(showArtistAlbums:), albums,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        };
        if ([kind isEqual:@"albums"])
            [[MCAPI sharedAPI] album:identifier completion:completion];
        else if ([kind isEqual:@"artists"])
            [[MCAPI sharedAPI] artist:identifier completion:completion];
        else
            [[MCAPI sharedAPI] playlist:identifier completion:completion];
    };
    [controller.navigationController pushViewController:v animated:YES];
}

static BOOL MCRequireCloudAccount(UIViewController *controller) {
    if ([MCAPI sharedAPI].loggedIn) return YES;
    __weak UIViewController *weakController = controller;
    MCChooseMessage(@"请先登录网易云", @"登录后可以加入网易云歌单或收藏推荐歌单。", @[@"扫码登录"], ^(NSInteger choice) {
        (void)choice;
        [weakController.navigationController pushViewController:[MCAccountController new] animated:YES];
    });
    return NO;
}
static void MCAddTrackToLocalPlaylist(UIViewController *controller, NSDictionary *track) {
    __weak UIViewController *weakController = controller;
    [[MCLibrary sharedLibrary] playlists:^(NSArray *lists) {
        if (!weakController) return;
        NSMutableArray *titles = [NSMutableArray arrayWithObject:@"新建歌单…"];
        for (NSDictionary *d in lists) [titles addObject:MCS(d[@"title"])];
        MCChoose(weakController, @"加入本地歌单", titles, ^(NSInteger i) {
            if (i == 0)
                MCInput(@"新建歌单", @"歌单完全离线保存", @"", ^(NSString *name) {
                    if (!name.length) return;
                    [[MCLibrary sharedLibrary] createPlaylist:name completion:^(NSString *identifier) {
                        if (identifier) [[MCLibrary sharedLibrary] addTrack:track toPlaylist:identifier];
                    }];
                });
            else [[MCLibrary sharedLibrary] addTrack:track toPlaylist:lists[i - 1][@"id"]];
        });
    }];
}
static void MCAddTrackToCloudPlaylist(UIViewController *controller, NSDictionary *track) {
    if (!MCRequireCloudAccount(controller)) return;
    __weak UIViewController *weakController = controller;
    [[MCAPI sharedAPI] editablePlaylists:^(id result, NSError *error) {
        if (!weakController) return;
        NSArray *lists = result;
        if (error || !lists.count) {
            MCMessage(weakController, error ? @"读取歌单失败" : @"还没有可加入的歌单",
                error.localizedDescription ?: @"请先在网易云创建一个自己的歌单，再回来加入歌曲。");
            return;
        }
        NSMutableArray *titles = [NSMutableArray array];
        for (NSDictionary *item in lists) [titles addObject:MCS(item[@"title"])];
        MCChoose(weakController, @"加入网易云歌单", titles, ^(NSInteger choice) {
            NSDictionary *playlist = lists[choice];
            [[MCAPI sharedAPI] addTrack:MCS(track[@"id"]) toPlaylist:playlist[@"id"]
                completion:^(id value, NSError *failure) {
                    (void)value;
                    MCMessage(weakController, failure ? @"加入失败" : @"已加入歌单",
                        failure.localizedDescription ?: [NSString stringWithFormat:@"已加入「%@」。", MCS(playlist[@"title"])]);
                }];
        });
    }];
}
static void MCSubscribeCloudPlaylist(UIViewController *controller, NSDictionary *playlist) {
    if (!MCRequireCloudAccount(controller)) return;
    __weak UIViewController *weakController = controller;
    [[MCAPI sharedAPI] subscribePlaylist:MCS(playlist[@"id"]) completion:^(id result, NSError *error) {
        (void)result;
        MCMessage(weakController, error ? @"收藏失败" : @"已收藏到网易云",
            error.localizedDescription ?: [NSString stringWithFormat:@"「%@」已收藏到网易云账号。", MCS(playlist[@"title"])]);
    }];
}
void MCShowTrackActions(UIViewController *controller, NSDictionary *track, NSString *localPlaylistID) {
    if (!track) return;
    __weak UIViewController *weakController = controller;
    [[MCLibrary sharedLibrary] favoriteTracks:^(NSArray *favorites) {
        if (!weakController) return;
        BOOL fav = NO;
        for (NSDictionary *item in favorites)
            if ([item[@"id"] isEqual:track[@"id"]]) { fav = YES; break; }
        BOOL isLocal = [MCS(track[@"id"]) hasPrefix:@"local:"];
        NSMutableArray *choices = [NSMutableArray arrayWithObjects:@"加入播放队列",
            fav ? @"取消本地收藏" : @"本地收藏", @"加入本地歌单", @"歌曲信息", nil];
        if (!isLocal) [choices addObjectsFromArray:@[@"加入网易云歌单", @"在网易云设为喜欢", @"取消网易云喜欢"]];
        if (MCS(track[@"artistID"]).length) [choices addObject:@"浏览歌手"];
        if (MCS(track[@"albumID"]).length) [choices addObject:@"浏览专辑"];
        if (localPlaylistID.length) [choices addObject:@"从此歌单移除"];
        MCChoose(weakController, MCS(track[@"title"]), choices, ^(NSInteger i) {
            UIViewController *current = weakController;
            if (!current) return;
            NSString *action = choices[i];
            if (i == 0) [[MCPlayer sharedPlayer] enqueueTrack:track];
            else if (i == 1) [[MCLibrary sharedLibrary] setFavorite:!fav track:track];
            else if (i == 2) MCAddTrackToLocalPlaylist(current, track);
            else if (i == 3) {
                NSMutableString *information = [NSMutableString stringWithFormat:@"%@\n%@ · %@\n时长 %@\n%@\nID %@",
                    MCS(track[@"title"]), MCS(track[@"artist"]), MCS(track[@"album"]),
                    MCTime([track[@"duration"] doubleValue]), MCS(track[@"format"]), MCS(track[@"id"])];
                MCPlayer *player = [MCPlayer sharedPlayer];
                if ([player.currentTrack[@"id"] isEqual:track[@"id"]] && player.qualityLabel.length)
                    [information appendFormat:@"\n实际音质：%@", player.qualityLabel];
                MCMessage(current, @"歌曲信息", information);
            } else if ([action isEqual:@"加入网易云歌单"]) MCAddTrackToCloudPlaylist(current, track);
            else if ([action isEqual:@"浏览歌手"])
                MCOpenCatalog(current, @{@"id":track[@"artistID"], @"title":MCS(track[@"artist"])}, @"artists");
            else if ([action isEqual:@"浏览专辑"])
                MCOpenCatalog(current, @{@"id":track[@"albumID"], @"title":MCS(track[@"album"])}, @"albums");
            else if ([action isEqual:@"从此歌单移除"])
                [[MCLibrary sharedLibrary] removeTrack:track[@"id"] fromPlaylist:localPlaylistID];
            else if (MCRequireCloudAccount(current))
                [[MCAPI sharedAPI] likeTrack:track[@"id"] liked:[action isEqual:@"在网易云设为喜欢"]
                    completion:^(id result, NSError *error) {
                        (void)result;
                        MCMessage(weakController, error ? @"操作失败" : @"已更新",
                            error.localizedDescription ?: @"网易云喜欢的音乐已更新。");
                    }];
        });
    }];
}

@implementation MCListController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.items = @[];
    self.tableView.rowHeight = 60;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, 52, 0);
    self.tableView.scrollIndicatorInsets = UIEdgeInsetsMake(0, 0, 52, 0);
    self.pullHint = [[UILabel alloc] initWithFrame:CGRectMake(0, -48, self.tableView.bounds.size.width, 48)];
    self.pullHint.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.pullHint.backgroundColor = [UIColor clearColor];
    self.pullHint.textAlignment = NSTextAlignmentCenter;
    self.pullHint.font = [UIFont systemFontOfSize:13];
    self.pullHint.hidden = YES;
    [self.tableView addSubview:self.pullHint];
    UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(flatSwipe:)];
    swipe.direction = UISwipeGestureRecognizerDirectionLeft;
    swipe.delegate = self;
    [self.tableView addGestureRecognizer:swipe];
    if ([self.kind isEqual:@"tracks"] || [self.kind isEqual:@"local"] ||
        [self.kind isEqual:@"libraryTracks"]) {
        self.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:@"播放全部"
                                             style:UIBarButtonItemStylePlain
                                            target:self
                                            action:@selector(playAll)];
    }
    if ([self.kind isEqual:@"queue"]) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"编辑"
            style:UIBarButtonItemStylePlain target:self action:@selector(toggleFlatEditing)];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(queueChanged)
                                                     name:MCPlayerDidChangeNotification
                                                   object:nil];
    }
    if ([self.kind isEqual:@"local"] || [self.kind isEqual:@"search"] || self.searchesLoadedTracks)
        [self setupSearch];
    if ([self.kind isEqual:@"playlists"] && [self.title isEqual:@"发现"]) {
        UIButton *daily = MCTextButton();
        daily.frame = CGRectMake(0, 0, 320, 56);
        daily.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        daily.titleLabel.font = [UIFont boldSystemFontOfSize:17];
        [daily setTitle:@"每日推荐  ›" forState:UIControlStateNormal];
        [daily addTarget:self action:@selector(dailyTapped) forControlEvents:UIControlEventTouchUpInside];
        self.tableView.tableHeaderView = daily;
    }
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(theme)
                                                 name:MCThemeDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(libraryChanged)
                                                 name:MCLibraryDidChangeNotification
                                               object:nil];
    [self theme];
    [self reload];
}
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self theme];
    if ([self.kind isEqual:@"queue"])
        [self queueChanged];
    if (self.loginRequired && [MCAPI sharedAPI].loggedIn)
        [self reload];
}
- (void)dailyTapped {
    MCListController *daily = MCNewList(@"每日推荐", @"tracks", ^(MCListController *target) {
        __weak MCListController *w = target;
        [[MCAPI sharedAPI] dailyRecommendations:^(id result, NSError *error) {
            [w receivedCatalog:result error:error];
        }];
    });
    [self.navigationController pushViewController:daily animated:YES];
}
- (void)loginTapped {
    [self.navigationController pushViewController:[MCAccountController new] animated:YES];
}
- (UIStatusBarStyle)preferredStatusBarStyle {
    return [MCTheme sharedTheme].dark ? UIStatusBarStyleBlackOpaque : UIStatusBarStyleDefault;
}
- (void)theme {
    MCTheme *t = [MCTheme sharedTheme];
    self.view.backgroundColor = t.background;
    self.tableView.backgroundView = nil;
    self.tableView.backgroundColor = t.background;
    [t applyToNavigationBar:self.navigationController.navigationBar];
    [t applyToSearchBar:self.search];
    if (self.search) self.tableView.tableHeaderView.backgroundColor = t.surface;
    [t applyToSegmentedControl:self.categories];
    self.status.textColor = t.muted;
    self.pullHint.textColor = t.muted;
    if (@available(iOS 7.0, *)) [self setNeedsStatusBarAppearanceUpdate];
    [self.tableView reloadData];
}
- (void)setupSearch {
    CGFloat width = self.tableView.bounds.size.width;
    UIView *header =
        [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, [self.kind isEqual:@"search"] ? 108 : 56)];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.search = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, width, 56)];
    self.search.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.search.placeholder = self.searchesLoadedTracks ? @"搜索喜欢的歌曲、歌手、专辑"
        : [self.kind isEqual:@"local"] ? @"搜索本地标题、歌手、专辑" : @"搜索网易云音乐";
    self.search.delegate = self;
    [header addSubview:self.search];
    if ([self.kind isEqual:@"search"]) {
        self.categories = [[UISegmentedControl alloc] initWithItems:@[ @"歌曲", @"歌手", @"专辑", @"歌单" ]];
        self.categories.frame = CGRectMake(12, 56, width - 24, 44);
        self.categories.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        self.categories.selectedSegmentIndex = 0;
        [self.categories addTarget:self
                            action:@selector(categoryChanged)
                  forControlEvents:UIControlEventValueChanged];
        [header addSubview:self.categories];
    }
    self.tableView.tableHeaderView = header;
}
- (void)categoryChanged {
    self.offset = 0;
    self.more = NO;
    self.items = @[];
    [self.tableView reloadData];
    [self reload];
}
- (void)searchBarSearchButtonClicked:(UISearchBar *)bar {
    [bar resignFirstResponder];
    self.query = [bar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (self.searchesLoadedTracks) { [self applyLoadedSearch]; return; }
    self.offset = 0;
    self.more = NO;
    self.items = @[];
    [self.tableView reloadData];
    [self reload];
}
- (void)searchBar:(UISearchBar *)bar textDidChange:(NSString *)text {
    if (self.searchesLoadedTracks) {
        self.query = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(applyLoadedSearch) object:nil];
        [self performSelector:@selector(applyLoadedSearch) withObject:nil afterDelay:.15];
        return;
    }
    if ([self.kind isEqual:@"local"]) {
        self.query = text;
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(reload) object:nil];
        [self performSelector:@selector(reload) withObject:nil afterDelay:.25];
    }
}
- (NSArray *)filteredLoadedItems {
    if (!self.query.length) return self.unfilteredItems ?: @[];
    NSArray *words = [self.query componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray *found = [NSMutableArray array];
    for (NSDictionary *track in self.unfilteredItems) {
        NSString *text = [NSString stringWithFormat:@"%@ %@ %@", MCS(track[@"title"]), MCS(track[@"artist"]), MCS(track[@"album"])];
        BOOL matches = YES;
        for (NSString *word in words)
            if (word.length && [text rangeOfString:word options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location == NSNotFound) { matches = NO; break; }
        if (matches) [found addObject:track];
    }
    return found;
}
- (void)applyLoadedSearch {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(applyLoadedSearch) object:nil];
    self.items = [self filteredLoadedItems];
    [self.tableView reloadData];
    if (!self.busy && !self.loginRequired && !self.loadedSearchFailed) {
        NSString *text = self.query.length
            ? [NSString stringWithFormat:@"找到 %lu / %lu 首", (unsigned long)self.items.count, (unsigned long)self.unfilteredItems.count]
            : [NSString stringWithFormat:@"按添加时间 · 新到旧 · %lu 首", (unsigned long)self.items.count];
        [self footer:self.catalogNotice ?: text retry:self.catalogNotice.length > 0];
    }
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutFooter];
}
- (void)layoutFooter {
    UIView *footer = self.tableView.tableFooterView;
    if (!footer || !self.status) return;
    CGFloat width = self.tableView.bounds.size.width, inner = MIN(560, width - 40);
    CGFloat textHeight = MAX(32, ceil([self.status sizeThatFits:CGSizeMake(inner, CGFLOAT_MAX)].height));
    self.status.frame = CGRectMake((width - inner) / 2, self.busy ? 40 : 12, inner, textHeight);
    UIView *spinner = [footer viewWithTag:6061];
    spinner.frame = CGRectMake((width - 20) / 2, 12, 20, 20);
    UIView *retry = [footer viewWithTag:6062];
    retry.frame = CGRectMake((width - 180) / 2, CGRectGetMaxY(self.status.frame) + 8, 180, 44);
    CGFloat height = CGRectGetMaxY(self.status.frame) + (retry ? 64 : 16);
    if (footer.frame.size.width != width || footer.frame.size.height != height) {
        footer.frame = CGRectMake(0, 0, width, height);
        self.tableView.tableFooterView = footer;
    }
}
- (void)footer:(NSString *)text retry:(BOOL)retry {
    UIView *footer = [UIView new];
    self.status = [UILabel new];
    self.status.backgroundColor = [UIColor clearColor];
    self.status.textAlignment = NSTextAlignmentCenter;
    self.status.numberOfLines = 0;
    self.status.font = [[MCTheme sharedTheme] fontForRole:MCTypeCaption];
    self.status.textColor = [MCTheme sharedTheme].muted;
    self.status.text = text;
    [footer addSubview:self.status];
    if (self.busy) {
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
        spinner.tag = 6061;
        spinner.color = [MCTheme sharedTheme].primary;
        [spinner startAnimating];
        [footer addSubview:spinner];
    }
    if (retry) {
        UIButton *button = MCTextButton();
        button.tag = 6062;
        [button setTitle:self.loginRequired ? @"登录" : self.more ? @"加载更多" : @"重试" forState:UIControlStateNormal];
        [button addTarget:self action:self.loginRequired ? @selector(loginTapped) : self.more ? @selector(loadMore) : @selector(reload)
            forControlEvents:UIControlEventTouchUpInside];
        [footer addSubview:button];
    }
    self.tableView.tableFooterView = footer;
    [self layoutFooter];
}
- (void)reload {
    if (self.busy) {
        self.pendingReload = YES;
        self.pullHint.text = @"下拉刷新";
        return;
    }
    self.pendingReload = NO;
    self.loginRequired = NO;
    self.catalogNotice = nil;
    self.busy = YES;
    [self footer:@"正在读取…" retry:NO];
    if ([self.kind isEqual:@"queue"]) {
        [self received:[MCPlayer sharedPlayer].queue error:nil];
        return;
    }
    if ([self.kind isEqual:@"search"]) {
        if (!self.query.length) {
            [self received:@[] error:nil];
            NSString *kind = @[@"歌曲", @"歌手", @"专辑", @"歌单"][MAX(0, MIN(3, self.categories.selectedSegmentIndex))];
            [self footer:[@"输入关键词搜索" stringByAppendingString:kind] retry:NO];
            return;
        }
        [self runSearch:NO];
        return;
    }
    if (self.loader)
        self.loader(self);
    else
        [self received:@[] error:nil];
}
- (void)runSearch:(BOOL)append {
    NSString *q = [self.query copy];
    NSInteger selected = self.categories.selectedSegmentIndex;
    NSInteger type = selected == 1 ? 100 : selected == 2 ? 10 : selected == 3 ? 1000 : 1;
    __weak MCListController *w = self;
    [[MCAPI sharedAPI] search:q
                         type:type
                       offset:append ? self.offset : 0
                   completion:^(id result, NSError *error) {
                       MCListController *s = w;
                       if (!s)
                           return;
                       if (![q isEqual:s.query] || selected != s.categories.selectedSegmentIndex) {
                           s.busy = NO;
                           [s reload];
                           return;
                       }
                       s.more = [result[@"more"] boolValue];
                       NSArray *found = result[@"items"] ?: @[];
                       s.offset = (append ? s.offset : 0) + found.count;
                       [s received:append ? [s.items arrayByAddingObjectsFromArray:found] : found
                             error:error];
                   }];
}
- (void)loadMore {
    if (self.busy)
        return;
    self.busy = YES;
    [self footer:@"正在加载…" retry:NO];
    [self runSearch:YES];
}
- (void)received:(NSArray *)items error:(NSError *)error {
    self.busy = NO;
    if (self.searchesLoadedTracks) self.loadedSearchFailed = error != nil;
    self.loginRequired = error.code == 301 && [error.domain isEqual:@"MCAPIErrorDomain"];
    if (self.pendingReload) {
        self.pendingReload = NO;
        [self reload];
        return;
    }
    self.pullHint.text = @"下拉刷新";
    if (!error) {
        self.items = [items isKindOfClass:[NSArray class]] ? items : @[];
        if (self.searchesLoadedTracks) {
            self.unfilteredItems = self.items;
            self.items = [self filteredLoadedItems];
        }
    }
    [self.tableView reloadData];
    [self footer:error.localizedDescription ?: self.catalogNotice
                     ?: (self.more ? @"还有更多搜索结果"
                         : self.items.count
                             ? [NSString stringWithFormat:@"%lu 项", (unsigned long)self.items.count]
                             : @"这里还没有内容。")
           retry:error != nil || self.more || self.catalogNotice.length > 0];
    if (self.searchesLoadedTracks && !error) [self applyLoadedSearch];
}
- (void)receivedCatalog:(NSDictionary *)result error:(NSError *)error {
    NSArray *tracks = [result isKindOfClass:[NSDictionary class]] ? result[@"tracks"] : nil;
    NSArray *missing = [result isKindOfClass:[NSDictionary class]] ? result[@"unavailableTrackIDs"] : nil;
    self.catalogNotice =
        !error && missing.count
            ? [NSString stringWithFormat:@"已加载 %lu / %lu 首\n%lu 首歌曲网易云暂未返回详情，可重试。",
                                         (unsigned long)tracks.count,
                                         (unsigned long)[result[@"totalCount"] unsignedIntegerValue],
                                         (unsigned long)missing.count]
            : nil;
    [self received:tracks error:error];
}
- (void)libraryChanged {
    if (self.loader &&
        ([self.kind isEqual:@"local"] || [self.kind hasPrefix:@"library"] || self.playlistID.length))
        [self reload];
}
- (void)queueChanged {
    self.items = [MCPlayer sharedPlayer].queue;
    [self.tableView reloadData];
}
- (void)playAll {
    if (self.items.count) {
        [[MCPlayer sharedPlayer] playTracks:self.items index:0];
        MCPushNow(self);
    }
}
- (void)showArtistAlbums:(UIButton *)sender {
    NSArray *a = objc_getAssociatedObject(sender, @selector(showArtistAlbums:));
    MCListController *v = MCNewList(@"歌手专辑", @"albums", ^(MCListController *s) {
        [s received:a error:nil];
    });
    [self.navigationController pushViewController:v animated:YES];
}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)section {
    (void)t;
    (void)section;
    return self.items.count;
}
- (NSString *)effectiveKind {
    if (![self.kind isEqual:@"search"])
        return self.kind;
    NSInteger i = self.categories.selectedSegmentIndex;
    return i == 1 ? @"artists" : i == 2 ? @"albums" : i == 3 ? @"playlists" : @"tracks";
}
- (BOOL)isTrackKind {
    NSString *k = [self effectiveKind];
    return
        [k isEqual:@"tracks"] || [k isEqual:@"local"] || [k isEqual:@"queue"] || [k isEqual:@"libraryTracks"];
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)p {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"item"];
    if (!c)
        c = [[MCMusicCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"item"];
    NSDictionary *d = self.items[p.row];
    MCTheme *theme = [MCTheme sharedTheme];
    c.backgroundColor = [UIColor clearColor];
    UIView *card = [UIView new];
    card.backgroundColor = theme.background;
    c.backgroundView = card;
    c.textLabel.backgroundColor = c.detailTextLabel.backgroundColor = [UIColor clearColor];
    c.textLabel.font = [theme fontForRole:MCTypeBody];
    c.textLabel.textColor = theme.text;
    c.detailTextLabel.font = [theme fontForRole:MCTypeCaption];
    c.detailTextLabel.textColor = theme.muted;
    c.textLabel.text = MCS(d[@"title"]);
    BOOL track = [self isTrackKind];
    c.detailTextLabel.text =
        track ? [NSString stringWithFormat:@"%@ · %@  %@", MCS(d[@"artist"]), MCS(d[@"album"]),
                                           MCTime([d[@"duration"] doubleValue])]
              : MCS(d[@"subtitle"]);
    BOOL playlistMenu = [self.kind isEqual:@"libraryPlaylists"] || [[self effectiveKind] isEqual:@"playlists"];
    c.accessoryView = nil;
    c.accessoryType = track || playlistMenu ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator;
    if (track || playlistMenu) {
        MCPlaybackButton *button = [[MCPlaybackButton alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
        button.icon = MCPlaybackIconDetails;
        button.ink = theme.muted;
        button.accessibilityLabel = playlistMenu ? @"歌单操作" : @"歌曲操作";
        [button addTarget:self action:@selector(trackAccessoryTapped:) forControlEvents:UIControlEventTouchUpInside];
        c.accessoryView = button;
    }
    c.imageView.backgroundColor = theme.background;
    c.imageView.layer.cornerRadius = 8;
    c.imageView.clipsToBounds = YES;
    [[MCArtwork sharedCache] load:MCS(d[@"artwork"]) into:c.imageView];
    UIView *selected = [UIView new];
    selected.backgroundColor = theme.surfaceContainer;
    c.selectedBackgroundView = selected;
    c.accessibilityLabel = [NSString stringWithFormat:@"%@，%@", c.textLabel.text, c.detailTextLabel.text];
    return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)p {
    [t deselectRowAtIndexPath:p animated:MCMotionEnabled()];
    if ([self isTrackKind]) {
        if (self.flatEditing && [self.kind isEqual:@"queue"]) { [self editQueueRow:p.row]; return; }
        [[MCPlayer sharedPlayer] playTracks:self.items index:p.row];
        MCPushNow(self);
    } else if ([self.kind isEqual:@"libraryPlaylists"]) {
        NSDictionary *d = self.items[p.row];
        NSString *pid = MCS(d[@"id"]);
        MCListController *v = MCNewList(MCS(d[@"title"]), @"tracks", ^(MCListController *s) {
            __weak MCListController *w = s;
            [[MCLibrary sharedLibrary] tracksInPlaylist:pid
                                             completion:^(NSArray *a) {
                                                 [w received:a error:nil];
                                             }];
        });
        v.playlistID = pid;
        [self.navigationController pushViewController:v animated:YES];
    } else
        MCOpenCatalog(self, self.items[p.row], [self effectiveKind]);
}
- (void)trackAccessoryTapped:(UIButton *)button {
    CGPoint point = [button convertPoint:CGPointMake(CGRectGetMidX(button.bounds), CGRectGetMidY(button.bounds))
                                  toView:self.tableView];
    NSIndexPath *path = [self.tableView indexPathForRowAtPoint:point];
    if (path && [self.kind isEqual:@"libraryPlaylists"]) [self editPlaylistRow:path.row];
    else if (path && self.flatEditing && [self.kind isEqual:@"queue"]) [self editQueueRow:path.row];
    else if (path && [[self effectiveKind] isEqual:@"playlists"]) {
        NSDictionary *playlist = self.items[path.row];
        __weak MCListController *weakSelf = self;
        MCChoose(self, MCS(playlist[@"title"]), @[@"打开歌单", @"收藏到网易云"], ^(NSInteger choice) {
            if (!weakSelf) return;
            if (choice == 0) MCOpenCatalog(weakSelf, playlist, @"playlists");
            else MCSubscribeCloudPlaylist(weakSelf, playlist);
        });
    } else if (path) [self tableView:self.tableView accessoryButtonTappedForRowWithIndexPath:path];
}
- (void)tableView:(UITableView *)t accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)p {
    (void)t;
    MCShowTrackActions(self, self.items[p.row], self.playlistID);
}
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    CGFloat pull = -scrollView.contentOffset.y - scrollView.contentInset.top;
    self.pullHint.hidden = pull < 4;
    self.pullHint.text = self.busy ? @"正在刷新…" : pull > 60 ? @"松开刷新" : @"下拉刷新";
}
- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    (void)decelerate;
    if (!self.busy && -scrollView.contentOffset.y - scrollView.contentInset.top > 60) [self reload];
}
- (void)toggleFlatEditing {
    self.flatEditing = !self.flatEditing;
    self.navigationItem.rightBarButtonItem.title = self.flatEditing ? @"完成" : @"编辑";
    [self footer:self.flatEditing ? @"点歌曲或右侧按钮，调整顺序或移除歌曲。" : @"" retry:NO];
}
- (void)editQueueRow:(NSUInteger)row {
    NSArray *queue = [MCPlayer sharedPlayer].queue;
    if (row >= queue.count) return;
    NSDictionary *track = queue[row];
    __weak MCListController *weakSelf = self;
    BOOL (^stillCurrent)(void) = ^BOOL {
        NSArray *current = [MCPlayer sharedPlayer].queue;
        if (row < current.count && [current[row] isEqual:track]) return YES;
        MCMessage(weakSelf, @"队列已变化", @"请重新打开此歌曲的操作菜单。");
        return NO;
    };
    MCChoose(self, MCS(track[@"title"]), @[@"上移", @"下移", @"移动到位置…", @"移除歌曲"], ^(NSInteger index) {
        if (!stillCurrent()) return;
        MCPlayer *player = [MCPlayer sharedPlayer];
        if (index == 0 && row > 0) [player moveQueueIndex:row toIndex:row - 1];
        else if (index == 1 && row + 1 < player.queue.count) [player moveQueueIndex:row toIndex:row + 1];
        else if (index == 3) [player removeQueueIndex:row];
        else if (index == 2) MCInput(@"移动到位置", @"输入目标序号，从 1 开始。",
            [NSString stringWithFormat:@"%lu", (unsigned long)row + 1], ^(NSString *value) {
                NSScanner *scanner = [NSScanner scannerWithString:value];
                NSInteger target = 0;
                if (![scanner scanInteger:&target] || !scanner.isAtEnd || target < 1 ||
                    (NSUInteger)target > [MCPlayer sharedPlayer].queue.count) {
                    MCMessage(weakSelf, @"位置无效", @"请输入队列范围内的整数序号。"); return;
                }
                if (stillCurrent()) [[MCPlayer sharedPlayer] moveQueueIndex:row toIndex:(NSUInteger)target - 1];
            });
    });
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return [gesture isKindOfClass:[UISwipeGestureRecognizer class]] ||
           [other isKindOfClass:[UISwipeGestureRecognizer class]];
}
- (void)editPlaylistRow:(NSUInteger)row {
    if (row >= self.items.count) return;
    NSDictionary *item = self.items[row];
    NSString *identifier = MCS(item[@"id"]);
    __weak MCListController *weakSelf = self;
    MCChoose(self, MCS(item[@"title"]), @[@"打开歌单", @"删除歌单"], ^(NSInteger choice) {
        MCListController *controller = weakSelf;
        if (choice == 1)
            MCConfirm(@"删除歌单", MCS(item[@"title"]), @"删除", ^{ [[MCLibrary sharedLibrary] deletePlaylist:identifier]; });
        else if (controller && row < controller.items.count && [controller.items[row] isEqual:item])
            [controller tableView:controller.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];
    });
}
- (void)flatSwipe:(UISwipeGestureRecognizer *)gesture {
    NSIndexPath *path = [self.tableView indexPathForRowAtPoint:[gesture locationInView:self.tableView]];
    if (!path || (NSUInteger)path.row >= self.items.count) return;
    if ([self.kind isEqual:@"queue"]) { [self editQueueRow:path.row]; return; }
    NSDictionary *item = self.items[path.row];
    NSString *identifier = MCS(item[@"id"]), *playlist = self.playlistID;
    if ([self.kind isEqual:@"libraryPlaylists"])
        MCConfirm(@"删除歌单", MCS(item[@"title"]), @"删除", ^{ [[MCLibrary sharedLibrary] deletePlaylist:identifier]; });
    else if (playlist.length)
        MCConfirm(@"从歌单移除", MCS(item[@"title"]), @"移除", ^{ [[MCLibrary sharedLibrary] removeTrack:identifier fromPlaylist:playlist]; });
}
- (BOOL)tableView:(UITableView *)t canEditRowAtIndexPath:(NSIndexPath *)p {
    (void)t;
    (void)p;
    return NO; // Editing actions use flat menus rather than native iOS 6 chrome.
}

@end

static MCListController *MCLibraryList(NSInteger row) {
    MCListController *v = MCNewList(
        @[ @"本地歌曲", @"本地收藏", @"最近播放", @"本地歌单", @"我的网易云歌单" ][row],
        row == 0   ? @"local"
        : row == 3 ? @"libraryPlaylists"
        : row == 4 ? @"playlists"
                   : @"libraryTracks",
        ^(MCListController *s) {
            __weak MCListController *w = s;
            void (^done)(NSArray *) = ^(NSArray *a) {
                [w received:a error:nil];
            };
            MCLibrary *lib = [MCLibrary sharedLibrary];
            if (row == 0)
                [lib tracksMatching:s.query ?: @"" completion:done];
            else if (row == 1)
                [lib favoriteTracks:done];
            else if (row == 2)
                [lib recentTracks:done];
            else if (row == 3)
                [lib playlists:done];
            else
                [[MCAPI sharedAPI] userPlaylists:^(id r, NSError *e) {
                    [w received:r error:e];
                }];
        });
    return v;
}

@interface MCLibraryController : MCFlatTableController
@property (nonatomic, strong) UILabel *instructions;
@end
@implementation MCLibraryController
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat width = self.tableView.bounds.size.width;
    CGSize fit = [self.instructions sizeThatFits:CGSizeMake(MAX(1, width - 32), CGFLOAT_MAX)];
    self.instructions.frame = CGRectMake(16, 12, MAX(1, width - 32), ceil(fit.height));
    UIView *footer = self.tableView.tableFooterView;
    CGSize size = CGSizeMake(width, ceil(fit.height) + 24);
    if (!CGSizeEqualToSize(footer.bounds.size, size)) {
        footer.frame = CGRectMake(0, 0, size.width, size.height);
        self.tableView.tableFooterView = footer;
    }
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"音乐库";
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeChanged)
                                                 name:MCThemeDidChangeNotification object:nil];
    self.tableView.rowHeight = 56;
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, 52, 0);
    self.tableView.scrollIndicatorInsets = UIEdgeInsetsMake(0, 0, 52, 0);
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"扫描"
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(scan)];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"设置"
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:self
                                                                            action:@selector(settings)];
    UIView *footer = [[UIView alloc] initWithFrame:CGRectZero];
    self.instructions = [UILabel new];
    self.instructions.backgroundColor = [UIColor clearColor];
    self.instructions.opaque = NO;
    self.instructions.numberOfLines = 0;
    self.instructions.lineBreakMode = NSLineBreakByWordWrapping;
    self.instructions.font = [UIFont systemFontOfSize:13];
    self.instructions.text = @"用 iTunes 文件共享导入音乐和同名 .lrc 歌词，返回应用后自动扫描。";
    [footer addSubview:self.instructions];
    self.tableView.tableFooterView = footer;
}
- (void)viewWillAppear:(BOOL)a {
    [super viewWillAppear:a];
    [self themeChanged];
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)themeChanged {
    self.tableView.backgroundView = nil;
    self.tableView.backgroundColor = [MCTheme sharedTheme].background;
    self.instructions.textColor = [MCTheme sharedTheme].muted;
    [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    (void)t;
    (void)s;
    return 6;
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)p {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"menu"];
    if (!c)
        c = [[MCFlatTableCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"menu"];
    c.textLabel.text = @[
        @"本地歌曲", @"本地收藏", @"最近播放", @"本地歌单", @"我的网易云歌单",
        @"账号与扫码登录"
    ][p.row];
    c.textLabel.backgroundColor = c.detailTextLabel.backgroundColor = [UIColor clearColor];
    c.textLabel.textColor = [MCTheme sharedTheme].text;
    c.backgroundColor = [MCTheme sharedTheme].surface;
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}
- (void)settings {
    [self.navigationController pushViewController:[MCSettingsController new] animated:YES];
}
- (void)scan {
    self.navigationItem.rightBarButtonItem.enabled = NO;
    __weak MCLibraryController *w = self;
    [[MCLibrary sharedLibrary] scan:^(NSUInteger count, NSArray *errors) {
        w.navigationItem.rightBarButtonItem.enabled = YES;
        NSString *message = [NSString stringWithFormat:@"本次扫描导入或更新 %lu 首。", (unsigned long)count];
        if (errors.count)
            message = [message
                stringByAppendingFormat:@"\n%lu 个文件未导入：\n%@", (unsigned long)errors.count,
                                        [[[errors subarrayWithRange:NSMakeRange(
                                                                        0, MIN((NSUInteger)3, errors.count))]
                                            valueForKey:@"localizedDescription"]
                                            componentsJoinedByString:@"\n"]];
        MCMessage(w, @"扫描完成", message);
    }];
}
- (void)newPlaylist {
    __weak MCLibraryController *w = self;
    MCInput(@"新建歌单", @"输入歌单名称", @"", ^(NSString *name) {
        if (!name.length)
            return;
        [[MCLibrary sharedLibrary] createPlaylist:name
                                       completion:^(NSString *identifier) {
                                           if (identifier.length)
                                               MCMessage(w, @"已创建", @"在歌曲右侧详情按钮中添加歌曲。");
                                       }];
    });
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)p {
    [t deselectRowAtIndexPath:p animated:MCMotionEnabled()];
    if (p.row == 5) {
        [self.navigationController pushViewController:[MCAccountController new] animated:YES];
        return;
    }
    NSInteger row = p.row;
    MCListController *v = MCLibraryList(row);
    if (row == 3)
        v.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:@"新建" style:UIBarButtonItemStylePlain
                                         target:self action:@selector(newPlaylist)];
    [self.navigationController pushViewController:v animated:YES];
}
@end

@interface MCDiscoverController : MCListController
@property (nonatomic, strong) UIView *discoverHeader;
@property (nonatomic, strong) MCMaterialCard *dailyCard;
@property (nonatomic, strong) UIButton *dailyOpen;
@property (nonatomic, strong) UIImageView *dailyCover;
@property (nonatomic, strong) UILabel *dailyTitle, *dailySubtitle, *songsHeading, *songsHint;
@property (nonatomic, strong) MCMaterialButton *dailyPlay;
@property (nonatomic, strong) NSArray *shortcuts, *recommendedPlaylists, *recentItems, *dailyTracks;
@property (nonatomic, strong) UISegmentedControl *shelfMode;
@property (nonatomic, strong) UIScrollView *shelf;
@property (nonatomic, strong) UILabel *shelfEmpty;
@property (nonatomic, strong) UIButton *shelfMore;
@property (nonatomic, copy) NSString *accountIdentity;
@property (nonatomic) NSUInteger discoverGeneration;
@property (nonatomic) CGFloat shelfTileWidth;
@property (nonatomic) BOOL hasDaily, hasTasteRecommendations, recommendationsSettled;
@end
@implementation MCDiscoverController
- (id)initWithStyle:(UITableViewStyle)style {
    if ((self = [super initWithStyle:style])) { self.title = @"发现"; self.kind = @"tracks"; }
    return self;
}
- (UILabel *)heading:(NSString *)text role:(MCTypeRole)role {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [[MCTheme sharedTheme] fontForRole:role];
    label.backgroundColor = [UIColor clearColor];
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.discoverHeader addSubview:label];
    return label;
}
- (UIBarButtonItem *)navigationIcon:(MCPlaybackIcon)icon label:(NSString *)label action:(SEL)action {
    MCPlaybackButton *button = [[MCPlaybackButton alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
    button.icon = icon;
    button.ink = [MCTheme sharedTheme].text;
    button.accessibilityLabel = label;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return [[UIBarButtonItem alloc] initWithCustomView:button];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.leftBarButtonItem = [self navigationIcon:MCPlaybackIconAccount label:@"账号" action:@selector(loginTapped)];
    self.navigationItem.rightBarButtonItem = [self navigationIcon:MCPlaybackIconSettings label:@"设置" action:@selector(discoverSettings)];
    self.discoverHeader = [UIView new];
    self.dailyCard = [MCMaterialCard new];
    self.dailyCard.emphasized = YES;
    [self.discoverHeader addSubview:self.dailyCard];
    // The card opens the catalog; the separate play button keeps its action.
    self.dailyOpen = [UIButton buttonWithType:UIButtonTypeCustom];
    self.dailyOpen.accessibilityLabel = @"打开每日推荐";
    self.dailyOpen.accessibilityHint = @"查看每日推荐歌曲列表";
    [self.dailyOpen addTarget:self action:@selector(dailyTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.dailyCard addSubview:self.dailyOpen];
    self.dailyCover = [UIImageView new];
    self.dailyCover.contentMode = UIViewContentModeScaleAspectFill;
    self.dailyCover.clipsToBounds = YES;
    self.dailyCover.layer.cornerRadius = [MCTheme sharedTheme].smallRadius;
    [self.dailyCard addSubview:self.dailyCover];
    self.dailyTitle = [self heading:@"每日推荐" role:MCTypeTitle];
    self.dailySubtitle = [self heading:@"为今天选一首好歌" role:MCTypeCaption];
    self.dailySubtitle.numberOfLines = 2;
    [self.dailyCard addSubview:self.dailyTitle];
    [self.dailyCard addSubview:self.dailySubtitle];
    self.dailyPlay = [[MCMaterialButton alloc] initWithTitle:@"播放" icon:MCPlaybackIconPlay filled:YES];
    [self.dailyPlay addTarget:self action:@selector(playDaily) forControlEvents:UIControlEventTouchUpInside];
    [self.dailyCard addSubview:self.dailyPlay];
    NSArray *titles = @[@"最近播放", @"喜欢的音乐", @"本地音乐", @"网易云歌单"];
    NSArray *icons = @[@(MCPlaybackIconRecent), @(MCPlaybackIconFavorite), @(MCPlaybackIconLocal), @(MCPlaybackIconPlaylist)];
    NSMutableArray *buttons = [NSMutableArray array];
    for (NSUInteger i = 0; i < titles.count; i++) {
        MCMaterialButton *button = [[MCMaterialButton alloc] initWithTitle:titles[i] icon:[icons[i] unsignedIntegerValue] filled:NO];
        button.vertical = YES;
        button.tag = i;
        if (i == 1) button.accessibilityLabel = @"网易云喜欢的音乐";
        [button addTarget:self action:@selector(openShortcut:) forControlEvents:UIControlEventTouchUpInside];
        [self.discoverHeader addSubview:button];
        [buttons addObject:button];
    }
    self.shortcuts = buttons;
    self.shelfMode = [[MCMaterialSegmentedControl alloc] initWithItems:@[@"推荐歌单", @"最近播放"]];
    self.shelfMode.selectedSegmentIndex = 0;
    [self.shelfMode addTarget:self action:@selector(shelfChanged) forControlEvents:UIControlEventValueChanged];
    [self.discoverHeader addSubview:self.shelfMode];
    self.shelfMore = MCTextButton();
    [self.shelfMore setTitle:@"查看全部" forState:UIControlStateNormal];
    [self.shelfMore addTarget:self action:@selector(openShelf) forControlEvents:UIControlEventTouchUpInside];
    [self.discoverHeader addSubview:self.shelfMore];
    self.shelf = [UIScrollView new];
    self.shelf.showsHorizontalScrollIndicator = NO;
    self.shelf.directionalLockEnabled = YES;
    [self.discoverHeader addSubview:self.shelf];
    self.shelfEmpty = [self heading:@"正在读取歌单…" role:MCTypeCaption];
    self.shelfEmpty.numberOfLines = 2;
    [self.shelf addSubview:self.shelfEmpty];
    self.songsHeading = [self heading:@"根据你喜欢的歌曲推荐" role:MCTypeSection];
    self.songsHint = [self heading:@"" role:MCTypeCaption];
    self.tableView.tableHeaderView = self.discoverHeader;
    [self updateDailyCard];
    [self theme];
}
- (NSString *)currentAccount {
    MCAPI *api = [MCAPI sharedAPI];
    return [NSString stringWithFormat:@"%d:%@", api.loggedIn, MCS(api.profile[@"userId"])];
}
- (void)viewWillAppear:(BOOL)animated {
    BOOL changed = ![self.accountIdentity isEqual:[self currentAccount]];
    BOOL retryLogin = self.loginRequired && [MCAPI sharedAPI].loggedIn;
    self.loginRequired = NO;
    [super viewWillAppear:animated];
    if (changed || retryLogin) { self.busy = NO; [self reload]; }
}
- (void)theme {
    [super theme];
    MCTheme *t = [MCTheme sharedTheme];
    self.dailyTitle.textColor = self.dailySubtitle.textColor = t.onPrimaryContainer;
    self.songsHeading.textColor = t.text;
    self.songsHint.textColor = t.muted;
    self.shelfEmpty.textColor = t.muted;
    [t applyToSegmentedControl:self.shelfMode];
    for (UIBarButtonItem *item in @[self.navigationItem.leftBarButtonItem ?: [UIBarButtonItem new],
                                   self.navigationItem.rightBarButtonItem ?: [UIBarButtonItem new]])
        if ([item.customView isKindOfClass:[MCPlaybackButton class]])
            ((MCPlaybackButton *)item.customView).ink = t.text;
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat width = self.tableView.bounds.size.width;
    MCDiscoverLayout l = MCDiscoverMakeLayout(width);
    self.dailyCard.frame = CGRectMake(l.hero.x, l.hero.y, l.hero.width, l.hero.height);
    self.dailyOpen.frame = self.dailyCard.bounds;
    CGFloat cover = l.hero.height - 24, textLeft = cover + 24;
    self.dailyCover.frame = CGRectMake(12, 12, cover, cover);
    self.dailyTitle.frame = CGRectMake(textLeft, 10, l.hero.width - textLeft - 12, 28);
    self.dailySubtitle.frame = CGRectMake(textLeft, 37, l.hero.width - textLeft - 12, 30);
    self.dailyPlay.frame = CGRectMake(textLeft, l.hero.height - 52, 100, 44);
    for (NSUInteger i=0;i<self.shortcuts.count;i++) {
        MCPlayerRect r = l.shortcuts[i];
        [self.shortcuts[i] setFrame:CGRectMake(r.x, r.y, r.width, r.height)];
    }
    self.shelfMode.frame = CGRectMake(l.shelfMode.x, l.shelfMode.y, l.shelfMode.width, l.shelfMode.height);
    self.shelfMore.frame = CGRectMake(l.shelfMore.x, l.shelfMore.y, l.shelfMore.width, l.shelfMore.height);
    self.shelf.frame = CGRectMake(l.shelf.x, l.shelf.y, l.shelf.width, l.shelf.height);
    self.shelfEmpty.frame = CGRectMake(0, 12, l.shelf.width, 64);
    if (self.shelfTileWidth != l.tileWidth) { self.shelfTileWidth = l.tileWidth; [self rebuildShelf]; }
    self.songsHeading.frame = CGRectMake(l.heading.x, l.heading.y, l.heading.width, 24);
    self.songsHint.frame = CGRectMake(l.heading.x, l.heading.y + 24, l.heading.width, 16);
    if (self.discoverHeader.frame.size.width != width || self.discoverHeader.frame.size.height != l.height) {
        self.discoverHeader.frame = CGRectMake(0, 0, width, l.height);
        self.tableView.tableHeaderView = self.discoverHeader;
    }
}
- (NSArray *)shelfItems {
    return self.shelfMode.selectedSegmentIndex == 1 ? self.recentItems : self.recommendedPlaylists;
}
- (void)rebuildShelf {
    for (UIView *view in [self.shelf.subviews copy])
        if ([view isKindOfClass:[MCCatalogTile class]]) [view removeFromSuperview];
    NSArray *items = [self shelfItems];
    CGFloat side = self.shelfTileWidth ?: 96;
    for (NSUInteger i=0;i<MIN((NSUInteger)8, items.count);i++) {
        MCCatalogTile *tile = [[MCCatalogTile alloc] initWithFrame:CGRectMake(i * (side + 12), 0, side, side + 38)];
        tile.tag = i;
        [tile showItem:items[i]];
        [tile addTarget:self action:@selector(openTile:) forControlEvents:UIControlEventTouchUpInside];
        [tile addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(tileActions:)]];
        [self.shelf addSubview:tile];
    }
    self.shelfEmpty.hidden = items.count > 0;
    self.shelf.contentSize = CGSizeMake(MAX(0, MIN((NSUInteger)8, items.count) * (side + 12) - 12), side + 38);
}
- (void)shelfChanged {
    self.shelf.contentOffset = CGPointZero;
    self.shelfEmpty.text = self.shelfMode.selectedSegmentIndex == 1 ? @"播放过的歌曲会出现在这里。" : @"暂无推荐歌单，可下拉刷新。";
    [self rebuildShelf];
}
- (void)updateDailyCard {
    MCAPI *api = [MCAPI sharedAPI];
    self.dailySubtitle.text = api.loggedIn ? (self.hasDaily ? @"为你挑选，随时开听" : @"发现今天的好音乐") : @"登录网易云，获取每日推荐";
    [self.dailyPlay setTitle:api.loggedIn ? @"播放" : @"登录" forState:UIControlStateNormal];
    self.dailyPlay.accessibilityLabel = api.loggedIn ? @"播放每日推荐" : @"登录获取每日推荐";
    self.songsHeading.text = self.hasTasteRecommendations ? @"根据你喜欢的歌曲推荐" : @"最近播放";
    self.songsHint.text = !api.loggedIn ? @"登录后获取个性化推荐"
        : self.hasTasteRecommendations ? @"网易云 · 为你推荐" : @"推荐暂不可用，先听最近播放";
    NSDictionary *item = self.hasDaily ? self.dailyTracks.firstObject : self.recommendedPlaylists.firstObject;
    [[MCArtwork sharedCache] load:MCS(item[@"artwork"]) into:self.dailyCover];
}
- (void)reload {
    if (self.busy) return;
    self.busy = YES;
    NSString *identity = [self currentAccount];
    if (![self.accountIdentity isEqual:identity]) { self.items = @[]; self.hasDaily = NO; self.hasTasteRecommendations = NO; self.dailyTracks = @[]; }
    self.accountIdentity = identity;
    self.recommendationsSettled = NO;
    NSUInteger generation = ++self.discoverGeneration;
    BOOL loggedIn = [MCAPI sharedAPI].loggedIn;
    __weak MCDiscoverController *weakSelf = self;
    [self footer:@"正在读取推荐…" retry:NO];
    [[MCLibrary sharedLibrary] recentTracks:^(NSArray *tracks) {
        MCDiscoverController *s = weakSelf;
        if (!s || generation != s.discoverGeneration) return;
        s.recentItems = tracks ?: @[];
        if (!loggedIn || (s.recommendationsSettled && !s.hasTasteRecommendations)) {
            s.items = s.recentItems;
            if (!loggedIn) {
                s.busy = NO;
                s.loginRequired = YES;
                [s footer:@"登录后获取个性化推荐，本地音乐可随时播放。" retry:YES];
            }
            [s.tableView reloadData];
            [s updateDailyCard];
        }
        [s rebuildShelf];
    }];
    [[MCAPI sharedAPI] discover:^(id result, NSError *error) {
        MCDiscoverController *s = weakSelf;
        if (!s || generation != s.discoverGeneration) return;
        if (!error) s.recommendedPlaylists = [result isKindOfClass:[NSArray class]] ? result : @[];
        if (s.shelfMode.selectedSegmentIndex == 0)
            s.shelfEmpty.text = error ? @"歌单暂时无法加载，下拉重试。" : @"暂无推荐歌单。";
        [s rebuildShelf];
        [s updateDailyCard];
    }];
    if (loggedIn) {
        [[MCAPI sharedAPI] dailyRecommendations:^(id result, NSError *error) {
            MCDiscoverController *s = weakSelf;
            if (!s || generation != s.discoverGeneration) return;
            s.dailyTracks = !error && [result[@"tracks"] isKindOfClass:[NSArray class]] ? result[@"tracks"] : @[];
            s.hasDaily = s.dailyTracks.count > 0;
            [s updateDailyCard];
        }];
        [[MCAPI sharedAPI] tasteRecommendations:^(id result, NSError *error) {
            MCDiscoverController *s = weakSelf;
            if (!s || generation != s.discoverGeneration) return;
            s.recommendationsSettled = YES;
            s.hasTasteRecommendations = !error && [result[@"tracks"] count] > 0;
            if (s.hasTasteRecommendations) [s receivedCatalog:result error:nil];
            else {
                s.items = s.recentItems ?: @[];
                [s received:s.items error:error];
                if (!error) [s footer:@"网易云暂无个性化推荐，先听最近播放。" retry:YES];
            }
            [s updateDailyCard];
        }];
    }
}
- (void)libraryChanged {
    __weak MCDiscoverController *weakSelf = self;
    [[MCLibrary sharedLibrary] recentTracks:^(NSArray *tracks) {
        MCDiscoverController *s = weakSelf;
        if (!s) return;
        s.recentItems = tracks ?: @[];
        if (![MCAPI sharedAPI].loggedIn || (s.recommendationsSettled && !s.hasTasteRecommendations)) {
            s.items = s.recentItems;
            [s.tableView reloadData];
        }
        if (s.shelfMode.selectedSegmentIndex == 1) [s rebuildShelf];
    }];
}
- (void)discoverSettings { [self.navigationController pushViewController:[MCSettingsController new] animated:YES]; }
- (void)playDaily {
    if (![MCAPI sharedAPI].loggedIn) { [self loginTapped]; return; }
    if (self.hasDaily && self.dailyTracks.count) {
        [[MCPlayer sharedPlayer] playTracks:self.dailyTracks index:0];
        MCPushNow(self);
    } else [self dailyTapped];
}
- (void)openShortcut:(UIButton *)sender {
    MCListController *list;
    if (sender.tag == 1) {
        list = MCNewList(@"网易云喜欢的音乐", @"tracks", ^(MCListController *target) {
            __weak MCListController *w = target;
            [[MCAPI sharedAPI] likedTracks:^(id result, NSError *error) {
                [w receivedCatalog:result error:error];
            }];
        });
        list.searchesLoadedTracks = YES;
    } else {
        NSInteger row = sender.tag == 0 ? 2 : sender.tag == 2 ? 0 : 4;
        list = MCLibraryList(row);
        if (sender.tag == 3) list.title = @"网易云歌单";
    }
    [self.navigationController pushViewController:list animated:YES];
}
- (void)openShelf {
    MCListController *list;
    if (self.shelfMode.selectedSegmentIndex == 1) list = MCLibraryList(2);
    else list = MCNewList(@"推荐歌单", @"playlists", ^(MCListController *target) {
        __weak MCListController *w = target;
        [[MCAPI sharedAPI] discover:^(id result, NSError *error) { [w received:result error:error]; }];
    });
    [self.navigationController pushViewController:list animated:YES];
}
- (void)openTile:(MCCatalogTile *)tile {
    NSArray *items = [self shelfItems];
    if ((NSUInteger)tile.tag >= items.count) return;
    if (self.shelfMode.selectedSegmentIndex == 1) {
        [[MCPlayer sharedPlayer] playTracks:items index:tile.tag];
        MCPushNow(self);
    } else MCOpenCatalog(self, items[tile.tag], @"playlists");
}
- (void)tileActions:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    NSArray *items = [self shelfItems];
    NSUInteger index = gesture.view.tag;
    if (index >= items.count) return;
    if (self.shelfMode.selectedSegmentIndex == 1) MCShowTrackActions(self, items[index], nil);
    else {
        NSDictionary *playlist = items[index];
        __weak MCDiscoverController *weakSelf = self;
        MCChoose(self, MCS(playlist[@"title"]), @[@"打开歌单", @"收藏到网易云"], ^(NSInteger choice) {
            if (!weakSelf) return;
            if (choice == 0) MCOpenCatalog(weakSelf, playlist, @"playlists");
            else MCSubscribeCloudPlaylist(weakSelf, playlist);
        });
    }
}
@end

@interface MCMiniPreview : UIView
@property (nonatomic, strong) UIImageView *cover;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *artistLabel;
- (void)showTrack:(NSDictionary *)track;
- (void)applyTheme;
@end
@implementation MCMiniPreview
- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.cover = [UIImageView new];
        self.cover.contentMode = UIViewContentModeScaleAspectFill;
        self.cover.layer.cornerRadius = 8;
        self.cover.clipsToBounds = YES;
        self.cover.opaque = NO;
        self.nameLabel = [UILabel new];
        self.artistLabel = [UILabel new];
        self.nameLabel.font = [UIFont systemFontOfSize:14];
        self.artistLabel.font = [UIFont systemFontOfSize:12];
        for (UILabel *label in @[self.nameLabel, self.artistLabel]) {
            label.backgroundColor = [UIColor clearColor];
            label.opaque = NO;
            label.lineBreakMode = NSLineBreakByTruncatingTail;
            [self addSubview:label];
        }
        [self addSubview:self.cover];
        [self applyTheme];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.cover.frame = CGRectMake(12, 8, 32, 32);
    self.nameLabel.frame = CGRectMake(54, 6, MAX(0, self.bounds.size.width - 62), 20);
    self.artistLabel.frame = CGRectMake(54, 27, MAX(0, self.bounds.size.width - 62), 16);
}
- (void)applyTheme {
    MCTheme *theme = [MCTheme sharedTheme];
    self.backgroundColor = theme.surface;
    self.cover.backgroundColor = theme.background;
    self.nameLabel.textColor = theme.text;
    self.artistLabel.textColor = theme.muted;
}
- (void)showTrack:(NSDictionary *)track {
    self.nameLabel.text = MCS(track[@"title"]);
    self.artistLabel.text = MCS(track[@"artist"]);
    [[MCArtwork sharedCache] load:MCS(track[@"artwork"]) into:self.cover];
}
@end

@interface MCRootController () <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIView *miniTray;
@property (nonatomic, strong) UIView *miniCarousel;
@property (nonatomic, strong) MCMiniPreview *miniNextPreview;
@property (nonatomic, strong) MCMiniPreview *miniPreviousPreview;
@property (nonatomic, strong) UIPanGestureRecognizer *miniPan;
@property (nonatomic, strong) MCQueueTransition *miniNextPlan;
@property (nonatomic, strong) MCQueueTransition *miniPreviousPlan;
@property (nonatomic) BOOL miniPanning, miniSettling, miniNoFadeUpdate;
@property (nonatomic) NSUInteger miniPanGeneration;
@property (nonatomic, strong) UIButton *mini;
@property (nonatomic, strong) MCPlaybackButton *toggleButton;
@property (nonatomic, strong) MCPlaybackButton *miniPrevious;
@property (nonatomic, strong) MCPlaybackButton *miniNext;
@property (nonatomic, strong) UIImageView *miniCover;
@property (nonatomic, strong) UILabel *miniTitle;
@property (nonatomic, strong) UILabel *miniArtist;
@property (nonatomic, strong) UIView *miniBoundary;
@property (nonatomic, strong) UIView *miniProgress;
@property (nonatomic, copy) NSString *miniArtwork;
@property (nonatomic, copy) NSString *miniTrackID;
@property (nonatomic) NSInteger miniSlideDirection;
@property (nonatomic) BOOL miniArtworkReady;
@property (nonatomic) BOOL lastFollowArtwork;
@property (nonatomic, copy) NSString *lastLibraryError;
@end
@interface MCNavigationController : UINavigationController <UINavigationControllerDelegate>
@property (nonatomic, strong) UIViewController *shownController;
@property (nonatomic, strong) UIView *outgoingLeftView;
@end
@implementation MCNavigationController
- (void)pushViewController:(UIViewController *)controller animated:(BOOL)animated {
    [super pushViewController:controller animated:animated && MCMotionEnabled()];
}
- (UIViewController *)popViewControllerAnimated:(BOOL)animated {
    return [super popViewControllerAnimated:animated && MCMotionEnabled()];
}
- (NSArray *)popToViewController:(UIViewController *)controller animated:(BOOL)animated {
    return [super popToViewController:controller animated:animated && MCMotionEnabled()];
}
- (NSArray *)popToRootViewControllerAnimated:(BOOL)animated {
    return [super popToRootViewControllerAnimated:animated && MCMotionEnabled()];
}
- (void)setViewControllers:(NSArray *)controllers animated:(BOOL)animated {
    [super setViewControllers:controllers animated:animated && MCMotionEnabled()];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.delegate = self;
    self.shownController = self.topViewController;
}
- (void)navigationController:(UINavigationController *)navigationController
    willShowViewController:(UIViewController *)viewController animated:(BOOL)animated {
    // Legacy UIKit cross-fades custom back captions at the same coordinates.
    // Hide the outgoing caption for the transition; restore its item afterwards.
    self.outgoingLeftView.hidden = NO;
    self.outgoingLeftView = nil;
    if (animated && self.shownController != viewController) {
        self.outgoingLeftView = self.shownController.navigationItem.leftBarButtonItem.customView;
        self.outgoingLeftView.hidden = YES;
        navigationController.navigationBar.userInteractionEnabled = NO;
    }
    NSUInteger index = [navigationController.viewControllers indexOfObjectIdenticalTo:viewController];
    if (index != NSNotFound && index > 0 &&
        (!viewController.navigationItem.leftBarButtonItem ||
         [viewController.navigationItem.leftBarButtonItem.customView isKindOfClass:[MCFlatBackButton class]])) {
        UIViewController *previous = navigationController.viewControllers[index - 1];
        MCFlatBackButton *back = [[MCFlatBackButton alloc] initWithTitle:previous.title ?: @"返回"];
        [back addTarget:self action:@selector(flatBack) forControlEvents:UIControlEventTouchUpInside];
        viewController.navigationItem.hidesBackButton = YES;
        viewController.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:back];
    }
    [[MCTheme sharedTheme] applyToNavigationBar:navigationController.navigationBar];
    [navigationController.tabBarController.view setNeedsLayout];
}
- (void)navigationController:(UINavigationController *)navigationController
    didShowViewController:(UIViewController *)viewController animated:(BOOL)animated {
    (void)animated;
    self.outgoingLeftView.hidden = NO;
    self.outgoingLeftView = nil;
    self.shownController = viewController;
    navigationController.navigationBar.userInteractionEnabled = YES;
    [navigationController.tabBarController.view setNeedsLayout];
}
- (void)flatBack { [self popViewControllerAnimated:YES]; }
- (UIStatusBarStyle)preferredStatusBarStyle {
    return [MCTheme sharedTheme].dark ? UIStatusBarStyleBlackOpaque : UIStatusBarStyleDefault;
}
@end
@implementation MCRootController
- (void)viewDidLoad {
    [super viewDidLoad];
    MCDiscoverController *discover = [[MCDiscoverController alloc] initWithStyle:UITableViewStylePlain];
    MCListController *search = MCNewList(@"搜索", @"search", nil);
    MCLibraryController *library = [[MCLibraryController alloc] initWithStyle:UITableViewStyleGrouped];
    NSArray *roots = @[ discover, search, library ];
    NSMutableArray *navs = [NSMutableArray array];
    NSArray *names = @[ @"发现", @"搜索", @"音乐库" ];
    for (NSUInteger i = 0; i < roots.count; i++) {
        UINavigationController *nav = [[MCNavigationController alloc] initWithRootViewController:roots[i]];
        nav.tabBarItem = [[UITabBarItem alloc] initWithTitle:names[i] image:[self tabIcon:i] tag:i];
        [navs addObject:nav];
    }
    self.viewControllers = navs;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(libraryError:)
                                                 name:MCLibraryDidChangeNotification
                                               object:nil];
    self.miniTray = [UIView new];
    self.miniTray.tag = 8080;
    self.miniTray.clipsToBounds = YES;
    self.miniTray.layer.cornerRadius = 16;
    [self.view addSubview:self.miniTray];
    self.miniCarousel = [UIView new];
    self.miniCarousel.clipsToBounds = YES;
    [self.miniTray addSubview:self.miniCarousel];
    self.mini = MCTextButton();
    [self.miniCarousel addSubview:self.mini];
    [self.mini addTarget:self action:@selector(now) forControlEvents:UIControlEventTouchUpInside];
    [self.mini addTarget:self action:@selector(miniPressed) forControlEvents:UIControlEventTouchDown];
    [self.mini addTarget:self action:@selector(miniReleased)
          forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    self.mini.accessibilityHint = @"点按打开播放页面，左滑下一首，右滑上一首";
    self.miniNextPreview = [MCMiniPreview new];
    self.miniPreviousPreview = [MCMiniPreview new];
    self.miniNextPreview.hidden = self.miniPreviousPreview.hidden = YES;
    [self.miniCarousel addSubview:self.miniNextPreview];
    [self.miniCarousel addSubview:self.miniPreviousPreview];
    self.miniPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(miniDragged:)];
    self.miniPan.delegate = self;
    [self.miniTray addGestureRecognizer:self.miniPan];
    self.miniCover = [UIImageView new];
    self.miniCover.contentMode = UIViewContentModeScaleAspectFill;
    self.miniCover.layer.cornerRadius = 8;
    self.miniCover.clipsToBounds = YES;
    [self.mini addSubview:self.miniCover];
    [[MCArtwork sharedCache] load:nil into:self.miniCover];
    self.miniTitle = [UILabel new];
    self.miniTitle.backgroundColor = [UIColor clearColor];
    self.miniTitle.opaque = NO;
    self.miniTitle.font = [UIFont systemFontOfSize:14];
    self.miniTitle.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.mini addSubview:self.miniTitle];
    self.miniArtist = [UILabel new];
    self.miniArtist.backgroundColor = [UIColor clearColor];
    self.miniArtist.opaque = NO;
    self.miniArtist.font = [UIFont systemFontOfSize:12];
    self.miniArtist.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.mini addSubview:self.miniArtist];
    self.miniBoundary = [UIView new];
    self.miniBoundary.opaque = NO;
    self.miniBoundary.userInteractionEnabled = NO;
    self.miniProgress = [UIView new];
    self.miniProgress.opaque = NO;
    self.miniProgress.userInteractionEnabled = NO;
    self.miniPrevious = [[MCPlaybackButton alloc] initWithFrame:CGRectZero];
    self.miniPrevious.icon = MCPlaybackIconPrevious;
    self.miniPrevious.accessibilityLabel = @"上一曲";
    [self.miniPrevious addTarget:self action:@selector(miniPreviousTapped) forControlEvents:UIControlEventTouchUpInside];
    self.miniNext = [[MCPlaybackButton alloc] initWithFrame:CGRectZero];
    self.miniNext.icon = MCPlaybackIconNext;
    self.miniNext.accessibilityLabel = @"下一曲";
    [self.miniNext addTarget:self action:@selector(miniNextTapped) forControlEvents:UIControlEventTouchUpInside];
    self.toggleButton = [[MCPlaybackButton alloc] initWithFrame:CGRectZero];
    [self.toggleButton addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
    [self.miniTray addSubview:self.miniPrevious];
    [self.miniTray addSubview:self.toggleButton];
    [self.miniTray addSubview:self.miniNext];
    [self.miniTray addSubview:self.miniBoundary];
    [self.miniTray addSubview:self.miniProgress];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(update)
                                                 name:MCPlayerDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(update)
                                                 name:MCThemeDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateMiniProgress)
        name:MCPlayerProgressNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(motionChanged)
        name:MCMotionDidChangeNotification object:nil];
    [self update];
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)motionChanged {
    if (!MCMotionEnabled()) { [self resetMiniPan]; MCFinishAnimations(self.miniTray); }
}
- (UIImage *)tabIcon:(NSUInteger)i {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(25, 25), NO, 0);
    UIBezierPath *p = [UIBezierPath bezierPath];
    p.lineWidth = 2;
    if (i == 0) {
        [p appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectMake(3, 3, 19, 19)]];
        [p moveToPoint:CGPointMake(9, 16)];
        [p addLineToPoint:CGPointMake(16, 8)];
    } else if (i == 1) {
        [p appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectMake(2, 2, 15, 15)]];
        [p moveToPoint:CGPointMake(16, 16)];
        [p addLineToPoint:CGPointMake(23, 23)];
    } else {
        [p moveToPoint:CGPointMake(4, 3)];
        [p addLineToPoint:CGPointMake(4, 22)];
        [p moveToPoint:CGPointMake(10, 3)];
        [p addLineToPoint:CGPointMake(10, 22)];
        [p moveToPoint:CGPointMake(16, 3)];
        [p addLineToPoint:CGPointMake(21, 22)];
    }
    [p stroke];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    BOOL tabBarHidden = self.tabBar.hidden;
    if ([self.selectedViewController isKindOfClass:[UINavigationController class]]) {
        // A catalog pushed above Now Playing inherits its hidden bottom bar.
        // Legacy UIKit may retain the tab bar's old onscreen frame.
        UINavigationController *nav = (UINavigationController *)self.selectedViewController;
        for (UIViewController *controller in nav.viewControllers)
            tabBarHidden |= controller.hidesBottomBarWhenPushed;
    }
    CGFloat w = self.view.bounds.size.width;
    MCPlayerRect tray = MCMiniPlayerMakeFrame(w, self.view.bounds.size.height,
                                            self.tabBar.frame.origin.y, tabBarHidden);
    self.miniTray.frame = CGRectMake(tray.x + 8, tray.y, tray.width - 16, tray.height);
    w = self.miniTray.bounds.size.width;
    self.miniCarousel.frame = CGRectMake(0, 2, w - 132, 50);
    CGFloat panelWidth = self.miniCarousel.bounds.size.width;
    self.mini.bounds = self.miniNextPreview.bounds = self.miniPreviousPreview.bounds = CGRectMake(0, 0, panelWidth, 50);
    self.mini.center = CGPointMake(panelWidth / 2, 25);
    self.miniNextPreview.center = CGPointMake(panelWidth * 1.5, 25);
    self.miniPreviousPreview.center = CGPointMake(-panelWidth / 2, 25);
    self.miniCover.frame = CGRectMake(12, 8, 32, 32);
    self.miniTitle.frame = CGRectMake(54, 6, MAX(0, w - 194), 20);
    self.miniArtist.frame = CGRectMake(54, 27, MAX(0, w - 194), 16);
    self.miniPrevious.frame = CGRectMake(w - 132, 4, 44, 44);
    self.toggleButton.frame = CGRectMake(w - 88, 4, 44, 44);
    self.miniNext.frame = CGRectMake(w - 44, 4, 44, 44);
    self.miniBoundary.frame = CGRectMake(0, 0, w, 2);
    [self updateMiniProgress];
    [self.view bringSubviewToFront:self.miniTray];
}
- (void)update {
    MCPlayer *p = [MCPlayer sharedPlayer];
    MCTheme *t = [MCTheme sharedTheme];
    self.view.backgroundColor = t.background;
    self.miniTray.backgroundColor = t.surfaceContainer;
    self.miniCarousel.backgroundColor = t.surfaceContainer;
    [self.miniNextPreview applyTheme];
    [self.miniPreviousPreview applyTheme];
    self.mini.backgroundColor = t.surfaceContainer;
    self.toggleButton.backgroundColor = [UIColor clearColor];
    self.miniTitle.textColor = t.text;
    self.miniArtist.textColor = t.muted;
    self.miniCover.backgroundColor = t.background;
    self.miniBoundary.backgroundColor = t.outline;
    self.miniProgress.backgroundColor = t.primary;
    self.toggleButton.fill = t.primary;
    self.toggleButton.ink = t.onPrimary;
    self.miniPrevious.ink = self.miniNext.ink = t.primary;
    [t applyToTabBar:self.tabBar];
    for (UINavigationController *nav in self.viewControllers) {
        [t applyToNavigationBar:nav.navigationBar];
        if (@available(iOS 7.0, *)) [nav setNeedsStatusBarAppearanceUpdate];
    }
    NSString *identifier = p.currentTrack[@"id"];
    BOOL changed = !(self.miniTrackID == identifier || [self.miniTrackID isEqual:identifier]);
    if (changed && (self.miniPanning || self.miniSettling)) [self resetMiniPan];
    self.miniTrackID = identifier;
    NSString *title = p.currentTrack ? MCS(p.currentTrack[@"title"]) : @"暮雨音乐";
    NSString *artist = p.currentTrack ? MCS(p.currentTrack[@"artist"]) : @"选择一首歌开始";
    if (changed && self.miniSlideDirection && MCMotionEnabled() && self.miniTray.window && !self.miniTray.hidden) {
        CGFloat offset = self.miniSlideDirection * 10;
        self.miniTitle.text = title;
        self.miniArtist.text = artist;
        self.miniTitle.alpha = self.miniArtist.alpha = 0;
        self.miniTitle.transform = self.miniArtist.transform = CGAffineTransformMakeTranslation(offset, 0);
        MCAnimate(.18, UIViewAnimationOptionCurveEaseOut, ^{
            self.miniTitle.alpha = self.miniArtist.alpha = 1;
            self.miniTitle.transform = self.miniArtist.transform = CGAffineTransformIdentity;
        });
    } else if (changed && !self.miniNoFadeUpdate) {
        MCFadeChange(self.miniTitle, .16, ^{ self.miniTitle.text = title; });
        MCFadeChange(self.miniArtist, .16, ^{ self.miniArtist.text = artist; });
    } else {
        self.miniTitle.text = title;
        self.miniArtist.text = artist;
    }
    self.miniSlideDirection = 0;
    self.mini.accessibilityLabel = [NSString stringWithFormat:@"%@，%@", self.miniTitle.text, self.miniArtist.text];
    NSString *artwork = p.currentTrack[@"artwork"];
    if (!(self.miniArtwork == artwork || [self.miniArtwork isEqual:artwork])) {
        self.miniArtwork = artwork;
        self.miniArtworkReady = NO;
        __weak MCRootController *w = self;
        [[MCArtwork sharedCache] load:artwork into:self.miniCover animated:!self.miniNoFadeUpdate completion:^(UIImage *image) {
            MCRootController *s = w;
            if (!s || !(s.miniArtwork == artwork || [s.miniArtwork isEqual:artwork])) return;
            s.miniArtworkReady = image != nil;
            [[MCTheme sharedTheme] updateArtwork:image];
        }];
    }
    if (self.lastFollowArtwork != t.followArtwork) {
        self.lastFollowArtwork = t.followArtwork;
        if (t.followArtwork) [t updateArtwork:self.miniArtworkReady ? self.miniCover.image : nil];
    }
    self.toggleButton.icon = p.playing ? MCPlaybackIconPause : MCPlaybackIconPlay;
    self.toggleButton.accessibilityLabel = p.playing ? @"暂停" : @"播放";
    self.toggleButton.enabled = p.currentTrack != nil;
    self.miniPrevious.enabled = self.miniNext.enabled = p.currentTrack != nil;
    [self updateMiniProgress];
}
- (void)updateMiniProgress {
    MCPlayer *player = [MCPlayer sharedPlayer];
    double progress = player.currentTrack && isfinite(player.duration) && player.duration > 0 && isfinite(player.position)
        ? MAX(0, MIN(1, player.position / player.duration)) : 0;
    CGFloat width = MAX(0, self.miniTray.bounds.size.width - 24) * progress;
    CGFloat previous = self.miniProgress.frame.size.width;
    void (^change)(void) = ^{ self.miniProgress.frame = CGRectMake(12, 0, MAX(0, self.miniTray.bounds.size.width - 24) * progress, 2); };
    if (!self.miniTray.hidden && self.miniTray.window && width > previous &&
        width - previous < MAX(1, self.miniTray.bounds.size.width * .08))
        MCAnimate(.45, UIViewAnimationOptionCurveLinear, change);
    else {
        MCFinishAnimations(self.miniProgress);
        change();
    }
}
- (void)libraryError:(NSNotification *)note {
    NSArray *errors = note.userInfo[@"errors"];
    if (!errors.count)
        return;
    NSString *message = [errors[0] localizedDescription];
    if ([message isEqual:self.lastLibraryError])
        return;
    self.lastLibraryError = message;
    MCMessage(self, @"曲库操作失败", message);
}
- (void)now {
    MCPushNow(self.selectedViewController);
}
- (void)miniPressed { self.miniCover.alpha = self.miniTitle.alpha = self.miniArtist.alpha = .65; }
- (void)miniReleased { self.miniCover.alpha = self.miniTitle.alpha = self.miniArtist.alpha = 1; }
- (void)miniPreviousTapped { self.miniSlideDirection = -1; [[MCPlayer sharedPlayer] previous]; }
- (void)miniNextTapped { self.miniSlideDirection = 1; [[MCPlayer sharedPlayer] next]; }
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    if (recognizer != self.miniPan) return YES;
    CGPoint velocity = [self.miniPan velocityInView:self.miniTray];
    return !self.miniSettling && [MCPlayer sharedPlayer].currentTrack &&
        fabs(velocity.x) > fabs(velocity.y);
}
- (void)setMiniPanOffset:(CGFloat)offset {
    CGAffineTransform transform = CGAffineTransformMakeTranslation(offset, 0);
    self.mini.transform = self.miniNextPreview.transform = self.miniPreviousPreview.transform = transform;
}
- (void)resetMiniPan {
    self.miniPanGeneration++;
    self.miniPanning = self.miniSettling = NO;
    MCFinishAnimations(self.miniCarousel);
    [self setMiniPanOffset:0];
    self.miniNextPreview.hidden = self.miniPreviousPreview.hidden = YES;
    self.miniNextPlan = self.miniPreviousPlan = nil;
}
- (void)miniDragged:(UIPanGestureRecognizer *)gesture {
    CGFloat width = self.miniCarousel.bounds.size.width;
    if (gesture.state == UIGestureRecognizerStateBegan) {
        [self resetMiniPan];
        [self miniReleased];
        self.miniPanning = YES;
        MCPlayer *player = [MCPlayer sharedPlayer];
        self.miniNextPlan = [player queueTransitionForward:YES];
        self.miniPreviousPlan = [player queueTransitionForward:NO];
        [self.miniNextPreview showTrack:self.miniNextPlan.track];
        [self.miniPreviousPreview showTrack:self.miniPreviousPlan.track];
        self.miniNextPreview.hidden = !self.miniNextPlan || !MCMotionEnabled();
        self.miniPreviousPreview.hidden = !self.miniPreviousPlan || !MCMotionEnabled();
    }
    if (!self.miniPanning) return;
    CGFloat translation = [gesture translationInView:self.miniTray].x;
    BOOL available = translation < 0 ? self.miniNextPlan != nil : self.miniPreviousPlan != nil;
    if (gesture.state == UIGestureRecognizerStateChanged) {
        if (MCMotionEnabled()) [self setMiniPanOffset:MCMiniDragOffset(translation, width, available)];
        return;
    }
    if (gesture.state != UIGestureRecognizerStateEnded && gesture.state != UIGestureRecognizerStateCancelled &&
        gesture.state != UIGestureRecognizerStateFailed) return;
    int direction = gesture.state == UIGestureRecognizerStateEnded ?
        MCMiniDragDestination(translation, [gesture velocityInView:self.miniTray].x, width,
                             self.miniPreviousPlan != nil, self.miniNextPlan != nil) : 0;
    MCQueueTransition *plan = direction < 0 ? self.miniNextPlan : direction > 0 ? self.miniPreviousPlan : nil;
    self.miniPanning = NO;
    self.miniSettling = YES;
    NSUInteger generation = ++self.miniPanGeneration;
    MCAnimateCompletion(.18, UIViewAnimationOptionCurveEaseOut, ^{
        [self setMiniPanOffset:direction * width];
    }, ^(BOOL finished) {
        (void)finished;
        if (generation != self.miniPanGeneration) return;
        [self resetMiniPan];
        self.miniNoFadeUpdate = YES;
        if (plan) [[MCPlayer sharedPlayer] commitQueueTransition:plan];
        [self update];
        self.miniNoFadeUpdate = NO;
    });
}
- (void)toggle {
    [[MCPlayer sharedPlayer] toggle];
}
- (void)settings {
    [(UINavigationController *)self.selectedViewController pushViewController:[MCSettingsController new]
                                                                     animated:YES];
}
- (void)account {
    [(UINavigationController *)self.selectedViewController pushViewController:[MCAccountController new]
                                                                     animated:YES];
}
@end

UIViewController *MCQueueController(void) {
    return MCNewList(@"播放队列", @"queue", nil);
}
