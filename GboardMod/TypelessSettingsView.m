#import "TypelessSettingsView.h"
#import "TypelessConfig.h"

@interface TypelessSettingsView () <UITextFieldDelegate>

@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UITextField *urlField;
@property (nonatomic, strong) UITextField *keyField;
@property (nonatomic, strong) UITextField *asrField;
@property (nonatomic, strong) UITextField *llmField;
@property (nonatomic, strong) UITextField *promptField;

@property (nonatomic, strong) UIButton *pasteUrlBtn;
@property (nonatomic, strong) UIButton *pasteKeyBtn;
@property (nonatomic, strong) UIButton *saveBtn;
@property (nonatomic, strong) UIButton *resetBtn;
@property (nonatomic, strong) UIButton *closeBtn;

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

- (void)setupUI {
    self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    _cardView = [[UIView alloc] initWithFrame:CGRectZero];
    _cardView.backgroundColor = [UIColor colorWithRed:0.96 green:0.97 blue:0.98 alpha:0.98];
    _cardView.layer.cornerRadius = 16.0;
    _cardView.layer.masksToBounds = YES;
    _cardView.layer.borderColor = [UIColor colorWithWhite:0.8 alpha:1.0].CGColor;
    _cardView.layer.borderWidth = 1.0;
    [self addSubview:_cardView];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 10, 200, 22)];
    title.text = @"⚙ AI 语音与模型配置";
    title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    title.textColor = [UIColor blackColor];
    [_cardView addSubview:title];

    _closeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    _closeBtn.frame = CGRectMake(0, 8, 44, 26);
    [_closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [_closeBtn setTitleColor:[UIColor colorWithWhite:0.3 alpha:1.0] forState:UIControlStateNormal];
    _closeBtn.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    [_closeBtn addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [_cardView addSubview:_closeBtn];

    _scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _scrollView.showsVerticalScrollIndicator = YES;
    [_cardView addSubview:_scrollView];

    // Presets Row
    UILabel *presetLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 4, 280, 16)];
    presetLabel.text = @"快速预设 (点击一键填入地址与推荐模型):";
    presetLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    presetLabel.textColor = [UIColor colorWithWhite:0.4 alpha:1.0];
    [_scrollView addSubview:presetLabel];

    NSArray *presets = @[@"OpenAI", @"Groq", @"DeepSeek", @"SiliconFlow"];
    CGFloat px = 16;
    for (int i = 0; i < presets.count; i++) {
        UIButton *pbtn = [UIButton buttonWithType:UIButtonTypeCustom];
        pbtn.tag = 100 + i;
        pbtn.frame = CGRectMake(px, 24, 70, 24);
        [pbtn setTitle:presets[i] forState:UIControlStateNormal];
        [pbtn setTitleColor:[UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0] forState:UIControlStateNormal];
        pbtn.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        pbtn.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:0.1];
        pbtn.layer.cornerRadius = 6;
        [pbtn addTarget:self action:@selector(presetTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_scrollView addSubview:pbtn];
        px += 76;
    }

    _urlField = [self createFieldWithPlaceholder:@"https://api.openai.com/v1" y:54 label:@"API 地址 (Base URL):"];
    _pasteUrlBtn = [self createPasteButtonForField:_urlField y:54];

    _keyField = [self createFieldWithPlaceholder:@"sk-..." y:102 label:@"API Key (不填自动走原生听写):"];
    _keyField.secureTextEntry = YES;
    _pasteKeyBtn = [self createPasteButtonForField:_keyField y:102];

    _asrField = [self createFieldWithPlaceholder:@"whisper-1 / SenseVoiceSmall" y:150 label:@"语音识别模型 (ASR):"];
    _llmField = [self createFieldWithPlaceholder:@"gpt-4o-mini / deepseek-chat" y:198 label:@"文本润色模型 (LLM):"];
    _promptField = [self createFieldWithPlaceholder:@"自定义润色提示词 (可留空使用默认)" y:246 label:@"AI 润色提示词 (Prompt):"];

    _resetBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    [_resetBtn setTitle:@"恢复默认" forState:UIControlStateNormal];
    [_resetBtn setTitleColor:[UIColor colorWithWhite:0.4 alpha:1.0] forState:UIControlStateNormal];
    _resetBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _resetBtn.backgroundColor = [UIColor colorWithWhite:0.92 alpha:1.0];
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
}

