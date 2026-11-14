#import "LintypeVoiceOverlayView.h"

@interface LintypeVoiceOverlayView ()

@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *transcriptLabel;
@property (nonatomic, strong) UIView *waveformContainer;
@property (nonatomic, strong) NSMutableArray<UIView *> *waveBars;
@property (nonatomic, strong) UIButton *doneButton;
@property (nonatomic, strong) UIButton *cancelButton;
@property (nonatomic, strong) UIButton *retryButton;
@property (nonatomic, copy) NSString *currentText;

@end

@implementation LintypeVoiceOverlayView

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
    self.currentText = @"";

    // Card View
    _cardView = [[UIView alloc] initWithFrame:CGRectZero];
    _cardView.backgroundColor = [UIColor colorWithRed:0.95 green:0.96 blue:0.97 alpha:0.96];
    _cardView.layer.cornerRadius = 20.0;
    _cardView.layer.masksToBounds = YES;
    _cardView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.6].CGColor;
    _cardView.layer.borderWidth = 1.0;
    [self addSubview:_cardView];

    // Status Label
    _statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _statusLabel.text = @"Lintype 正在倾听...";
    _statusLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _statusLabel.textColor = [UIColor colorWithRed:0.2 green:0.4 blue:0.8 alpha:1.0];
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    [_cardView addSubview:_statusLabel];

    // Waveform Container
    _waveformContainer = [[UIView alloc] initWithFrame:CGRectZero];
    [_cardView addSubview:_waveformContainer];

    _waveBars = [NSMutableArray array];
    for (int i = 0; i < 5; i++) {
        UIView *bar = [[UIView alloc] initWithFrame:CGRectZero];
        bar.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];
        bar.layer.cornerRadius = 2.5;
        bar.layer.masksToBounds = YES;
        [_waveformContainer addSubview:bar];
        [_waveBars addObject:bar];
    }

    // Transcript Label
    _transcriptLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _transcriptLabel.text = @"请说话，文字将实时显示...";
    _transcriptLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
    _transcriptLabel.textColor = [UIColor colorWithWhite:0.1 alpha:1.0];
    _transcriptLabel.textAlignment = NSTextAlignmentCenter;
    _transcriptLabel.numberOfLines = 3;
    _transcriptLabel.adjustsFontSizeToFitWidth = YES;
    _transcriptLabel.minimumScaleFactor = 0.8;
    [_cardView addSubview:_transcriptLabel];

    // Cancel Button
    _cancelButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [_cancelButton setTitle:@"✕ 取消" forState:UIControlStateNormal];
    [_cancelButton setTitleColor:[UIColor colorWithWhite:0.35 alpha:1.0] forState:UIControlStateNormal];
    _cancelButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    _cancelButton.backgroundColor = [UIColor colorWithRed:0.88 green:0.89 blue:0.91 alpha:1.0];
    _cancelButton.layer.cornerRadius = 15;
    [_cancelButton addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];
    [_cardView addSubview:_cancelButton];

    // Retry Button
    _retryButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [_retryButton setTitle:@"重说" forState:UIControlStateNormal];
    [_retryButton setTitleColor:[UIColor colorWithWhite:0.35 alpha:1.0] forState:UIControlStateNormal];
    _retryButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    _retryButton.backgroundColor = [UIColor colorWithRed:0.88 green:0.89 blue:0.91 alpha:1.0];
    _retryButton.layer.cornerRadius = 15;
    [_retryButton addTarget:self action:@selector(retryTapped) forControlEvents:UIControlEventTouchUpInside];
    [_cardView addSubview:_retryButton];

    // Done Button
    _doneButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [_doneButton setTitle:@"✓ 完成上屏" forState:UIControlStateNormal];
    [_doneButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _doneButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    _doneButton.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];
    _doneButton.layer.cornerRadius = 15;
    [_doneButton addTarget:self action:@selector(doneTapped) forControlEvents:UIControlEventTouchUpInside];
    [_cardView addSubview:_doneButton];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;

    CGFloat cardW = MIN(w - 24, 360);
    CGFloat cardH = MIN(h - 16, 186);
    CGFloat cardX = (w - cardW) / 2.0;
    CGFloat cardY = (h - cardH) / 2.0;
    _cardView.frame = CGRectMake(cardX, cardY, cardW, cardH);

    _statusLabel.frame = CGRectMake(12, 10, cardW - 24, 20);

    // Waveform
    CGFloat waveW = 70;
    CGFloat waveH = 26;
    _waveformContainer.frame = CGRectMake((cardW - waveW) / 2.0, 32, waveW, waveH);
    CGFloat barW = 5;
    CGFloat spacing = 8;
    for (int i = 0; i < 5; i++) {
        UIView *b = _waveBars[i];
        CGFloat bx = i * (barW + spacing);
        CGFloat bh = b.frame.size.height > 0 ? b.frame.size.height : 6;
        b.frame = CGRectMake(bx, (waveH - bh) / 2.0, barW, bh);
    }

    _transcriptLabel.frame = CGRectMake(16, 62, cardW - 32, 60);

    // Buttons
    CGFloat btnY = cardH - 42;
    CGFloat btnH = 30;
    _cancelButton.frame = CGRectMake(14, btnY, 70, btnH);
    _retryButton.frame = CGRectMake(92, btnY, 60, btnH);
    _doneButton.frame = CGRectMake(cardW - 120, btnY, 106, btnH);
}

- (void)updateAudioLevel:(CGFloat)level {
    dispatch_async(dispatch_get_main_queue(), ^{
        CGFloat clamped = MAX(0.05, MIN(1.0, level));
        CGFloat heights[5] = {
            (CGFloat)(6.0 + clamped * 16.0 * 0.6),
            (CGFloat)(6.0 + clamped * 22.0 * 0.9),
            (CGFloat)(6.0 + clamped * 26.0 * 1.0),
            (CGFloat)(6.0 + clamped * 22.0 * 0.85),
            (CGFloat)(6.0 + clamped * 16.0 * 0.5)
        };
        for (int i = 0; i < 5; i++) {
            UIView *b = self.waveBars[i];
            CGRect r = b.frame;
            r.size.height = heights[i];
            r.origin.y = (26.0 - heights[i]) / 2.0;
            b.frame = r;
        }
    });
}

- (void)updateTranscriptText:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.currentText = text ?: @"";
        if (text.length > 0) {
            self.transcriptLabel.text = text;
            self.transcriptLabel.textColor = [UIColor blackColor];
            self.statusLabel.text = @"Lintype 识别中...";
        } else {
            self.transcriptLabel.text = @"请说话，文字将实时显示...";
            self.transcriptLabel.textColor = [UIColor colorWithWhite:0.4 alpha:1.0];
            self.statusLabel.text = @"Lintype 正在倾听...";
        }
    });
}

- (void)setStatusText:(NSString *)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = status;
    });
}

- (void)reset {
    self.currentText = @"";
    [self updateTranscriptText:@""];
    [self updateAudioLevel:0];
}

- (void)doneTapped {
    if ([self.delegate respondsToSelector:@selector(voiceOverlayDidTapDone:)]) {
        [self.delegate voiceOverlayDidTapDone:self.currentText];
    }
}

- (void)cancelTapped {
    if ([self.delegate respondsToSelector:@selector(voiceOverlayDidTapCancel)]) {
        [self.delegate voiceOverlayDidTapCancel];
    }
}

- (void)retryTapped {
    [self reset];
    if ([self.delegate respondsToSelector:@selector(voiceOverlayDidTapRetry)]) {
        [self.delegate voiceOverlayDidTapRetry];
    }
}

@end
