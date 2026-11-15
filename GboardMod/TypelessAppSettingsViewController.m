#import "TypelessAppSettingsViewController.h"
#import "TypelessConfig.h"
#import "TypelessHostBridge.h"
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <Speech/Speech.h>

@interface TypelessAppSettingsViewController () <UITextFieldDelegate, UITextViewDelegate>
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *contentStack;

// Status & Keep-Alive card
@property (nonatomic, strong) UIView *statusDot;
@property (nonatomic, strong) UILabel *statusTitleLabel;
@property (nonatomic, strong) UILabel *statusDetailLabel;
@property (nonatomic, strong) UISegmentedControl *launchInterfaceSegment;
@property (nonatomic, strong) UISwitch *keepAliveSwitch;
@property (nonatomic, strong) UISwitch *pipSwitch;
@property (nonatomic, strong) NSTimer *statusRefreshTimer;

// Separated ASR (Voice) card
@property (nonatomic, strong) UISegmentedControl *asrEngineSegment;
@property (nonatomic, strong) UIStackView *asrCloudContainer;
@property (nonatomic, strong) UITextField *asrUrlField;
@property (nonatomic, strong) UITextField *asrKeyField;
@property (nonatomic, strong) UITextField *asrModelField;
@property (nonatomic, strong) UILabel *asrTestResultLabel;

// Separated LLM (Text) card
@property (nonatomic, strong) UITextField *llmUrlField;
@property (nonatomic, strong) UITextField *llmKeyField;
@property (nonatomic, strong) UITextField *llmModelField;
@property (nonatomic, strong) UISwitch *smartCleanupSwitch;
@property (nonatomic, strong) UILabel *llmTestResultLabel;

// Prompt card
@property (nonatomic, strong) UISegmentedControl *promptModeSegment;
@property (nonatomic, strong) UITextView *promptTextView;
@property (nonatomic, copy) NSMutableArray<NSString *> *draftPrompts;
@property (nonatomic, assign) NSInteger activePromptIndex;
@end

@implementation TypelessAppSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [[TypelessConfig sharedConfig] load];
    TypelessConfig *cfg = [TypelessConfig sharedConfig];

    self.draftPrompts = [NSMutableArray arrayWithObjects:
                         [cfg promptForMode:TypelessVoiceModeDictate],
                         [cfg promptForMode:TypelessVoiceModeEdit],
                         [cfg promptForMode:TypelessVoiceModeTranslate],
                         [cfg promptForMode:TypelessVoiceModeHelpWrite],
                         nil];
    self.activePromptIndex = 0;

    if (@available(iOS 13.0, *)) {
        self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    } else {
        self.view.backgroundColor = [UIColor colorWithRed:0.95 green:0.95 blue:0.97 alpha:1.0];
    }

    [self setupNavigationBar];
    [self setupScrollLayout];
    [self buildKeepAliveSection];
    [self buildAsrSection];
    [self buildLlmSection];
    [self buildPromptSection];
    [self buildFooterActions];
    [self loadConfigIntoUI];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    tap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:tap];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillHideNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshBridgeStatusUI];
    [self.statusRefreshTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.statusRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(NSTimer * _Nonnull timer) {
        [weakSelf refreshBridgeStatusUI];
    }];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.statusRefreshTimer invalidate];
    self.statusRefreshTimer = nil;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Navigation & Safe Scroll Layout

- (void)setupNavigationBar {
    self.title = @"Typeless AI 设置";
    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
        [appearance configureWithDefaultBackground];
        appearance.backgroundColor = [UIColor systemGroupedBackgroundColor];
        self.navigationController.navigationBar.standardAppearance = appearance;
        self.navigationController.navigationBar.scrollEdgeAppearance = appearance;
    }

    UIBarButtonItem *closeBtn = [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                                                 style:UIBarButtonItemStylePlain
                                                                target:self
                                                                action:@selector(closeTapped)];
    self.navigationItem.leftBarButtonItem = closeBtn;

    UIBarButtonItem *saveBtn = [[UIBarButtonItem alloc] initWithTitle:@"保存"
                                                                style:UIBarButtonItemStyleDone
                                                               target:self
                                                               action:@selector(saveTapped)];
    saveBtn.tintColor = [UIColor colorWithRed:0.15 green:0.39 blue:0.92 alpha:1.0];
    self.navigationItem.rightBarButtonItem = saveBtn;
}

- (void)setupScrollLayout {
    self.scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:self.scrollView];

    self.contentStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    self.contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentStack.axis = UILayoutConstraintAxisVertical;
    self.contentStack.spacing = 16.0;
    self.contentStack.alignment = UIStackViewAlignmentFill;
    [self.scrollView addSubview:self.contentStack];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.contentStack.topAnchor constraintEqualToAnchor:self.scrollView.topAnchor constant:12.0],
        [self.contentStack.leadingAnchor constraintEqualToAnchor:self.scrollView.leadingAnchor constant:16.0],
        [self.contentStack.trailingAnchor constraintEqualToAnchor:self.scrollView.trailingAnchor constant:-16.0],
        [self.contentStack.bottomAnchor constraintEqualToAnchor:self.scrollView.bottomAnchor constant:-28.0],
        [self.contentStack.widthAnchor constraintEqualToAnchor:self.scrollView.widthAnchor constant:-32.0],
    ]];
}

#pragma mark - Reusable UI Builders

- (UIView *)addSectionHeader:(NSString *)title subtitle:(nullable NSString *)subtitle {
    UIStackView *hdr = [[UIStackView alloc] init];
    hdr.axis = UILayoutConstraintAxisHorizontal;
    hdr.alignment = UIStackViewAlignmentCenter;
    hdr.distribution = UIStackViewDistributionEqualSpacing;
    hdr.layoutMargins = UIEdgeInsetsMake(4, 4, 0, 4);
    hdr.layoutMarginsRelativeArrangement = YES;

    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = title;
    lbl.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
    if (@available(iOS 13.0, *)) lbl.textColor = [UIColor secondaryLabelColor];
    [hdr addArrangedSubview:lbl];

    if (subtitle.length > 0) {
        UILabel *sub = [[UILabel alloc] init];
        sub.text = subtitle;
        sub.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        if (@available(iOS 13.0, *)) sub.textColor = [UIColor tertiaryLabelColor];
        [hdr addArrangedSubview:sub];
    }

    [self.contentStack addArrangedSubview:hdr];
    return hdr;
}

