#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

/// Fish-only patch for the user-provided voicetool v1.2 binary.
/// It intentionally has no call-through to the original TTS implementation.
static NSString *const kFishKey = @"vtpatch.token.fish";       // Reuse V2 saved official key.
static NSString *const kVoices = @"vtpatch.shared.voices";    // Reuse V2 saved ID mappings.
static NSString *const kWelcome = @"vtpatch.v3.welcome";
static NSString *const kDomain = @"VoiceTokenPatch.Fish";
static NSString *VTStatus = @"正在检测原插件入口";
static BOOL VTBridgeInstalled = NO;
static BOOL VTAuthInstalled = NO;
static __weak id VTOriginalController;
static NSURL *VTLastAudioURL;
static void VTShowSettings(void);
static UIWindow *VTOverlay;
static __weak UIWindow *VTPreviousKey;
static NSTimeInterval VTLastShake;

static NSUserDefaults *VTDefaults(void) { return NSUserDefaults.standardUserDefaults; }
static NSString *VTTrim(NSString *str) {
    if (![str isKindOfClass:NSString.class]) return @"";
    return [str stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}
static NSString *VTKey(void) {
    NSString *value = VTTrim([VTDefaults() stringForKey:kFishKey]);
    if ([value.lowercaseString hasPrefix:@"bearer "]) value = VTTrim([value substringFromIndex:7]);
    if ([value rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound) return @"";
    return value;
}
static NSArray<NSDictionary *> *VTVoices(void) {
    id raw = [VTDefaults() objectForKey:kVoices];
    return [raw isKindOfClass:NSArray.class] ? raw : @[];
}
static void VTSaveVoices(NSArray *voices) { [VTDefaults() setObject:voices forKey:kVoices]; }
static NSString *VTReferenceID(NSString *voiceID) {
    for (NSDictionary *voice in VTVoices()) {
        if (![voice isKindOfClass:NSDictionary.class]) continue;
        if ([voice[@"id"] isKindOfClass:NSString.class] && [voice[@"id"] isEqualToString:voiceID]) {
            NSString *fishID = VTTrim(voice[@"fishID"]);
            if (fishID.length) return fishID;
        }
    }
    return voiceID;
}
static void VTSetStatus(NSString *value) { @synchronized (VTDefaults()) { VTStatus = [value copy]; } }
static NSString *VTGetStatus(void) { @synchronized (VTDefaults()) { return [VTStatus copy]; } }
static NSError *VTError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:kDomain code:code userInfo:@{NSLocalizedDescriptionKey:message ?: @"未知错误"}];
}

/// Uses the official Fish Audio hosted API; never sends requests to the author's host.
static NSData *VTOfficialTTS(NSString *text, NSString *voiceID, NSError **error) {
    NSString *key = VTKey();
    if (!key.length) {
        if (error) *error = VTError(1001, @"请先填写 Fish Audio 官方 API Token。已阻止合成，不会回退作者接口。");
        return nil;
    }
    if (![text isKindOfClass:NSString.class] || !VTTrim(text).length) {
        if (error) *error = VTError(1002, @"未收到有效合成文字。");
        return nil;
    }
    if (![voiceID isKindOfClass:NSString.class] || !VTTrim(voiceID).length) {
        if (error) *error = VTError(1003, @"没有有效音色 ID / reference_id。");
        return nil;
    }
    NSString *referenceID = VTReferenceID(VTTrim(voiceID));
    NSDictionary *body = @{@"text": text, @"reference_id":referenceID, @"format":@"wav"};
    NSError *jsonError = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonError];
    if (!json) { if (error) *error = jsonError; return nil; }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://api.fish.audio/v1/tts"]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = json;
    request.timeoutInterval = 65.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"s2.1-pro" forHTTPHeaderField:@"model"];
    // Do not log keys, text, or audio. The reply is assumed to be raw audio NSData.
    __block NSData *audio;
    __block NSURLResponse *reply;
    __block NSError *networkError;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSURLSession *session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *err) {
        audio = data;
        reply = response;
        networkError = err;
        dispatch_semaphore_signal(done);
    }];
    [task resume];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 70 * NSEC_PER_SEC)) != 0) {
        [task cancel];
        [session invalidateAndCancel];
        if (error) *error = VTError(1004, @"Fish 官方接口超时，未调用作者接口。");
        return nil;
    }
    [session finishTasksAndInvalidate];
    if (networkError) { if (error) *error = networkError; return nil; }
    NSInteger status = [reply isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)reply statusCode] : 0;
    if (status < 200 || status >= 300) {
        // Deliberately do not echo the response body (might contain private details).
        if (error) *error = VTError(status ?: 1005, [NSString stringWithFormat:@"Fish 官方接口 HTTP %ld；未调用作者接口。检查 Token、音色 ID 和官方额度。", (long)status]);
        return nil;
    }
    NSString *mime = reply.MIMEType.lowercaseString ?: @"";
    if ([mime containsString:@"json"]) {
        if (error) *error = VTError(1006, @"Fish 返回了 JSON 而非音频，已停止。");
        return nil;
    }
    if (!audio.length) {
        if (error) *error = VTError(1007, @"Fish 返回空音频。");
        return nil;
    }
    return audio;
}

