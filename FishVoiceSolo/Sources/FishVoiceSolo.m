#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>

/*
 FishVoice Solo V5: one self-contained library.
 No voicetool.dylib, no third-party classes, no author entitlement or API.
 This library supplies its own independent global overlay.
 */
static NSString *const kService = @"com.fishvoicesolo.fishkey";
static NSString *const kAccount = @"official_fish_api_key";
static NSString *const kFavorites = @"fishvoicesolo.savedvoices";
static NSString *const kSelected = @"fishvoicesolo.selected";
static NSString *const kModel = @"fishvoicesolo.model";
static NSString *const kFirst = @"fishvoicesolo.welcome5";
static UIWindow *FVSWindow;
static __weak UIWindow *FVSOldWindow;
static NSTimeInterval FVSLastShake = 0;

static NSString *FVSTrim(NSString *s) {
    if (![s isKindOfClass:NSString.class]) return @"";
    return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}
static NSString *FVSKey(void) {
    NSDictionary *q=@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
                      (__bridge id)kSecAttrService:kService,
                      (__bridge id)kSecAttrAccount:kAccount,
                      (__bridge id)kSecReturnData:@YES,
                      (__bridge id)kSecMatchLimit:(__bridge id)kSecMatchLimitOne};
    CFTypeRef out=NULL;
    OSStatus status=SecItemCopyMatching((__bridge CFDictionaryRef)q,&out);
    if(status!=errSecSuccess || !out) return @"";
    NSData *data=CFBridgingRelease(out);
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}
static BOOL FVSSaveKey(NSString *input) {
    NSString *key=FVSTrim(input);
    if ([key.lowercaseString hasPrefix:@"bearer "]) key=FVSTrim([key substringFromIndex:7]);
    if ([key rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location!=NSNotFound) return NO;
    NSDictionary *q=@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
                      (__bridge id)kSecAttrService:kService,
                      (__bridge id)kSecAttrAccount:kAccount};
    SecItemDelete((__bridge CFDictionaryRef)q);
    if(!key.length) return YES;
    NSData *data=[key dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableDictionary *add=[q mutableCopy];
    add[(__bridge id)kSecValueData]=data;
    add[(__bridge id)kSecAttrAccessible]=(__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    return SecItemAdd((__bridge CFDictionaryRef)add,NULL)==errSecSuccess;
}
static NSArray<NSDictionary *> *FVSFavorites(void) {
    id list=[NSUserDefaults.standardUserDefaults objectForKey:kFavorites];
    return [list isKindOfClass:NSArray.class] ? list : @[];
}
static void FVSSetFavorites(NSArray *list) {
    [NSUserDefaults.standardUserDefaults setObject:list forKey:kFavorites];
}
static NSError *FVSError(NSInteger code,NSString *message) {
    return [NSError errorWithDomain:@"FishVoiceSolo" code:code
      userInfo:@{NSLocalizedDescriptionKey:message ?: @"未知错误"}];
}
static NSString *FVSSelected(void) {
    return [NSUserDefaults.standardUserDefaults stringForKey:kSelected] ?: @"";
}
static NSString *FVSModel(void) {
    NSString *name=[NSUserDefaults.standardUserDefaults stringForKey:kModel];
    return [name isEqualToString:@"s2.1-pro-free"] ? name : @"s2.1-pro";
}
static void FVSSafeMain(dispatch_block_t cb) {
    if ([NSThread isMainThread]) cb();
    else dispatch_async(dispatch_get_main_queue(),cb);
}
static UILabel *FVSLabel(NSString *text,CGFloat size,BOOL headline) {
    UILabel *label=[UILabel new];
    label.text=text;
    label.textColor=UIColor.labelColor;
    label.numberOfLines=0;
    label.font=headline ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
    return label;
}
static UIButton *FVSButton(NSString *title,id owner,SEL selector) {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font=[UIFont boldSystemFontOfSize:15];
    button.titleLabel.numberOfLines=2;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:42].active=YES;
    [button addTarget:owner action:selector forControlEvents:UIControlEventTouchUpInside];
    return button;
}
static void FVSAlert(UIViewController *controller,NSString *title,NSString *message) {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}
static void FVSOpen(void);
static void FVSClose(void) {
    FVSSafeMain(^{
        UIWindow *previous=FVSOldWindow;
        FVSWindow.hidden=YES;
        FVSWindow.rootViewController=nil;
        FVSWindow=nil;
        if(previous && !previous.hidden) [previous makeKeyWindow];
        FVSOldWindow=nil;
    });
}
@interface FVSPanel : UIViewController <UITextFieldDelegate>
@property(nonatomic,strong) UITextField *keyField;
@property(nonatomic,strong) UITextView *composer;
@property(nonatomic,strong) UILabel *voiceLabel;
@property(nonatomic,strong) UILabel *resultLabel;
@property(nonatomic,strong) UISegmentedControl *modelSegment;
@property(nonatomic,strong) UIStackView *savedVoicesStack;
@property(nonatomic,strong) UIButton *generateButton;
@property(nonatomic,strong) AVAudioPlayer *player;
@property(nonatomic,strong) NSURL *latestAudioURL;
@property(nonatomic,copy) NSString *latestText;
@end

@implementation FVSPanel
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor=UIColor.systemBackgroundColor;
    UIScrollView *scroll=[UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints=NO;
    [self.view addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];
    UIStackView *stack=[UIStackView new];
    stack.axis=UILayoutConstraintAxisVertical;
    stack.spacing=12;
    stack.translatesAutoresizingMaskIntoConstraints=NO;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:16],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-25],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:18],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-18],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-36]
    ]];
    [stack addArrangedSubview:FVSLabel(@"Fish 官方语音 · Solo V5",23,YES)];
    [stack addArrangedSubview:FVSLabel(@"独立单 dylib：不需要作者插件、作者 API 或作者额度。使用自己的 Fish 官方账户合成语音。",13,NO)];
    [stack addArrangedSubview:FVSLabel(@"Fish 官方 API Key（保存在 iPhone 钥匙串）",15,YES)];
    UITextField *keyField=[UITextField new];
    keyField.placeholder=@"输入 Fish 官方 API Key";
    keyField.text=FVSKey();
    keyField.secureTextEntry=YES;
    keyField.autocapitalizationType=UITextAutocapitalizationTypeNone;
    keyField.autocorrectionType=UITextAutocorrectionTypeNo;
    keyField.clearButtonMode=UITextFieldViewModeWhileEditing;
    keyField.borderStyle=UITextBorderStyleRoundedRect;
    [keyField.heightAnchor constraintEqualToConstant:46].active=YES;
    self.keyField=keyField;
    [stack addArrangedSubview:keyField];
    [stack addArrangedSubview:FVSButton(@"保存 / 清空官方 API Key",self,@selector(saveKey))];
    [stack addArrangedSubview:FVSButton(@"显示 / 隐藏 Key",self,@selector(toggleKey))];

    [stack addArrangedSubview:FVSLabel(@"选择官方模型",15,YES)];
    self.modelSegment=[[UISegmentedControl alloc] initWithItems:@[@"官方付费 s2.1-pro",@"官方免费模型"]];
    self.modelSegment.selectedSegmentIndex=[FVSModel() isEqualToString:@"s2.1-pro-free"] ? 1 : 0;
    [self.modelSegment addTarget:self action:@selector(changedModel:) forControlEvents:UIControlEventValueChanged];
    [self.modelSegment.heightAnchor constraintEqualToConstant:37].active=YES;
    [stack addArrangedSubview:self.modelSegment];
    [stack addArrangedSubview:FVSLabel(@"免费模型仅在 Fish 账户有对应权限时可用；选择付费模型可能消耗你的官方额度。",12,NO)];

    [stack addArrangedSubview:FVSLabel(@"官方音色库",17,YES)];
    self.voiceLabel=FVSLabel(@"尚未选择音色",13,NO);
    [stack addArrangedSubview:self.voiceLabel];
    [self refreshVoiceLabel];
    [stack addArrangedSubview:FVSButton(@"搜索 Fish 官方公开音色",self,@selector(searchVoices))];
    [stack addArrangedSubview:FVSButton(@"读取我的 Fish 官方音色",self,@selector(myVoices))];
    [stack addArrangedSubview:FVSButton(@"+ 手动添加官方 reference_id",self,@selector(addManualVoice))];
    self.savedVoicesStack=[UIStackView new];
    self.savedVoicesStack.axis=UILayoutConstraintAxisVertical;
    self.savedVoicesStack.spacing=7;
    [stack addArrangedSubview:self.savedVoicesStack];
    [self refreshSavedVoices];

    [stack addArrangedSubview:FVSLabel(@"输入文字 → 官方合成",17,YES)];
    UITextView *composer=[UITextView new];
    composer.font=[UIFont systemFontOfSize:16];
    composer.layer.cornerRadius=9;
    composer.layer.borderWidth=1;
    composer.layer.borderColor=UIColor.separatorColor.CGColor;
    composer.text=@"你好，这是 Fish 官方语音测试。";
    [composer.heightAnchor constraintEqualToConstant:126].active=YES;
    self.composer=composer;
    [stack addArrangedSubview:composer];
    self.generateButton=FVSButton(@"用 Fish 官方账户生成语音",self,@selector(generate));
    [stack addArrangedSubview:self.generateButton];
    self.resultLabel=FVSLabel(@"未生成音频",13,NO);
    [stack addArrangedSubview:self.resultLabel];
    [stack addArrangedSubview:FVSButton(@"▶ 试听最新音频",self,@selector(previewAudio))];
    [stack addArrangedSubview:FVSButton(@"分享 / 发送音频文件",self,@selector(shareAudio))];
    [stack addArrangedSubview:FVSLabel(@"注意：这里是 iOS 系统分享音频文件，不是抖音原生语音消息自动发送。原生 IM 发送适配尚未完成。",12,NO)];
    [stack addArrangedSubview:FVSButton(@"关闭面板（摇一摇再打开）",self,@selector(closePanel))];
}
- (void)saveKey {
    NSString *key=FVSTrim(self.keyField.text);
    if(!FVSSaveKey(key)) { FVSAlert(self,@"保存失败",@"无法写入 Keychain，请检查签名与钥匙串权限。");return; }
    [self.view endEditing:YES];
    FVSAlert(self,@"保存成功",key.length ? @"Fish 官方 Key 已保存在本机钥匙串。" : @"Fish 官方 Key 已清空。");
}
- (void)toggleKey { self.keyField.secureTextEntry=!self.keyField.secureTextEntry; }
- (void)changedModel:(UISegmentedControl *)control {
    NSString *model=control.selectedSegmentIndex==1 ? @"s2.1-pro-free" : @"s2.1-pro";
    [NSUserDefaults.standardUserDefaults setObject:model forKey:kModel];
}
- (void)refreshVoiceLabel {
    NSString *voice=FVSSelected();
    NSString *name=voice;
    for(NSDictionary *one in FVSFavorites()) {
        if([one[@"id"] isEqualToString:voice]) { name=one[@"title"] ?: voice; break; }
    }
    self.voiceLabel.text=voice.length ? [NSString stringWithFormat:@"当前：%@\nreference_id：%@",name,voice] : @"当前尚未选择音色，请搜索官方音色或手动输入 reference_id";
}
- (void)refreshSavedVoices {
    for(UIView *view in self.savedVoicesStack.arrangedSubviews.copy) {
        [self.savedVoicesStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    NSArray *favorites=FVSFavorites();
    if(!favorites.count) {
        [self.savedVoicesStack addArrangedSubview:FVSLabel(@"尚无收藏的音色",13,NO)];
        return;
    }
    for(NSDictionary *one in favorites) {
        NSString *voice=one[@"id"];
        if (![voice isKindOfClass:NSString.class]) continue;
        UIStackView *line=[UIStackView new];
        line.axis=UILayoutConstraintAxisHorizontal;
        line.alignment=UIStackViewAlignmentCenter;
        line.spacing=6;
        UILabel *name=FVSLabel([NSString stringWithFormat:@"%@\n%@",one[@"title"] ?: @"未命名",voice],12,NO);
        [name setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        [line addArrangedSubview:name];
        UIButton *choose=FVSButton(@"使用",self,@selector(selectVoice:));
        choose.accessibilityIdentifier=voice;
        [line addArrangedSubview:choose];
        UIButton *remove=FVSButton(@"删除",self,@selector(deleteVoice:));
        remove.accessibilityIdentifier=voice;
        [line addArrangedSubview:remove];
        [self.savedVoicesStack addArrangedSubview:line];
    }
}
- (void)selectVoice:(UIButton *)sender {
    NSString *voice=FVSTrim(sender.accessibilityIdentifier);
    if(!voice.length) return;
    [NSUserDefaults.standardUserDefaults setObject:voice forKey:kSelected];
    [self refreshVoiceLabel];
    [self.view endEditing:YES];
}
- (void)deleteVoice:(UIButton *)sender {
    NSString *voice=FVSTrim(sender.accessibilityIdentifier);
    NSMutableArray *list=[NSMutableArray array];
    for(NSDictionary *one in FVSFavorites()) {
        if (![one[@"id"] isEqualToString:voice]) [list addObject:one];
    }
    FVSSetFavorites(list);
    if([FVSSelected() isEqualToString:voice]) [NSUserDefaults.standardUserDefaults removeObjectForKey:kSelected];
    [self refreshSavedVoices];
    [self refreshVoiceLabel];
}
- (void)saveVoiceID:(NSString *)voice title:(NSString *)title {
    NSString *v=FVSTrim(voice);
    if(!v.length) {FVSAlert(self,@"缺少音色 ID",@"请填写 Fish 官方 reference_id。");return;}
    NSString *label=FVSTrim(title);
    if(!label.length) label=v;
    NSMutableArray *all=[NSMutableArray array];
    for(NSDictionary *item in FVSFavorites()) {
        if(![item[@"id"] isEqualToString:v]) [all addObject:item];
    }
    [all insertObject:@{@"id":v,@"title":label} atIndex:0];
    FVSSetFavorites(all);
    [NSUserDefaults.standardUserDefaults setObject:v forKey:kSelected];
    [self refreshSavedVoices];
    [self refreshVoiceLabel];
}
- (void)addManualVoice {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"添加 Fish 官方音色" message:@"只能使用你的官方 Key 可访问的 reference_id，不能直接复制原作者私有模型。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f){ f.placeholder=@"Fish 官方 reference_id"; f.autocapitalizationType=UITextAutocapitalizationTypeNone; }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f){ f.placeholder=@"音色名称"; }];
    __weak typeof(self) weakSelf=self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存并选用" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        [weakSelf saveVoiceID:alert.textFields[0].text title:alert.textFields[1].text];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)searchVoices {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"搜索官方公开音色" message:@"使用 Fish 官方 /model 接口搜索，不读取原作者音色服务器。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.placeholder=@"例如：中文女声、主播、男声";}];
    __weak typeof(self) weakSelf=self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"搜索" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [weakSelf loadModelsWithTitle:alert.textFields.firstObject.text own:NO];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)myVoices { [self loadModelsWithTitle:@"" own:YES]; }
- (void)loadModelsWithTitle:(NSString *)title own:(BOOL)own {
    NSString *key=FVSKey();
    if(!key.length) {FVSAlert(self,@"需要官方 Key",@"先保存 Fish 官方 API Key。");return;}
    NSURLComponents *parts=[NSURLComponents componentsWithString:@"https://api.fish.audio/model"];
    NSMutableArray *query=[NSMutableArray arrayWithArray:@[
        [NSURLQueryItem queryItemWithName:@"page_size" value:@"30"],
        [NSURLQueryItem queryItemWithName:@"page_number" value:@"1"]]];
    if(own) [query addObject:[NSURLQueryItem queryItemWithName:@"self" value:@"true"]];
    if(!own && FVSTrim(title).length) [query addObject:[NSURLQueryItem queryItemWithName:@"title" value:FVSTrim(title)]];
    parts.queryItems=query;
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:parts.URL];
    request.timeoutInterval=25;
    [request setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
    self.resultLabel.text=@"正在查询 Fish 官方音色……";
    __weak typeof(self) weakSelf=self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error) {
        NSError *failure=error;
        NSInteger status=[(NSHTTPURLResponse *)response statusCode];
        NSArray *items=nil;
        if(!failure && (status<200 || status>=300)) failure=FVSError(status,[NSString stringWithFormat:@"Fish 官方音色库 HTTP %ld", (long)status]);
        if(!failure && data.length) {
            id payload=[NSJSONSerialization JSONObjectWithData:data options:0 error:&failure];
            if([payload isKindOfClass:NSDictionary.class] && [payload[@"items"] isKindOfClass:NSArray.class]) {
                items=payload[@"items"];
            } else if (!failure) failure=FVSError(100,@"官方音色接口返回格式无法识别。");
        }
        NSArray *voices=items;
        NSError *err=failure;
        FVSSafeMain(^{
            FVSPanel *panel=weakSelf; if(!panel) return;
            if(err) {panel.resultLabel.text=@"音色搜索失败";FVSAlert(panel,@"Fish 官方音色库",err.localizedDescription);return;}
            [panel showModelResults:voices title:own ? @"我的 Fish 官方音色": @"Fish 公开音色"];
        });
    }] resume];
}
- (void)showModelResults:(NSArray *)items title:(NSString *)title {
    UIAlertController *picker=[UIAlertController alertControllerWithTitle:title message:items.count?@"点击音色后保存并选用（最多显示 20 个）":@"没有找到可用音色，试试更换关键词。" preferredStyle:UIAlertControllerStyleActionSheet];
    NSUInteger limit=MIN(items.count,20);
    __weak typeof(self) weakSelf=self;
    for(NSUInteger i=0;i<limit;i++){
        id entry=items[i];
        if(![entry isKindOfClass:NSDictionary.class])continue;
        NSString *voice=entry[@"_id"] ?: entry[@"id"];
        NSString *name=entry[@"title"];
        if (![voice isKindOfClass:NSString.class] || !voice.length)continue;
        if(![name isKindOfClass:NSString.class]) name=voice;
        NSString *selectedVoice=[voice copy];
        NSString *selectedName=[name copy];
        [picker addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [weakSelf saveVoiceID:selectedVoice title:selectedName];
        }]];
    }
    [picker addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    picker.popoverPresentationController.sourceView=self.view;
    picker.popoverPresentationController.sourceRect=CGRectMake(CGRectGetMidX(self.view.bounds),CGRectGetMidY(self.view.bounds),2,2);
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)generate {
    NSString *text=FVSTrim(self.composer.text);
    NSString *voice=FVSSelected();
    NSString *key=FVSKey();
    if(!key.length){FVSAlert(self,@"没有 Fish 官方 Key",@"先填写并保存 Fish 官方 API Key。");return;}
    if(!text.length){FVSAlert(self,@"没有文字",@"请先填写要合成的文本。");return;}
    if(!voice.length){FVSAlert(self,@"没有选中音色",@"请先从 Fish 官方音色库选用一个音色。");return;}
    if(text.length>5000){FVSAlert(self,@"文字过长",@"首次建议使用短句测试；单次最多 5000 字符。");return;}
    NSString *model=FVSModel();
    if([model isEqualToString:@"s2.1-pro"]) {
        UIAlertController *confirm=[UIAlertController alertControllerWithTitle:@"确认消耗 Fish 官方额度"
          message:@"你选择的是 Fish 官方付费模型。本次语音合成可能产生官方账户费用，绝不会调用原作者服务。"
          preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        __weak typeof(self) weakSelf=self;
        [confirm addAction:[UIAlertAction actionWithTitle:@"继续官方合成" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [weakSelf startTTSWithText:text voice:voice model:model key:key];
        }]];
        [self presentViewController:confirm animated:YES completion:nil];
        return;
    }
    [self startTTSWithText:text voice:voice model:model key:key];
}
- (void)startTTSWithText:(NSString *)text voice:(NSString *)voice model:(NSString *)model key:(NSString *)key {
    NSDictionary *body=@{@"text":text,@"reference_id":voice,@"format":@"mp3"};
    NSError *serError=nil;
    NSData *data=[NSJSONSerialization dataWithJSONObject:body options:0 error:&serError];
    if(!data){FVSAlert(self,@"数据错误",serError.localizedDescription);return;}
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://api.fish.audio/v1/tts"]];
    request.HTTPMethod=@"POST";
    request.HTTPBody=data;
    request.timeoutInterval=90;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
    [request setValue:model forHTTPHeaderField:@"model"];
    [request setValue:@"audio/mpeg" forHTTPHeaderField:@"Accept"];
    self.generateButton.enabled=NO;
    self.resultLabel.text=[NSString stringWithFormat:@"正在向 Fish 官方合成（%@）……",model];
    __weak typeof(self) weakSelf=self;
    NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    NSURLSession *session=[NSURLSession sessionWithConfiguration:config];
    [[session dataTaskWithRequest:request completionHandler:^(NSData *audio,NSURLResponse *response,NSError *error){
        NSInteger status=[response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode]:0;
        NSError *failure=error;
        if(!failure && (status<200 || status>=300)) {
            failure=FVSError(status,[NSString stringWithFormat:@"Fish 官方返回 HTTP %ld。请检查 Key、额度或音色权限。",(long)status]);
        }
        if(!failure && !audio.length) failure=FVSError(2001,@"官方接口返回空音频。");
        NSString *mime=response.MIMEType.lowercaseString ?: @"";
        if(!failure && ([mime containsString:@"json"] || [mime containsString:@"html"])) failure=FVSError(2002,@"官方返回非音频格式。");
        /* Verify MP3 frame or ID3 signature before accepting. */
        if(!failure && audio.length>=3){
            const uint8_t *bytes=audio.bytes;
            BOOL mp3=(!memcmp(bytes,"ID3",3)) || (bytes[0]==0xff && (bytes[1]&0xe0)==0xe0);
            if(!mp3) failure=FVSError(2003,@"收到的文件不是可识别的 MP3，已停止保存。");
        }
        NSURL *location=nil;
        if(!failure) {
            NSString *name=[NSString stringWithFormat:@"FishSolo-%@.mp3",NSUUID.UUID.UUIDString];
            NSURL *folder=[NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
            location=[folder URLByAppendingPathComponent:name];
            if(![audio writeToURL:location options:NSDataWritingAtomic error:&failure]) location=nil;
        }
        NSURL *saved=location;
        NSError *failureResult=failure;
        FVSSafeMain(^{
            FVSPanel *panel=weakSelf; if(!panel) return;
            panel.generateButton.enabled=YES;
            if(failureResult){panel.resultLabel.text=@"生成失败（没有回退作者接口）";FVSAlert(panel,@"Fish 官方合成失败",failureResult.localizedDescription);return;}
            panel.latestAudioURL=saved;
            panel.latestText=text;
            panel.player=nil;
            panel.resultLabel.text=[NSString stringWithFormat:@"Fish 官方合成完成 · %@ · %lu KB\n可试听或分享文件；抖音原生语音发送尚未适配。",model,(unsigned long)(audio.length/1024)];
        });
    }] resume];
    [session finishTasksAndInvalidate];
}
- (void)previewAudio {
    if(!self.latestAudioURL){FVSAlert(self,@"没有生成音频",@"请先完成官方语音合成。");return;}
    if(self.player.isPlaying){[self.player stop];self.resultLabel.text=@"播放已停止";return;}
    NSError *error=nil;
    AVAudioPlayer *p=[[AVAudioPlayer alloc] initWithContentsOfURL:self.latestAudioURL error:&error];
    if(!p){FVSAlert(self,@"音频播放失败",error.localizedDescription ?: @"无法打开文件");return;}
    self.player=p;
    [p prepareToPlay];
    [p play];
}
- (void)shareAudio {
    if(!self.latestAudioURL){FVSAlert(self,@"暂无音频",@"先生成并保存音频。");return;}
    UIActivityViewController *share=[[UIActivityViewController alloc] initWithActivityItems:@[self.latestAudioURL] applicationActivities:nil];
    share.popoverPresentationController.sourceView=self.view;
    share.popoverPresentationController.sourceRect=CGRectMake(CGRectGetMidX(self.view.bounds),55,2,2);
    [self presentViewController:share animated:YES completion:nil];
}
- (void)closePanel {
    [self.player stop];
    FVSClose();
}
@end

static void FVSOpen(void){
    FVSSafeMain(^{
        if(FVSWindow || UIApplication.sharedApplication.applicationState!=UIApplicationStateActive)return;
        UIWindowScene *scene=nil;
        for(UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
            if([candidate isKindOfClass:UIWindowScene.class] && candidate.activationState==UISceneActivationStateForegroundActive) {
                scene=(UIWindowScene *)candidate;break;
            }
        }
        if(!scene)return;
        UIWindow *previous=nil;
        for(UIWindow *entry in scene.windows) if(entry.isKeyWindow) {previous=entry;break;}
        FVSOldWindow=previous;
        FVSWindow=[[UIWindow alloc] initWithWindowScene:scene];
        FVSWindow.windowLevel=UIWindowLevelAlert+10;
        FVSWindow.rootViewController=[FVSPanel new];
        [FVSWindow makeKeyAndVisible];
        if(![NSUserDefaults.standardUserDefaults boolForKey:kFirst]) {
            [NSUserDefaults.standardUserDefaults setBool:YES forKey:kFirst];
            FVSAlert(FVSWindow.rootViewController,@"Fish 官方独立插件 V5",
                     @"不需要 voicetool.dylib，也不需要作者 Token。首次可搜索官方音色、填写官方 Key，之后摇一摇重新打开。抖音原生语音消息自动发送尚未实现。");
        }
    });
}
static void FVSShake(void) {
    NSTimeInterval now=NSDate.date.timeIntervalSince1970;
    if(now-FVSLastShake<1.4)return;
    FVSLastShake=now;
    FVSOpen();
}
@implementation UIApplication (FishSoloMotion)
- (void)fvs_sendEvent:(UIEvent *)event {
    [self fvs_sendEvent:event];
    if(event.type==UIEventTypeMotion && event.subtype==UIEventSubtypeMotionShake)FVSShake();
}
@end
@implementation UIWindow (FishSoloMotion)
- (void)fvs_motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    [self fvs_motionEnded:motion withEvent:event];
    if(motion==UIEventSubtypeMotionShake)FVSShake();
}
@end
static void FVSSwizzle(Class cls,SEL original,SEL replacement) {
    Method first=class_getInstanceMethod(cls,original);
    Method second=class_getInstanceMethod(cls,replacement);
    if(first && second)method_exchangeImplementations(first,second);
}
__attribute__((constructor)) static void FVSLoad(void) {
    @autoreleasepool {
        NSString *bundle=NSBundle.mainBundle.bundleIdentifier;
        NSString *exe=NSBundle.mainBundle.infoDictionary[@"CFBundleExecutable"];
        if(![bundle isEqualToString:@"com.ss.iphone.ugc.Aweme"] && ![exe isEqualToString:@"Aweme"])return;
        FVSSwizzle(UIApplication.class,@selector(sendEvent:),@selector(fvs_sendEvent:));
        FVSSwizzle(UIWindow.class,@selector(motionEnded:withEvent:),@selector(fvs_motionEnded:withEvent:));
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
          object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
            if(![NSUserDefaults.standardUserDefaults boolForKey:kFirst]) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.5 * NSEC_PER_SEC)),dispatch_get_main_queue(),^{FVSOpen();});
            }
        }];
        dispatch_async(dispatch_get_main_queue(),^{
            if(UIApplication.sharedApplication.applicationState==UIApplicationStateActive
               && ![NSUserDefaults.standardUserDefaults boolForKey:kFirst])FVSOpen();
        });
    }
}
