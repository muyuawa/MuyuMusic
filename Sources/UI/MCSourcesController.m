#import "MCSourcesController.h"
#import "MCMusicSources.h"
#import "MCSourceRepository.h"
#import "MCSourceSecurity.h"
#import "MCTheme.h"
#import "MCFlatControls.h"
#import "MCDialogs.h"
#import "MCMotion.h"
#import "MCLegal.h"
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <limits.h>
#include <stdlib.h>

static UITableViewCell *MCSourceCell(UITableViewCellStyle style) {
    UITableViewCell *cell = [[MCFlatTableCell alloc] initWithStyle:style reuseIdentifier:nil];
    MCTheme *theme = [MCTheme sharedTheme];
    cell.backgroundColor = theme.surface;
    cell.textLabel.backgroundColor = cell.detailTextLabel.backgroundColor = [UIColor clearColor];
    cell.textLabel.textColor = theme.text;
    cell.detailTextLabel.textColor = theme.muted;
    cell.textLabel.font = [UIFont systemFontOfSize:15];
    return cell;
}
static NSString *MCSourceText(id value) {
    if (![value isKindOfClass:[NSString class]])
        return @"";
    return [value length] > 500 ? [[value substringToIndex:500] stringByAppendingString:@"…"] : value;
}

// The advanced editor is entered explicitly: secrets are never rendered in a list or detail page.
@interface MCSourceJSONController : UIViewController
@property (nonatomic, strong) UITextView *editor;
@property (nonatomic, copy) NSDictionary *configuration;
@property (nonatomic, copy) void (^saved)(NSDictionary *);
@end
@implementation MCSourceJSONController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"高级配置";
    self.view.backgroundColor = [MCTheme sharedTheme].background;
    self.editor = [[UITextView alloc] initWithFrame:self.view.bounds];
    self.editor.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.editor.backgroundColor = [MCTheme sharedTheme].surface;
    self.editor.textColor = [MCTheme sharedTheme].text;
    self.editor.font = [UIFont systemFontOfSize:15];
    self.editor.autocorrectionType = UITextAutocorrectionTypeNo;
    self.editor.autocapitalizationType = UITextAutocapitalizationTypeNone;
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.configuration
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    self.editor.text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    self.editor.accessibilityLabel = @"API JSON 配置，可能包含密钥";
    [self.view addSubview:self.editor];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"应用"
                                                                              style:UIBarButtonItemStyleDone
                                                                             target:self
                                                                             action:@selector(apply)];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboard:)
                                                 name:UIKeyboardWillChangeFrameNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(hideSecrets)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showEditor)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
}
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}
- (void)hideSecrets {
    self.editor.hidden = YES;
}
- (void)showEditor {
    self.editor.hidden = NO;
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.editor.hidden = NO;
}
- (void)keyboard:(NSNotification *)note {
    CGRect frame = [self.view convertRect:[note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue]
                                 fromView:nil];
    CGFloat overlap = CGRectGetHeight(CGRectIntersection(self.view.bounds, frame));
    if (CGRectIsNull(CGRectIntersection(self.view.bounds, frame)))
        overlap = 0;
    UIEdgeInsets inset = self.editor.contentInset;
    inset.bottom = overlap;
    self.editor.contentInset = inset;
    self.editor.scrollIndicatorInsets = inset;
    [self.editor scrollRangeToVisible:self.editor.selectedRange];
}
- (void)apply {
    if ([self.editor.text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 64 * 1024) {
        MCMessage(self, @"配置过大", @"配置不能超过 64 KB。");
        return;
    }
    id object =
        [NSJSONSerialization JSONObjectWithData:[self.editor.text dataUsingEncoding:NSUTF8StringEncoding]
                                        options:0
                                          error:nil];
    if (![object isKindOfClass:[NSDictionary class]]) {
        MCMessage(self, @"JSON 无效", @"请输入一个 JSON 对象。检查引号、逗号和括号。");
        return;
    }
    if (self.saved)
        self.saved(object);
    [self.navigationController popViewControllerAnimated:YES];
}
@end

@interface MCSourceAPIController : MCFlatTableController <UITextFieldDelegate>
@property (nonatomic, copy) NSDictionary *entry;
@property (nonatomic, strong) NSMutableDictionary *configuration;
@property (nonatomic, strong) NSArray *fields;
@property (nonatomic) BOOL revealed;
@end
@implementation MCSourceAPIController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.entry ? @"编辑 API" : @"添加 API";
    self.tableView.backgroundView = nil;
    self.tableView.backgroundColor = [MCTheme sharedTheme].background;
    self.tableView.rowHeight = 82;
    self.configuration = [self.entry[@"configuration"] mutableCopy]
                             ?: [@{@"name" : @"", @"url" : @"", @"urlPath" : @""} mutableCopy];
    NSMutableArray *fields = [NSMutableArray array];
    for (NSInteger index = 0; index < 3; index++) {
        UITextField *field = [UITextField new];
        field.delegate = self;
        field.tag = index;
        field.font = [UIFont systemFontOfSize:15];
        field.textColor = [MCTheme sharedTheme].text;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.placeholder =
            @[ @"例如：我的音源", @"https://example.com/music?id={id}", @"可空，例如 data.url" ][index];
        field.returnKeyType = index == 2 ? UIReturnKeyDone : UIReturnKeyNext;
        field.secureTextEntry = index == 1;
        [field addTarget:self action:@selector(fieldChanged:) forControlEvents:UIControlEventEditingChanged];
        [fields addObject:field];
    }
    self.fields = fields;
    [self refreshFields];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"保存"
                                                                              style:UIBarButtonItemStyleDone
                                                                             target:self
                                                                             action:@selector(save)];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(maskSecrets)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
}
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}
- (void)maskSecrets {
    self.revealed = NO;
    ((UITextField *)self.fields[1]).secureTextEntry = YES;
    [self.tableView reloadData];
}
- (void)refreshFields {
    NSArray *keys = @[ @"name", @"url", @"urlPath" ];
    for (NSInteger i = 0; i < 3; i++)
        ((UITextField *)self.fields[i]).text =
            [self.configuration[keys[i]] isKindOfClass:[NSString class]] ? self.configuration[keys[i]] : @"";
}
- (void)fieldChanged:(UITextField *)field {
    self.configuration[@[ @"name", @"url", @"urlPath" ][field.tag]] = field.text ?: @"";
}
- (void)textFieldDidBeginEditing:(UITextField *)field {
    [self.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:field.tag inSection:0]
                          atScrollPosition:UITableViewScrollPositionMiddle
                                  animated:MCMotionEnabled()];
}
- (BOOL)textFieldShouldReturn:(UITextField *)field {
    if (field.tag < 2)
        [self.fields[field.tag + 1] becomeFirstResponder];
    else
        [field resignFirstResponder];
    return YES;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 3 : 2;
}
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)path {
    return path.section == 0 ? 82 : 48;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return section == 0 ? @"默认仅允许 HTTPS；HTTP API 需在音源页关闭“仅允许 HTTPS”。URL 可用 "
                          @"{id}、{quality}、{source}、{title}、{artist}。字段路径留空时自动查找播放地址。"
                        : @"URL 默认遮蔽。高级配置可设置请求方式、请求头和返回字段；其中可能包含密钥。";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = MCSourceCell(UITableViewCellStyleDefault);
    if (path.section == 0) {
        UILabel *label =
            [[UILabel alloc] initWithFrame:CGRectMake(15, 8, tableView.bounds.size.width - 30, 22)];
        label.backgroundColor = [UIColor clearColor];
        label.opaque = NO;
        label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        label.text = @[ @"名称", @"请求 URL 模板", @"音频 URL 字段路径" ][path.row];
        label.font = [UIFont systemFontOfSize:13];
        label.textColor = [MCTheme sharedTheme].muted;
        [cell.contentView addSubview:label];
        UITextField *field = self.fields[path.row];
        field.frame = CGRectMake(15, 31, tableView.bounds.size.width - 30, 44);
        field.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        field.accessibilityLabel = label.text;
        [cell.contentView addSubview:field];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        cell.textLabel.text =
            path.row == 0 ? (self.revealed ? @"隐藏请求 URL" : @"显示请求 URL") : @"高级配置（JSON）";
        cell.accessoryType =
            path.row == 1 ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:MCMotionEnabled()];
    if (path.section != 1)
        return;
    [self.view endEditing:YES];
    if (path.row == 0) {
        self.revealed = !self.revealed;
        ((UITextField *)self.fields[1]).secureTextEntry = !self.revealed;
        [tableView reloadData];
    } else {
        MCSourceJSONController *controller = [MCSourceJSONController new];
        controller.configuration = self.configuration;
        __weak MCSourceAPIController *weakSelf = self;
        controller.saved = ^(NSDictionary *configuration) {
            weakSelf.configuration = [configuration mutableCopy];
            [weakSelf refreshFields];
        };
        [self.navigationController pushViewController:controller animated:YES];
    }
}
- (void)save {
    [self.view endEditing:YES];
    NSError *error = nil;
    NSDictionary *entry = [[MCMusicSources sharedSources] saveAPIConfiguration:self.configuration
                                                                    identifier:self.entry[@"identifier"]
                                                                         error:&error];
    if (!entry) {
        MCMessage(self, @"无法保存", error.localizedDescription ?: @"请检查 API 配置。");
        return;
    }
    [self.navigationController popViewControllerAnimated:YES];
}
@end