- (UIStackView *)makeCardStack {
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = 16.0;
    if (@available(iOS 13.0, *)) {
        card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    } else {
        card.backgroundColor = [UIColor whiteColor];
    }

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12.0;
    [card addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:14.0],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14.0],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14.0],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14.0],
    ]];

    [self.contentStack addArrangedSubview:card];
    return stack;
}

- (UIView *)makeHairline {
    UIView *line = [[UIView alloc] init];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(iOS 13.0, *)) {
        line.backgroundColor = [UIColor separatorColor];
    } else {
        line.backgroundColor = [UIColor colorWithWhite:0.88 alpha:1.0];
    }
    [line.heightAnchor constraintEqualToConstant:1.0 / [UIScreen mainScreen].scale].active = YES;
    return line;
}

- (UIView *)makeIconBadge:(NSString *)sfSymbol color:(UIColor *)bg {
    UIView *box = [[UIView alloc] init];
    box.translatesAutoresizingMaskIntoConstraints = NO;
    box.backgroundColor = bg;
    box.layer.cornerRadius = 8.0;
    [box.widthAnchor constraintEqualToConstant:30.0].active = YES;
    [box.heightAnchor constraintEqualToConstant:30.0].active = YES;

    if (@available(iOS 13.0, *)) {
        UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:sfSymbol]];
        iv.translatesAutoresizingMaskIntoConstraints = NO;
        iv.tintColor = [UIColor whiteColor];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        [box addSubview:iv];
        [NSLayoutConstraint activateConstraints:@[
            [iv.centerXAnchor constraintEqualToAnchor:box.centerXAnchor],
            [iv.centerYAnchor constraintEqualToAnchor:box.centerYAnchor],
            [iv.widthAnchor constraintEqualToConstant:17.0],
            [iv.heightAnchor constraintEqualToConstant:17.0],
        ]];
    }
    return box;
}

- (UIView *)makeSwitchRowTitle:(NSString *)title
                      subtitle:(nullable NSString *)subtitle
                      sfSymbol:(NSString *)sfSymbol
                     iconColor:(UIColor *)iconColor
                     outSwitch:(UISwitch * _Nonnull * _Nonnull)outSwitch
                        action:(SEL)action {
    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 12.0;

    [row addArrangedSubview:[self makeIconBadge:sfSymbol color:iconColor]];

    UIStackView *txtStack = [[UIStackView alloc] init];
    txtStack.axis = UILayoutConstraintAxisVertical;
    txtStack.spacing = 2.0;

    UILabel *tLbl = [[UILabel alloc] init];
    tLbl.text = title;
    tLbl.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [txtStack addArrangedSubview:tLbl];

    if (subtitle.length > 0) {
        UILabel *sLbl = [[UILabel alloc] init];
        sLbl.text = subtitle;
        sLbl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        sLbl.numberOfLines = 0;
        if (@available(iOS 13.0, *)) sLbl.textColor = [UIColor secondaryLabelColor];
        [txtStack addArrangedSubview:sLbl];
    }

    [row addArrangedSubview:txtStack];

    UISwitch *sw = [[UISwitch alloc] init];
    sw.onTintColor = [UIColor colorWithRed:0.15 green:0.39 blue:0.92 alpha:1.0];
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [row addArrangedSubview:sw];
    *outSwitch = sw;

    return row;
}

- (UIView *)makeFieldRowWithLabel:(NSString *)label
                      placeholder:(NSString *)placeholder
                           secure:(BOOL)secure
                         outField:(UITextField * _Nonnull * _Nonnull)outField {
    UIStackView *box = [[UIStackView alloc] init];
    box.axis = UILayoutConstraintAxisVertical;
    box.spacing = 6.0;

    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = label;
    lbl.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
    if (@available(iOS 13.0, *)) lbl.textColor = [UIColor secondaryLabelColor];
    [box addArrangedSubview:lbl];

    UIView *fieldWrap = [[UIView alloc] init];
    fieldWrap.translatesAutoresizingMaskIntoConstraints = NO;
    fieldWrap.layer.cornerRadius = 10.0;
    if (@available(iOS 13.0, *)) {
        fieldWrap.backgroundColor = [UIColor tertiarySystemFillColor];
    } else {
        fieldWrap.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1.0];
    }

    UITextField *tf = [[UITextField alloc] init];
    tf.translatesAutoresizingMaskIntoConstraints = NO;
    tf.placeholder = placeholder;
    tf.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
    tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    tf.returnKeyType = UIReturnKeyDone;
    tf.secureTextEntry = secure;
    tf.delegate = self;
    [fieldWrap addSubview:tf];

    UIButton *auxBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    auxBtn.translatesAutoresizingMaskIntoConstraints = NO;
    auxBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    [auxBtn setTitle:@"粘贴" forState:UIControlStateNormal];
    auxBtn.tintColor = [UIColor colorWithRed:0.15 green:0.39 blue:0.92 alpha:1.0];
    [auxBtn addTarget:self action:@selector(pasteIntoSiblingField:) forControlEvents:UIControlEventTouchUpInside];
    [fieldWrap addSubview:auxBtn];

    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
        [fieldWrap.heightAnchor constraintEqualToConstant:40.0],
        [tf.leadingAnchor constraintEqualToAnchor:fieldWrap.leadingAnchor constant:12.0],
        [tf.topAnchor constraintEqualToAnchor:fieldWrap.topAnchor],
        [tf.bottomAnchor constraintEqualToAnchor:fieldWrap.bottomAnchor],
        [auxBtn.trailingAnchor constraintEqualToAnchor:fieldWrap.trailingAnchor constant:-10.0],
        [auxBtn.centerYAnchor constraintEqualToAnchor:fieldWrap.centerYAnchor],
    ]];

    if (secure) {
        UIButton *eyeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        eyeBtn.translatesAutoresizingMaskIntoConstraints = NO;
        eyeBtn.tag = 7701;
        if (@available(iOS 13.0, *)) {
            [eyeBtn setImage:[UIImage systemImageNamed:@"eye"] forState:UIControlStateNormal];
            eyeBtn.tintColor = [UIColor secondaryLabelColor];
        } else {
            [eyeBtn setTitle:@"显" forState:UIControlStateNormal];
            eyeBtn.tintColor = [UIColor grayColor];
        }
        [eyeBtn addTarget:self action:@selector(toggleSecureField:) forControlEvents:UIControlEventTouchUpInside];
        [fieldWrap addSubview:eyeBtn];

        [constraints addObjectsFromArray:@[
            [eyeBtn.trailingAnchor constraintEqualToAnchor:auxBtn.leadingAnchor constant:-6.0],
            [eyeBtn.centerYAnchor constraintEqualToAnchor:fieldWrap.centerYAnchor],
            [eyeBtn.widthAnchor constraintEqualToConstant:26.0],
            [tf.trailingAnchor constraintEqualToAnchor:eyeBtn.leadingAnchor constant:-6.0],
        ]];
    } else {
        [constraints addObject:[tf.trailingAnchor constraintEqualToAnchor:auxBtn.leadingAnchor constant:-6.0]];
    }

    [NSLayoutConstraint activateConstraints:constraints];
    [box addArrangedSubview:fieldWrap];
    *outField = tf;
    return box;
}

