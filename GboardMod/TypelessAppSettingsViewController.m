#import "TypelessAppSettingsViewController.h"
#import "TypelessConfig.h"

@interface TypelessAppSettingsViewController () <UITextFieldDelegate>

@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIView *contentView;

@property (nonatomic, strong) UISegmentedControl *asrEngineSegment;
@property (nonatomic, strong) UITextField *urlField;
@property (nonatomic, strong) UITextField *keyField;
@property (nonatomic, strong) UITextField *asrField;
@property (nonatomic, strong) UITextField *llmField;
@property (nonatomic, strong) UITextView *promptTextView;

@property (nonatomic, strong) UIButton *testBtn;
@property (nonatomic, strong) UIActivityIndicatorView *testSpinner;
@property (nonatomic, strong) UILabel *testResultLabel;

@end

@implementation TypelessAppSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"AI 语音与模型配置";
    self.view.backgroundColor = [self backgroundColorForTheme];

    [self setupNavigationItem];
    [self setupScrollView];
    [self reloadConfigValues];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self.view action:@selector(endEditing:)];
    tap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:tap];
}

- (UIColor *)backgroundColorForTheme {
    if (@available(iOS 13.0, *)) {
        return [UIColor systemGroupedBackgroundColor];
    }
    return [UIColor colorWithRed:0.94 green:0.94 blue:0.96 alpha:1.0];
}

- (UIColor *)cardBackgroundColorForTheme {
    if (@available(iOS 13.0, *)) {
        return [UIColor secondarySystemGroupedBackgroundColor];
    }
    return [UIColor whiteColor];
}

- (void)setupNavigationItem {
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"保存"
                                                                              style:UIBarButtonItemStyleDone
                                                                             target:self
                                                                             action:@selector(saveAction)];
}