/// Exact instance selector from the supplied arm64e image. The ABI has six
/// parameters after self/_cmd: five objects plus NSError**.
static id VTBridgeTTS(id self, SEL cmd, id text, id authorToken,
                      id voiceID, id endpoint, id options, NSError **error) {
    (void)self; (void)cmd; (void)authorToken; (void)endpoint; (void)options;
    VTSetStatus(@"本次合成：直连 api.fish.audio/v1/tts");
    if (error) *error = nil;
    if (![text isKindOfClass:NSString.class] || ![voiceID isKindOfClass:NSString.class]) {
        VTSetStatus(@"已阻止：原插件输入格式不符合预期");
        if (error) *error = VTError(1008, @"原插件文本或音色不是字符串；已阻止合成。");
        return nil;
    }
    NSError *failure = nil;
    NSData *audio = VTOfficialTTS(text, voiceID, &failure);
    if (!audio.length) {
        VTSetStatus([@"Fish 官方失败： " stringByAppendingString:failure.localizedDescription ?: @"未知错误"]);
        if (error) *error = failure;
        return nil; // Fail closed. No call-through to author's method.
    }
    VTSetStatus([NSString stringWithFormat:@"Fish 官方已返回音频 %lu 字节（原插件解析仍需实机验证）", (unsigned long)audio.length]);
    return audio;
}

/* The original plugin's auth is separate from Fish billing. Replace its login
   prompt with OUR own authorized-only-by-Fish operation panel: no fake author
   license, no transmission of Fish API key to author's service. */