- (UIStackView *)makeChipRowWithTitles:(NSArray<NSString *> *)titles action:(SEL)action {
    UIScrollView *sc = [[UIScrollView alloc] init];
    sc.showsHorizontalScrollIndicator = NO;

    UIStackView *row = [[UIStackView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 8.0;
    [sc addSubview:row];

    [NSLayoutConstraint activateConstraints:@[
        [sc.heightAnchor constraintEqualToConstant:30.0],
        [row.topAnchor constraintEqualToAnchor:sc.topAnchor],
        [row.bottomAnchor constraintEqualToAnchor:sc.bottomAnchor],
        [row.leadingAnchor constraintEqualToAnchor:sc.leadingAnchor],
        [row.trailingAnchor constraintEqualToAnchor:sc.trailingAnchor],
        [row.heightAnchor constraintEqualToAnchor:sc.heightAnchor],
    ]];

    for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.tag = i;
        [btn setTitle:titles[i] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
        btn.contentEdgeInsets = UIEdgeInsetsMake(4, 11, 4, 11);
        btn.layer.cornerRadius = 8.0;
        if (@available(iOS 13.0, *)) {
            btn.backgroundColor = [UIColor tertiarySystemFillColor];
            [btn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        } else {
            btn.backgroundColor = [UIColor colorWithWhite:0.93 alpha:1.0];
        }
        [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
        [row addArrangedSubview:btn];
    }

    UIStackView *wrapper = [[UIStackView alloc] initWithArrangedSubviews:@[sc]];
    wrapper.axis = UILayoutConstraintAxisVertical;
    return wrapper;
}

- (UIButton *)makeTintedButton:(NSString *)title color:(UIColor *)tint bgAlpha:(CGFloat)alpha action:(SEL)action {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:tint forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
    btn.backgroundColor = [tint colorWithAlphaComponent:alpha];
    btn.layer.cornerRadius = 10.0;
    [btn.heightAnchor constraintEqualToConstant:38.0].active = YES;
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

#pragma mark - Sections

- (void)buildKeepAliveSection {
    [self addSectionHeader:@"后台语音保活与权限" subtitle:@"免切 App 键盘直录"];
    UIStackView *card = [self makeCardStack];

    // Live status pill row
    UIStackView *stRow = [[UIStackView alloc] init];
    stRow.axis = UILayoutConstraintAxisHorizontal;
    stRow.alignment = UIStackViewAlignmentTop;
    stRow.spacing = 10.0;

    self.statusDot = [[UIView alloc] init];
    self.statusDot.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusDot.layer.cornerRadius = 5.0;
    [self.statusDot.widthAnchor constraintEqualToConstant:10.0].active = YES;
    [self.statusDot.heightAnchor constraintEqualToConstant:10.0].active = YES;

    UIView *dotHolder = [[UIView alloc] init];
    dotHolder.translatesAutoresizingMaskIntoConstraints = NO;
    [dotHolder addSubview:self.statusDot];
    [NSLayoutConstraint activateConstraints:@[
        [dotHolder.widthAnchor constraintEqualToConstant:12.0],
        [dotHolder.heightAnchor constraintEqualToConstant:18.0],
        [self.statusDot.centerXAnchor constraintEqualToAnchor:dotHolder.centerXAnchor],
        [self.statusDot.centerYAnchor constraintEqualToAnchor:dotHolder.centerYAnchor],
    ]];

    UIStackView *lblCol = [[UIStackView alloc] init];
    lblCol.axis = UILayoutConstraintAxisVertical;
    lblCol.spacing = 3.0;

    self.statusTitleLabel = [[UILabel alloc] init];
    self.statusTitleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];

    self.statusDetailLabel = [[UILabel alloc] init];
    self.statusDetailLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
    self.statusDetailLabel.numberOfLines = 0;
    if (@available(iOS 13.0, *)) self.statusDetailLabel.textColor = [UIColor secondaryLabelColor];

    [lblCol addArrangedSubview:self.statusTitleLabel];
    [lblCol addArrangedSubview:self.statusDetailLabel];
    [stRow addArrangedSubview:dotHolder];
    [stRow addArrangedSubview:lblCol];
    [card addArrangedSubview:stRow];

    [card addArrangedSubview:[self makeHairline]];

    UILabel *launchTitle = [[UILabel alloc] init];
    launchTitle.text = @"默认启动界面（每次唤起键盘）";
    launchTitle.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightSemibold];
    [card addArrangedSubview:launchTitle];

    self.launchInterfaceSegment = [[UISegmentedControl alloc] initWithItems:@[@"键盘界面 (九宫格)", @"语音输入界面"]];
    [self.launchInterfaceSegment addTarget:self action:@selector(launchInterfaceChanged:) forControlEvents:UIControlEventValueChanged];
    [card addArrangedSubview:self.launchInterfaceSegment];

    UILabel *launchHint = [[UILabel alloc] init];
    launchHint.text = @"提示：切换或默认进入语音界面时仅展示待命面板，需手动点击/长按麦克风才会录音";
    launchHint.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    launchHint.numberOfLines = 0;
    if (@available(iOS 13.0, *)) launchHint.textColor = [UIColor secondaryLabelColor];
    [card addArrangedSubview:launchHint];

    [card addArrangedSubview:[self makeHairline]];

    UISwitch *kaSw = nil;
    [card addArrangedSubview:[self makeSwitchRowTitle:@"后台语音保活（纯音频 · 推荐）"
                                             subtitle:@"无需画中画浮窗！依靠静音音频会话维持后台与 127.0.0.1 桥接在线"
                                             sfSymbol:@"waveform.badge.mic"
                                            iconColor:[UIColor colorWithRed:0.06 green:0.73 blue:0.51 alpha:1.0]
                                            outSwitch:&kaSw
                                               action:@selector(keepAliveSwitchChanged:)]];
    self.keepAliveSwitch = kaSw;

    [card addArrangedSubview:[self makeHairline]];

    UISwitch *pipSw = nil;
    [card addArrangedSubview:[self makeSwitchRowTitle:@"画中画 (PiP) 辅助保活（可选·默认关）"
                                             subtitle:@"非必需；仅当纯音频保活在后台仍被系统中断时再按需开启 (iOS 15+)"
                                             sfSymbol:@"pip.fill"
                                            iconColor:[UIColor colorWithRed:0.39 green:0.40 blue:0.95 alpha:1.0]
                                            outSwitch:&pipSw
                                               action:@selector(pipSwitchChanged:)]];
    self.pipSwitch = pipSw;

    UIStackView *btnRow = [[UIStackView alloc] init];
    btnRow.axis = UILayoutConstraintAxisHorizontal;
    btnRow.spacing = 10.0;
    btnRow.distribution = UIStackViewDistributionFillEqually;

    UIColor *blue = [UIColor colorWithRed:0.15 green:0.39 blue:0.92 alpha:1.0];
    UIColor *emerald = [UIColor colorWithRed:0.02 green:0.59 blue:0.41 alpha:1.0];
    [btnRow addArrangedSubview:[self makeTintedButton:@"授权麦克风/识别" color:emerald bgAlpha:0.12 action:@selector(requestPermissionsTapped)]];
    [btnRow addArrangedSubview:[self makeTintedButton:@"诊断保活链路" color:blue bgAlpha:0.10 action:@selector(diagnoseBridgeTapped)]];
    [card addArrangedSubview:btnRow];
}

- (void)buildAsrSection {
    [self addSectionHeader:@"语音识别模型 (ASR)" subtitle:@"独立负责语音转文字"];
    UIStackView *card = [self makeCardStack];

    self.asrEngineSegment = [[UISegmentedControl alloc] initWithItems:@[@"Apple 本地识别", @"Whisper 云端 API"]];
    [self.asrEngineSegment addTarget:self action:@selector(asrEngineChanged:) forControlEvents:UIControlEventValueChanged];
    [card addArrangedSubview:self.asrEngineSegment];

    self.asrCloudContainer = [[UIStackView alloc] init];
    self.asrCloudContainer.axis = UILayoutConstraintAxisVertical;
    self.asrCloudContainer.spacing = 10.0;

    [self.asrCloudContainer addArrangedSubview:[self makeChipRowWithTitles:@[@"OpenAI", @"Groq", @"SiliconFlow", @"自定义"] action:@selector(asrPresetTapped:)]];

    UITextField *urlF = nil, *keyF = nil, *modF = nil;
    [self.asrCloudContainer addArrangedSubview:[self makeFieldRowWithLabel:@"语音 Base URL" placeholder:@"https://api.openai.com/v1" secure:NO outField:&urlF]];
    [self.asrCloudContainer addArrangedSubview:[self makeFieldRowWithLabel:@"语音 API Key" placeholder:@"sk-..." secure:YES outField:&keyF]];
    [self.asrCloudContainer addArrangedSubview:[self makeFieldRowWithLabel:@"语音 Model ID" placeholder:@"whisper-1" secure:NO outField:&modF]];
    self.asrUrlField = urlF;
    self.asrKeyField = keyF;
    self.asrModelField = modF;

    [self.asrCloudContainer addArrangedSubview:[self makeChipRowWithTitles:@[@"whisper-1", @"whisper-large-v3-turbo", @"FunAudioLLM/SenseVoiceSmall"] action:@selector(asrModelChipTapped:)]];

    [card addArrangedSubview:self.asrCloudContainer];

    UIColor *orange = [UIColor colorWithRed:0.85 green:0.47 blue:0.04 alpha:1.0];
    [card addArrangedSubview:[self makeTintedButton:@"测试语音模型接口" color:orange bgAlpha:0.12 action:@selector(testAsrTapped)]];

    self.asrTestResultLabel = [[UILabel alloc] init];
    self.asrTestResultLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    self.asrTestResultLabel.numberOfLines = 0;
    self.asrTestResultLabel.hidden = YES;
    [card addArrangedSubview:self.asrTestResultLabel];
}

- (void)buildLlmSection {
    UIStackView *hdr = (UIStackView *)[self addSectionHeader:@"文本处理模型 (LLM)" subtitle:nil];
    UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [copyBtn setTitle:@"复用语音接口与 Key" forState:UIControlStateNormal];
    copyBtn.titleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
    copyBtn.tintColor = [UIColor colorWithRed:0.15 green:0.39 blue:0.92 alpha:1.0];
    [copyBtn addTarget:self action:@selector(copyAsrToLlmTapped) forControlEvents:UIControlEventTouchUpInside];
    [hdr addArrangedSubview:copyBtn];

    UIStackView *card = [self makeCardStack];

    [card addArrangedSubview:[self makeChipRowWithTitles:@[@"OpenAI", @"DeepSeek", @"Groq", @"SiliconFlow"] action:@selector(llmPresetTapped:)]];

    UITextField *urlF = nil, *keyF = nil, *modF = nil;
    [card addArrangedSubview:[self makeFieldRowWithLabel:@"文本 Base URL" placeholder:@"https://api.openai.com/v1" secure:NO outField:&urlF]];
    [card addArrangedSubview:[self makeFieldRowWithLabel:@"文本 API Key" placeholder:@"sk-..." secure:YES outField:&keyF]];
    [card addArrangedSubview:[self makeFieldRowWithLabel:@"文本 Model ID" placeholder:@"gpt-4o-mini" secure:NO outField:&modF]];
    self.llmUrlField = urlF;
    self.llmKeyField = keyF;
    self.llmModelField = modF;

    [card addArrangedSubview:[self makeChipRowWithTitles:@[@"gpt-4o-mini", @"deepseek-chat", @"Qwen/Qwen2.5-7B-Instruct"] action:@selector(llmModelChipTapped:)]];

    [card addArrangedSubview:[self makeHairline]];

    UISwitch *cleanupSw = nil;
    [card addArrangedSubview:[self makeSwitchRowTitle:@"听写后自动 AI 润色排版"
                                             subtitle:@"关闭则「润色听写」只做原样语音上屏，改写/翻译/帮写仍用本模型"
                                             sfSymbol:@"sparkles"
                                            iconColor:[UIColor colorWithRed:0.55 green:0.36 blue:0.96 alpha:1.0]
                                            outSwitch:&cleanupSw
                                               action:@selector(smartCleanupChanged:)]];
    self.smartCleanupSwitch = cleanupSw;

    UIColor *blue = [UIColor colorWithRed:0.15 green:0.39 blue:0.92 alpha:1.0];
    [card addArrangedSubview:[self makeTintedButton:@"测试文本模型连通性" color:blue bgAlpha:0.12 action:@selector(testLlmTapped)]];

    self.llmTestResultLabel = [[UILabel alloc] init];
    self.llmTestResultLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    self.llmTestResultLabel.numberOfLines = 0;
    self.llmTestResultLabel.hidden = YES;
    [card addArrangedSubview:self.llmTestResultLabel];
}

- (void)buildPromptSection {
    [self addSectionHeader:@"各场景系统指令 (Prompt)" subtitle:@"按场景自动生效"];
    UIStackView *card = [self makeCardStack];

    self.promptModeSegment = [[UISegmentedControl alloc] initWithItems:@[@"润色听写", @"选中改写", @"实时翻译", @"AI 帮写"]];
    self.promptModeSegment.selectedSegmentIndex = 0;
    [self.promptModeSegment addTarget:self action:@selector(promptModeChanged:) forControlEvents:UIControlEventValueChanged];
    [card addArrangedSubview:self.promptModeSegment];

    self.promptTextView = [[UITextView alloc] init];
    self.promptTextView.translatesAutoresizingMaskIntoConstraints = NO;
    self.promptTextView.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightRegular];
    self.promptTextView.layer.cornerRadius = 10.0;
    self.promptTextView.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
    self.promptTextView.delegate = self;
    if (@available(iOS 13.0, *)) {
        self.promptTextView.backgroundColor = [UIColor tertiarySystemFillColor];
    } else {
        self.promptTextView.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1.0];
    }
    [self.promptTextView.heightAnchor constraintEqualToConstant:112.0].active = YES;
    [card addArrangedSubview:self.promptTextView];
}

- (void)buildFooterActions {
    UIButton *saveBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    saveBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [saveBtn setTitle:@"保存全部设置" forState:UIControlStateNormal];
    [saveBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    saveBtn.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    saveBtn.backgroundColor = [UIColor colorWithRed:0.15 green:0.39 blue:0.92 alpha:1.0];
    saveBtn.layer.cornerRadius = 14.0;
    [saveBtn.heightAnchor constraintEqualToConstant:48.0].active = YES;
    [saveBtn addTarget:self action:@selector(saveTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.contentStack addArrangedSubview:saveBtn];

    UIButton *resetBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [resetBtn setTitle:@"恢复默认配置" forState:UIControlStateNormal];
    [resetBtn setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    resetBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [resetBtn addTarget:self action:@selector(resetTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.contentStack addArrangedSubview:resetBtn];
}

#pragma mark - Load / Persist

- (void)loadConfigIntoUI {
    TypelessConfig *cfg = [TypelessConfig sharedConfig];
    self.launchInterfaceSegment.selectedSegmentIndex = (cfg.launchInterface == TypelessLaunchInterfaceVoice) ? 1 : 0;
    self.keepAliveSwitch.on = [TypelessHostBridge sharedBridge].isKeepAliveActive || [[NSUserDefaults standardUserDefaults] boolForKey:@"LintypeHostKeepAlivePref"];
    self.pipSwitch.on = cfg.pipKeepAliveEnabled;

    self.asrEngineSegment.selectedSegmentIndex = cfg.useAppleASR ? 0 : 1;
    self.asrUrlField.text = cfg.asrBaseURL;
    self.asrKeyField.text = cfg.asrApiKey;
    self.asrModelField.text = cfg.asrModel;
    [self updateAsrCloudVisibility];

    self.llmUrlField.text = cfg.llmBaseURL;
    self.llmKeyField.text = cfg.llmApiKey;
    self.llmModelField.text = cfg.llmModel;
    self.smartCleanupSwitch.on = cfg.smartDictationCleanup;

    self.draftPrompts = [NSMutableArray arrayWithObjects:
                         [cfg promptForMode:TypelessVoiceModeDictate],
                         [cfg promptForMode:TypelessVoiceModeEdit],
                         [cfg promptForMode:TypelessVoiceModeTranslate],
                         [cfg promptForMode:TypelessVoiceModeHelpWrite],
                         nil];
    self.promptTextView.text = self.draftPrompts[self.activePromptIndex];
    [self refreshBridgeStatusUI];
}

- (void)saveUIToConfig {
    if (self.activePromptIndex >= 0 && self.activePromptIndex < (NSInteger)self.draftPrompts.count) {
        self.draftPrompts[self.activePromptIndex] = self.promptTextView.text ?: @"";
    }

    TypelessConfig *cfg = [TypelessConfig sharedConfig];
    cfg.launchInterface = (self.launchInterfaceSegment.selectedSegmentIndex == 1)
        ? TypelessLaunchInterfaceVoice
        : TypelessLaunchInterfaceKeyboard;
    cfg.pipKeepAliveEnabled = self.pipSwitch.on;
    cfg.useAppleASR = (self.asrEngineSegment.selectedSegmentIndex == 0);
    cfg.asrBaseURL = self.asrUrlField.text ?: @"";
    cfg.asrApiKey = self.asrKeyField.text ?: @"";
    cfg.asrModel = self.asrModelField.text ?: @"";

    cfg.llmBaseURL = self.llmUrlField.text ?: @"";
    cfg.llmApiKey = self.llmKeyField.text ?: @"";
    cfg.llmModel = self.llmModelField.text ?: @"";
    cfg.smartDictationCleanup = self.smartCleanupSwitch.on;

    cfg.customPromptDictate = self.draftPrompts[0];
    cfg.customPromptEdit = self.draftPrompts[1];
    cfg.customPromptTranslate = self.draftPrompts[2];
    cfg.customPromptHelpWrite = self.draftPrompts[3];
    [cfg save];
}

- (void)refreshBridgeStatusUI {
    TypelessHostBridge *bridge = [TypelessHostBridge sharedBridge];
    TypelessConfig *cfg = [TypelessConfig sharedConfig];

    BOOL active = bridge.isKeepAliveActive;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    BOOL micOK = ([[AVAudioSession sharedInstance] recordPermission] == AVAudioSessionRecordPermissionGranted);
#pragma clang diagnostic pop

    if (active && micOK) {
        self.statusDot.backgroundColor = [UIColor colorWithRed:0.06 green:0.73 blue:0.51 alpha:1.0];
        self.statusTitleLabel.text = bridge.isPipActive ? @"后台语音保活运行中 (PiP + 音频)" : @"后台语音保活运行中";
    } else if (active) {
        self.statusDot.backgroundColor = [UIColor colorWithRed:0.96 green:0.62 blue:0.04 alpha:1.0];
        self.statusTitleLabel.text = @"保活已启动 · 待授权麦克风";
    } else {
        self.statusDot.backgroundColor = [UIColor colorWithRed:0.58 green:0.64 blue:0.72 alpha:1.0];
        self.statusTitleLabel.text = @"后台语音保活未开启";
    }

    NSString *groupDesc = cfg.hasSharedAppGroup
        ? [NSString stringWithFormat:@"AppGroup: %@", cfg.detectedAppGroupIdentifier ?: @"已共享"]
        : @"无 AppGroup 权限（已自动启用 127.0.0.1 本地桥接）";
    NSString *pipDesc = @"";
    if (@available(iOS 15.0, *)) {
        pipDesc = [AVPictureInPictureController isPictureInPictureSupported]
            ? (bridge.isPipActive ? @"PiP 活跃" : (cfg.pipKeepAliveEnabled ? @"PiP 就绪" : @"纯音频保活（PiP 未开）"))
            : @"设备不支持 PiP";
    }
    self.statusDetailLabel.text = [NSString stringWithFormat:@"麦克风：%@  ·  %@\n%@",
                                   micOK ? @"已授权" : @"未授权",
                                   pipDesc,
                                   groupDesc];
}

- (void)updateAsrCloudVisibility {
    BOOL isApple = (self.asrEngineSegment.selectedSegmentIndex == 0);
    self.asrCloudContainer.alpha = isApple ? 0.55 : 1.0;
    self.asrUrlField.enabled = !isApple;
    self.asrKeyField.enabled = !isApple;
    self.asrModelField.enabled = !isApple;
}

#pragma mark - Actions

- (void)closeTapped {
    [self dismissKeyboard];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)saveTapped {
    [self dismissKeyboard];
    [self saveUIToConfig];
    [[TypelessHostBridge sharedBridge] refreshPipSettingIfActive];
    [self showAlertTitle:@"配置已保存" message:@"语音模型与文本模型配置已生效，并在键盘端同步。"];
}

- (void)resetTapped {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"恢复默认配置"
                                                                message:@"将清空自定义的语音与文本 API 设置并还原默认 Prompt，确认继续？"
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"确认重置" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [[TypelessConfig sharedConfig] resetToDefaults];
        [self loadConfigIntoUI];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)launchInterfaceChanged:(UISegmentedControl *)seg {
    TypelessConfig *cfg = [TypelessConfig sharedConfig];
    cfg.launchInterface = (seg.selectedSegmentIndex == 1)
        ? TypelessLaunchInterfaceVoice
        : TypelessLaunchInterfaceKeyboard;
    [cfg save];
}

- (void)keepAliveSwitchChanged:(UISwitch *)sw {
    if (sw.on) {
        [[TypelessHostBridge sharedBridge] startKeepAliveAndShowToast:NO];
    } else {
        [[TypelessHostBridge sharedBridge] stopKeepAlive];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refreshBridgeStatusUI];
    });
}

- (void)pipSwitchChanged:(UISwitch *)sw {
    [TypelessConfig sharedConfig].pipKeepAliveEnabled = sw.on;
    [[TypelessConfig sharedConfig] save];
    [[TypelessHostBridge sharedBridge] refreshPipSettingIfActive];
    if (sw.on && ![TypelessHostBridge sharedBridge].isKeepAliveActive) {
        self.keepAliveSwitch.on = YES;
        [[TypelessHostBridge sharedBridge] startKeepAliveAndShowToast:NO];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refreshBridgeStatusUI];
    });
}

- (void)requestPermissionsTapped {
    [[AVAudioSession sharedInstance] requestRecordPermission:^(BOOL micGranted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            Class sfCls = NSClassFromString(@"SFSpeechRecognizer");
            if (sfCls && [sfCls respondsToSelector:@selector(requestAuthorization:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                [sfCls requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self refreshBridgeStatusUI];
                        NSString *msg = [NSString stringWithFormat:@"麦克风：%@\nApple 语音识别：%@",
                                         micGranted ? @"已授权" : @"未授权（请前往系统设置-Gboard开启）",
                                         ((NSInteger)status == 3) ? @"已授权" : @"未授权或不可用"];
                        [self showAlertTitle:@"权限状态" message:msg];
                    });
                }];
#pragma clang diagnostic pop
            } else {
                [self refreshBridgeStatusUI];
                [self showAlertTitle:@"麦克风权限" message:micGranted ? @"麦克风已授权" : @"麦克风未授权，请在系统设置中开启"];
            }
        });
    }];
}