@interface MCSourceFilesController : MCFlatTableController
@property (nonatomic, copy) NSArray *files;
@property (nonatomic, copy) void (^picked)(NSString *);
@end
@implementation MCSourceFilesController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择本地脚本";
    self.tableView.rowHeight = 56;
    self.tableView.backgroundView = nil;
    self.tableView.backgroundColor = [MCTheme sharedTheme].background;
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    NSMutableArray *files = [NSMutableArray array];
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:documents error:nil])
        if ([[name.pathExtension lowercaseString] isEqual:@"js"])
            [files addObject:name];
    self.files = [files sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.files.count;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"通过 iTunes 文件共享，将 UTF-8 的 .js 文件放入 Documents 根目录。每个脚本最多 1 MB。";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = MCSourceCell(UITableViewCellStyleDefault);
    cell.textLabel.text = self.files[path.row];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    NSString *name = self.files[path.row];
    [self.navigationController popViewControllerAnimated:YES];
    if (self.picked)
        self.picked(name);
}
@end

@interface MCSourceRepositoryController : MCFlatTableController
@property (nonatomic, copy) NSArray *items;
@end
@implementation MCSourceRepositoryController
- (instancetype)init {
    return [super initWithStyle:UITableViewStyleGrouped];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"仓库音源";
    self.tableView.rowHeight = 68;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reload)
                                                 name:MCSourceRepositoryDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reloadSources)
                                                 name:MCSourceSecurityDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reload)
                                                 name:MCMusicSourcesDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reload)
                                                 name:MCThemeDidChangeNotification
                                               object:nil];
    [self reload];
    if (!self.items.count)
        [[MCSourceRepository sharedRepository] refreshCatalog];
}
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}
- (void)reload {
    MCSourceRepository *repository = [MCSourceRepository sharedRepository];
    self.items = repository.catalog;
    self.tableView.backgroundView = nil;
    self.tableView.backgroundColor = [MCTheme sharedTheme].background;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:repository.busy ? @"取消" : @"刷新"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(refresh)];
    [self.tableView reloadData];
}
- (void)refresh {
    MCSourceRepository *repository = [MCSourceRepository sharedRepository];
    if (repository.busy)
        [repository cancel];
    else
        [repository refreshCatalog];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 1 : self.items.count;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"pdone / lx-music-source" : @"可导入的音源";
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return section == 0 ? @"轻点下面的音源导入或更新。导入后回到音源页手动选择。"
                        : @"仓库脚本来自第三方，请确认来源可信及内容授权；接入不代表软件对其安全性或版权的保证。"
                          @"列表来自 GitHub；离线时保留缓存。当前曲库需要支持网易云 "
                          @"wy，具体源是否可用以实际导入和播放为准。";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = MCSourceCell(UITableViewCellStyleSubtitle);
    MCSourceRepository *repository = [MCSourceRepository sharedRepository];
    if (path.section == 0) {
        cell.textLabel.text = repository.busy ? @"正在处理…" : @"最近同步结果";
        cell.detailTextLabel.text = repository.statusText;
    } else {
        NSDictionary *item = self.items[path.row];
        NSDictionary *entry = [repository entryForPath:item[@"path"]];
        cell.textLabel.text = entry ? MCSourceText(entry[@"name"]) : item[@"name"];
        cell.detailTextLabel.text = [repository statusForItem:item];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.textLabel.enabled = !repository.busy;
    }
    cell.detailTextLabel.numberOfLines = 2;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:MCMotionEnabled()];
    MCSourceRepository *repository = [MCSourceRepository sharedRepository];
    if (path.section == 0) {
        NSMutableString *message = [repository.statusText mutableCopy];
        for (NSString *key in [[repository.errors allKeys] sortedArrayUsingSelector:@selector(compare:)])
            [message appendFormat:@"\n\n%@：%@", key, repository.errors[key]];
        MCMessage(self, @"同步结果", message);
        return;
    }
    if (repository.busy)
        return;
    NSDictionary *item = self.items[path.row];
    NSDictionary *entry = [repository entryForPath:item[@"path"]];
    MCChoose(self, item[@"name"], @[ entry ? @"更新音源" : @"导入音源", @"查看信息" ], ^(NSInteger index) {
        if (index == 0)
            [repository importCatalogItem:item];
        else
            MCMessage(
                self, item[@"name"],
                [NSString
                    stringWithFormat:@"仓库：pdone/lx-music-source\n文件：%@\n大小：%lu KB\n\n%@",
                                     item[@"path"],
                                     (unsigned long)(([item[@"size"] unsignedLongLongValue] + 1023) / 1024),
                                     [repository statusForItem:item]]);
    });
}
@end

