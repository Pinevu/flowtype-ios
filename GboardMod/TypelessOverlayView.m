#import "TypelessOverlayView.h"
#import "TypelessConfig.h"
#import "TypelessSettingsView.h"
#import "TypelessVoiceManager.h"

@interface TypelessOverlayView () <TypelessSettingsViewDelegate>

@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UIButton *modeButton;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *gearButton;

@property (nonatomic, strong) UIView *waveContainer;
@property (nonatomic, strong) NSMutableArray<UIView *> *waveBars;
@property (nonatomic, strong) UILabel *transcriptLabel;

@property (nonatomic, strong) UIButton *cancelBtn;
@property (nonatomic, strong) UIButton *retryBtn;
@property (nonatomic, strong) UIButton *doneBtn;

@property (nonatomic, strong) TypelessSettingsView *settingsView;
@property (nonatomic, copy) NSString *currentTranscript;

@end

@implementation TypelessOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupUI];
    }
    return self;
}

- (void)setupUI {
    self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.currentTranscript = @"";

    _cardView = [[UIView alloc] initWithFrame:CGRectZero];
    _cardView.backgroundColor = [UIColor colorWithRed:0.95 green:0.96 blue:0.98 alpha:0.97];
    _cardView.layer.cornerRadius = 20.0;
    _cardView.layer.masksToBounds = YES;
    _cardView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.6].CGColor;
    _cardView.layer.borderWidth = 1.0;
    [self addSubview:_cardView];

    // Mode Button (Typeless style pill)
    _modeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _modeButton.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:0.12];
    _modeButton.layer.cornerRadius = 12;
    _modeButton.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    [_modeButton setTitleColor:[UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0] forState:UIControlStateNormal];
    [_modeButton addTarget:self action:@selector(toggleModeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self updateModeButtonTitle];
    [_cardView addSubview:_modeButton];

    // Status Label
    _statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _statusLabel.text = @"Typeless 正在倾听...";
    _statusLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _statusLabel.textColor = [UIColor colorWithWhite:0.3 alpha:1.0];
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    [_cardView addSubview:_statusLabel];

    // Gear Settings Button
    _gearButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [_gearButton setTitle:@"⚙" forState:UIControlStateNormal];
    [_gearButton setTitleColor:[UIColor colorWithWhite:0.35 alpha:1.0] forState:UIControlStateNormal];
    _gearButton.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightRegular];
    [_gearButton addTarget:self action:@selector(openSettingsTapped) forControlEvents:UIControlEventTouchUpInside];
    [_cardView addSubview:_gearButton];

    // Waveform Container
    _waveContainer = [[UIView alloc] initWithFrame:CGRectZero];
    [_cardView addSubview:_waveContainer];

    _waveBars = [NSMutableArray array];
    for (int i = 0; i < 5; i++) {
        UIView *b = [[UIView alloc] initWithFrame:CGRectZero];
        b.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];
        b.layer.cornerRadius = 2.5;
        b.layer.masksToBounds = YES;
        [_waveContainer addSubview:b];
        [_waveBars addObject:b];
    }

    // Transcript Label
    _transcriptLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _transcriptLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    _transcriptLabel.textColor = [UIColor colorWithWhite:0.1 alpha:1.0];
    _transcriptLabel.textAlignment = NSTextAlignmentCenter;
    _transcriptLabel.numberOfLines = 3;
    _transcriptLabel.adjustsFontSizeToFitWidth = YES;
    _transcriptLabel.minimumScaleFactor = 0.8;
    [_cardView addSubview:_transcriptLabel];

    // Bottom Action Buttons
    _cancelBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    [_cancelBtn setTitle:@"✕ 取消" forState:UIControlStateNormal];
    [_cancelBtn setTitleColor:[UIColor colorWithWhite:0.35 alpha:1.0] forState:UIControlStateNormal];
    _cancelBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _cancelBtn.backgroundColor = [UIColor colorWithRed:0.88 green:0.89 blue:0.91 alpha:1.0];
    _cancelBtn.layer.cornerRadius = 14;
    [_cancelBtn addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];
    [_cardView addSubview:_cancelBtn];

    _retryBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    [_retryBtn setTitle:@"重说" forState:UIControlStateNormal];
    [_retryBtn setTitleColor:[UIColor colorWithWhite:0.35 alpha:1.0] forState:UIControlStateNormal];
    _retryBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _retryBtn.backgroundColor = [UIColor colorWithRed:0.88 green:0.89 blue:0.91 alpha:1.0];
    _retryBtn.layer.cornerRadius = 14;
    [_retryBtn addTarget:self action:@selector(retryTapped) forControlEvents:UIControlEventTouchUpInside];
    [_cardView addSubview:_retryBtn];

    _doneBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    [_doneBtn setTitle:@"✓ 完成上屏" forState:UIControlStateNormal];
    [_doneBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _doneBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    _doneBtn.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];
    _doneBtn.layer.cornerRadius = 14;
    [_doneBtn addTarget:self action:@selector(doneTapped) forControlEvents:UIControlEventTouchUpInside];
    [_cardView addSubview:_doneBtn];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;

    CGFloat cardW = MIN(w - 20, 360);
    CGFloat cardH = MIN(h - 12, 192);
    CGFloat cardX = (w - cardW) / 2.0;
    CGFloat cardY = (h - cardH) / 2.0;
    _cardView.frame = CGRectMake(cardX, cardY, cardW, cardH);

    _modeButton.frame = CGRectMake(12, 8, 92, 24);
    _statusLabel.frame = CGRectMake(108, 8, cardW - 156, 24);
    _gearButton.frame = CGRectMake(cardW - 40, 6, 32, 28);

    // Waveform
    CGFloat waveW = 70;
    CGFloat waveH = 24;
    _waveContainer.frame = CGRectMake((cardW - waveW) / 2.0, 34, waveW, waveH);
    CGFloat barW = 5;
    CGFloat spacing = 8;
    for (int i = 0; i < 5; i++) {
        UIView *b = _waveBars[i];
        CGFloat bx = i * (barW + spacing);
        CGFloat bh = b.frame.size.height > 0 ? b.frame.size.height : 6;
        b.frame = CGRectMake(bx, (waveH - bh) / 2.0, barW, bh);
    }

    _transcriptLabel.frame = CGRectMake(14, 62, cardW - 28, 70);

    CGFloat btnY = cardH - 42;
    CGFloat btnH = 30;
    _cancelBtn.frame = CGRectMake(12, btnY, 68, btnH);
    _retryBtn.frame = CGRectMake(88, btnY, 58, btnH);
    _doneBtn.frame = CGRectMake(cardW - 126, btnY, 114, btnH);

    if (_settingsView) {
        _settingsView.frame = self.bounds;
    }
}