- (void)diagnoseBridgeTapped {
    TypelessHostBridge *bridge = [TypelessHostBridge sharedBridge];
    TypelessConfig *cfg = [TypelessConfig sharedConfig];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    BOOL micOK = ([[AVAudioSession sharedInstance] recordPermission] == AVAudioSessionRecordPermissionGranted);
#pragma clang diagnostic pop
    Class sfCls = NSClassFromString(@"SFSpeechRecognizer");
    NSInteger sfStatus = sfCls ? (NSInteger)[sfCls authorizationStatus] : -1;

    NSString *launchDesc = (cfg.launchInterface == TypelessLaunchInterfaceVoice)
        ? @"语音输入界面（手动点击开始录音）"
        : @"键盘界面（iOS 风格九宫格）";
    NSString *report = [NSString stringWithFormat:
                        @"• 启动默认界面：%@\n• 保活总开关：%@\n• 127.0.0.1 本地桥接：%@\n• PiP 画中画：%@\n• AppGroup 共享：%@\n• 麦克风权限：%@\n• 系统语音识别：%@\n\n提示：后台保活并非必须开启 PiP；默认纯音频保活已可在无悬浮窗的情况下维持 127.0.0.1 桥接在线。",
                        launchDesc,
                        bridge.isKeepAliveActive ? @"运行中" : @"未开启",
                        bridge.isLoopbackServerActive ? @"已监听 48912 端口" : @"未监听",
                        bridge.isPipActive ? @"活跃中" : (cfg.pipKeepAliveEnabled ? @"就绪（切出后台时自动触发）" : @"已关闭（默认纯音频保活）"),
                        cfg.hasSharedAppGroup ? (cfg.detectedAppGroupIdentifier ?: @"可用") : @"无（已启用本地直连）",
                        micOK ? @"已授权" : @"未授权",
                        (sfStatus == 3) ? @"已授权" : @"未授权"];
    [self showAlertTitle:@"保活与桥接诊断" message:report];
}

