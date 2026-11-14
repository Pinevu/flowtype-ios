#import "TypelessSettingsView.h"
#import "TypelessConfig.h"

@interface TypelessSettingsView () <UITextFieldDelegate>

@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIButton *closeBtn;
@property (nonatomic, strong) UIScrollView *scrollView;

@property (nonatomic, strong) UIButton *asrWhisperBtn;
@property (nonatomic, strong) UIButton *asrAppleBtn;
@property (nonatomic, assign) BOOL pendingUseAppleASR;

@property (nonatomic, strong) UITextField *urlField;
@property (nonatomic, strong) UITextField *keyField;
@property (nonatomic, strong) UITextField *asrField;
@property (nonatomic, strong) UITextField *llmField;
@property (nonatomic, strong) UILabel *promptTitleLabel;
@property (nonatomic, strong) UITextField *promptField;

@property (nonatomic, strong) UIButton *pasteUrlBtn;
@property (nonatomic, strong) UIButton *pasteKeyBtn;
@property (nonatomic, strong) UIButton *resetBtn;
@property (nonatomic, strong) UIButton *saveBtn;

@property (nonatomic, strong) NSArray<UIButton *> *presetButtons;

@end

@implementation TypelessSettingsView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupUI];
        [self reloadConfig];
    }
    return self;
}

- (BOOL)isDark {
    if (@available(iOS 12.0, *)) {
        return self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    }
    return NO;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self applyThemeColors];
}

- (void)setupUI {
    self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.38];
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    _cardView = [[UIView alloc] initWithFrame:CGRectZero];
    _cardView.layer.cornerRadius = 16.0;
    _cardView.layer.masksToBounds = YES;
    _cardView.layer.borderWidth = 0.8;
    [self addSubview:_cardView];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.text = @"AI 语音与模型配置";
    _titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    [_cardView addSubview:_titleLabel];

    _closeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    if (@available(iOS 13.0, *)) {
        [_closeBtn setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    } else {
        [_closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    }
    [_closeBtn addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [_cardView addSubview:_closeBtn];

    _scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _scrollView.showsVerticalScrollIndicator = YES;
    _scrollView.alwaysBounceVertical = YES;
    [_cardView addSubview:_scrollView];

    // Quick Presets Row
    UILabel *presetLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 4, 290, 16)];
    presetLabel.text = @"快速预设 (一键填入接口与推荐模型):";
    presetLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    presetLabel.textColor = [UIColor colorWithRed:0.55 green:0.55 blue:0.58 alpha:1.0];
    [_scrollView addSubview:presetLabel];

    NSArray *presets = @[@"OpenAI", @"Groq", @"DeepSeek", @"SiliconFlow"];
    NSMutableArray *pBtns = [NSMutableArray array];
    for (int i = 0; i < (int)presets.count; i++) {
        UIButton *pbtn = [UIButton buttonWithType:UIButtonTypeCustom];
        pbtn.tag = 100 + i;
        [pbtn setTitle:presets[i] forState:UIControlStateNormal];
        [pbtn setTitleColor:[UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0] forState:UIControlStateNormal];
        pbtn.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        pbtn.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:0.12];
        pbtn.layer.cornerRadius = 8;
        [pbtn addTarget:self action:@selector(presetTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_scrollView addSubview:pbtn];
        [pBtns addObject:pbtn];
    }
    _presetButtons = pBtns;

    // ASR Engine Mode Switch
    UILabel *asrEngineLbl = [[UILabel alloc] initWithFrame:CGRectMake(14, 54, 290, 16)];
    asrEngineLbl.text = @"语音识别方式:";
    asrEngineLbl.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    asrEngineLbl.textColor = [UIColor colorWithRed:0.55 green:0.55 blue:0.58 alpha:1.0];
    [_scrollView addSubview:asrEngineLbl];

    _asrWhisperBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    [_asrWhisperBtn setTitle:@"Whisper 云端接口" forState:UIControlStateNormal];
    _asrWhisperBtn.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    _asrWhisperBtn.layer.cornerRadius = 7;
    [_asrWhisperBtn addTarget:self action:@selector(selectWhisperASR) forControlEvents:UIControlEventTouchUpInside];
    [_scrollView addSubview:_asrWhisperBtn];

    _asrAppleBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    [_asrAppleBtn setTitle:@"Apple 本地识别 (推荐 DeepSeek)" forState:UIControlStateNormal];
    _asrAppleBtn.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    _asrAppleBtn.layer.cornerRadius = 7;
    [_asrAppleBtn addTarget:self action:@selector(selectAppleASR) forControlEvents:UIControlEventTouchUpInside];
    [_scrollView addSubview:_asrAppleBtn];

    _urlField = [self createFieldWithPlaceholder:@"https://api.openai.com/v1" y:102 label:@"API 地址 (Base URL):" labelOut:nil];
    _pasteUrlBtn = [self createPasteButton];

    _keyField = [self createFieldWithPlaceholder:@"sk-... (不填将自动使用 Apple 本地识别)" y:150 label:@"API Key:" labelOut:nil];
    _keyField.secureTextEntry = YES;
    _pasteKeyBtn = [self createPasteButton];

    _asrField = [self createFieldWithPlaceholder:@"whisper-1 / FunAudioLLM/SenseVoiceSmall" y:198 label:@"语音识别模型 (ASR):" labelOut:nil];
    _llmField = [self createFieldWithPlaceholder:@"gpt-4o-mini / deepseek-chat" y:246 label:@"文本处理模型 (LLM):" labelOut:nil];

    UILabel *pLbl = nil;
    _promptField = [self createFieldWithPlaceholder:@"自定义当前模式 AI 提示词 (留空用默认)" y:294 label:@"提示词 (Prompt):" labelOut:&pLbl];
    _promptTitleLabel = pLbl;

    _resetBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    [_resetBtn setTitle:@"恢复默认" forState:UIControlStateNormal];
    _resetBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _resetBtn.layer.cornerRadius = 14;
    [_resetBtn addTarget:self action:@selector(resetTapped) forControlEvents:UIControlEventTouchUpInside];
    [_cardView addSubview:_resetBtn];

    _saveBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    [_saveBtn setTitle:@"保存并生效" forState:UIControlStateNormal];
    [_saveBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _saveBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    _saveBtn.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];
    _saveBtn.layer.cornerRadius = 14;
    [_saveBtn addTarget:self action:@selector(saveTapped) forControlEvents:UIControlEventTouchUpInside];
    [_cardView addSubview:_saveBtn];

    [self applyThemeColors];
}