- (void)updateModeButtonTitle {
    TypelessConfig *cfg = [TypelessConfig sharedConfig];
    if (cfg.isAIPolish) {
        [_modeButton setTitle:@"✨ AI 润色" forState:UIControlStateNormal];
        _modeButton.backgroundColor = [UIColor colorWithRed:0.5 green:0.2 blue:0.9 alpha:0.12];
        [_modeButton setTitleColor:[UIColor colorWithRed:0.5 green:0.2 blue:0.9 alpha:1.0] forState:UIControlStateNormal];
    } else {
        [_modeButton setTitle:@"🎙 直录听写" forState:UIControlStateNormal];
        _modeButton.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:0.12];
        [_modeButton setTitleColor:[UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0] forState:UIControlStateNormal];
    }
}

- (void)toggleModeTapped {
    TypelessConfig *cfg = [TypelessConfig sharedConfig];
    cfg.isAIPolish = !cfg.isAIPolish;
    [cfg save];
    [self updateModeButtonTitle];
}

- (void)openSettingsTapped {
    if (!_settingsView) {
        _settingsView = [[TypelessSettingsView alloc] initWithFrame:self.bounds];
        _settingsView.delegate = self;
    } else {
        _settingsView.frame = self.bounds;
        [_settingsView reloadConfig];
    }
    _settingsView.alpha = 0.0;
    [self addSubview:_settingsView];
    [self bringSubviewToFront:_settingsView];
    [UIView animateWithDuration:0.2 animations:^{
        self.settingsView.alpha = 1.0;
    }];
}