- (void)asrEngineChanged:(UISegmentedControl *)seg {
    [self updateAsrCloudVisibility];
}

- (void)asrPresetTapped:(UIButton *)btn {
    self.asrEngineSegment.selectedSegmentIndex = 1;
    [self updateAsrCloudVisibility];
    switch (btn.tag) {
        case 0:
            self.asrUrlField.text = @"https://api.openai.com/v1";
            self.asrModelField.text = @"whisper-1";
            break;
        case 1:
            self.asrUrlField.text = @"https://api.groq.com/openai/v1";
            self.asrModelField.text = @"whisper-large-v3-turbo";
            break;
        case 2:
            self.asrUrlField.text = @"https://api.siliconflow.cn/v1";
            self.asrModelField.text = @"FunAudioLLM/SenseVoiceSmall";
            break;
        default:
            break;
    }
}

- (void)asrModelChipTapped:(UIButton *)btn {
    NSString *t = [btn titleForState:UIControlStateNormal];
    if (t.length > 0) self.asrModelField.text = t;
}

- (void)copyAsrToLlmTapped {
    if (self.asrUrlField.text.length > 0) self.llmUrlField.text = self.asrUrlField.text;
    if (self.asrKeyField.text.length > 0) self.llmKeyField.text = self.asrKeyField.text;
    self.llmTestResultLabel.hidden = NO;
    self.llmTestResultLabel.textColor = [UIColor colorWithRed:0.06 green:0.55 blue:0.40 alpha:1.0];
    self.llmTestResultLabel.text = @"已将语音 Base URL 与 API Key 复制到文本模型配置（别忘了点击保存）。";
}

