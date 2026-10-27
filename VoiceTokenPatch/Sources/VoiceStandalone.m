#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

/// Fish Audio standalone workspace V4.
/// This library does NOT call any author's auth, synthesis or quota service.
/// It does NOT pretend to have integrated an undocumented Douyin voice-message sender.
static NSString *const VTKey = @"vtpatch.token.fish";
static NSString *const VTVoiceStore = @"vtpatch.v4.voices";
static NSString *const VTPreviousVoices = @"vtpatch.shared.voices";
static NSString *const VTFirstLaunch = @"vtpatch.v4.welcome";
static NSString *const VTSelected = @"vtpatch.v4.selected";
static UIWindow *VTPanelWindow = nil;
static __weak UIWindow *VTPreviousWindow = nil;
static NSTimeInterval VTLastShake = 0;

static NSUserDefaults *Prefs(void) { return NSUserDefaults.standardUserDefaults; }
static NSString *Trim(id value) {
    if (![value isKindOfClass:NSString.class]) return @"";
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}
static NSString *OfficialKey(void) {
    NSString *key = Trim([Prefs() stringForKey:VTKey]);
    if ([key.lowercaseString hasPrefix:@"bearer "]) key = Trim([key substringFromIndex:7]);
    return [key rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location == NSNotFound ? key : @"";
}
static NSArray<NSDictionary *> *Voices(void) {
    id raw = [Prefs() objectForKey:VTVoiceStore];
    return [raw isKindOfClass:NSArray.class] ? raw : @[];
}
static void SaveVoices(NSArray *voices) { [Prefs() setObject:voices forKey:VTVoiceStore]; }
static void MigrateVoices(void) {
    if ([Prefs() objectForKey:VTVoiceStore]) return;
    NSMutableArray *all = [NSMutableArray array];
    for (id item in [Prefs() arrayForKey:VTPreviousVoices] ?: @[]) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *name = Trim(item[@"name"]);
        NSString *ref = Trim(item[@"fishID"]).length ? Trim(item[@"fishID"]) : Trim(item[@"id"]);
        if (name.length && ref.length) [all addObject:@{@"name": name, @"id":ref}];
    }
    // A public voice reference from the official Fish Audio developer documentation.
    // No network or usage charges until the user actually requests generation.
    if (!all.count) [all addObject:@{@"name": @"Fish 官方文档示例音色", @"id": @"7f92f8afb8ec43bf81429cc1c9199cb1"}];
    SaveVoices(all);
    if (![Prefs() stringForKey:VTSelected]) [Prefs() setObject:all.firstObject[@"id"] ?: @"" forKey:VTSelected];
}
static void Alert(UIViewController *vc, NSString *title, NSString *message) {
    if (!vc || vc.presentedViewController) return;
    UIAlertController *panel = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [panel addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [vc presentViewController:panel animated:YES completion:nil];
}
static UILabel *Label(NSString *value, CGFloat size, BOOL bold) {
    UILabel *label = [UILabel new];
    label.text = value;
    label.numberOfLines = 0;
    label.font = bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
    label.textColor = UIColor.labelColor;
    return label;
}
static UIButton *Button(NSString *value, id target, SEL action) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:value forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    button.titleLabel.numberOfLines = 0;
    button.contentEdgeInsets = UIEdgeInsetsMake(8, 12, 8, 12);
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    return button;
}
static void DismissPanel(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ DismissPanel(); }); return; }
    UIWindow *previous = VTPreviousWindow;
    VTPanelWindow.hidden = YES;
    VTPanelWindow.rootViewController = nil;
    VTPanelWindow = nil;
    if (previous && !previous.hidden) [previous makeKeyWindow];
    VTPreviousWindow = nil;
}

@interface VTFishWorkspace : UIViewController <AVAudioPlayerDelegate>
@property(nonatomic,strong) UITextField *tokenField;
@property(nonatomic,strong) UITextView *textField;
@property(nonatomic,strong) UIStackView *voiceStack;
@property(nonatomic,strong) UILabel *selectedLabel;
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) UIButton *generateButton;
@property(nonatomic,strong) UIButton *playButton;
@property(nonatomic,strong) UIButton *shareButton;
@property(nonatomic,strong) NSURL *audioURL;
@property(nonatomic,strong) AVAudioPlayer *player;
@property(nonatomic,strong) NSURLSessionDataTask *activeTask;
@end