- (void)setupScrollView {
    _scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:_scrollView];

    _contentView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 0)];
    [_scrollView addSubview:_contentView];

    CGFloat y = 16.0;
    CGFloat width = self.view.bounds.size.width;
    CGFloat margin = 16.0;
    CGFloat cardWidth = width - margin * 2;

    // 1. Presets Section
    UIView *presetCard = [self createCardWithY:y width:cardWidth height:90];
    UILabel *pLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 10, cardWidth - 28, 18)];
    pLabel.text = @"⚡ 快速预设 (一键填入主流接口与推荐模型)";
    pLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    pLabel.textColor = [UIColor systemBlueColor];
    [presetCard addSubview:pLabel];

    NSArray *presets = @[@"OpenAI", @"Groq", @"DeepSeek", @"SiliconFlow"];
    CGFloat btnW = (cardWidth - 28 - 24) / 4.0;
    for (int i = 0; i < presets.count; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.tag = 200 + i;
        btn.frame = CGRectMake(14 + i * (btnW + 8), 38, btnW, 36);
        [btn setTitle:presets[i] forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        btn.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.1];
        btn.layer.cornerRadius = 8;
        [btn addTarget:self action:@selector(presetTapped:) forControlEvents:UIControlEventTouchUpInside];
        [presetCard addSubview:btn];
    }
    y += 102;

    // 2. ASR Engine Section
    UIView *engineCard = [self createCardWithY:y width:cardWidth height:82];
    UILabel *eLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 10, cardWidth - 28, 18)];
    eLabel.text = @"🎙 语音识别引擎 (ASR)";
    eLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [engineCard addSubview:eLabel];

    _asrEngineSegment = [[UISegmentedControl alloc] initWithItems:@[@"Whisper 云端接口", @"Apple 本地听写 (推荐 DeepSeek)"]];
    _asrEngineSegment.frame = CGRectMake(14, 38, cardWidth - 28, 32);
    _asrEngineSegment.selectedSegmentIndex = 0;
    [engineCard addSubview:_asrEngineSegment];
    y += 94;

    // 3. API Details Section
    UIView *apiCard = [self createCardWithY:y width:cardWidth height:280];
    UILabel *apiTitle = [[UILabel alloc] initWithFrame:CGRectMake(14, 10, cardWidth - 28, 18)];
    apiTitle.text = @"🌐 模型服务与密钥配置";
    apiTitle.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [apiCard addSubview:apiTitle];

    CGFloat curY = 36;
    _urlField = [self addFieldToCard:apiCard y:&curY label:@"API 地址 (Base URL)" placeholder:@"https://api.openai.com/v1" width:cardWidth hasPaste:YES];
    _keyField = [self addFieldToCard:apiCard y:&curY label:@"API Key (不填自动使用 Apple 听写)" placeholder:@"sk-..." width:cardWidth hasPaste:YES];
    _keyField.secureTextEntry = YES;
    _asrField = [self addFieldToCard:apiCard y:&curY label:@"语音识别模型 (ASR)" placeholder:@"whisper-1 / SenseVoiceSmall" width:cardWidth hasPaste:NO];
    _llmField = [self addFieldToCard:apiCard y:&curY label:@"文本处理模型 (LLM)" placeholder:@"gpt-4o-mini / deepseek-chat" width:cardWidth hasPaste:NO];
    y += 292;

    // 4. Custom Prompt Section
    UIView *promptCard = [self createCardWithY:y width:cardWidth height:130];
    UILabel *promptTitle = [[UILabel alloc] initWithFrame:CGRectMake(14, 10, cardWidth - 28, 18)];
    promptTitle.text = @"📝 AI 提示词要求 (Prompt)";
    promptTitle.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [promptCard addSubview:promptTitle];

    _promptTextView = [[UITextView alloc] initWithFrame:CGRectMake(14, 34, cardWidth - 28, 84)];
    _promptTextView.font = [UIFont systemFontOfSize:13];
    _promptTextView.layer.cornerRadius = 8;
    _promptTextView.layer.borderWidth = 0.6;
    if (@available(iOS 13.0, *)) {
        _promptTextView.layer.borderColor = [UIColor separatorColor].CGColor;
        _promptTextView.backgroundColor = [UIColor tertiarySystemGroupedBackgroundColor];
    } else {
        _promptTextView.layer.borderColor = [UIColor colorWithWhite:0.8 alpha:1.0].CGColor;
        _promptTextView.backgroundColor = [UIColor colorWithWhite:0.96 alpha:1.0];
    }
    [promptCard addSubview:_promptTextView];
    y += 142;

    // 5. Test & Action Section
    _testBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    _testBtn.frame = CGRectMake(margin, y, cardWidth, 44);
    _testBtn.backgroundColor = [UIColor systemBlueColor];
    _testBtn.layer.cornerRadius = 10;
    [_testBtn setTitle:@"🔌 测试 API 连通性" forState:UIControlStateNormal];
    [_testBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _testBtn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [_testBtn addTarget:self action:@selector(testApiConnection) forControlEvents:UIControlEventTouchUpInside];
    [_contentView addSubview:_testBtn];

    _testSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    _testSpinner.center = CGPointMake(cardWidth - 30, 22);
    _testSpinner.hidesWhenStopped = YES;
    [_testBtn addSubview:_testSpinner];
    y += 50;

    _testResultLabel = [[UILabel alloc] initWithFrame:CGRectMake(margin, y, cardWidth, 40)];
    _testResultLabel.font = [UIFont systemFontOfSize:12];
    _testResultLabel.numberOfLines = 2;
    _testResultLabel.textAlignment = NSTextAlignmentCenter;
    [_contentView addSubview:_testResultLabel];
    y += 46;

    UIButton *resetBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    resetBtn.frame = CGRectMake(margin, y, cardWidth, 36);
    [resetBtn setTitle:@"恢复默认配置" forState:UIControlStateNormal];
    [resetBtn setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    [resetBtn addTarget:self action:@selector(resetAction) forControlEvents:UIControlEventTouchUpInside];
    [_contentView addSubview:resetBtn];
    y += 50;

    _contentView.frame = CGRectMake(0, 0, width, y);
    _scrollView.contentSize = CGSizeMake(width, y);
}

- (UIView *)createCardWithY:(CGFloat)y width:(CGFloat)width height:(CGFloat)height {
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(16, y, width, height)];
    card.backgroundColor = [self cardBackgroundColorForTheme];
    card.layer.cornerRadius = 12;
    card.layer.masksToBounds = YES;
    card.layer.borderWidth = 0.5;
    if (@available(iOS 13.0, *)) {
        card.layer.borderColor = [UIColor separatorColor].CGColor;
    } else {
        card.layer.borderColor = [UIColor colorWithWhite:0.85 alpha:1.0].CGColor;
    }
    [_contentView addSubview:card];
    return card;
}