static void VTInterceptAuth(id self, SEL cmd, BOOL force) {
    (void)cmd; (void)force;
    VTOriginalController = self;
    dispatch_async(dispatch_get_main_queue(), ^{ VTShowSettings(); });
}
static void VTInstallBridge(void) {
    @synchronized (VTDefaults()) {
        Class fish = objc_getClass("ZyyFishAudioConfiguration");
        SEL ttsSel = NSSelectorFromString(@"requestForText:token:voiceID:endpoint:options:error:");
        if (!VTBridgeInstalled && fish) {
            /* Analysis of the arm64e original proves this belongs to the
               metaclass. V3 incorrectly used class_getInstanceMethod. */
            Method method = class_getClassMethod(fish, ttsSel);
            if (method) {
                char type[16] = {0};
                method_getReturnType(method, type, sizeof(type));
                BOOL matches = type[0] == '@' && method_getNumberOfArguments(method) == 8;
                for (unsigned i=2; matches && i<=6; ++i) {
                    method_getArgumentType(method, i, type, sizeof(type));
                    matches = type[0]=='@';
                }
                if (matches) {
                    method_getArgumentType(method, 7, type, sizeof(type));
                    matches = type[0]=='^' && type[1]=='@';
                }
                if (matches) {
                    method_setImplementation(method, (IMP)VTBridgeTTS);
                    VTBridgeInstalled = YES;
                }
            }
        }
        /* Independently redirect author's prompt instead of forging a token. */
        Class controller = objc_getClass("AllVoiceController");
        if (!VTAuthInstalled && controller) {
            Method auth = class_getInstanceMethod(controller, @selector(presentAuth:));
            if (auth) {
                char type[16]={0};
                method_getReturnType(auth,type,sizeof(type));
                if (type[0]=='v' && method_getNumberOfArguments(auth)==3) {
                    method_getArgumentType(auth,2,type,sizeof(type));
                    if (type[0]=='B' || type[0]=='c') {
                        method_setImplementation(auth,(IMP)VTInterceptAuth);
                        VTAuthInstalled = YES;
                    }
                }
            }
        }
        VTStatus = [NSString stringWithFormat:
            @"Fish TTS 类方法 %@\n作者授权弹窗独立替换 %@\n注意：原作者其他私有请求未被证明全被截获。",
            VTBridgeInstalled ? @"已接管" : @"未找到",
            VTAuthInstalled ? @"已接管" : @"未找到"];
    }
}
static UILabel *VTLabel(NSString *text, CGFloat size) {
    UILabel *label = [UILabel new];
    label.text = text;
    label.numberOfLines = 0;
    label.font = [UIFont systemFontOfSize:size];
    label.textColor = UIColor.labelColor;
    return label;
}
static UIButton *VTButton(NSString *title, id target, SEL action) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:42].active = YES;
    return button;
}
static void VTMessage(UIViewController *vc, NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [vc presentViewController:alert animated:YES completion:nil];
}
static void VTClose(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ VTClose(); }); return; }
    UIWindow *last = VTPreviousKey;
    VTOverlay.hidden = YES;
    VTOverlay.rootViewController = nil;
    VTOverlay = nil;
    if (last && !last.isHidden) [last makeKeyWindow];
    VTPreviousKey = nil;
}
@interface VTFishPanel : UIViewController
@property (nonatomic, strong) UITextField *keyField;
@property (nonatomic, strong) UITextView *composerField;
@property (nonatomic, strong) UITextField *composerVoice;
@property (nonatomic, strong) UIButton *generateButton;
@property (nonatomic, strong) UIStackView *voices;
@end
@implementation VTFishPanel
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
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
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:22],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-22],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40]
    ]];
    [stack addArrangedSubview:VTLabel(@"Fish Audio 官方专用 · V3", 22)];
    [stack addArrangedSubview:VTLabel(@"只接管已识别的原插件语音合成入口。不会改动作者的语音工具自定义页面。官方请求失败不回退作者接口；其他未识别的网络路径仍需实机验证。", 12)];
    [stack addArrangedSubview:VTLabel(@"Fish Audio 官方 API Token", 16)];
    UITextField *field = [UITextField new];
    field.placeholder = @"输入 Fish 官方 API Key";
    field.text = [VTDefaults() stringForKey:kFishKey] ?: @"";
    field.secureTextEntry = YES;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.borderStyle = UITextBorderStyleRoundedRect;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    [field.heightAnchor constraintEqualToConstant:46].active = YES;
    self.keyField = field;
    [stack addArrangedSubview:field];
    [stack addArrangedSubview:VTButton(@"保存官方 Token（清空也会保存）", self, @selector(saveKey))];
    [stack addArrangedSubview:VTButton(@"显示 / 隐藏 Token", self, @selector(showKey))];
    [stack addArrangedSubview:VTButton(@"查看当前合成入口状态", self, @selector(showStatus))];
    [stack addArrangedSubview:VTLabel(@"官方独立合成 / 抖音语音发送", 19)];
    [stack addArrangedSubview:VTLabel(@"无需作者 Token。输入文字和 Fish 官方 reference_id，点击生成并尝试通过原插件发送模块发送。发送模块属于原插件，兼容性待真机验证。", 12)];
    UITextView *composer = [UITextView new];
    composer.font = [UIFont systemFontOfSize:16];
    composer.layer.borderColor = UIColor.separatorColor.CGColor;
    composer.layer.borderWidth = 1;
    composer.layer.cornerRadius = 9;
    [composer.heightAnchor constraintEqualToConstant:115].active = YES;
    self.composerField = composer;
    id controller = VTOriginalController;
    if (!controller) {
        Class ctrlClass = objc_getClass("AllVoiceController");
        if ([ctrlClass respondsToSelector:@selector(shared)])
            controller = ((id (*)(id,SEL))objc_msgSend)(ctrlClass,@selector(shared));
    }
    if ([controller respondsToSelector:@selector(sourceText)]) {
        id originalText = ((id (*)(id,SEL))objc_msgSend)(controller,@selector(sourceText));
        if ([originalText isKindOfClass:NSString.class]) composer.text = originalText;
    }
    [stack addArrangedSubview:composer];
    UITextField *voiceField = [UITextField new];
    voiceField.borderStyle = UITextBorderStyleRoundedRect;
    voiceField.placeholder = @"Fish 官方 reference_id / 原作者音色 ID";
    voiceField.autocorrectionType = UITextAutocorrectionTypeNo;
    voiceField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    if ([controller respondsToSelector:@selector(defaultVoice)]) {
        id originalVoice = ((id (*)(id,SEL))objc_msgSend)(controller,@selector(defaultVoice));
        if ([originalVoice isKindOfClass:NSString.class]) voiceField.text = originalVoice;
    }
    if (!voiceField.text.length) {
        NSDictionary *first = VTVoices().firstObject;
        if ([first isKindOfClass:NSDictionary.class]) voiceField.text = first[@"id"];
    }
    self.composerVoice = voiceField;
    [stack addArrangedSubview:voiceField];
    UIButton *generate = VTButton(@"使用官方额度合成并发送", self, @selector(generateAndSend));
    self.generateButton = generate;
    [stack addArrangedSubview:generate];
    [stack addArrangedSubview:VTButton(@"分享最近生成的音频文件", self, @selector(shareLatestAudio))];
    [stack addArrangedSubview:VTLabel(@"音色 ID 映射（保留 V2 已保存的本地列表）", 16)];
    [stack addArrangedSubview:VTLabel(@"下方条目不会自动添加到原作者的自绘选择器；原作者选中的 ID 必须与这里记录的 ID 一致。私有音色需要 Fish 官方调用权限。", 12)];
    self.voices = [UIStackView new];
    self.voices.axis = UILayoutConstraintAxisVertical;
    self.voices.spacing = 8;
    [stack addArrangedSubview:self.voices];
    [self refreshVoices];
    [stack addArrangedSubview:VTButton(@"+ 添加作者音色 ID / 官方 reference_id 映射", self, @selector(addVoice))];
    [stack addArrangedSubview:VTButton(@"关闭设置（摇一摇重新打开）", self, @selector(closePanel))];
}