@implementation VTFishWorkspace
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40]
    ]];
    [stack addArrangedSubview:Label(@"Fish 官方独立语音工作台 · V4", 21, YES)];
    [stack addArrangedSubview:Label(@"独立调用 api.fish.audio。不调用作者 Token、授权、合成服务器或额度接口。摇一摇可重新打开。", 13, NO)];
    [stack addArrangedSubview:Label(@"① 官方 Fish Audio API Key", 16, YES)];
    UITextField *key = [UITextField new];
    key.text = [Prefs() stringForKey:VTKey] ?: @"";
    key.placeholder = @"只填写 Fish 官方 API Key";
    key.secureTextEntry = YES;
    key.clearButtonMode = UITextFieldViewModeWhileEditing;
    key.borderStyle = UITextBorderStyleRoundedRect;
    key.autocorrectionType = UITextAutocorrectionTypeNo;
    key.autocapitalizationType = UITextAutocapitalizationTypeNone;
    [key.heightAnchor constraintEqualToConstant:44].active = YES;
    self.tokenField = key;
    [stack addArrangedSubview:key];
    [stack addArrangedSubview:Button(@"保存 / 清空官方 Key", self, @selector(saveKey))];
    [stack addArrangedSubview:Button(@"显示 / 隐藏 Key", self, @selector(toggleKey))];
    [stack addArrangedSubview:Label(@"② 选择 Fish 官方音色 reference_id", 16, YES)];
    self.selectedLabel = Label(@"", 13, NO);
    [stack addArrangedSubview:self.selectedLabel];
    self.voiceStack = [UIStackView new];
    self.voiceStack.axis = UILayoutConstraintAxisVertical;
    self.voiceStack.spacing = 7;
    [stack addArrangedSubview:self.voiceStack];
    [self refreshVoices];
    [stack addArrangedSubview:Button(@"+ 添加 Fish 音色 ID / 名称", self, @selector(addVoice))];
    [stack addArrangedSubview:Label(@"旧版本地音色会尝试迁移。作者私有音色不能凭名称或 ID 复制，必须使用你的官方账户有权限访问的 reference_id。", 12, NO)];
    [stack addArrangedSubview:Label(@"③ 输入要合成的文本", 16, YES)];
    UITextView *textView = [UITextView new];
    textView.font = [UIFont systemFontOfSize:16];
    textView.backgroundColor = UIColor.secondarySystemBackgroundColor;
    textView.layer.cornerRadius = 10;
    textView.text = @"你好，这是一条使用 Fish Audio 官方接口生成的语音。";
    textView.scrollEnabled = YES;
    [textView.heightAnchor constraintEqualToConstant:106].active = YES;
    self.textField = textView;
    [stack addArrangedSubview:textView];
    [stack addArrangedSubview:Button(@"开始官方语音合成（会消耗官方额度）", self, @selector(generate))];
    self.statusLabel = Label(@"准备就绪：仅调用 Fish 官方接口", 13, NO);
    [stack addArrangedSubview:self.statusLabel];
    self.generateButton = stack.arrangedSubviews.lastObject == self.statusLabel ? (UIButton *)stack.arrangedSubviews[stack.arrangedSubviews.count - 2] : nil;
    self.playButton = Button(@"▶ 试听已生成语音", self, @selector(play));
    self.playButton.enabled = NO;
    [stack addArrangedSubview:self.playButton];
    self.shareButton = Button(@"分享 / 保存音频文件", self, @selector(shareAudio));
    self.shareButton.enabled = NO;
    [stack addArrangedSubview:self.shareButton];
    [stack addArrangedSubview:Label(@"注意：音频分享由 iOS 分享菜单处理；不等于自动发送成抖音私聊的原生语音气泡。原插件的作者授权按钮仍由原插件管理。", 12, NO)];
    [stack addArrangedSubview:Button(@"查看技术诊断", self, @selector(diagnostics))];
    [stack addArrangedSubview:Button(@"关闭独立工作台", self, @selector(closePanel))];
}
- (void)saveKey {
    [Prefs() setObject:Trim(self.tokenField.text) forKey:VTKey];
    [self.view endEditing:YES];
    Alert(self, @"已保存", @"仅供 Fish 官方直连接口使用。官方 Key 目前保存在本机 NSUserDefaults；不要把 Key 粘贴到作者授权窗口。");
}
- (void)toggleKey { self.tokenField.secureTextEntry = !self.tokenField.secureTextEntry; }
- (void)refreshVoices {
    for (UIView *v in self.voiceStack.arrangedSubviews.copy) {
        [self.voiceStack removeArrangedSubview:v]; [v removeFromSuperview];
    }
    NSString *selected = [Prefs() stringForKey:VTSelected] ?: @"";
    self.selectedLabel.text = [NSString stringWithFormat:@"当前 reference_id：%@", selected.length ? selected : @"（未选择）"];
    for (id candidate in Voices()) {
        if (![candidate isKindOfClass:NSDictionary.class]) continue;
        NSString *ref = Trim(candidate[@"id"]);
        NSString *name = Trim(candidate[@"name"]);
        if (!ref.length) continue;
        UIStackView *line = [UIStackView new];
        line.axis = UILayoutConstraintAxisHorizontal;
        line.spacing = 6;
        [line setAlignment:UIStackViewAlignmentCenter];
        UILabel *lab = Label([NSString stringWithFormat:@"%@%@\n%@", [selected isEqualToString:ref] ? @"✓ " : @"", name, ref], 12, NO);
        [lab setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        [line addArrangedSubview:lab];
        UIButton *select = Button(@"选用", self, @selector(selectVoice:));
        select.accessibilityIdentifier = ref;
        [line addArrangedSubview:select];
        UIButton *remove = Button(@"删除", self, @selector(removeVoice:));
        remove.accessibilityIdentifier = ref;
        [line addArrangedSubview:remove];
        [self.voiceStack addArrangedSubview:line];
    }
}
- (void)selectVoice:(UIButton *)button {
    [Prefs() setObject:Trim(button.accessibilityIdentifier) forKey:VTSelected];
    [self refreshVoices];
}
- (void)removeVoice:(UIButton *)button {
    NSString *identifier = Trim(button.accessibilityIdentifier);
    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *v in Voices()) if (![Trim(v[@"id"]) isEqualToString:identifier]) [items addObject:v];
    SaveVoices(items);
    if ([[Prefs() stringForKey:VTSelected] isEqualToString:identifier]) {
        [Prefs() setObject:items.count ? items.firstObject[@"id"] : @"" forKey:VTSelected];
    }
    [self refreshVoices];
}
- (void)addVoice {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"添加官方音色"
                                                                   message:@"必须填你的 Fish 官方账户可访问的 reference_id"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = @"音色名称"; }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = @"Fish reference_id"; f.autocapitalizationType = UITextAutocapitalizationTypeNone; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *name = Trim(alert.textFields[0].text), *ref = Trim(alert.textFields[1].text);
        if (!name.length || !ref.length) { Alert(weakSelf, @"无效输入", @"名称和 reference_id 均不能为空。"); return; }
        NSMutableArray *all = [Voices() mutableCopy];
        for (NSDictionary *v in all) if ([v[@"id"] isEqualToString:ref]) { Alert(weakSelf, @"重复", @"该 reference_id 已存在。"); return; }
        [all addObject:@{@"name":name,@"id":ref}];
        SaveVoices(all);
        [Prefs() setObject:ref forKey:VTSelected];
        [weakSelf refreshVoices];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)setBusy:(BOOL)busy {
    self.generateButton.enabled = !busy;
    self.statusLabel.text = busy ? @"正在请求 Fish 官方服务器…" : self.statusLabel.text;
}
- (void)generate {
    NSString *token = Trim(self.tokenField.text);
    if ([token.lowercaseString hasPrefix:@"bearer "]) token = Trim([token substringFromIndex:7]);
    if (!token.length || [token rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound) {
        Alert(self, @"缺少官方 Key", @"请在上方填写有效的 Fish Audio 官方 API Key。"); return;
    }
    NSString *reference = Trim([Prefs() stringForKey:VTSelected]);
    if (!reference.length) { Alert(self, @"没有音色", @"请先选用官方音色 reference_id。"); return; }
    NSString *spoken = Trim(self.textField.text);
    if (spoken.length < 1 || spoken.length > 2000) {
        Alert(self, @"文本长度不合适", @"请填写 1—2000 字符，短文本更适合先验证官方用量。"); return;
    }
    [Prefs() setObject:token forKey:VTKey];
    [self.view endEditing:YES];
    self.audioURL = nil;
    self.playButton.enabled = NO; self.shareButton.enabled = NO;
    [self.player stop]; self.player = nil;
    NSError *jsonError = nil;
    NSData *payload = [NSJSONSerialization dataWithJSONObject:@{@"text":spoken,@"reference_id":reference,@"format":@"mp3"}
                                                      options:0 error:&jsonError];
    if (!payload) { Alert(self, @"构造请求失败", jsonError.localizedDescription); return; }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://api.fish.audio/v1/tts"]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = payload;
    request.timeoutInterval = 90;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"s2.1-pro" forHTTPHeaderField:@"model"];
    [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [self setBusy:YES];
    self.statusLabel.text = @"正在调用 api.fish.audio/v1/tts（只扣官方账号可计费用量）";
    __weak typeof(self) weakSelf = self;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    self.activeTask = [session dataTaskWithRequest:request completionHandler:^(NSData *bytes, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf setBusy:NO];
            strongSelf.activeTask = nil;
            if (error) {
                strongSelf.statusLabel.text = [NSString stringWithFormat:@"官方请求失败：%@", error.localizedDescription];
                return;
            }
            NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
            if (http.statusCode < 200 || http.statusCode >= 300) {
                strongSelf.statusLabel.text = [NSString stringWithFormat:@"Fish 官方 HTTP %ld。检查官方 Key、音色权限及额度。未请求作者服务器。", (long)http.statusCode];
                return;
            }
            NSString *mime = response.MIMEType.lowercaseString ?: @"";
            if (!bytes.length || bytes.length > 30 * 1024 * 1024 || [mime containsString:@"json"] || [mime containsString:@"text/"]) {
                strongSelf.statusLabel.text = @"Fish 返回空数据或非预期音频，已停止。";
                return;
            }
            NSURL *folder = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"VoiceTokenPatch"] isDirectory:YES];
            NSError *saveError = nil;
            [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:&saveError];
            if (saveError) { strongSelf.statusLabel.text = saveError.localizedDescription; return; }
            NSURL *file = [folder URLByAppendingPathComponent:[[NSUUID.UUID.UUIDString stringByAppendingString:@".mp3"] copy]];
            if (![bytes writeToURL:file options:NSDataWritingAtomic error:&saveError]) {
                strongSelf.statusLabel.text = saveError.localizedDescription; return;
            }
            strongSelf.audioURL = file;
            strongSelf.playButton.enabled = YES;
            strongSelf.shareButton.enabled = YES;
            strongSelf.statusLabel.text = [NSString stringWithFormat:@"Fish 官方合成成功：%lu KB。可试听或分享音频。", (unsigned long)(bytes.length / 1024)];
        });
        [session finishTasksAndInvalidate];
    }];
    [self.activeTask resume];
}
- (void)play {
    if (!self.audioURL) return;
    if (self.player.isPlaying) { [self.player stop]; [self.playButton setTitle:@"▶ 试听已生成语音" forState:UIControlStateNormal]; return; }
    NSError *error = nil;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:NULL];
    [[AVAudioSession sharedInstance] setActive:YES error:NULL];
    self.player = [[AVAudioPlayer alloc] initWithContentsOfURL:self.audioURL error:&error];
    self.player.delegate = self;
    if (!self.player || ![self.player play]) {
        Alert(self, @"播放失败", error.localizedDescription ?: @"设备当前无法解码此音频。");
        return;
    }
    [self.playButton setTitle:@"■ 停止试听" forState:UIControlStateNormal];
}
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    [self.playButton setTitle:@"▶ 试听已生成语音" forState:UIControlStateNormal];
}
- (void)shareAudio {
    if (!self.audioURL) return;
    UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[self.audioURL] applicationActivities:nil];
    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) { popover.sourceView = self.shareButton; popover.sourceRect = self.shareButton.bounds; }
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)diagnostics {
    NSString *report = [NSString stringWithFormat:
                        @"音频合成：完全独立 HTTP 请求\n目标服务器：api.fish.audio\n作者 Token 验证：不调用\n作者额度接口：不调用\n原插件授权弹窗：不修改\n官方 Key：%@\n已选音色：%@\n音频文件：%@\n\n原生抖音私聊语音发送：尚未集成，不能通过分享菜单保证发送为语音气泡。",
                        OfficialKey().length ? @"已配置" : @"未配置",
                        [Prefs() stringForKey:VTSelected] ?: @"",
                        self.audioURL ? @"已生成" : @"未生成"];
    Alert(self, @"工作台技术诊断", report);
}
- (void)closePanel {
    [self.player stop];
    [self.activeTask cancel];
    [Prefs() setObject:Trim(self.tokenField.text) forKey:VTKey];
    DismissPanel();
}
@end