@interface MCSourcesController ()
@property (nonatomic, copy) NSArray *entries;
@property (nonatomic, strong) MCSourceTask *importTask;
@property (nonatomic) BOOL importing;
@property (nonatomic) NSUInteger importGeneration;
@end
@implementation MCSourcesController
- (instancetype)init {
    return [super initWithStyle:UITableViewStyleGrouped];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"音源";
    self.tableView.rowHeight = 60;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reloadSources)
                                                 name:MCMusicSourcesDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reloadSources)
                                                 name:MCThemeDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reloadSources)
                                                 name:MCSourceRepositoryDidChangeNotification
                                               object:nil];
    [self reloadSources];
}
- (void)dealloc {
    [self.importTask cancel];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSources];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    NSString *notice = [[MCMusicSources sharedSources] consumeRecoveryNotice];
    if (notice.length)
        MCMessage(self, @"音源已恢复", notice);
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.isMovingFromParentViewController || self.navigationController.isBeingDismissed)
        [self cancelImport];
}
- (void)reloadSources {
    self.entries = [MCMusicSources sharedSources].entries;
    self.tableView.backgroundView = nil;
    self.tableView.backgroundColor = [MCTheme sharedTheme].background;
    [self.tableView reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? (self.importing ? 3 : 2) : section == 1 ? 5 : section == 2 ? self.entries.count : 1;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? nil : section == 1 ? @"音源选项" : section == 2 ? @"播放地址来源" : @"使用说明";
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 3) return nil;
    return section == 0 ? @"导入兼容洛雪协议的脚本，或配置自己的 API。第三方源不代表软件对其版权、安全性或可用性的保证，请仅使用可信且合法的来源。"
           : section == 1
               ? @"自动同步在回到前台时每天检查已订阅源。可选仓库提供的加速下载；目录由 GitHub "
                 @"获取，下载内容仍校验。仅允许 HTTPS 默认开启；关闭后允许自定义音源使用未加密的 "
                 @"HTTP，请重试播放以生效。"
               : @"网易云为默认内置音源，保留原有直连与登录。切换用于下次解析，当前歌曲继续播放。轻"
                 @"点来源可选择或查看信息。";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = MCSourceCell(UITableViewCellStyleSubtitle);
    if (path.section == 3) {
        cell.textLabel.text = @"第三方音源免责声明";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    if (path.section == 0) {
        cell.textLabel.text = path.row == 0   ? @"导入脚本"
                              : path.row == 1 ? @"添加 API"
                                              : @"正在导入…轻点取消";
        if (path.row == 2) {
            UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
                initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
            [spinner startAnimating];
            cell.accessoryView = spinner;
        } else
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.textLabel.enabled = !self.importing || path.row == 2;
    } else if (path.section == 1) {
        MCSourceRepository *repository = [MCSourceRepository sharedRepository];
        if (path.row == 0) {
            cell.textLabel.text = @"仓库音源";
            cell.detailTextLabel.text = @"pdone / lx-music-source";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (path.row == 1) {
            cell.textLabel.text = repository.busy ? @"正在同步…轻点取消" : @"同步仓库音源";
            cell.detailTextLabel.text = repository.statusText;
            cell.detailTextLabel.numberOfLines = 2;
        } else if (path.row == 2) {
            cell.textLabel.text = @"自动同步";
            MCFlatSwitch *toggle = [MCFlatSwitch new];
            toggle.on = repository.autoSyncEnabled;
            toggle.onTintColor = [MCTheme sharedTheme].primary;
            toggle.accessibilityLabel = @"每天回到前台时同步已订阅音源";
            [toggle addTarget:self
                          action:@selector(automaticChanged:)
                forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (path.row == 3) {
            cell.textLabel.text = @"下载方式";
            cell.detailTextLabel.text = [repository.downloadRoute isEqual:@"GitHub"]
                                            ? @"GitHub 官方接口"
                                            : [@"加速 · " stringByAppendingString:repository.downloadRoute];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.textLabel.text = @"仅允许 HTTPS";
            cell.detailTextLabel.text = @"自定义音源的请求与播放地址";
            MCFlatSwitch *toggle = [MCFlatSwitch new];
            toggle.on = MCSourceHTTPSOnly();
            toggle.onTintColor = [MCTheme sharedTheme].primary;
            toggle.accessibilityLabel = @"仅允许 HTTPS，关闭后允许自定义音源使用 HTTP";
            [toggle addTarget:self
                          action:@selector(httpsChanged:)
                forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
    } else {
        NSDictionary *entry = self.entries[path.row];
        cell.textLabel.text = MCSourceText(entry[@"name"]);
        BOOL builtin = [entry[@"kind"] isEqual:@"builtin"];
        cell.detailTextLabel.text =
            builtin ? @"内置 · 网易云直连"
            : [entry[@"kind"] isEqual:@"api"]
                ? @"自定义 API"
                : ([entry[@"selectable"] boolValue] ? @"洛雪脚本 · 支持当前曲库" : @"不可选 · 轻点查看原因");
        cell.accessoryType = [entry[@"identifier"] isEqual:[MCMusicSources sharedSources].selectedIdentifier]
                                 ? UITableViewCellAccessoryCheckmark
                                 : UITableViewCellAccessoryNone;
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:MCMotionEnabled()];
    if (path.section == 3) {
        MCMessage(self, @"第三方音源免责声明", MCSourceDisclaimerText);
        return;
    }
    if (path.section == 1) {
        if (path.row == 0)
            [self.navigationController pushViewController:[MCSourceRepositoryController new] animated:YES];
        else if (path.row == 1) {
            MCSourceRepository *repository = [MCSourceRepository sharedRepository];
            if (repository.busy)
                [repository cancel];
            else
                [repository synchronize];
        } else if (path.row == 3) {
            NSArray *routes = [MCSourceRepository downloadRoutes];
            MCChoose(self, @"选择脚本下载方式", routes, ^(NSInteger index) {
                [MCSourceRepository sharedRepository].downloadRoute = routes[index];
            });
        }
        return;
    }
    if (path.section == 0) {
        if (self.importing) {
            if (path.row == 2)
                [self cancelImport];
            return;
        }
        if (path.row == 1) {
            [self.navigationController
                pushViewController:[[MCSourceAPIController alloc] initWithStyle:UITableViewStyleGrouped]
                          animated:YES];
            return;
        }
        __weak MCSourcesController *weakSelf = self;
        MCChoose(self, @"导入脚本", @[ @"从 Documents 选择", @"从 HTTPS 网址导入" ], ^(NSInteger index) {
            if (index == 0) {
                MCSourceFilesController *files =
                    [[MCSourceFilesController alloc] initWithStyle:UITableViewStyleGrouped];
                files.picked = ^(NSString *name) {
                    [weakSelf importLocal:name];
                };
                [weakSelf.navigationController pushViewController:files animated:YES];
            } else
                MCInput(@"脚本网址", @"输入完整的 HTTPS .js 地址。", @"", ^(NSString *value) {
                    [weakSelf importURL:value];
                });
        });
    } else
        [self actionsForEntry:self.entries[path.row]];
}
- (void)automaticChanged:(MCFlatSwitch *)toggle {
    [MCSourceRepository sharedRepository].autoSyncEnabled = toggle.on;
}
- (void)httpsChanged:(MCFlatSwitch *)toggle {
    MCSetSourceHTTPSOnly(toggle.on);
}
- (void)actionsForEntry:(NSDictionary *)entry {
    BOOL builtin = [entry[@"kind"] isEqual:@"builtin"];
    BOOL api = [entry[@"kind"] isEqual:@"api"];
    NSMutableArray *choices = [NSMutableArray arrayWithObjects:@"设为当前音源", @"查看信息", nil];
    if (api)
        [choices addObject:@"编辑 API"];
    if (!builtin)
        [choices addObject:@"删除音源"];
    __weak MCSourcesController *weakSelf = self;
    MCChoose(self, MCSourceText(entry[@"name"]), choices, ^(NSInteger index) {
        if (index == 0) {
            NSError *error = nil;
            if (![[MCMusicSources sharedSources] selectIdentifier:entry[@"identifier"] error:&error])
                MCMessage(weakSelf, @"无法选择音源",
                          error.localizedDescription ?: MCSourceText(entry[@"reason"]));
        } else if (index == 1)
            [weakSelf showEntry:entry];
        else if (api && index == 2) {
            MCSourceAPIController *editor =
                [[MCSourceAPIController alloc] initWithStyle:UITableViewStyleGrouped];
            editor.entry = entry;
            [weakSelf.navigationController pushViewController:editor animated:YES];
        } else
            MCChoose(weakSelf, @"删除此音源？当前歌曲会继续播放。", @[ @"删除" ], ^(NSInteger ignored) {
                (void)ignored;
                NSError *error = nil;
                if (![[MCMusicSources sharedSources] removeIdentifier:entry[@"identifier"] error:&error])
                    MCMessage(weakSelf, @"无法删除", error.localizedDescription);
            });
    });
}
- (void)showEntry:(NSDictionary *)entry {
    if ([entry[@"kind"] isEqual:@"builtin"]) {
        MCMessage(self, @"网易云", @"内置音源，保留网易云账号权限和原有直连播放接口。此音源不能删除。");
        return;
    }
    if ([entry[@"kind"] isEqual:@"api"]) {
        MCMessage(self, MCSourceText(entry[@"name"]),
                  @"自定义 API。URL 与密钥默认隐藏；可通过“编辑 API”查看或更改配置。");
        return;
    }
    NSDictionary *info = entry[@"information"];
    NSArray *platforms =
        [entry[@"sources"] isKindOfClass:[NSDictionary class]] ? [entry[@"sources"] allKeys] : @[];
    NSString *message = [NSString
        stringWithFormat:@"版本：%@\n作者：%@\n声明平台：%@\n\n%@\n\n%@", MCSourceText(info[@"version"]),
                         MCSourceText(info[@"author"]), [platforms componentsJoinedByString:@"、"],
                         MCSourceText(info[@"description"]),
                         [entry[@"selectable"] boolValue] ? @"支持当前网易云曲库（wy）。"
                                                          : MCSourceText(entry[@"reason"])];
    if (entry[@"subscription"])
        message =
            [message stringByAppendingFormat:@"\n\n仓库订阅：pdone/lx-music-source\n%@\n可自动或手动同步。",
                                             MCSourceText(entry[@"subscription"][@"path"])];
    MCMessage(self, MCSourceText(entry[@"name"]), message);
}
- (void)cancelImport {
    self.importGeneration++;
    [self.importTask cancel];
    self.importTask = nil;
    self.importing = NO;
    [self.tableView reloadData];
}
- (NSUInteger)beginImport {
    self.importing = YES;
    self.importGeneration++;
    [self.tableView reloadData];
    return self.importGeneration;
}
- (void)finished:(NSDictionary *)entry error:(NSError *)error generation:(NSUInteger)generation {
    if (generation != self.importGeneration)
        return;
    self.importTask = nil;
    self.importing = NO;
    [self reloadSources];
    if (error)
        MCMessage(self, @"导入失败", error.localizedDescription ?: @"脚本无法初始化。");
    else if (entry)
        [self showEntry:entry];
}
- (void)importURL:(NSString *)value {
    NSURL *url = [NSURL
        URLWithString:[value
                          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
    if (![url.scheme.lowercaseString isEqual:@"https"] || !url.host.length || url.user || url.password) {
        MCMessage(self, @"网址无效", @"请输入不含用户名与密码的 HTTPS 地址。");
        return;
    }
    NSUInteger generation = [self beginImport];
    __weak MCSourcesController *weakSelf = self;
    MCSourceTask *task =
        [[MCMusicSources sharedSources] importScriptURL:url
                                             completion:^(NSDictionary *entry, NSError *error) {
                                                 [weakSelf finished:entry error:error generation:generation];
                                             }];
    if (self.importing && generation == self.importGeneration)
        self.importTask = task;
}
- (void)importLocal:(NSString *)name {
    NSUInteger generation = [self beginImport];
    __weak MCSourcesController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Only direct children of the canonical Documents directory are accepted.
        // O_NOFOLLOW rejects links; F_GETPATH verifies the actual opened file location.
        // openat is unavailable in the iOS 7 SDK.
        NSString *documents =
            NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
        NSString *script = nil;
        char canonical[PATH_MAX], opened[PATH_MAX];
        NSString *expected = nil;
        int fd = -1;
        struct stat directoryStat;
        BOOL ordinaryDirectory =
            lstat(documents.fileSystemRepresentation, &directoryStat) == 0 && S_ISDIR(directoryStat.st_mode);
        if (ordinaryDirectory && realpath(documents.fileSystemRepresentation, canonical) &&
            [name.lastPathComponent isEqual:name] && [name.pathExtension.lowercaseString isEqual:@"js"]) {
            expected = [[NSString stringWithUTF8String:canonical] stringByAppendingPathComponent:name];
            fd = open(expected.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
        }
        struct stat statbuf;
        BOOL contained = fd >= 0 && fcntl(fd, F_GETPATH, opened) == 0 &&
                         [expected isEqual:[NSString stringWithUTF8String:opened]];
        if (contained && fstat(fd, &statbuf) == 0 && S_ISREG(statbuf.st_mode) && statbuf.st_size > 0 &&
            statbuf.st_size <= 1024 * 1024) {
            NSMutableData *data = [NSMutableData data];
            unsigned char buffer[8192];
            ssize_t count = 0;
            while (data.length <= 1024 * 1024 && (count = read(fd, buffer, sizeof(buffer))) > 0)
                [data appendBytes:buffer length:(NSUInteger)count];
            if (count == 0 && data.length <= 1024 * 1024)
                script = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        }
        if (fd >= 0)
            close(fd);
        dispatch_async(dispatch_get_main_queue(), ^{
            MCSourcesController *controller = weakSelf;
            if (!controller || controller.importGeneration != generation)
                return;
            if (!script) {
                NSError *error = [NSError
                    errorWithDomain:@"MCSourcesUI"
                               code:1
                           userInfo:@{
                               NSLocalizedDescriptionKey :
                                   @"请选择 Documents 中的普通 UTF-8 .js 文件（1 MB 以内）。不支持符号链接。"
                           }];
                [controller finished:nil error:error generation:generation];
                return;
            }
            MCSourceTask *task = [[MCMusicSources sharedSources]
                importScript:script
                      origin:@"local"
                  completion:^(NSDictionary *entry, NSError *error) {
                      [weakSelf finished:entry error:error generation:generation];
                  }];
            if (controller.importing && controller.importGeneration == generation)
                controller.importTask = task;
        });
    });
}
@end