- (UIButton *)createPasteButton {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    [btn setTitle:@"粘贴" forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    btn.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:0.12];
    btn.layer.cornerRadius = 5;
    [btn addTarget:self action:@selector(pasteButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [_scrollView addSubview:btn];
    return btn;
}

- (UITextField *)createFieldWithPlaceholder:(NSString *)placeholder y:(CGFloat)y label:(NSString *)labelTxt labelOut:(UILabel **)outLbl {
    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(14, y, 220, 16)];
    lbl.text = labelTxt;
    lbl.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    lbl.textColor = [UIColor colorWithRed:0.5 green:0.5 blue:0.54 alpha:1.0];
    [_scrollView addSubview:lbl];
    if (outLbl) *outLbl = lbl;

    UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(14, y + 18, 280, 28)];
    tf.placeholder = placeholder;
    tf.font = [UIFont systemFontOfSize:12];
    tf.layer.cornerRadius = 7;
    tf.layer.borderWidth = 0.8;
    tf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 28)];
    tf.leftViewMode = UITextFieldViewModeAlways;
    tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
    tf.delegate = self;
    [_scrollView addSubview:tf];
    return tf;
}

- (void)applyThemeColors {
    BOOL dark = [self isDark];
    _cardView.backgroundColor = dark ? [UIColor colorWithRed:0.15 green:0.15 blue:0.17 alpha:0.98]
                                     : [UIColor colorWithRed:0.96 green:0.97 blue:0.98 alpha:0.98];
    _cardView.layer.borderColor = (dark ? [UIColor colorWithWhite:0.28 alpha:1.0]
                                        : [UIColor colorWithWhite:0.82 alpha:1.0]).CGColor;
    _titleLabel.textColor = dark ? [UIColor whiteColor] : [UIColor blackColor];
    _closeBtn.tintColor = dark ? [UIColor colorWithWhite:0.65 alpha:1.0] : [UIColor colorWithWhite:0.45 alpha:1.0];
    [_closeBtn setTitleColor:_closeBtn.tintColor forState:UIControlStateNormal];

    UIColor *tfBg = dark ? [UIColor colorWithWhite:0.22 alpha:1.0] : [UIColor whiteColor];
    UIColor *tfBorder = dark ? [UIColor colorWithWhite:0.32 alpha:1.0] : [UIColor colorWithWhite:0.82 alpha:1.0];
    UIColor *tfText = dark ? [UIColor whiteColor] : [UIColor blackColor];

    for (UITextField *tf in @[_urlField, _keyField, _asrField, _llmField, _promptField]) {
        tf.backgroundColor = tfBg;
        tf.layer.borderColor = tfBorder.CGColor;
        tf.textColor = tfText;
    }

    _resetBtn.backgroundColor = dark ? [UIColor colorWithWhite:0.25 alpha:1.0] : [UIColor colorWithWhite:0.9 alpha:1.0];
    [_resetBtn setTitleColor:(dark ? [UIColor whiteColor] : [UIColor colorWithWhite:0.3 alpha:1.0]) forState:UIControlStateNormal];

    [self updateASREngineButtonsUI];
}