static void ShowWorkspace(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ ShowWorkspace(); }); return; }
    if (VTPanelWindow || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    UIWindowScene *active = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        if (scene.activationState == UISceneActivationStateForegroundActive) { active = (UIWindowScene *)scene; break; }
    }
    if (!active) return;
    for (UIWindow *window in active.windows) if (window.isKeyWindow) { VTPreviousWindow = window; break; }
    VTPanelWindow = [[UIWindow alloc] initWithWindowScene:active];
    VTPanelWindow.windowLevel = UIWindowLevelAlert + 12;
    VTPanelWindow.rootViewController = [VTFishWorkspace new];
    [VTPanelWindow makeKeyAndVisible];
    if (![Prefs() boolForKey:VTFirstLaunch]) {
        [Prefs() setBool:YES forKey:VTFirstLaunch];
        dispatch_async(dispatch_get_main_queue(), ^{
            Alert(VTPanelWindow.rootViewController, @"Fish 官方独立工作台已启动",
                  @"这个工作台绕开了原插件的操作流程，不需要填写作者 Token。可自行合成、试听和分享语音，但抖音原生私聊语音气泡发送尚未对接。");
        });
    }
}
@interface UIApplication (VTFishV4Shake)
- (void)vtv4_sendEvent:(UIEvent *)event;
@end
@implementation UIApplication (VTFishV4Shake)
- (void)vtv4_sendEvent:(UIEvent *)event {
    [self vtv4_sendEvent:event];
    if (event.type != UIEventTypeMotion || event.subtype != UIEventSubtypeMotionShake) return;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (now - VTLastShake < 1.5) return;
    VTLastShake = now;
    ShowWorkspace();
}
@end
__attribute__((constructor)) static void SetupV4(void) {
    @autoreleasepool {
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
        NSString *executable = NSBundle.mainBundle.infoDictionary[@"CFBundleExecutable"];
        if (![bundle isEqualToString:@"com.ss.iphone.ugc.Aweme"] && ![executable isEqualToString:@"Aweme"]) return;
        MigrateVoices();
        Method original = class_getInstanceMethod(UIApplication.class, @selector(sendEvent:));
        Method replacement = class_getInstanceMethod(UIApplication.class, @selector(vtv4_sendEvent:));
        if (original && replacement) method_exchangeImplementations(original, replacement);
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            if (![Prefs() boolForKey:VTFirstLaunch]) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ ShowWorkspace(); });
            }
        }];
    }
}