/* WAV duration calculator: no AVFoundation dependency. */
static double VTDurationWAV(NSData *audio) {
    const unsigned char *p = audio.bytes;
    NSUInteger length = audio.length;
    if (length < 44 || memcmp(p,"RIFF",4)!=0 || memcmp(p+8,"WAVE",4)!=0) return 0;
    uint32_t byteRate = 0, payload = 0;
    for (NSUInteger pos=12; pos+8 <= length;) {
        uint32_t chunkLen = (uint32_t)p[pos+4] | ((uint32_t)p[pos+5]<<8) |
             ((uint32_t)p[pos+6]<<16) | ((uint32_t)p[pos+7]<<24);
        NSUInteger next = pos + 8 + chunkLen + (chunkLen & 1);
        if (next > length) break;
        if (!memcmp(p+pos,"fmt ",4) && chunkLen>=16) {
            byteRate = (uint32_t)p[pos+16] | ((uint32_t)p[pos+17]<<8) |
                     ((uint32_t)p[pos+18]<<16) | ((uint32_t)p[pos+19]<<24);
        }
        if (!memcmp(p+pos,"data",4)) payload = chunkLen;
        pos = next;
    }
    return byteRate ? (double)payload/(double)byteRate : 0;
}
static BOOL VTSendViaOriginalSender(NSURL *audioURL, NSString *text, double duration) {
    Class ctlClass = objc_getClass("AllVoiceController");
    Class senderClass = objc_getClass("AllVoiceSender");
    Class itemClass = objc_getClass("AllVoiceSendItem");
    if (!ctlClass || !senderClass || !itemClass ||
        ![ctlClass respondsToSelector:@selector(shared)] ||
        ![senderClass respondsToSelector:@selector(shared)]) return NO;
    id ctl = VTOriginalController;
    if (!ctl) ctl = ((id (*)(id,SEL))objc_msgSend)(ctlClass,@selector(shared));
    if (!ctl || ![ctl respondsToSelector:@selector(platform)]) return NO;
    id platform = ((id (*)(id,SEL))objc_msgSend)(ctl,@selector(platform));
    if (!platform) return NO;
    id item = [[itemClass alloc] init];
    if (![item respondsToSelector:@selector(setAudioPath:)] ||
        ![item respondsToSelector:@selector(setDuration:)] ||
        ![item respondsToSelector:@selector(setAudioText:)] ||
        ![item respondsToSelector:@selector(setMime:)]) return NO;
    [item setValue:audioURL.path forKey:@"audioPath"];
    [item setValue:@(duration) forKey:@"duration"];
    [item setValue:text forKey:@"audioText"];
    [item setValue:@"audio/wav" forKey:@"mime"];
    id sender = ((id (*)(id,SEL))objc_msgSend)(senderClass,@selector(shared));
    if (![sender respondsToSelector:@selector(send:platform:)]) return NO;
    return ((BOOL (*)(id,SEL,id,id))objc_msgSend)(sender,@selector(send:platform:),item,platform);
}