- (void)llmPresetTapped:(UIButton *)btn {
    switch (btn.tag) {
        case 0:
            self.llmUrlField.text = @"https://api.openai.com/v1";
            self.llmModelField.text = @"gpt-4o-mini";
            break;
        case 1:
            self.llmUrlField.text = @"https://api.deepseek.com/v1";
            self.llmModelField.text = @"deepseek-chat";
            break;
        case 2:
            self.llmUrlField.text = @"https://api.groq.com/openai/v1";
            self.llmModelField.text = @"llama-3.3-70b-versatile";
            break;
        case 3:
            self.llmUrlField.text = @"https://api.siliconflow.cn/v1";
            self.llmModelField.text = @"Qwen/Qwen2.5-7B-Instruct";
            break;
        default:
            break;
    }
}

- (void)llmModelChipTapped:(UIButton *)btn {
    NSString *t = [btn titleForState:UIControlStateNormal];
    if (t.length > 0) self.llmModelField.text = t;
}

- (void)smartCleanupChanged:(UISwitch *)sw {}

- (void)promptModeChanged:(UISegmentedControl *)seg {
    if (self.activePromptIndex >= 0 && self.activePromptIndex < (NSInteger)self.draftPrompts.count) {
        self.draftPrompts[self.activePromptIndex] = self.promptTextView.text ?: @"";
    }
    self.activePromptIndex = seg.selectedSegmentIndex;
    self.promptTextView.text = self.draftPrompts[self.activePromptIndex];
}