- (UITextField *)addFieldToCard:(UIView *)card y:(CGFloat *)y label:(NSString *)label placeholder:(NSString *)placeholder width:(CGFloat)width hasPaste:(BOOL)hasPaste {
    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(14, *y, width - 28, 14)];
    lbl.text = label;
    lbl.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightMedium];
    lbl.textColor = [UIColor secondaryLabelColor];
    [card addSubview:lbl];

    CGFloat tfW = hasPaste ? (width - 28 - 56) : (width - 28);
    UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(14, *y + 16, tfW, 30)];
    tf.placeholder = placeholder;
    tf.font = [UIFont systemFontOfSize:13];
    tf.layer.cornerRadius = 6;
    tf.layer.borderWidth = 0.5;
    tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
    tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    tf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 30)];
    tf.leftViewMode = UITextFieldViewModeAlways;
    if (@available(iOS 13.0, *)) {
        tf.backgroundColor = [UIColor tertiarySystemGroupedBackgroundColor];
        tf.layer.borderColor = [UIColor separatorColor].CGColor;
    } else {
        tf.backgroundColor = [UIColor colorWithWhite:0.96 alpha:1.0];
        tf.layer.borderColor = [UIColor colorWithWhite:0.8 alpha:1.0].CGColor;
    }
    tf.delegate = self;
    [card addSubview:tf];

    if (hasPaste) {
        UIButton *pBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        pBtn.frame = CGRectMake(width - 14 - 50, *y + 16, 50, 30);
        [pBtn setTitle:@"粘贴" forState:UIControlStateNormal];
        pBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        objc_setAssociatedObject(pBtn, "targetField", tf, OBJC_ASSOCIATION_ASSIGN);
        [pBtn addTarget:self action:@selector(pasteIntoField:) forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:pBtn];
    }

    *y += 58;
    return tf;
}