- (UIButton *)createPasteButtonForField:(UITextField *)field y:(CGFloat)y {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = CGRectMake(250, y, 64, 18);
    [btn setTitle:@"📋 粘贴" forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    btn.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:0.1];
    btn.layer.cornerRadius = 4;
    [btn addTarget:self action:@selector(pasteButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [_scrollView addSubview:btn];
    return btn;
}

- (void)pasteButtonTapped:(UIButton *)sender {
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    NSString *clip = pb.string ?: @"";
    NSString *clean = [clip stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (clean.length == 0) return;

    if (sender == _pasteUrlBtn) {
        _urlField.text = clean;
    } else if (sender == _pasteKeyBtn) {
        _keyField.text = clean;
    }
}

- (UITextField *)createFieldWithPlaceholder:(NSString *)placeholder y:(CGFloat)y label:(NSString *)labelTxt {
    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(16, y, 220, 16)];
    lbl.text = labelTxt;
    lbl.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    lbl.textColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    [_scrollView addSubview:lbl];

    UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(16, y + 18, 300, 28)];
    tf.placeholder = placeholder;
    tf.font = [UIFont systemFontOfSize:12];
    tf.backgroundColor = [UIColor whiteColor];
    tf.layer.cornerRadius = 6;
    tf.layer.borderWidth = 0.8;
    tf.layer.borderColor = [UIColor colorWithWhite:0.82 alpha:1.0].CGColor;
    tf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 28)];
    tf.leftViewMode = UITextFieldViewModeAlways;
    tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
    tf.delegate = self;
    [_scrollView addSubview:tf];
    return tf;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;

    CGFloat cardW = MIN(w - 16, 380);
    CGFloat cardH = MIN(h - 8, 266);
    CGFloat cardX = (w - cardW) / 2.0;
    CGFloat cardY = (h - cardH) / 2.0;
    _cardView.frame = CGRectMake(cardX, cardY, cardW, cardH);

    _closeBtn.frame = CGRectMake(cardW - 44, 6, 36, 28);
    _scrollView.frame = CGRectMake(0, 36, cardW, cardH - 80);
    _scrollView.contentSize = CGSizeMake(cardW, 296);

    CGFloat fieldW = cardW - 32;
    _pasteUrlBtn.frame = CGRectMake(cardW - 74, 54, 58, 18);
    _urlField.frame = CGRectMake(16, 72, fieldW, 28);

    _pasteKeyBtn.frame = CGRectMake(cardW - 74, 102, 58, 18);
    _keyField.frame = CGRectMake(16, 120, fieldW, 28);

    _asrField.frame = CGRectMake(16, 168, fieldW, 28);
    _llmField.frame = CGRectMake(16, 216, fieldW, 28);
    _promptField.frame = CGRectMake(16, 264, fieldW, 28);

    CGFloat btnY = cardH - 38;
    CGFloat btnW = (cardW - 40) / 2.0;
    _resetBtn.frame = CGRectMake(16, btnY, btnW * 0.7, 30);
    _saveBtn.frame = CGRectMake(16 + btnW * 0.7 + 10, btnY, cardW - 32 - (btnW * 0.7 + 10), 30);
}

- (void)reloadConfig {
    TypelessConfig *cfg = [TypelessConfig sharedConfig];
    _urlField.text = cfg.baseURL ?: @"";
    _keyField.text = cfg.apiKey ?: @"";
    _asrField.text = cfg.asrModel ?: @"";
    _llmField.text = cfg.llmModel ?: @"";
    _promptField.text = cfg.customPrompt ?: @"";
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
            break;
        case 101: // Groq
            _urlField.text = @"https://api.groq.com/openai/v1";
            _asrField.text = @"whisper-large-v3-turbo";
            _llmField.text = @"llama-3.1-8b-instant";
            break;
        case 102: // DeepSeek
            _urlField.text = @"https://api.deepseek.com/v1";
            _asrField.text = @"whisper-1";
            _llmField.text = @"deepseek-chat";
            break;
        case 103: // SiliconFlow
            _urlField.text = @"https://api.siliconflow.cn/v1";
            _asrField.text = @"FunAudioLLM/SenseVoiceSmall";
            _llmField.text = @"deepseek-ai/DeepSeek-V2.5";
            break;
    }
}

- (void)saveTapped {
    TypelessConfig *cfg = [TypelessConfig sharedConfig];
    cfg.baseURL = [_urlField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    cfg.apiKey = [_keyField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    cfg.asrModel = [_asrField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    cfg.llmModel = [_llmField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (_promptField.text.length > 0) {
        cfg.customPrompt = [_promptField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
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