- (void)generateAndSend {
    NSString *text = VTTrim(self.composerField.text);
    NSString *voiceID = VTTrim(self.composerVoice.text);
    NSString *token = VTTrim(self.keyField.text);
    if (!text.length || !voiceID.length) {
        VTMessage(self, @"信息不完整", @"必须填写合成文字与 Fish 官方音色 reference_id。");
        return;
    }
    [VTDefaults() setObject:token forKey:kFishKey];
    self.generateButton.enabled = NO;
    [self.view endEditing:YES];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSError *problem = nil;
        NSData *audio = VTOfficialTTS(text, voiceID, &problem);
        double duration = audio ? VTDurationWAV(audio) : 0;
        NSString *filename = [NSString stringWithFormat:@"vtpatch-fish-%@.wav",NSUUID.UUID.UUIDString];
        NSURL *dest = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:filename]];
        if (audio && !duration) {
            problem = VTError(1102, @"官方输出不是可识别的 PCM WAV；不能交给原插件发送。");
        }
        if (audio && duration && ![audio writeToURL:dest options:NSDataWritingAtomic error:&problem]) {
            audio = nil;
        }
        NSError *failure = problem;
        dispatch_async(dispatch_get_main_queue(), ^{
            VTFishPanel *panel=weakSelf;
            if (!panel) return;
            panel.generateButton.enabled = YES;
            if (failure || !audio.length || !duration) {
                VTMessage(panel,@"Fish 官方合成失败",failure.localizedDescription ?: @"未得到音频；没有回退作者接口。");
                return;
            }
            VTLastAudioURL = dest;
            BOOL sent = NO;
            @try { sent = VTSendViaOriginalSender(dest,text,duration); }
            @catch (NSException *exception) { VTSetStatus(@"原插件发送调用出现异常；文件已保存"); }
            if (sent) {
                VTMessage(panel,@"已调用发送模块",@"Fish 官方已生成音频，原插件发送模块返回成功。请到聊天中核实是否真正发出；作者授权仍未使用。");
            } else {
                VTMessage(panel,@"音频已生成",@"Fish 官方音频已经本地保存，但原插件发送模块未确认成功。可点击「分享最近生成的音频文件」尝试其他合法分享方式。");
            }
        });
    });
}
- (void)shareLatestAudio {
    if (!VTLastAudioURL || ![NSFileManager.defaultManager fileExistsAtPath:VTLastAudioURL.path]) {
        VTMessage(self,@"暂无音频",@"先用官方 Token 生成一段语音。");
        return;
    }
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[VTLastAudioURL] applicationActivities:nil];
    share.popoverPresentationController.sourceView = self.view;
    share.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds),50,1,1);
    [self presentViewController:share animated:YES completion:nil];
}
- (void)saveKey {
    [VTDefaults() setObject:VTTrim(self.keyField.text) forKey:kFishKey];
    [self.view endEditing:YES];
    VTMessage(self, @"已保存", @"Fish 官方 API Token 已保存；不会启用作者 Token。");
}
- (void)showKey { self.keyField.secureTextEntry = !self.keyField.secureTextEntry; }
- (void)showStatus { VTInstallBridge(); VTMessage(self, @"合成入口诊断", VTGetStatus()); }
- (void)closePanel {
    [VTDefaults() setObject:VTTrim(self.keyField.text) forKey:kFishKey];
    [self.view endEditing:YES];
    VTClose();
}
- (void)refreshVoices {
    for (UIView *view in self.voices.arrangedSubviews.copy) {
        [self.voices removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    NSArray *all = VTVoices();
    if (!all.count) { [self.voices addArrangedSubview:VTLabel(@"当前无本地映射，可手动新增。", 13)]; return; }
    for (NSDictionary *item in all) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *key = item[@"id"] ?: @"";
        NSString *name = item[@"name"] ?: @"未命名";
        NSString *mapped = item[@"fishID"] ?: @"";
        UIStackView *line = [UIStackView new];
        line.axis = UILayoutConstraintAxisHorizontal;
        line.spacing = 8;
        UILabel *label = VTLabel([NSString stringWithFormat:@"%@\n原 ID: %@\n官方 ID: %@", name, key, mapped.length ? mapped : @"同原 ID"], 12);
        [label setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        [line addArrangedSubview:label];
        UIButton *edit = VTButton(@"映射", self, @selector(editVoice:));
        edit.accessibilityIdentifier = key;
        [line addArrangedSubview:edit];
        UIButton *del = VTButton(@"删除", self, @selector(removeVoice:));
        del.accessibilityIdentifier = key;
        [line addArrangedSubview:del];
        [self.voices addArrangedSubview:line];
    }
}
- (void)addVoice {
    UIAlertController *dialog = [UIAlertController alertControllerWithTitle:@"添加音色映射" message:@"公开 Fish 音色可直接使用官方 reference_id；不能仅凭作者私有名称复制模型。" preferredStyle:UIAlertControllerStyleAlert];
    [dialog addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = @"作者列表里的 voiceID"; }];
    [dialog addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = @"音色名称"; }];
    [dialog addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = @"Fish 官方 reference_id（可留空）"; }];
    [dialog addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [dialog addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *key = VTTrim(dialog.textFields[0].text);
        NSString *name = VTTrim(dialog.textFields[1].text);
        NSString *fish = VTTrim(dialog.textFields[2].text);
        if (!key.length || !name.length) { VTMessage(weakSelf, @"输入有误", @"必须填写作者音色 ID 和音色名称。"); return; }
        NSMutableArray *all = [VTVoices() mutableCopy];
        for (NSDictionary *old in all) {
            if ([old[@"id"] isEqualToString:key]) { VTMessage(weakSelf, @"已存在", @"该 ID 已添加，请使用映射按钮修改。"); return; }
        }
        [all addObject:@{@"id":key, @"name":name, @"fishID":fish}];
        VTSaveVoices(all);
        [weakSelf refreshVoices];
    }]];
    [self presentViewController:dialog animated:YES completion:nil];
}
- (void)editVoice:(UIButton *)sender {
    NSString *key = sender.accessibilityIdentifier;
    NSDictionary *selected = nil;
    for (NSDictionary *item in VTVoices()) { if ([item[@"id"] isEqualToString:key]) { selected = item; break; } }
    if (!selected) return;
    NSString *current = selected[@"fishID"] ?: @"";
    UIAlertController *dialog = [UIAlertController alertControllerWithTitle:@"绑定 Fish 官方音色" message:@"输入你自己的官方 Token 可访问的 reference_id，留空则使用原音色 ID。" preferredStyle:UIAlertControllerStyleAlert];
    [dialog addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = @"reference_id"; f.text = current; }];
    [dialog addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [dialog addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSMutableArray *all = [NSMutableArray array];
        for (NSDictionary *item in VTVoices()) {
            if ([item[@"id"] isEqualToString:key]) {
                NSMutableDictionary *entry = [item mutableCopy];
                entry[@"fishID"] = VTTrim(dialog.textFields.firstObject.text);
                [all addObject:entry];
            } else { [all addObject:item]; }
        }
        VTSaveVoices(all);
        [weakSelf refreshVoices];
    }]];
    [self presentViewController:dialog animated:YES completion:nil];
}
- (void)removeVoice:(UIButton *)sender {
    NSString *key = sender.accessibilityIdentifier;
    NSMutableArray *all = [NSMutableArray array];
    for (NSDictionary *item in VTVoices()) if (![item[@"id"] isEqualToString:key]) [all addObject:item];
    VTSaveVoices(all);
    [self refreshVoices];
}
@end