- (void)updateASREngineButtonsUI {
    BOOL dark = [self isDark];
    UIColor *activeBg = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];
    UIColor *inactiveBg = dark ? [UIColor colorWithWhite:0.24 alpha:1.0] : [UIColor colorWithWhite:0.9 alpha:1.0];
    UIColor *inactiveTxt = dark ? [UIColor colorWithWhite:0.8 alpha:1.0] : [UIColor colorWithWhite:0.3 alpha:1.0];

    if (_pendingUseAppleASR) {
        _asrWhisperBtn.backgroundColor = inactiveBg;
        [_asrWhisperBtn setTitleColor:inactiveTxt forState:UIControlStateNormal];
        _asrAppleBtn.backgroundColor = activeBg;
        [_asrAppleBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    } else {
        _asrWhisperBtn.backgroundColor = activeBg;
        [_asrWhisperBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        _asrAppleBtn.backgroundColor = inactiveBg;
        [_asrAppleBtn setTitleColor:inactiveTxt forState:UIControlStateNormal];
    }
}

- (void)selectWhisperASR {
    _pendingUseAppleASR = NO;
    [self updateASREngineButtonsUI];
}

- (void)selectAppleASR {
    _pendingUseAppleASR = YES;
    [self updateASREngineButtonsUI];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;

    CGFloat cardW = MIN(w - 14, 390);
    CGFloat cardH = MIN(h - 8, 286);
    _cardView.frame = CGRectMake((w - cardW) / 2.0, (h - cardH) / 2.0, cardW, cardH);

    _titleLabel.frame = CGRectMake(14, 9, cardW - 60, 22);
    _closeBtn.frame = CGRectMake(cardW - 38, 6, 30, 28);

    _scrollView.frame = CGRectMake(0, 36, cardW, cardH - 78);
    _scrollView.contentSize = CGSizeMake(cardW, 348);

    // Preset row
    CGFloat availW = cardW - 28;
    CGFloat pSpacing = 6;
    CGFloat pBtnW = (availW - pSpacing * 3) / 4.0;
    for (int i = 0; i < (int)_presetButtons.count; i++) {
        _presetButtons[i].frame = CGRectMake(14 + i * (pBtnW + pSpacing), 22, pBtnW, 24);
    }

    // ASR Engine toggle row
    _asrWhisperBtn.frame = CGRectMake(14, 72, availW * 0.42, 24);
    _asrAppleBtn.frame = CGRectMake(14 + availW * 0.42 + 6, 72, availW * 0.58 - 6, 24);

    _pasteUrlBtn.frame = CGRectMake(cardW - 62, 102, 48, 16);
    _urlField.frame = CGRectMake(14, 120, availW, 28);

    _pasteKeyBtn.frame = CGRectMake(cardW - 62, 150, 48, 16);
    _keyField.frame = CGRectMake(14, 168, availW, 28);

    _asrField.frame = CGRectMake(14, 216, availW, 28);
    _llmField.frame = CGRectMake(14, 264, availW, 28);
    _promptField.frame = CGRectMake(14, 312, availW, 28);

    CGFloat btnY = cardH - 36;
    CGFloat resetW = (cardW - 38) * 0.34;
    _resetBtn.frame = CGRectMake(14, btnY, resetW, 28);
    _saveBtn.frame = CGRectMake(14 + resetW + 10, btnY, cardW - 28 - resetW - 10, 28);
}

- (void)pasteButtonTapped:(UIButton *)sender {
    NSString *clip = [UIPasteboard generalPasteboard].string ?: @"";
    NSString *clean = [clip stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (clean.length == 0) return;

    if (sender == _pasteUrlBtn) {
        _urlField.text = clean;
    } else if (sender == _pasteKeyBtn) {
        _keyField.text = clean;
    }
}

- (void)reloadConfig {
    TypelessConfig *cfg = [TypelessConfig sharedConfig];
    _urlField.text = cfg.baseURL ?: @"";
    _keyField.text = cfg.apiKey ?: @"";
    _asrField.text = cfg.asrModel ?: @"";
    _llmField.text = cfg.llmModel ?: @"";
    _pendingUseAppleASR = cfg.useAppleASR;

    NSString *modeTitle = [TypelessConfig titleForMode:cfg.voiceMode];
    _promptTitleLabel.text = [NSString stringWithFormat:@"「%@」模式提示词 (Prompt):", modeTitle];
    _promptField.text = cfg.customPrompt ?: @"";

    [self applyThemeColors];
}

- (void)resetTapped {
    [[TypelessConfig sharedConfig] resetToDefaults];
    [self reloadConfig];
}

- (void)presetTapped:(UIButton *)sender {
    switch (sender.tag) {
        case 100: // OpenAI
            _urlField.text = @"https://api.openai.com/v1";
            _asrField.text = @"whisper-1";
            _llmField.text = @"gpt-4o-mini";
            _pendingUseAppleASR = NO;
            break;
        case 101: // Groq
            _urlField.text = @"https://api.groq.com/openai/v1";
            _asrField.text = @"whisper-large-v3-turbo";
            _llmField.text = @"llama-3.1-8b-instant";
            _pendingUseAppleASR = NO;
            break;
        case 102: // DeepSeek (LLM only -> pair with Apple Local ASR)
            _urlField.text = @"https://api.deepseek.com/v1";
            _asrField.text = @"";
            _llmField.text = @"deepseek-chat";
            _pendingUseAppleASR = YES;
            break;
        case 103: // SiliconFlow
            _urlField.text = @"https://api.siliconflow.cn/v1";
            _asrField.text = @"FunAudioLLM/SenseVoiceSmall";
            _llmField.text = @"deepseek-ai/DeepSeek-V2.5";
            _pendingUseAppleASR = NO;
            break;
    }
    [self updateASREngineButtonsUI];
}

- (void)saveTapped {
    TypelessConfig *cfg = [TypelessConfig sharedConfig];
    cfg.baseURL = [_urlField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    cfg.apiKey = [_keyField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    cfg.asrModel = [_asrField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    cfg.llmModel = [_llmField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    cfg.useAppleASR = _pendingUseAppleASR;

    NSString *promptTxt = [_promptField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (promptTxt.length > 0) {
        cfg.customPrompt = promptTxt;
    }
    [cfg save];

    [self endEditing:YES];
    if ([self.delegate respondsToSelector:@selector(typelessSettingsDidSave)]) {
        [self.delegate typelessSettingsDidSave];
    }
}

- (void)closeTapped {
    [self endEditing:YES];
    if ([self.delegate respondsToSelector:@selector(typelessSettingsDidClose)]) {
        [self.delegate typelessSettingsDidClose];
    }
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

@end
