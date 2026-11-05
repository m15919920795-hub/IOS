#import "GXCameraViewController.h"
#import "GXCameraClient.h"
#import "GXVideoView.h"
#import "GXVPWire.h"
#import "GXPersonClient.h"

@interface GXCameraViewController () <GXCameraClientDelegate, GXPersonClientDelegate, UITextFieldDelegate>
@property (nonatomic, strong) GXCameraClient *client;
@property (nonatomic, strong) GXPersonClient *personClient;
@property (nonatomic, strong) UISwitch *personSwitch;
@property (nonatomic, strong) UIButton *personConnectButton;
@property (nonatomic, strong) UILabel *personLabel;
@property (nonatomic, strong) NSDictionary *personState;
@property (nonatomic, strong) GXVideoView *videoView;
@property (nonatomic, strong) UITextField *hostField, *portField;
@property (nonatomic, strong) UIButton *connectButton, *startButton, *stopButton, *statusButton, *idrButton;
@property (nonatomic, strong) UIButton *videoOnlyButton;
@property (nonatomic, strong) UIScrollView *controlsScrollView;
@property (nonatomic, strong) UIStackView *controlsStack;
@property (nonatomic) BOOL videoOnly;
@property (nonatomic, strong) UISegmentedControl *profiles;
@property (nonatomic, strong) UILabel *titleLabel, *stateLabel, *statsLabel, *hintLabel;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) NSMutableArray<NSString *> *logs;
@property (nonatomic, strong) NSDictionary<NSString *, id> *status;
@end