static void VTShowSettings(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ VTShowSettings(); }); return; }
    if (VTOverlay || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    UIWindowScene *activeScene = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
            if (![candidate isKindOfClass:UIWindowScene.class]) continue;
            if (candidate.activationState == UISceneActivationStateForegroundActive) {
                activeScene = (UIWindowScene *)candidate; break;
            }
        }
    }
    UIWindow *keyWindow = nil;
    NSArray *windows = activeScene ? activeScene.windows : @[];
    for (UIWindow *candidate in windows) if (candidate.isKeyWindow) { keyWindow = candidate; break; }
    VTPreviousKey = keyWindow;
    VTOverlay = activeScene ? [[UIWindow alloc] initWithWindowScene:activeScene] : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    VTOverlay.windowLevel = UIWindowLevelAlert + 20;
    VTOverlay.rootViewController = [VTFishPanel new];
    [VTOverlay makeKeyAndVisible];
    if (![VTDefaults() boolForKey:kWelcome]) {
        [VTDefaults() setBool:YES forKey:kWelcome];
        UIAlertController *welcome = [UIAlertController alertControllerWithTitle:@"V4 Fish 官方独立语音已加载"
          message:@"只填写 Fish 官方 Token。作者授权弹窗会进入独立官方语音页面，不再把官方 Key 发往作者服务器。摇一摇也能打开。"
          preferredStyle:UIAlertControllerStyleAlert];
        [welcome addAction:[UIAlertAction actionWithTitle:@"打开官方设置" style:UIAlertActionStyleDefault handler:nil]];
        [VTOverlay.rootViewController presentViewController:welcome animated:YES completion:nil];
    }
}
static void VTShake(void) {
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (now - VTLastShake < 1.5) return;
    VTLastShake = now;
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) VTShowSettings();
}
@implementation UIApplication (VTFishShake)
- (void)vtfish_sendEvent:(UIEvent *)event {
    [self vtfish_sendEvent:event];
    if (event.type == UIEventTypeMotion && event.subtype == UIEventSubtypeMotionShake) VTShake();
}
@end
@implementation UIWindow (VTFishShake)
- (void)vtfish_motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    [self vtfish_motionEnded:motion withEvent:event];
    if (motion == UIEventSubtypeMotionShake) VTShake();
}
@end
static void VTSwap(Class cls, SEL original, SEL replacement) {
    Method a = class_getInstanceMethod(cls, original);
    Method b = class_getInstanceMethod(cls, replacement);
    if (a && b) method_exchangeImplementations(a, b);
}
__attribute__((constructor)) static void VTInit(void) {
    @autoreleasepool {
        NSString *exe = NSBundle.mainBundle.infoDictionary[@"CFBundleExecutable"];
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
        if (![exe isEqualToString:@"Aweme"] && ![bundle isEqualToString:@"com.ss.iphone.ugc.Aweme"]) return;
        VTInstallBridge();
        VTSwap(UIApplication.class, @selector(sendEvent:), @selector(vtfish_sendEvent:));
        VTSwap(UIWindow.class, @selector(motionEnded:withEvent:), @selector(vtfish_motionEnded:withEvent:));
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
          object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                VTInstallBridge();
                if (![VTDefaults() boolForKey:kWelcome]) VTShowSettings();
            });
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
                VTInstallBridge();
                if (![VTDefaults() boolForKey:kWelcome]) VTShowSettings();
            }
        });
    }
}