- (void)toggleSecureField:(UIButton *)btn {
    UIView *wrap = btn.superview;
    for (UIView *sub in wrap.subviews) {
        if ([sub isKindOfClass:[UITextField class]]) {
            UITextField *tf = (UITextField *)sub;
            tf.secureTextEntry = !tf.secureTextEntry;
            if (@available(iOS 13.0, *)) {
                [btn setImage:[UIImage systemImageNamed:(tf.secureTextEntry ? @"eye" : @"eye.slash")] forState:UIControlStateNormal];
            }
            break;
        }
    }
}

- (void)pasteIntoSiblingField:(UIButton *)btn {
    NSString *clip = [UIPasteboard generalPasteboard].string;
    if (clip.length == 0) return;
    UIView *wrap = btn.superview;
    for (UIView *sub in wrap.subviews) {
        if ([sub isKindOfClass:[UITextField class]]) {
            ((UITextField *)sub).text = [clip stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            break;
        }
    }
}

#pragma mark - Connectivity Tests (ASR & LLM Separate)

- (void)testAsrTapped {
    [self dismissKeyboard];
    if (self.asrEngineSegment.selectedSegmentIndex == 0) {
        Class sfCls = NSClassFromString(@"SFSpeechRecognizer");
        SFSpeechRecognizer *rec = sfCls ? [[sfCls alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:@"zh_CN"]] : nil;
        self.asrTestResultLabel.hidden = NO;
        BOOL ok = (rec && rec.isAvailable);
        self.asrTestResultLabel.textColor = ok ? [UIColor colorWithRed:0.06 green:0.55 blue:0.40 alpha:1.0] : [UIColor systemRedColor];
        self.asrTestResultLabel.text = ok ? @"Apple 本地语音识别器就绪可用！" : @"Apple 本地识别器当前不可用，可先点击“授权麦克风/识别”或切换 Whisper 云端。";
        return;
    }

    NSString *base = [self.asrUrlField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];
    NSString *key = [self.asrKeyField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (base.length == 0 || key.length == 0) {
        self.asrTestResultLabel.hidden = NO;
        self.asrTestResultLabel.textColor = [UIColor systemRedColor];
        self.asrTestResultLabel.text = @"请先填写语音 Base URL 和 API Key";
        return;
    }

    self.asrTestResultLabel.hidden = NO;
    if (@available(iOS 13.0, *)) {
        self.asrTestResultLabel.textColor = [UIColor secondaryLabelColor];
    } else {
        self.asrTestResultLabel.textColor = [UIColor grayColor];
    }
    self.asrTestResultLabel.text = @"正在检测语音接口...";

    NSString *urlStr = [base stringByAppendingString:@"/models"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    req.timeoutInterval = 12.0;
    [req setValue:[NSString stringWithFormat:@"Bearer %@", key] forHTTPHeaderField:@"Authorization"];

    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSInteger code = [(NSHTTPURLResponse *)response statusCode];
            int ms = (int)((CFAbsoluteTimeGetCurrent() - start) * 1000.0);
            if (error) {
                self.asrTestResultLabel.textColor = [UIColor systemRedColor];
                self.asrTestResultLabel.text = [NSString stringWithFormat:@"连接失败：%@", error.localizedDescription];
            } else if (code >= 200 && code < 300) {
                self.asrTestResultLabel.textColor = [UIColor colorWithRed:0.06 green:0.55 blue:0.40 alpha:1.0];
                self.asrTestResultLabel.text = [NSString stringWithFormat:@"语音接口鉴权成功（HTTP %ld · %dms）", (long)code, ms];
            } else {
                NSString *body = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
                self.asrTestResultLabel.textColor = [UIColor systemRedColor];
                self.asrTestResultLabel.text = [NSString stringWithFormat:@"HTTP %ld：%@", (long)code, [body substringToIndex:MIN(body.length, (NSUInteger)120)]];
            }
        });
    }] resume];
}