#pragma mark - TypelessSettingsViewDelegate

- (void)typelessSettingsDidSave {
    [self typelessSettingsDidClose];
    [self updateModeButtonTitle];
    [self resetForNewRecording];
    [[TypelessVoiceManager sharedManager] startRecordingWithLevelHandler:^(CGFloat level) {
        [self updateAudioLevel:level];
    }];
}

- (void)typelessSettingsDidClose {
    if (_settingsView) {
        [UIView animateWithDuration:0.2 animations:^{
            self.settingsView.alpha = 0.0;
        } completion:^(BOOL finished) {
            [self.settingsView removeFromSuperview];
        }];
    }
}

- (void)updateAudioLevel:(CGFloat)level {
    dispatch_async(dispatch_get_main_queue(), ^{
        CGFloat clamped = MAX(0.05, MIN(1.0, level));
        CGFloat heights[5] = {
            (CGFloat)(6.0 + clamped * 14.0 * 0.6),
            (CGFloat)(6.0 + clamped * 20.0 * 0.9),
            (CGFloat)(6.0 + clamped * 24.0 * 1.0),
            (CGFloat)(6.0 + clamped * 20.0 * 0.85),
            (CGFloat)(6.0 + clamped * 14.0 * 0.5)
        };
        for (int i = 0; i < 5; i++) {
            UIView *b = self.waveBars[i];
            CGRect r = b.frame;
            r.size.height = heights[i];
            r.origin.y = (24.0 - heights[i]) / 2.0;
            b.frame = r;
        }
    });
}

- (void)updateTranscriptText:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.currentTranscript = text ?: @"";
        if (text.length > 0) {
            self.transcriptLabel.text = text;
            self.transcriptLabel.textColor = [UIColor blackColor];
        } else {
            TypelessConfig *cfg = [TypelessConfig sharedConfig];
            if ([cfg hasValidApiKey]) {
                self.transcriptLabel.text = @"请说话，点击「完成上屏」即可调用自定义大模型识别与润色...";
            } else {
                self.transcriptLabel.text = @"请说话，文字将实时显示 (点击右上角 ⚙ 可配置自选大模型)...";
            }
            self.transcriptLabel.textColor = [UIColor colorWithWhite:0.45 alpha:1.0];
        }
    });
}

- (void)setStatusText:(NSString *)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = status;
    });
}

- (void)resetForNewRecording {
    self.currentTranscript = @"";
    self.statusLabel.text = @"Typeless 正在倾听...";
    [self updateModeButtonTitle];
    [self updateTranscriptText:@""];
    [self updateAudioLevel:0];
}

- (void)doneTapped {
    self.doneBtn.enabled = NO;
    [self.doneBtn setTitle:@"处理中..." forState:UIControlStateNormal];
    [self setStatusText:@"AI 处理中..."];

    [[TypelessVoiceManager sharedManager] stopRecordingAndProcessWithStatusHandler:^(NSString * _Nonnull status) {
        [self setStatusText:status];
    } completionHandler:^(NSString * _Nullable text, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.doneBtn.enabled = YES;
            [self.doneBtn setTitle:@"✓ 完成上屏" forState:UIControlStateNormal];

            if (error) {
                [self setStatusText:[NSString stringWithFormat:@"错误: %@", error.localizedDescription]];
                [self updateTranscriptText:[NSString stringWithFormat:@"处理失败: %@", error.localizedDescription]];
            } else if (text && text.length > 0) {
                [[TypelessVoiceManager sharedManager] commitTextDirectly:text];
            } else {
                [[TypelessVoiceManager sharedManager] commitTextDirectly:self.currentTranscript];
            }
        });
    }];
}

- (void)cancelTapped {
    [[TypelessVoiceManager sharedManager] cancelRecording];
}

- (void)retryTapped {
    [self resetForNewRecording];
    [[TypelessVoiceManager sharedManager] startRecordingWithLevelHandler:^(CGFloat level) {
        [self updateAudioLevel:level];
    }];
}

@end