@implementation GXCameraViewController
- (UIButton *)button:(NSString *)title action:(SEL)selector {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *style = [UIButtonConfiguration tintedButtonConfiguration];
    style.title = title; style.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    button.configuration = style;
    [button addTarget:self action:selector forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintEqualToConstant:42].active = YES;
    return button;
}
- (UITextField *)field:(NSString *)text placeholder:(NSString *)placeholder {
    UITextField *field = [UITextField new]; field.text = text; field.placeholder = placeholder;
    field.borderStyle = UITextBorderStyleRoundedRect; field.delegate = self;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    return field;
}
- (UILabel *)label:(CGFloat)size weight:(UIFontWeight)weight {
    UILabel *label = [UILabel new]; label.font = [UIFont systemFontOfSize:size weight:weight];
    label.numberOfLines = 0; return label;
}
- (UIStackView *)row:(NSArray<UIView *> *)views {
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:views];
    row.axis = UILayoutConstraintAxisHorizontal; row.spacing = 8; row.alignment = UIStackViewAlignmentFill;
    return row;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.view.tintColor = [UIColor colorWithRed:0.08 green:0.54 blue:0.72 alpha:1];
    self.logs = [NSMutableArray array];
    self.titleLabel = [self label:25 weight:UIFontWeightBold]; self.titleLabel.text = @"GX 摄像板";
    self.hintLabel = [self label:12 weight:UIFontWeightRegular];
    self.hintLabel.textColor = UIColor.secondaryLabelColor;
    self.hintLabel.text = @"先连接 GX-7259 热点 · 连接后点击开始 · 切换档位前先停止";
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    self.hostField = [self field:[defaults stringForKey:@"GXHost"] ?: @"192.168.188.1" placeholder:@"设备 IP"];
    self.hostField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    self.portField = [self field:[defaults stringForKey:@"GXPort"] ?: @"5600" placeholder:@"端口"];
    self.portField.keyboardType = UIKeyboardTypeNumberPad;
    [self.portField.widthAnchor constraintEqualToConstant:72].active = YES;
    self.connectButton = [self button:@"连接" action:@selector(connectTapped)];
    [self.connectButton.widthAnchor constraintEqualToConstant:76].active = YES;
    UIStackView *connection = [self row:@[self.hostField, self.portField, self.connectButton]];
    self.stateLabel = [self label:14 weight:UIFontWeightSemibold]; self.stateLabel.text = @"未连接";
    self.videoView = [GXVideoView new];
    self.videoView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.videoView];
    self.profiles = [[UISegmentedControl alloc] initWithItems:@[@"720p · 25 fps", @"1080p · 20 fps"]];
    self.profiles.selectedSegmentIndex = 0;
    self.startButton = [self button:@"开始" action:@selector(startTapped)];
    self.stopButton = [self button:@"停止" action:@selector(stopTapped)];
    self.statusButton = [self button:@"状态" action:@selector(statusTapped)];
    self.idrButton = [self button:@"关键帧" action:@selector(idrTapped)];
    UIStackView *commands = [self row:@[self.startButton, self.stopButton, self.statusButton, self.idrButton]];
    commands.distribution = UIStackViewDistributionFillEqually;
    self.statsLabel = [self label:12 weight:UIFontWeightRegular];
    self.statsLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.statsLabel.text = @"接收 0 fps · 硬解 0 fps · 显示 0 fps\n0 kbit/s · 等待视频";
    UILabel *personTitle = [self label:14 weight:UIFontWeightSemibold]; personTitle.text = @"人形识别 · 300 ms";
    self.personSwitch = [UISwitch new];
    [self.personSwitch addTarget:self action:@selector(personSwitchChanged) forControlEvents:UIControlEventValueChanged];
    self.personConnectButton = [self button:@"识别重连" action:@selector(personConnectTapped)];
    [self.personConnectButton.widthAnchor constraintEqualToConstant:94].active = YES;
    UIStackView *personRow = [self row:@[personTitle, self.personSwitch, self.personConnectButton]];
    personRow.alignment = UIStackViewAlignmentCenter;
    self.personLabel = [self label:12 weight:UIFontWeightRegular]; self.personLabel.numberOfLines = 2;
    self.personLabel.text = @"识别端口未连接";
    self.logView = [UITextView new]; self.logView.editable = NO; self.logView.selectable = YES;
    self.logView.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.logView.layer.cornerRadius = 8;
    self.logView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    NSLayoutConstraint *logHeight = [self.logView.heightAnchor constraintEqualToConstant:110];
    logHeight.priority = 999; logHeight.active = YES;
    self.controlsStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.titleLabel, self.hintLabel, connection, self.stateLabel,
        self.profiles, commands, self.statsLabel, personRow, self.personLabel, self.logView]];
    UIStackView *content = self.controlsStack;
    content.axis = UILayoutConstraintAxisVertical; content.spacing = 8;
    content.layoutMarginsRelativeArrangement = YES;
    content.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(10, 10, 10, 10);
    content.translatesAutoresizingMaskIntoConstraints = NO;
    self.controlsScrollView = [UIScrollView new];
    self.controlsScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.controlsScrollView.backgroundColor = [UIColor.systemBackgroundColor colorWithAlphaComponent:0.88];
    self.controlsScrollView.layer.cornerRadius = 12;
    self.controlsScrollView.clipsToBounds = YES;
    self.controlsScrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.controlsScrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.controlsScrollView addSubview:content];
    [self.view addSubview:self.controlsScrollView];
    self.videoOnlyButton = [self button:@"仅画面" action:@selector(videoOnlyTapped)];
    UIButtonConfiguration *toggleStyle = [self.videoOnlyButton.configuration copy];
    toggleStyle.baseForegroundColor = UIColor.whiteColor;
    toggleStyle.baseBackgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.6];
    self.videoOnlyButton.configuration = toggleStyle;
    self.videoOnlyButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.videoOnlyButton.accessibilityHint = @"隐藏控制面板，保留实时画面和人框；再次点击恢复界面。";
    [self.view addSubview:self.videoOnlyButton];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    UILayoutGuide *scrollContent = self.controlsScrollView.contentLayoutGuide;
    UILayoutGuide *scrollFrame = self.controlsScrollView.frameLayoutGuide;
    // Fill the display with video; keep interactive controls inside the safe area.
    [NSLayoutConstraint activateConstraints:@[
        [self.videoView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.videoView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.videoView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.videoView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.videoOnlyButton.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [self.videoOnlyButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [self.videoOnlyButton.widthAnchor constraintEqualToConstant:112],
        [self.controlsScrollView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [self.controlsScrollView.trailingAnchor constraintEqualToAnchor:self.videoOnlyButton.leadingAnchor constant:-8],
        [self.controlsScrollView.topAnchor constraintEqualToAnchor:self.videoOnlyButton.topAnchor],
        [self.controlsScrollView.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor constant:-8],
        [self.controlsScrollView.heightAnchor constraintGreaterThanOrEqualToConstant:42],
        [content.leadingAnchor constraintEqualToAnchor:scrollContent.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:scrollContent.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:scrollContent.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:scrollContent.bottomAnchor],
        [content.widthAnchor constraintEqualToAnchor:scrollFrame.widthAnchor]
    ]];
    NSLayoutConstraint *panelHeight = [self.controlsScrollView.heightAnchor constraintEqualToAnchor:content.heightAnchor];
    panelHeight.priority = UILayoutPriorityDefaultLow; panelHeight.active = YES;
    [self updateControlsLayout];
    self.client = [[GXCameraClient alloc] initWithVideoView:self.videoView]; self.client.delegate = self;
    self.personClient = [GXPersonClient new]; self.personClient.delegate = self;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(background:)
        name:UIApplicationDidEnterBackgroundNotification object:nil];
    [self applyStatus:@{}];
    [self renderPersonState];
    [self appendLog:@"首次连接请允许“本地网络”权限。请先关闭电脑测试程序，设备仅支持一个客户端。"];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; [self.client disconnect]; [self.personClient disconnect]; }
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self updateControlsLayout];
}
- (void)updateControlsLayout {
    BOOL compact = self.view.bounds.size.height < 500;
    self.titleLabel.hidden = self.hintLabel.hidden = compact;
    self.logView.hidden = self.view.bounds.size.height < 700;
    CGFloat spacing = compact ? 5 : 8;
    if (self.controlsStack.spacing != spacing) self.controlsStack.spacing = spacing;
}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation { return UIInterfaceOrientationLandscapeRight; }
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return self.videoOnly; }
- (void)videoOnlyTapped {
    [self.view endEditing:YES];
    self.videoOnly = !self.videoOnly;
    self.controlsScrollView.hidden = self.videoOnly;
    UIButtonConfiguration *configuration = [self.videoOnlyButton.configuration copy];
    configuration.title = self.videoOnly ? @"恢复界面" : @"仅画面";
    self.videoOnlyButton.configuration = configuration;
    self.videoOnlyButton.accessibilityHint = self.videoOnly ? @"显示控制面板，继续播放实时画面和人框。" :
        @"隐藏控制面板，保留实时画面和人框；再次点击恢复界面。";
    [self setNeedsUpdateOfHomeIndicatorAutoHidden];
}
- (void)background:(NSNotification *)notification {
    (void)notification;
    [self.client disconnect]; [self.personClient disconnect]; UIApplication.sharedApplication.idleTimerDisabled = NO;
    [self appendLog:@"进入后台：断开并清理视频。返回后手动连接、开始。"];
}
- (BOOL)textFieldShouldReturn:(UITextField *)textField { [textField resignFirstResponder]; return YES; }
- (void)connectTapped {
    [self.view endEditing:YES];
    [self.videoView setPersonDetectionResult:nil];
    if ([self.status[@"connected"] boolValue] || [self.status[@"connecting"] boolValue]) {
        [self.client disconnect]; [self.personClient disconnect]; return;
    }
    NSString *host = [self.hostField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *portString = self.portField.text ?: @"";
    NSCharacterSet *nonDigits = NSCharacterSet.decimalDigitCharacterSet.invertedSet;
    NSInteger port = portString.integerValue;
    if (!host.length || [portString rangeOfCharacterFromSet:nonDigits].location != NSNotFound || port < 1 || port > 65535) {
        [self appendLog:@"请输入正确的设备 IP 和 1～65535 的端口。"] ; return;
    }
    [NSUserDefaults.standardUserDefaults setObject:host forKey:@"GXHost"];
    [NSUserDefaults.standardUserDefaults setObject:portString forKey:@"GXPort"];
    [self.client connectToHost:host port:(uint16_t)port];
    [self.personClient connectToHost:host];
}
- (void)startTapped { [self.client startProfile:(uint8_t)(self.profiles.selectedSegmentIndex + 1)]; }
- (void)stopTapped { [self.videoView setPersonDetectionResult:nil]; [self.client stop]; }
- (void)statusTapped { [self.client getStatus]; }
- (void)idrTapped { [self.client requestIDR]; }
- (void)personConnectTapped {
    [self.videoView setPersonDetectionResult:nil];
    NSString *host = [self.hostField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (host.length) [self.personClient connectToHost:host];
}
- (void)personSwitchChanged {
    [self.videoView setPersonDetectionResult:nil];
    [self.personClient setDetectionEnabled:self.personSwitch.on];
}
- (void)personClient:(GXPersonClient *)client stateChanged:(NSDictionary<NSString *,id> *)state {
    (void)client; self.personState = state; [self renderPersonState];
}
- (void)personClient:(GXPersonClient *)client logMessage:(NSString *)message { (void)client; [self appendLog:message]; }
- (void)renderPersonState {
    NSDictionary *s = self.personState ?: @{};
    BOOL connected = [s[@"connected"] boolValue], known = [s[@"known"] boolValue];
    self.personSwitch.enabled = connected && known && [s[@"ready"] boolValue] && ![s[@"pending"] boolValue];
    if (![s[@"pending"] boolValue]) [self.personSwitch setOn:[s[@"enabled"] boolValue] animated:NO];
    self.personConnectButton.enabled = ![s[@"connecting"] boolValue];
    NSString *text;
    if (!connected) text = [s[@"connecting"] boolValue] ? @"识别端口连接中…" : @"识别端口未连接；点击“识别重连”连接 5601";
    else if (!known) text = @"等待读取识别状态…";
    else if (![s[@"ready"] boolValue]) text = [NSString stringWithFormat:@"模型未就绪，init_status=%@", s[@"init_status"]];
    else if ([s[@"pending"] boolValue]) text = @"等待识别开关应答…";
    else if (![s[@"enabled"] boolValue]) text = @"人形识别已关闭；视频继续播放";
    else if (![s[@"running"] boolValue]) text = @"人形识别已开启，等待视频 START";
    else {
        NSDictionary *r = s[@"result"];
        BOOL matches = [self.status[@"state"] unsignedIntValue] == GXVPRunning &&
            [r[@"stream"] unsignedIntValue] == [self.status[@"stream"] unsignedIntValue];
        if (!r || !matches) text = @"人形识别已开启，等待当前视频流检测结果…";
        else if (![r[@"valid"] boolValue]) text = [NSString stringWithFormat:@"检测失败，seq=%@ status=%@", r[@"seq"], r[@"status"]];
        else {
            text = [NSString stringWithFormat:@"人数 %@ · Stream %@ · 检测序号 %@ · 推理 %.1f ms",
                r[@"count"], r[@"stream"], r[@"seq"], [r[@"run_us"] doubleValue]/1000];
            NSDictionary *box = [r[@"boxes"] firstObject];
            if (box) text = [text stringByAppendingFormat:@"\n首框 score=%.3f  视频坐标 (%@,%@,%@,%@)",
                [box[@"score"] doubleValue], box[@"video_x"], box[@"video_y"], box[@"video_w"], box[@"video_h"]];
        }
    }
    self.personLabel.text = text;
    NSDictionary *result = s[@"result"];
    BOOL showBoxes = connected && known && [s[@"ready"] boolValue] && [s[@"enabled"] boolValue] &&
        [s[@"running"] boolValue] && ![s[@"pending"] boolValue] && result && [result[@"valid"] boolValue] &&
        [result[@"status"] integerValue] == 0 && [self.status[@"connected"] boolValue] &&
        [self.status[@"configured"] boolValue] && ![self.status[@"pending"] boolValue] &&
        [self.status[@"state"] unsignedIntValue] == GXVPRunning &&
        [result[@"generation"] unsignedIntValue] == [s[@"generation"] unsignedIntValue] &&
        [result[@"stream"] unsignedIntValue] == [s[@"stream"] unsignedIntValue] &&
        [result[@"stream"] unsignedIntValue] == [self.status[@"stream"] unsignedIntValue] &&
        [result[@"video_width"] unsignedIntValue] == [self.status[@"width"] unsignedIntValue] &&
        [result[@"video_height"] unsignedIntValue] == [self.status[@"height"] unsignedIntValue];
    [self.videoView setPersonDetectionResult:showBoxes ? result : nil];
}
- (void)cameraClient:(GXCameraClient *)client statusChanged:(NSDictionary<NSString *,id> *)status {
    (void)client; [self applyStatus:status];
}
- (void)cameraClient:(GXCameraClient *)client logMessage:(NSString *)message { (void)client; [self appendLog:message]; }
- (void)applyStatus:(NSDictionary<NSString *, id> *)status {
    self.status = status;
    BOOL connected = [status[@"connected"] boolValue], connecting = [status[@"connecting"] boolValue];
    BOOL pending = [status[@"pending"] boolValue]; NSUInteger state = [status[@"state"] unsignedIntegerValue];
    UIButtonConfiguration *configuration = [self.connectButton.configuration copy];
    configuration.title = connecting ? @"取消" : connected ? @"断开" : @"连接";
    self.connectButton.configuration = configuration;
    self.hostField.enabled = self.portField.enabled = !connected && !connecting;
    self.profiles.enabled = self.startButton.enabled = connected && state == GXVPIdle && !pending;
    self.stopButton.enabled = connected && !pending;
    self.statusButton.enabled = connected; self.idrButton.enabled = connected && state == GXVPRunning && !pending;
    NSArray *states = @[@"空闲", @"启动中", @"播放中", @"停止中"];
    NSString *stateText = !connected ? (connecting ? @"连接中…" : @"未连接") :
        [NSString stringWithFormat:@"%@%@ · Stream %u", states[MIN(state, 3)], pending ? @"（等待应答）" : @"",
            [status[@"stream"] unsignedIntValue]];
    self.stateLabel.text = stateText;
    self.stateLabel.textColor = connected ? self.view.tintColor : UIColor.secondaryLabelColor;
    if ([status[@"profile"] unsignedIntValue] && state == GXVPRunning)
        self.profiles.selectedSegmentIndex = [status[@"profile"] integerValue] - 1;
    BOOL hardware = [status[@"hardware"] boolValue];
    self.statsLabel.text = [NSString stringWithFormat:
        @"接收 %.1f fps · 硬解 %.1f fps · 显示 %.1f fps\n%.0f kbit/s · %@ · 队列 %@ · 丢弃 %@ / 替换 %@",
        [status[@"receiveFPS"] doubleValue], [status[@"decodeFPS"] doubleValue], [status[@"displayFPS"] doubleValue],
        [status[@"kbps"] doubleValue], hardware ? @"硬件解码" : @"等待视频", status[@"queue"] ?: @0,
        status[@"drops"] ?: @0, status[@"replaced"] ?: @0];
    UIApplication.sharedApplication.idleTimerDisabled = connected && state == GXVPRunning;
    [self renderPersonState];
}
- (void)appendLog:(NSString *)message {
    NSDateFormatter *formatter = [NSDateFormatter new]; formatter.dateFormat = @"HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"%@  %@", [formatter stringFromDate:NSDate.date], message];
    [self.logs addObject:line]; if (self.logs.count > 100) [self.logs removeObjectAtIndex:0];
    self.logView.text = [self.logs componentsJoinedByString:@"\n"];
    if (self.logView.text.length) [self.logView scrollRangeToVisible:NSMakeRange(self.logView.text.length - 1, 1)];
    NSLog(@"%@", line);
}
@end