- (void)testLlmTapped {
    [self dismissKeyboard];
    NSString *base = [self.llmUrlField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];
    NSString *key = [self.llmKeyField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *model = [self.llmModelField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (base.length == 0 || key.length == 0 || model.length == 0) {
        self.llmTestResultLabel.hidden = NO;
        self.llmTestResultLabel.textColor = [UIColor systemRedColor];
        self.llmTestResultLabel.text = @"请先完整填写文本 Base URL、API Key 与 Model ID";
        return;
    }

    self.llmTestResultLabel.hidden = NO;
    if (@available(iOS 13.0, *)) {
        self.llmTestResultLabel.textColor = [UIColor secondaryLabelColor];
    } else {
        self.llmTestResultLabel.textColor = [UIColor grayColor];
    }
    self.llmTestResultLabel.text = @"正在测试对话模型...";

    NSString *urlStr = [base stringByAppendingString:@"/chat/completions"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 15.0;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", key] forHTTPHeaderField:@"Authorization"];
    NSDictionary *payload = @{
        @"model": model,
        @"messages": @[@{@"role": @"user", @"content": @"Reply with one word: ok"}],
        @"max_tokens": @(10),
        @"temperature": @(0)
    };
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];

    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSInteger code = [(NSHTTPURLResponse *)response statusCode];
            int ms = (int)((CFAbsoluteTimeGetCurrent() - start) * 1000.0);
            if (error) {
                self.llmTestResultLabel.textColor = [UIColor systemRedColor];
                self.llmTestResultLabel.text = [NSString stringWithFormat:@"连接失败：%@", error.localizedDescription];
            } else if (code >= 200 && code < 300 && data) {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSArray *choices = [json isKindOfClass:[NSDictionary class]] ? json[@"choices"] : nil;
                NSString *reply = choices.firstObject[@"message"][@"content"] ?: @"ok";
                self.llmTestResultLabel.textColor = [UIColor colorWithRed:0.06 green:0.55 blue:0.40 alpha:1.0];
                self.llmTestResultLabel.text = [NSString stringWithFormat:@"连通成功（HTTP %ld · %dms）返回：%@", (long)code, ms, [reply stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
            } else {
                NSString *body = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
                self.llmTestResultLabel.textColor = [UIColor systemRedColor];
                self.llmTestResultLabel.text = [NSString stringWithFormat:@"HTTP %ld：%@", (long)code, [body substringToIndex:MIN(body.length, (NSUInteger)120)]];
            }
        });
    }] resume];
}

#pragma mark - Keyboard & Alerts

- (void)dismissKeyboard {
    [self.view endEditing:YES];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)keyboardWillChange:(NSNotification *)note {
    CGRect kbFrame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect local = [self.view convertRect:kbFrame fromView:nil];
    CGFloat overlap = MAX(0, CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(local));
    self.scrollView.contentInset = UIEdgeInsetsMake(0, 0, overlap > 0 ? overlap + 12.0 : 0, 0);
    self.scrollView.scrollIndicatorInsets = self.scrollView.contentInset;
}

- (void)showAlertTitle:(NSString *)title message:(NSString *)msg {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
