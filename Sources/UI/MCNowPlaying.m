#import "MCUI.h"
#import "MCTheme.h"
#import "MCArtwork.h"
#import "MCDialogs.h"
#import "MCSourcesController.h"
#import "MCPlayer.h"
#import "MCAPI.h"
#import "MCSourceSecurity.h"
#import "MCLibrary.h"
#import "MCLyrics.h"
#import "MCLyricCell.h"
#import "MCPlaybackButton.h"
#import "MCNowPlayingLayout.h"
#import "MCMotion.h"
#import "MCMaterialControls.h"
#import "MCPlayerCoverCard.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>
#include <float.h>
extern UIViewController *MCQueueController(void);
static NSString *MCTimeString(double value) {
    if (!isfinite(value) || value < 0) value = 0;
    return [NSString stringWithFormat:@"%u:%02u", (unsigned)value / 60, (unsigned)value % 60];
}
static CGRect MCRect(MCPlayerRect r) { return CGRectMake(r.x, r.y, r.width, r.height); }
@interface MCNowPlayingController () <UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIView *content;
@property (nonatomic, strong) UIView *bodyContainer;
@property (nonatomic, strong) MCPlayerCoverCard *coverCard;
@property (nonatomic, strong) UIImageView *cover;
@property (nonatomic, strong) UILabel *navigationTitle;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) UILabel *elapsed;
@property (nonatomic, strong) UILabel *total;
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, strong) MCPlaybackButton *previousButton;
@property (nonatomic, strong) MCPlaybackButton *play;
@property (nonatomic, strong) MCPlaybackButton *nextButton;
@property (nonatomic, strong) MCPlaybackButton *repeat;
@property (nonatomic, strong) MCPlaybackButton *shuffleButton;
@property (nonatomic, strong) MCPlaybackButton *favoriteButton;
@property (nonatomic, strong) MCPlaybackButton *details;
@property (nonatomic, strong) UIButton *queueButton;
@property (nonatomic, strong) MCMaterialModeControl *mode;
@property (nonatomic, strong) UITableView *lyricsTable;
@property (nonatomic, strong) UILabel *lyricsEmpty;
@property (nonatomic, strong) NSArray *lines;
@property (nonatomic, strong) NSMutableDictionary *lyricHeights;
@property (nonatomic) BOOL lyricsTranslation, lyricsRomanization;
@property (nonatomic, copy) NSString *trackID;
@property (nonatomic) NSInteger activeLine;
@property (nonatomic) BOOL dragging;
@property (nonatomic) BOOL lyricsNeedCenter;
@property (nonatomic) CFTimeInterval lyricsResumeAfter;
@property (nonatomic) NSUInteger favoriteGeneration;
@property (nonatomic) BOOL favoriteChanging;
@property (nonatomic) BOOL previousTranslucent;
@end
@implementation MCNowPlayingController
- (id)init {
    if ((self = [super init])) {
        self.hidesBottomBarWhenPushed = YES;
        if (@available(iOS 7.0, *)) {
            self.edgesForExtendedLayout = UIRectEdgeNone;
            self.automaticallyAdjustsScrollViewInsets = NO;
        }
        _activeLine = -1;
    }
    return self;
}
- (MCPlaybackButton *)button:(MCPlaybackIcon)icon label:(NSString *)label action:(SEL)action {
    MCPlaybackButton *b = [[MCPlaybackButton alloc] initWithFrame:CGRectZero];
    b.icon = icon;
    b.accessibilityLabel = label;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.content addSubview:b];
    return b;
}
- (UILabel *)label:(CGFloat)size {
    UILabel *l = [UILabel new];
    l.backgroundColor = [UIColor clearColor];
    l.opaque = NO;
    l.textAlignment = NSTextAlignmentCenter;
    l.font = [UIFont systemFontOfSize:size];
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.content addSubview:l];
    return l;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"正在播放";
    self.lyricHeights = [NSMutableDictionary dictionary];
    self.lyricsTranslation = MCLyricsShowTranslation();
    self.lyricsRomanization = MCLyricsUseRomanization();
    self.content = [UIView new];
    [self.view addSubview:self.content];
    for (NSNumber *direction in @[@(UISwipeGestureRecognizerDirectionLeft), @(UISwipeGestureRecognizerDirectionRight)]) {
        UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(swipeMode:)];
        swipe.direction = direction.unsignedIntegerValue;
        swipe.delegate = self;
        [self.content addGestureRecognizer:swipe];
    }
    self.mode = [[MCMaterialModeControl alloc] initWithItems:@[ @"封面", @"歌词" ]];
    self.mode.selectedSegmentIndex = 0;
    self.mode.accessibilityLabel = @"播放页面内容";
    [self.mode addTarget:self action:@selector(modeChanged) forControlEvents:UIControlEventValueChanged];
    [self.content addSubview:self.mode];
    self.bodyContainer = [UIView new];
    [self.content addSubview:self.bodyContainer];
    self.coverCard = [MCPlayerCoverCard new];
    self.cover = self.coverCard.artworkView;
    [self.coverCard.titleButton addTarget:self action:@selector(titleTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.coverCard.qualityButton addTarget:self action:@selector(qualityTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.bodyContainer addSubview:self.coverCard];
    self.lyricsTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.lyricsTable.dataSource = self;
    self.lyricsTable.delegate = self;
    self.lyricsTable.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.lyricsTable.rowHeight = 56;
    self.lyricsTable.showsVerticalScrollIndicator = NO;
    self.lyricsTable.hidden = YES;
    self.lyricsTable.clipsToBounds = YES;
    self.lyricsEmpty = [UILabel new];
    self.lyricsEmpty.backgroundColor = [UIColor clearColor];
    self.lyricsEmpty.opaque = NO;
    self.lyricsEmpty.font = [UIFont systemFontOfSize:14];
    self.lyricsEmpty.numberOfLines = 4;
    self.lyricsEmpty.textAlignment = NSTextAlignmentCenter;
    self.lyricsTable.backgroundView = self.lyricsEmpty;
    [self.bodyContainer addSubview:self.lyricsTable];
    self.slider = [UISlider new];
    self.slider.accessibilityLabel = @"播放进度";
    [self.slider addTarget:self action:@selector(dragStart) forControlEvents:UIControlEventTouchDown];
    [self.slider addTarget:self action:@selector(dragProgress) forControlEvents:UIControlEventValueChanged];
    [self.slider addTarget:self action:@selector(seek)
          forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
    [self.slider addTarget:self action:@selector(dragCancelled) forControlEvents:UIControlEventTouchCancel];
    [self.content addSubview:self.slider];
    self.elapsed = [self label:11];
    self.elapsed.textAlignment = NSTextAlignmentLeft;
    self.total = [self label:11];
    self.total.textAlignment = NSTextAlignmentRight;
    self.status = [self label:10];
    [self.status addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(errorTapped)]];
    self.previousButton = [self button:MCPlaybackIconPrevious label:@"上一首" action:@selector(previous)];
    self.play = [self button:MCPlaybackIconPlay label:@"播放" action:@selector(toggle)];
    self.nextButton = [self button:MCPlaybackIconNext label:@"下一首" action:@selector(next)];
    self.repeat = [self button:MCPlaybackIconSequence label:@"顺序播放" action:@selector(repeatTapped)];
    self.repeat.accessibilityHint = @"切换顺序、列表循环或单曲循环";
    self.shuffleButton = [self button:MCPlaybackIconShuffle label:@"随机播放" action:@selector(shuffleTapped)];
    self.favoriteButton = self.coverCard.favoriteButton;
    self.favoriteButton.accessibilityLabel = @"本地收藏";
    [self.favoriteButton addTarget:self action:@selector(favorite) forControlEvents:UIControlEventTouchUpInside];
    self.details = [[MCPlaybackButton alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
    self.details.icon = MCPlaybackIconDetails;
    self.details.accessibilityLabel = @"歌曲操作";
    [self.details addTarget:self action:@selector(trackActions) forControlEvents:UIControlEventTouchUpInside];
    // One fixed-width item keeps both controls visible with long back titles on iOS 6.
    UIView *navigationActions = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 88, 44)];
    navigationActions.clipsToBounds = YES;
    MCPlaybackButton *queueIcon = [MCPlaybackButton new];
    queueIcon.icon = MCPlaybackIconQueue;
    queueIcon.accessibilityLabel = @"播放队列";
    self.queueButton = queueIcon;
    self.queueButton.frame = CGRectMake(0, 0, 44, 44);
    self.queueButton.titleLabel.font = [UIFont systemFontOfSize:14];
    [self.queueButton addTarget:self action:@selector(queueTapped) forControlEvents:UIControlEventTouchUpInside];
    self.details.frame = CGRectMake(44, 0, 44, 44);
    [navigationActions addSubview:self.queueButton];
    [navigationActions addSubview:self.details];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:navigationActions];
    self.navigationItem.rightBarButtonItem.width = 88;
    self.navigationTitle = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 96, 28)];
    self.navigationTitle.backgroundColor = [UIColor clearColor];
    self.navigationTitle.opaque = NO;
    self.navigationTitle.font = [UIFont boldSystemFontOfSize:14];
    self.navigationTitle.textAlignment = NSTextAlignmentCenter;
    self.navigationTitle.lineBreakMode = NSLineBreakByTruncatingTail;
    // UILabel sizeThatFits grows with a long lyric title. Bound its container too.
    UIView *titleContainer = [[UIView alloc] initWithFrame:self.navigationTitle.frame];
    titleContainer.clipsToBounds = YES;
    self.navigationTitle.frame = titleContainer.bounds;
    self.navigationTitle.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [titleContainer addSubview:self.navigationTitle];
    self.navigationItem.titleView = titleContainer;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(update)
                                                 name:MCPlayerDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(progress)
                                                 name:MCPlayerProgressNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(theme)
                                                 name:MCThemeDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshFavorite)
                                                 name:MCLibraryDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(motionChanged)
        name:MCMotionDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(lyricOptionsChanged)
        name:MCLyricsOptionsDidChangeNotification object:nil];
    [[MCArtwork sharedCache] load:nil into:self.cover];
    [self.coverCard updateArtwork:nil];
    [self update];
    [self theme];
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)motionChanged {
    if (!MCMotionEnabled()) {
        MCFinishAnimations(self.content);
        [self.lyricsTable setContentOffset:self.lyricsTable.contentOffset animated:NO];
    }
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.previousTranslucent = self.navigationController.navigationBar.translucent;
    self.navigationController.navigationBar.translucent = NO;
    [self.tabBarController.view viewWithTag:8080].hidden = YES;
    [self theme];
    [self update];
    [self refreshFavorite];
    self.lyricsResumeAfter = 0;
    self.lyricsNeedCenter = YES;
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.navigationController.navigationBar.translucent = self.previousTranslucent;
    [self.tabBarController.view viewWithTag:8080].hidden = NO;
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    /* edgesForExtendedLayout excludes both bars; do not subtract the top guide twice. */
    self.content.frame = self.view.bounds;
    MCNowPlayingLayout l = MCNowPlayingMakeLayout(self.content.bounds.size.width, self.content.bounds.size.height);
    self.mode.frame = MCRect(l.mode);
    self.bodyContainer.frame = MCRect(l.body);
    self.coverCard.frame = CGRectOffset(MCRect(l.cover), -l.body.x, -l.body.y);
    BOOL resized = !CGRectEqualToRect(self.lyricsTable.frame, self.bodyContainer.bounds);
    self.lyricsTable.frame = self.bodyContainer.bounds;
    if (resized) {
        [self.lyricHeights removeAllObjects];
        [self.lyricsTable reloadData];
        [self updateLyricInsets];
        self.lyricsNeedCenter = YES;
    }
    self.slider.frame = MCRect(l.slider);
    self.elapsed.frame = MCRect(l.elapsed);
    self.total.frame = MCRect(l.total);
    self.status.frame = MCRect(l.status);
    self.previousButton.frame = MCRect(l.previous);
    self.play.frame = MCRect(l.play);
    self.nextButton.frame = MCRect(l.next);
    self.repeat.frame = MCRect(l.repeat);
    self.shuffleButton.frame = MCRect(l.shuffle);
    [self centerLyrics:NO];
}
- (void)theme {
    MCTheme *t = [MCTheme sharedTheme];
    self.view.backgroundColor = self.bodyContainer.backgroundColor = t.surface;
    self.lyricsTable.backgroundColor = t.surface;
    self.lyricsEmpty.textColor = t.muted;
    self.navigationTitle.textColor = t.text;
    self.elapsed.textColor = self.total.textColor = t.muted;
    ((MCPlaybackButton *)self.queueButton).ink = t.text;

    [t applyToNavigationBar:self.navigationController.navigationBar];
    [self.slider setMinimumTrackImage:MCPlayerSliderTrack(t.primary) forState:UIControlStateNormal];
    [self.slider setMaximumTrackImage:MCPlayerSliderTrack(t.surfaceContainerHigh)
                            forState:UIControlStateNormal];
    [self.slider setThumbImage:MCPlayerSliderThumb(t.primary, NO) forState:UIControlStateNormal];
    [self.slider setThumbImage:MCPlayerSliderThumb(t.primary, YES) forState:UIControlStateHighlighted];
    [self updateButtonColors];
    [self updateLyricCells];
}
- (void)updateButtonColors {
    MCTheme *t = [MCTheme sharedTheme];
    self.play.fill = t.primary;
    self.play.ink = t.onPrimary;
    self.previousButton.ink = self.nextButton.ink = self.details.ink = t.text;
    self.repeat.selectionFill = self.shuffleButton.selectionFill = t.primaryContainer;
    self.repeat.ink = self.repeat.selected ? t.onPrimaryContainer : t.muted;
    self.shuffleButton.ink = self.shuffleButton.selected ? t.onPrimaryContainer : t.muted;
    self.status.textColor = [MCPlayer sharedPlayer].error ? t.accent : t.muted;
}
- (void)update {
    MCPlayer *p = [MCPlayer sharedPlayer];
    NSDictionary *track = p.currentTrack;
    self.navigationTitle.text = @"正在播放";
    self.navigationTitle.accessibilityLabel = self.navigationTitle.text;
    self.play.icon = p.playing ? MCPlaybackIconPause : MCPlaybackIconPlay;
    self.play.accessibilityLabel = p.playing ? @"暂停" : @"播放";
    NSInteger repeat = MAX(0, MIN(2, p.repeatMode));
    self.repeat.icon = repeat == 2 ? MCPlaybackIconRepeatOne : MCPlaybackIconRepeat;
    self.repeat.accessibilityLabel = @[ @"循环关闭", @"列表循环", @"单曲循环" ][repeat];
    self.repeat.selected = repeat != 0;
    self.shuffleButton.selected = p.shuffle;
    self.shuffleButton.accessibilityValue = p.shuffle ? @"已开启" : @"已关闭";
    NSString *quality = p.qualityLabel;
    if (!quality.length || [quality isEqual:@"—"]) quality = @"音质待加载";
    [self.coverCard showTitle:track[@"title"] ?: @"还没有播放歌曲"
        artist:track[@"artist"] ?: @"从搜索或音乐库选择歌曲" quality:quality];
    NSString *reason = MCSourceFailureText(p.error.localizedDescription, @"未知播放错误，请重试或切换音源。");
    NSString *brief = [reason substringToIndex:MIN((NSUInteger)10, reason.length)];
    if (reason.length > 10) brief = [brief stringByAppendingString:@"…"];
    if ([reason rangeOfString:@"仅允许 HTTPS"].location != NSNotFound)
        brief = @"HTTP 被 HTTPS 拦截";
    NSRegularExpression *httpStatus = [NSRegularExpression regularExpressionWithPattern:@"HTTP [0-9]{3}" options:0 error:NULL];
    NSTextCheckingResult *statusMatch = [httpStatus firstMatchInString:reason options:0 range:NSMakeRange(0, reason.length)];
    if (statusMatch) brief = [reason substringWithRange:statusMatch.range];
    self.status.text = p.error ? [NSString stringWithFormat:@"%@ · 查看详情", brief] : p.buffering ? @"正在缓冲…" : @"";
    self.status.userInteractionEnabled = p.error != nil;
    self.status.accessibilityLabel = p.error ? [@"播放失败：" stringByAppendingString:reason] : self.status.text;
    self.status.accessibilityTraits = p.error ? UIAccessibilityTraitButton : UIAccessibilityTraitStaticText;
    self.status.accessibilityHint = p.error ? @"点按查看原因、重试或切换音源" : nil;
    self.details.accessibilityHint = @"收藏、加入歌单、浏览歌手和查看歌曲信息";
    self.details.enabled = track != nil;
    self.play.enabled = self.previousButton.enabled = self.nextButton.enabled = track != nil;
    self.favoriteButton.enabled = track != nil && !self.favoriteChanging;
    NSString *identifier = track[@"id"];
    if (!(self.trackID == identifier || [self.trackID isEqual:identifier])) {
        self.trackID = identifier;
        self.lines = @[];
        [self.lyricHeights removeAllObjects];
        self.activeLine = -1;
        self.lyricsResumeAfter = 0;
        self.lyricsNeedCenter = YES;
        self.favoriteButton.selected = NO;
        self.favoriteChanging = NO;
        [self refreshFavorite];
        __weak MCNowPlayingController *weakSelf = self;
        [[MCArtwork sharedCache] load:track[@"artwork"] into:self.cover animated:YES completion:^(UIImage *image) {
            [weakSelf.coverCard updateArtwork:image];
        }];
        [self loadLyrics:track];
    } else if (!track) self.lyricsEmpty.text = @"选择歌曲后显示歌词";
    [self updateButtonColors];
    [self progress];
}
- (void)loadLyrics:(NSDictionary *)track {
    self.lyricsEmpty.text = track ? @"正在读取歌词…" : @"选择歌曲后显示歌词";
    self.lyricsEmpty.hidden = NO;
    [self.lyricsTable reloadData];
    if (!track) return;
    NSString *identifier = [self.trackID copy];
    __weak MCNowPlayingController *w = self;
    void (^loaded)(NSDictionary *, NSError *) = ^(NSDictionary *variants, NSError *error) {
        MCNowPlayingController *s = w;
        if (!s || ![s.trackID isEqual:identifier]) return;
        s.lines = [MCLyrics parseOriginal:variants[@"original"] translation:variants[@"translation"]
                           romanization:variants[@"romanization"]];
        [s.lyricHeights removeAllObjects];
        s.activeLine = -1;
        s.lyricsNeedCenter = YES;
        s.lyricsEmpty.text = error ? [NSString stringWithFormat:@"歌词读取失败\n%@", error.localizedDescription] : @"暂无可用的同步歌词";
        s.lyricsEmpty.hidden = s.lines.count > 0;
        [s.lyricsTable reloadData];
        [s updateLyricInsets];
        [s progress];
    };
    if (track[@"path"])
        [[MCLibrary sharedLibrary] lyricsForTrack:track completion:^(NSString *text) { loaded(@{@"original":text ?: @""}, nil); }];
    else
        [[MCAPI sharedAPI] lyricVariants:identifier completion:^(id result, NSError *error) { loaded(result, error); }];
}
- (void)progress {
    MCPlayer *p = [MCPlayer sharedPlayer];
    if (!self.dragging) {
        self.slider.maximumValue = MAX(1, p.duration);
        self.slider.value = p.position;
        self.elapsed.text = MCTimeString(p.position);
    }
    self.slider.enabled = p.duration > 0;
    self.total.text = MCTimeString(p.duration);
    NSInteger index = [MCLyrics indexAtTime:p.position lines:self.lines];
    if (index != self.activeLine) {
        self.activeLine = index;
        self.lyricsNeedCenter = YES;
        [self updateLyricCells];
    }
    [self centerLyrics:YES];
}
- (void)centerLyrics:(BOOL)animated {
    if (!self.lyricsNeedCenter || self.lyricsTable.hidden || self.activeLine < 0 ||
        self.activeLine >= (NSInteger)self.lines.count || self.lyricsTable.bounds.size.height <= 0 ||
        !MCLyricCanFollow(CACurrentMediaTime(), self.lyricsResumeAfter,
                         self.lyricsTable.dragging, self.lyricsTable.decelerating)) return;
    CGRect row = [self.lyricsTable rectForRowAtIndexPath:[NSIndexPath indexPathForRow:self.activeLine inSection:0]];
    CGFloat y = CGRectGetMidY(row) - self.lyricsTable.bounds.size.height / 2;
    self.lyricsNeedCenter = NO;
    [self.lyricsTable setContentOffset:CGPointMake(0, y) animated:animated && MCMotionEnabled()];
}
- (void)styleLyricCell:(UITableViewCell *)cell row:(NSInteger)row {
    NSString *text = [MCLyrics displayTextForLine:self.lines[row] romanization:self.lyricsRomanization];
    [(MCLyricCell *)cell showText:text translation:[self translationAtRow:row] active:row == self.activeLine];
}
- (NSString *)translationAtRow:(NSInteger)row {
    NSString *translation = self.lines[row][@"translation"];
    NSString *main = [MCLyrics displayTextForLine:self.lines[row] romanization:self.lyricsRomanization];
    return self.lyricsTranslation && ![translation isEqual:main] ? translation : nil;
}
- (CGFloat)lyricHeightAtRow:(NSInteger)row {
    NSNumber *cached = self.lyricHeights[@(row)];
    if (cached) return cached.doubleValue;
    CGFloat height = [MCLyricCell heightForText:[MCLyrics displayTextForLine:self.lines[row] romanization:self.lyricsRomanization]
        translation:[self translationAtRow:row] width:self.lyricsTable.bounds.size.width];
    self.lyricHeights[@(row)] = @(height);
    return height;
}
- (void)updateLyricInsets {
    CGFloat height = self.lyricsTable.bounds.size.height;
    CGFloat first = self.lines.count ? [self lyricHeightAtRow:0] : 56;
    CGFloat last = self.lines.count ? [self lyricHeightAtRow:self.lines.count - 1] : 56;
    UIEdgeInsets insets = UIEdgeInsetsMake(MAX(0, (height - first) / 2), 0, MAX(0, (height - last) / 2), 0);
    if (!UIEdgeInsetsEqualToEdgeInsets(insets, self.lyricsTable.contentInset)) self.lyricsTable.contentInset = insets;
}
- (void)lyricOptionsChanged {
    self.lyricsTranslation = MCLyricsShowTranslation();
    self.lyricsRomanization = MCLyricsUseRomanization();
    [self.lyricHeights removeAllObjects];
    [self.lyricsTable reloadData];
    [self updateLyricInsets];
    self.lyricsNeedCenter = YES;
    self.lyricsResumeAfter = 0;
    [self progress];
}
- (void)updateLyricCells {
    for (NSIndexPath *path in self.lyricsTable.indexPathsForVisibleRows)
        [self styleLyricCell:[self.lyricsTable cellForRowAtIndexPath:path] row:path.row];
}
- (void)modeChanged {
    BOOL lyrics = self.mode.selectedSegmentIndex == 1;
    if (self.lyricsTable.hidden == !lyrics) return;
    [self.content layoutIfNeeded];
    MCFadeChange(self.bodyContainer, .15, ^{
        self.coverCard.hidden = lyrics;
        self.lyricsTable.hidden = !lyrics;
        self.lyricsResumeAfter = 0;
        self.lyricsNeedCenter = YES;
        [self update];
        self.lyricsNeedCenter = YES;
        [self centerLyrics:NO];
    });
}
- (void)dragStart { self.dragging = YES; }
- (void)dragProgress { self.elapsed.text = MCTimeString(self.slider.value); }
- (void)dragCancelled { self.dragging = NO; [self progress]; }
- (void)seek {
    self.dragging = NO;
    self.lyricsResumeAfter = 0;
    self.lyricsNeedCenter = YES;
    [[MCPlayer sharedPlayer] seek:self.slider.value];
}
- (void)toggle { [[MCPlayer sharedPlayer] toggle]; }
- (void)next { [[MCPlayer sharedPlayer] next]; }
- (void)previous { [[MCPlayer sharedPlayer] previous]; }
- (void)swipeMode:(UISwipeGestureRecognizer *)swipe {
    self.mode.selectedSegmentIndex = swipe.direction == UISwipeGestureRecognizerDirectionLeft ? 1 : 0;
    [self modeChanged];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    (void)gesture;
    for (UIView *view = touch.view; view && view != self.content; view = view.superview)
        if ([view isKindOfClass:[UIControl class]]) return NO;
    return YES;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return [gesture isKindOfClass:[UISwipeGestureRecognizer class]] && other == self.lyricsTable.panGestureRecognizer;
}
- (void)trackActions { MCShowTrackActions(self, [MCPlayer sharedPlayer].currentTrack, nil); }
- (void)repeatTapped {
    MCPlayer *p = [MCPlayer sharedPlayer];
    p.repeatMode = (p.repeatMode + 1) % 3;
    [self update];
}
- (void)shuffleTapped { [MCPlayer sharedPlayer].shuffle = ![MCPlayer sharedPlayer].shuffle; [self update]; }
- (void)errorTapped {
    if ([MCPlayer sharedPlayer].error) [self qualityTapped];
}
- (NSString *)songInformation {
    MCPlayer *p = [MCPlayer sharedPlayer];
    NSDictionary *track = p.currentTrack;
    return [NSString stringWithFormat:@"%@\n%@\n%@\n实际音质：%@", track[@"title"] ?: @"还没有播放歌曲",
        track[@"artist"] ?: @"", track[@"album"] ?: @"", p.qualityLabel ?: @"播放后显示"];
}
- (void)titleTapped { MCMessage(self, @"歌曲详情", [self songInformation]); }
- (void)qualityTapped {
    MCPlayer *p = [MCPlayer sharedPlayer];
    NSDictionary *track = p.currentTrack;
    NSString *text = [self songInformation];
    if (p.error) {
        __weak MCNowPlayingController *weakSelf = self;
        NSString *message = [NSString stringWithFormat:@"歌曲：%@\n音源：%@\n\n%@",
            track[@"title"] ?: @"未知歌曲", p.playbackSourceName,
            MCSourceFailureText(p.error.localizedDescription, @"未知播放错误，请重试或切换音源。")];
        MCChooseMessage(@"播放失败", message, @[@"重试播放", @"切换音源", @"歌曲详情"], ^(NSInteger choice) {
            if (choice == 0)
                [[MCPlayer sharedPlayer] retry];
            else if (choice == 1)
                [weakSelf.navigationController pushViewController:[[MCSourcesController alloc] initWithStyle:UITableViewStyleGrouped] animated:YES];
            else
                MCMessage(weakSelf, @"歌曲详情", text);
        });
    } else
        MCMessage(self, @"歌曲详情", text);
}
- (void)queueTapped { [self.navigationController pushViewController:MCQueueController() animated:YES]; }
- (void)refreshFavorite {
    NSString *identifier = [self.trackID copy];
    NSUInteger generation = ++self.favoriteGeneration;
    if (!identifier) { self.favoriteButton.selected = NO; self.favoriteButton.enabled = NO; return; }
    __weak MCNowPlayingController *w = self;
    [[MCLibrary sharedLibrary] favoriteTracks:^(NSArray *tracks) {
        MCNowPlayingController *s = w;
        if (!s || generation != s.favoriteGeneration || ![s.trackID isEqual:identifier]) return;
        BOOL found = NO;
        for (NSDictionary *track in tracks) if ([track[@"id"] isEqual:identifier]) { found = YES; break; }
        s.favoriteButton.selected = found;
        s.favoriteChanging = NO;
        s.favoriteButton.enabled = YES;
        s.favoriteButton.accessibilityLabel = found ? @"取消本地收藏" : @"加入本地收藏";
        s.favoriteButton.accessibilityValue = found ? @"已收藏" : @"未收藏";
        [s updateButtonColors];
    }];
}
- (void)favorite {
    NSDictionary *track = [MCPlayer sharedPlayer].currentTrack;
    if (!track || self.favoriteChanging) return;
    self.favoriteChanging = YES;
    self.favoriteButton.enabled = NO;
    __weak MCNowPlayingController *w = self;
    [[MCLibrary sharedLibrary] favoriteTracks:^(NSArray *tracks) {
        BOOL found = NO;
        for (NSDictionary *d in tracks) if ([d[@"id"] isEqual:track[@"id"]]) { found = YES; break; }
        [[MCLibrary sharedLibrary] setFavorite:!found track:track];
        [w refreshFavorite];
    }];
}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)section { return self.lines.count; }
- (CGFloat)tableView:(UITableView *)t heightForRowAtIndexPath:(NSIndexPath *)path { return [self lyricHeightAtRow:path.row]; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [t dequeueReusableCellWithIdentifier:@"lyric"];
    if (!cell) {
        cell = [[MCLyricCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"lyric"];
    }
    [self styleLyricCell:cell row:path.row];
    return cell;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)path {
    [t deselectRowAtIndexPath:path animated:MCMotionEnabled()];
    if (path.row >= (NSInteger)self.lines.count) return;
    [t setContentOffset:t.contentOffset animated:NO];
    self.lyricsResumeAfter = 0;
    self.lyricsNeedCenter = YES;
    [[MCPlayer sharedPlayer] seek:[self.lines[path.row][@"time"] doubleValue]];
}
- (void)scrollViewWillBeginDragging:(UIScrollView *)scroll {
    if (scroll != self.lyricsTable) return;
    self.lyricsResumeAfter = DBL_MAX;
    self.lyricsNeedCenter = YES;
}
- (void)scrollViewDidEndDragging:(UIScrollView *)scroll willDecelerate:(BOOL)decelerate {
    if (scroll == self.lyricsTable && !decelerate) self.lyricsResumeAfter = CACurrentMediaTime() + 3;
}
- (void)scrollViewDidEndDecelerating:(UIScrollView *)scroll {
    if (scroll == self.lyricsTable) self.lyricsResumeAfter = CACurrentMediaTime() + 3;
}
@end