- (void)pasteIntoField:(UIButton *)sender {
    UITextField *tf = objc_getAssociatedObject(sender, "targetField");
    if (tf) {
        NSString *clip = [UIPasteboard generalPasteboard].string ?: @"";
        NSString *clean = [clip stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (clean.length > 0) {
            tf.text = clean;
        }
    }
}

- (void)reloadConfigValues {
    TypelessConfig *cfg = [TypelessConfig sharedConfig];
    _asrEngineSegment.selectedSegmentIndex = cfg.useAppleASR ? 1 : 0;
    _urlField.text = cfg.baseURL ?: @"";
    _keyField.text = cfg.apiKey ?: @"";
    _asrField.text = cfg.asrModel ?: @"";
    _llmField.text = cfg.llmModel ?: @"";
    _promptTextView.text = cfg.customPrompt ?: @"";
}

- (void)presetTapped:(UIButton *)sender {
    switch (sender.tag) {
        case 200: // OpenAI
            _urlField.text = @"https://api.openai.com/v1";
            _asrField.text = @"whisper-1";
            _llmField.text = @"gpt-4o-mini";
            _asrEngineSegment.selectedSegmentIndex = 0;
            break;
        case 201: // Groq
            _urlField.text = @"https://api.groq.com/openai/v1";
            _asrField.text = @"whisper-large-v3-turbo";
            _llmField.text = @"llama-3.1-8b-instant";
            _asrEngineSegment.selectedSegmentIndex = 0;
            break;
        case 202: // DeepSeek
            _urlField.text = @"https://api.deepseek.com/v1";
            _asrField.text = @"";
            _llmField.text = @"deepseek-chat";
            _asrEngineSegment.selectedSegmentIndex = 1;
            break;
        case 203: // SiliconFlow
            _urlField.text = @"https://api.siliconflow.cn/v1";
            _asrField.text = @"FunAudioLLM/SenseVoiceSmall";
            _llmField.text = @"deepseek-ai/DeepSeek-V2.5";
            _asrEngineSegment.selectedSegmentIndex = 0;
            break;
    }
}

- (void)testApiConnection {
    NSString *base = [_urlField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *key = [_keyField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *model = [_llmField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (key.length == 0) {
        _testResultLabel.textColor = [UIColor systemOrangeColor];
        _testResultLabel.text = @"未填写 API Key，当前模式将直接使用 Apple 本地免费听写";
        return;
    }

    [_testSpinner startAnimating];
    _testBtn.enabled = NO;
    _testResultLabel.textColor = [UIColor secondaryLabelColor];
    _testResultLabel.text = @"正在连接测试...";

    NSString *cleanBase = [base stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    NSURL *url = [NSURL URLWithString:[cleanBase stringByAppendingString:@"/chat/completions"]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 10.0;
    [req setValue:[NSString stringWithFormat:@"Bearer %@", key] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSDictionary *payload = @{
        @"model": model.length > 0 ? model : @"gpt-4o-mini",
        @"messages": @[@{@"role": @"user", @"content": @"hi"}],
        @"max_tokens": @(5)
    };
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.testSpinner stopAnimating];
            self.testBtn.enabled = YES;

            if (error) {
                self.testResultLabel.textColor = [UIColor systemRedColor];
                self.testResultLabel.text = [NSString stringWithFormat:@"连接失败: %@", error.localizedDescription];
                return;
            }

            NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
            if (httpResp.statusCode == 200) {
                self.testResultLabel.textColor = [UIColor systemGreenColor];
                self.testResultLabel.text = @"✅ API 连接成功！大模型正常响应。";
            } else {
                self.testResultLabel.textColor = [UIColor systemOrangeColor];
                self.testResultLabel.text = [NSString stringWithFormat:@"接口返回状态码 %ld，请检查 Key 与模型名称", (long)httpResp.statusCode];
            }
        });
    }] resume];
}

- (void)saveAction {
    [self.view endEditing:YES];
    TypelessConfig *cfg = [TypelessConfig sharedConfig];
    cfg.useAppleASR = (_asrEngineSegment.selectedSegmentIndex == 1);
    cfg.baseURL = [_urlField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    cfg.apiKey = [_keyField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    cfg.asrModel = [_asrField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    cfg.llmModel = [_llmField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (_promptTextView.text.length > 0) {
        cfg.customPrompt = [_promptTextView.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    [cfg save];

    // Export shared configuration JSON for Keyboard Extension
    @try {
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        dict[@"baseURL"] = cfg.baseURL ?: @"";
        dict[@"apiKey"] = cfg.apiKey ?: @"";
        dict[@"asrModel"] = cfg.asrModel ?: @"";
        dict[@"llmModel"] = cfg.llmModel ?: @"";
        dict[@"useAppleASR"] = @(cfg.useAppleASR);
        dict[@"customPrompt"] = cfg.customPrompt ?: @"";

        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:nil];
        if (jsonData) {
            NSString *appSupport = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
            NSString *localPath = [appSupport stringByAppendingPathComponent:@"typeless_config.json"];
            [jsonData writeToFile:localPath atomically:YES];
        }
    } @catch (NSException *e) {}

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"保存成功"
                                                                   message:@"AI 语音与模型配置已生效，已同步至输入法。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)resetAction {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"恢复默认"
                                                                   message:@"确定将所有 AI 语音设置恢复为默认值吗？"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"恢复" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [[TypelessConfig sharedConfig] resetToDefaults];
        [self reloadConfigValues];
        self.testResultLabel.text = @"";
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

@end
