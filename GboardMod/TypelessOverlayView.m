#import "TypelessOverlayView.h"
#import "TypelessConfig.h"
#import "TypelessSettingsView.h"
#import "TypelessVoiceManager.h"
#import "TypelessHostBridge.h"

@interface TypelessOverlayView () <TypelessSettingsViewDelegate>

// Top Toolbar
@property (nonatomic, strong) UIView *toolbarView;
@property (nonatomic, strong) UIButton *manualToggleBtn;
@property (nonatomic, strong) UIScrollView *modeScrollView;
@property (nonatomic, strong) NSMutableArray<UIButton *> *modeButtons;
@property (nonatomic, strong) UIButton *undoBtn;
@property (nonatomic, strong) UIButton *modelPillBtn;
@property (nonatomic, strong) UIView *toolbarDivider;

// Accessory Strip
@property (nonatomic, strong) UILabel *accessoryHintLabel;
@property (nonatomic, strong) UIButton *translateLangPill;

// Center Idle View
@property (nonatomic, strong) UIView *idleContainer;
@property (nonatomic, strong) UIButton *bigMicButton;
@property (nonatomic, strong) UIImageView *bigMicIconView;
@property (nonatomic, strong) UILabel *idleTitleLabel;
@property (nonatomic, strong) UILabel *idleSubtitleLabel;

// Center Recording View
@property (nonatomic, strong) UIView *recordingContainer;
@property (nonatomic, strong) UIView *waveContainer;
@property (nonatomic, strong) NSMutableArray<UIView *> *waveBars;
@property (nonatomic, strong) UILabel *partialTextLabel;
@property (nonatomic, strong) UIButton *recCancelBtn;
@property (nonatomic, strong) UIButton *recDoneBtn;

// Center Processing / Error View
@property (nonatomic, strong) UIView *statusContainer;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *statusTitleLabel;
@property (nonatomic, strong) UIButton *statusActionBtn;

// Bottom Utility Keys
@property (nonatomic, strong) UIView *bottomBar;
@property (nonatomic, strong) UIButton *pinyinBackKey;
@property (nonatomic, strong) UIButton *spaceKey;
@property (nonatomic, strong) UIButton *backspaceKey;
@property (nonatomic, strong) UIButton *returnKey;
@property (nonatomic, strong) NSTimer *backspaceRepeatTimer;

// Settings Sheet
@property (nonatomic, strong, nullable) TypelessSettingsView *settingsView;
@property (nonatomic, copy, nullable) NSString *transientNotice;
@property (nonatomic, assign) NSInteger errorActionKind; // 0 = retry, 1 = wake host keepalive, 2 = open iOS settings

@end

@implementation TypelessOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupUI];
        [self refreshStateUI];
    }
    return self;
}

- (void)dealloc {
    [_backspaceRepeatTimer invalidate];
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

#pragma mark - UI Construction

- (void)setupUI {
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    // Swipe right/left to return to Gboard native keyboard
    UISwipeGestureRecognizer *swipeLeft = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(switchToManualTapped)];
    swipeLeft.direction = UISwipeGestureRecognizerDirectionLeft;
    [self addGestureRecognizer:swipeLeft];

    UISwipeGestureRecognizer *swipeRight = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(switchToManualTapped)];
    swipeRight.direction = UISwipeGestureRecognizerDirectionRight;
    [self addGestureRecognizer:swipeRight];

    // 1. Top Toolbar
    _toolbarView = [[UIView alloc] initWithFrame:CGRectZero];
    [self addSubview:_toolbarView];

    _manualToggleBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    _manualToggleBtn.layer.cornerRadius = 13.0;
    _manualToggleBtn.layer.masksToBounds = YES;
    [self configureButton:_manualToggleBtn symbolName:@"keyboard" title:@"手打" fontSize:12 weight:UIFontWeightSemibold spacing:4];
    [_manualToggleBtn addTarget:self action:@selector(switchToManualTapped) forControlEvents:UIControlEventTouchUpInside];
    [_toolbarView addSubview:_manualToggleBtn];

    _modeScrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _modeScrollView.showsHorizontalScrollIndicator = NO;
    [_toolbarView addSubview:_modeScrollView];

    _modeButtons = [NSMutableArray array];
    for (NSInteger m = TypelessVoiceModeDictate; m <= TypelessVoiceModeHelpWrite; m++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.tag = m;
        btn.layer.cornerRadius = 12.0;
        btn.layer.masksToBounds = YES;
        [btn setTitle:[TypelessConfig titleForMode:(TypelessVoiceMode)m] forState:UIControlStateNormal];
        [btn addTarget:self action:@selector(modeTabTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_modeScrollView addSubview:btn];
        [_modeButtons addObject:btn];
    }

    _undoBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    if (@available(iOS 13.0, *)) {
        UIImage *img = [UIImage systemImageNamed:@"arrow.uturn.backward.circle.fill"];
        [_undoBtn setImage:img forState:UIControlStateNormal];
    } else {
        [_undoBtn setTitle:@"↶" forState:UIControlStateNormal];
    }
    _undoBtn.tintColor = [UIColor systemOrangeColor];
    [_undoBtn addTarget:self action:@selector(undoTapped) forControlEvents:UIControlEventTouchUpInside];
    [_toolbarView addSubview:_undoBtn];

    _modelPillBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    _modelPillBtn.layer.cornerRadius = 12.0;
    _modelPillBtn.layer.masksToBounds = YES;
    [_modelPillBtn addTarget:self action:@selector(openSettingsTapped) forControlEvents:UIControlEventTouchUpInside];
    [_toolbarView addSubview:_modelPillBtn];

    _toolbarDivider = [[UIView alloc] initWithFrame:CGRectZero];
    [self addSubview:_toolbarDivider];

    // 2. Accessory Hint Row
    _accessoryHintLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _accessoryHintLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
    _accessoryHintLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_accessoryHintLabel];

    _translateLangPill = [UIButton buttonWithType:UIButtonTypeCustom];
    _translateLangPill.layer.cornerRadius = 11.5;
    _translateLangPill.layer.masksToBounds = YES;
    _translateLangPill.titleLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightMedium];
    [_translateLangPill addTarget:self action:@selector(cycleTranslateLangTapped) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_translateLangPill];

    // 3a. Center Idle View
    _idleContainer = [[UIView alloc] initWithFrame:CGRectZero];
    [self addSubview:_idleContainer];

    _bigMicButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _bigMicButton.layer.cornerRadius = 39.0;
    _bigMicButton.layer.masksToBounds = NO;
    _bigMicButton.layer.shadowColor = [UIColor blackColor].CGColor;
    _bigMicButton.layer.shadowOffset = CGSizeMake(0, 2);
    _bigMicButton.layer.shadowRadius = 6;
    _bigMicButton.layer.shadowOpacity = 0.08;
    [_bigMicButton addTarget:self action:@selector(startRecordingTapped) forControlEvents:UIControlEventTouchUpInside];
    [_idleContainer addSubview:_bigMicButton];

    _bigMicIconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _bigMicIconView.contentMode = UIViewContentModeScaleAspectFit;
    _bigMicIconView.userInteractionEnabled = NO;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:30 weight:UIImageSymbolWeightMedium];
        _bigMicIconView.image = [UIImage systemImageNamed:@"mic" withConfiguration:cfg];
    }
    [_bigMicButton addSubview:_bigMicIconView];

    _idleTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _idleTitleLabel.font = [UIFont systemFontOfSize:15.5 weight:UIFontWeightSemibold];
    _idleTitleLabel.textAlignment = NSTextAlignmentCenter;
    [_idleContainer addSubview:_idleTitleLabel];

    _idleSubtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _idleSubtitleLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
    _idleSubtitleLabel.textAlignment = NSTextAlignmentCenter;
    [_idleContainer addSubview:_idleSubtitleLabel];

    // 3b. Center Recording View
    _recordingContainer = [[UIView alloc] initWithFrame:CGRectZero];
    [self addSubview:_recordingContainer];

    _waveContainer = [[UIView alloc] initWithFrame:CGRectZero];
    [_recordingContainer addSubview:_waveContainer];

    _waveBars = [NSMutableArray array];
    for (int i = 0; i < 9; i++) {
        UIView *b = [[UIView alloc] initWithFrame:CGRectZero];
        b.backgroundColor = [UIColor colorWithRed:1.0 green:0.23 blue:0.19 alpha:1.0];
        b.layer.cornerRadius = 2.5;
        b.layer.masksToBounds = YES;
        [_waveContainer addSubview:b];
        [_waveBars addObject:b];
    }

    _partialTextLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _partialTextLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    _partialTextLabel.textAlignment = NSTextAlignmentCenter;
    _partialTextLabel.numberOfLines = 2;
    [_recordingContainer addSubview:_partialTextLabel];

    _recCancelBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    _recCancelBtn.layer.cornerRadius = 18.0;
    [self configureButton:_recCancelBtn symbolName:@"xmark" title:@"取消" fontSize:14 weight:UIFontWeightMedium spacing:5];
    [_recCancelBtn addTarget:self action:@selector(cancelRecordingTapped) forControlEvents:UIControlEventTouchUpInside];
    [_recordingContainer addSubview:_recCancelBtn];

    _recDoneBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    _recDoneBtn.layer.cornerRadius = 18.0;
    _recDoneBtn.backgroundColor = [UIColor colorWithRed:1.0 green:0.23 blue:0.19 alpha:1.0];
    [self configureButton:_recDoneBtn symbolName:@"stop.fill" title:@"完成 (0.0s)" fontSize:14 weight:UIFontWeightSemibold spacing:6];
    [_recDoneBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _recDoneBtn.tintColor = [UIColor whiteColor];
    [_recDoneBtn addTarget:self action:@selector(finishRecordingTapped) forControlEvents:UIControlEventTouchUpInside];
    [_recordingContainer addSubview:_recDoneBtn];

    // 3c. Center Processing / Error View
    _statusContainer = [[UIView alloc] initWithFrame:CGRectZero];
    [self addSubview:_statusContainer];

    if (@available(iOS 13.0, *)) {
        _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    } else {
        _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    }
    _spinner.hidesWhenStopped = YES;
    [_statusContainer addSubview:_spinner];

    _statusTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _statusTitleLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightMedium];
    _statusTitleLabel.textAlignment = NSTextAlignmentCenter;
    _statusTitleLabel.numberOfLines = 3;
    [_statusContainer addSubview:_statusTitleLabel];

    _statusActionBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    _statusActionBtn.layer.cornerRadius = 14.0;
    _statusActionBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [_statusActionBtn addTarget:self action:@selector(statusActionTapped) forControlEvents:UIControlEventTouchUpInside];
    [_statusContainer addSubview:_statusActionBtn];

    // 4. Bottom Utility Key Row
    _bottomBar = [[UIView alloc] initWithFrame:CGRectZero];
    [self addSubview:_bottomBar];

    _pinyinBackKey = [self makeBottomKeyWithSymbol:@"keyboard" title:@"拼音" fontSize:13 weight:UIFontWeightMedium];
    [_pinyinBackKey addTarget:self action:@selector(switchToManualTapped) forControlEvents:UIControlEventTouchUpInside];
    [_bottomBar addSubview:_pinyinBackKey];

    _spaceKey = [self makeBottomKeyWithSymbol:nil title:@"空格" fontSize:14 weight:UIFontWeightRegular];
    [_spaceKey addTarget:self action:@selector(spaceTapped) forControlEvents:UIControlEventTouchUpInside];
    [_bottomBar addSubview:_spaceKey];

    _backspaceKey = [self makeBottomKeyWithSymbol:@"delete.left" title:@"" fontSize:16 weight:UIFontWeightRegular];
    [_backspaceKey addTarget:self action:@selector(backspaceTouchDown) forControlEvents:UIControlEventTouchDown];
    [_backspaceKey addTarget:self action:@selector(backspaceTouchUp) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [_bottomBar addSubview:_backspaceKey];

    _returnKey = [self makeBottomKeyWithSymbol:nil title:@"换行" fontSize:14 weight:UIFontWeightSemibold];
    [_returnKey addTarget:self action:@selector(returnTapped) forControlEvents:UIControlEventTouchUpInside];
    [_bottomBar addSubview:_returnKey];

    [self applyThemeColors];
}

- (UIButton *)makeBottomKeyWithSymbol:(nullable NSString *)sym title:(NSString *)title fontSize:(CGFloat)size weight:(UIFontWeight)weight {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.layer.cornerRadius = 7.0;
    btn.layer.shadowColor = [UIColor blackColor].CGColor;
    btn.layer.shadowOffset = CGSizeMake(0, 1.0);
    btn.layer.shadowRadius = 0.4;
    btn.layer.shadowOpacity = 0.25;
    btn.layer.masksToBounds = NO;
    [self configureButton:btn symbolName:sym title:title fontSize:size weight:weight spacing:4];
    return btn;
}

- (void)configureButton:(UIButton *)btn symbolName:(nullable NSString *)sym title:(NSString *)title fontSize:(CGFloat)size weight:(UIFontWeight)weight spacing:(CGFloat)spacing {
    btn.titleLabel.font = [UIFont systemFontOfSize:size weight:weight];
    [btn setTitle:title forState:UIControlStateNormal];
    if (sym && sym.length > 0) {
        if (@available(iOS 13.0, *)) {
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:size weight:UIImageSymbolWeightMedium];
            UIImage *img = [UIImage systemImageNamed:sym withConfiguration:cfg];
            [btn setImage:img forState:UIControlStateNormal];
            if (title.length > 0) {
                btn.imageEdgeInsets = UIEdgeInsetsMake(0, -spacing / 2.0, 0, spacing / 2.0);
                btn.titleEdgeInsets = UIEdgeInsetsMake(0, spacing / 2.0, 0, -spacing / 2.0);
            }
        }
    }
}

#pragma mark - Layout

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    if (w <= 0 || h <= 0) return;

    // 1. Top Toolbar
    CGFloat tbH = 38.0;
    _toolbarView.frame = CGRectMake(0, 0, w, tbH);
    _toolbarDivider.frame = CGRectMake(0, tbH, w, 0.5);

    _manualToggleBtn.frame = CGRectMake(8, 6, 62, 26);

    CGFloat rightEdge = w - 8;
    _modelPillBtn.frame = CGRectMake(rightEdge - 66, 6, 66, 26);
    rightEdge -= 70;

    if (!_undoBtn.hidden) {
        _undoBtn.frame = CGRectMake(rightEdge - 26, 6, 26, 26);
        rightEdge -= 30;
    }

    CGFloat scrollX = 76;
    CGFloat scrollW = MAX(40, rightEdge - scrollX - 4);
    _modeScrollView.frame = CGRectMake(scrollX, 0, scrollW, tbH);

    CGFloat mx = 0;
    for (UIButton *b in _modeButtons) {
        b.frame = CGRectMake(mx, 7, 46, 24);
        mx += 50;
    }
    _modeScrollView.contentSize = CGSizeMake(mx, tbH);

    // 2. Accessory Hint Row
    CGFloat accY = tbH + 6;
    _accessoryHintLabel.frame = CGRectMake(12, accY, w - 24, 20);
    _translateLangPill.frame = CGRectMake(12, accY - 1, 168, 23);

    // 4. Bottom Key Row
    CGFloat bottomH = 38.0;
    CGFloat bottomPad = 6.0;
    _bottomBar.frame = CGRectMake(8, h - bottomH - bottomPad, w - 16, bottomH);
    CGFloat barW = _bottomBar.bounds.size.width;
    CGFloat gap = 6.0;
    CGFloat pinyinW = 70.0;
    CGFloat backW = 54.0;
    CGFloat retW = 70.0;
    CGFloat spaceW = MAX(60, barW - pinyinW - backW - retW - gap * 3);

    _pinyinBackKey.frame = CGRectMake(0, 0, pinyinW, bottomH);
    _spaceKey.frame = CGRectMake(pinyinW + gap, 0, spaceW, bottomH);
    _backspaceKey.frame = CGRectMake(pinyinW + gap + spaceW + gap, 0, backW, bottomH);
    _returnKey.frame = CGRectMake(barW - retW, 0, retW, bottomH);

    // 3. Center Focal Zone
    CGFloat centerTop = accY + 22;
    CGFloat centerBottom = h - bottomH - bottomPad - 6;
    CGFloat centerH = MAX(90, centerBottom - centerTop);
    CGRect centerFrame = CGRectMake(0, centerTop, w, centerH);

    _idleContainer.frame = centerFrame;
    _recordingContainer.frame = centerFrame;
    _statusContainer.frame = centerFrame;

    // Idle Layout
    CGFloat micSize = MIN(78.0, centerH * 0.56);
    _bigMicButton.layer.cornerRadius = micSize / 2.0;
    CGFloat totalIdleH = micSize + 44;
    CGFloat idleStartY = MAX(2, (centerH - totalIdleH) / 2.0);
    _bigMicButton.frame = CGRectMake((w - micSize) / 2.0, idleStartY, micSize, micSize);
    CGFloat iconDim = micSize * 0.44;
    _bigMicIconView.frame = CGRectMake((micSize - iconDim) / 2.0, (micSize - iconDim) / 2.0, iconDim, iconDim);
    _idleTitleLabel.frame = CGRectMake(16, idleStartY + micSize + 8, w - 32, 20);
    _idleSubtitleLabel.frame = CGRectMake(16, idleStartY + micSize + 30, w - 32, 16);

    // Recording Layout
    CGFloat waveW = 9 * 5 + 8 * 5;
    CGFloat recStartY = MAX(4, (centerH - 116) / 2.0);
    _waveContainer.frame = CGRectMake((w - waveW) / 2.0, recStartY, waveW, 40);
    for (int i = 0; i < (int)_waveBars.count; i++) {
        UIView *b = _waveBars[i];
        CGFloat bh = b.frame.size.height > 4 ? b.frame.size.height : 10;
        b.frame = CGRectMake(i * 10.0, (40.0 - bh) / 2.0, 5.0, bh);
    }
    _partialTextLabel.frame = CGRectMake(18, recStartY + 42, w - 36, 32);
    CGFloat btnRowY = recStartY + 78;
    _recCancelBtn.frame = CGRectMake((w - 224) / 2.0, btnRowY, 82, 36);
    _recDoneBtn.frame = CGRectMake((w - 224) / 2.0 + 92, btnRowY, 132, 36);

    // Status / Error Layout
    CGFloat statStartY = MAX(6, (centerH - 96) / 2.0);
    _spinner.center = CGPointMake(w / 2.0, statStartY + 14);
    _statusTitleLabel.frame = CGRectMake(20, statStartY + 30, w - 40, 40);
    _statusActionBtn.frame = CGRectMake((w - 96) / 2.0, statStartY + 74, 96, 28);

    if (_settingsView) {
        _settingsView.frame = self.bounds;
    }
}

#pragma mark - Theme & State Sync

- (void)applyThemeColors {
    BOOL dark = [self isDark];
    self.backgroundColor = dark ? [UIColor colorWithRed:0.11 green:0.11 blue:0.12 alpha:1.0]
                                : [UIColor colorWithRed:0.824 green:0.835 blue:0.863 alpha:1.0];

    _toolbarDivider.backgroundColor = dark ? [UIColor colorWithWhite:1.0 alpha:0.12]
                                           : [UIColor colorWithWhite:0.0 alpha:0.12];

    UIColor *blueAccent = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];
    _manualToggleBtn.backgroundColor = [blueAccent colorWithAlphaComponent:0.15];
    [_manualToggleBtn setTitleColor:blueAccent forState:UIControlStateNormal];
    _manualToggleBtn.tintColor = blueAccent;

    TypelessConfig *cfg = [TypelessConfig sharedConfig];
    for (UIButton *b in _modeButtons) {
        BOOL active = (b.tag == cfg.voiceMode);
        if (active) {
            b.backgroundColor = blueAccent;
            [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            b.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        } else {
            b.backgroundColor = [UIColor clearColor];
            [b setTitleColor:(dark ? [UIColor colorWithWhite:0.9 alpha:1.0] : [UIColor colorWithWhite:0.1 alpha:1.0])
                    forState:UIControlStateNormal];
            b.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        }
    }

    if ([cfg hasValidApiKey]) {
        UIColor *greenAccent = [UIColor colorWithRed:0.18 green:0.72 blue:0.42 alpha:1.0];
        _modelPillBtn.backgroundColor = [greenAccent colorWithAlphaComponent:0.15];
        [self configureButton:_modelPillBtn symbolName:@"checkmark.circle.fill" title:@"模型" fontSize:11 weight:UIFontWeightSemibold spacing:3];
        [_modelPillBtn setTitleColor:greenAccent forState:UIControlStateNormal];
        _modelPillBtn.tintColor = greenAccent;
    } else {
        UIColor *orangeAccent = [UIColor systemOrangeColor];
        _modelPillBtn.backgroundColor = [orangeAccent colorWithAlphaComponent:0.16];
        [self configureButton:_modelPillBtn symbolName:@"slider.horizontal.3" title:@"模型" fontSize:11 weight:UIFontWeightSemibold spacing:3];
        [_modelPillBtn setTitleColor:orangeAccent forState:UIControlStateNormal];
        _modelPillBtn.tintColor = orangeAccent;
    }

    _accessoryHintLabel.textColor = dark ? [UIColor colorWithWhite:0.65 alpha:1.0] : [UIColor colorWithWhite:0.42 alpha:1.0];
    _translateLangPill.backgroundColor = [blueAccent colorWithAlphaComponent:0.14];
    [_translateLangPill setTitleColor:blueAccent forState:UIControlStateNormal];

    // Big Mic Circle matching the soft lavender-blue aura in screenshot
    _bigMicButton.backgroundColor = dark ? [UIColor colorWithRed:0.25 green:0.32 blue:0.65 alpha:0.38]
                                         : [UIColor colorWithRed:0.46 green:0.52 blue:0.86 alpha:0.28];
    _bigMicIconView.tintColor = blueAccent;

    _idleTitleLabel.textColor = dark ? [UIColor whiteColor] : [UIColor blackColor];
    _idleSubtitleLabel.textColor = dark ? [UIColor colorWithWhite:0.55 alpha:1.0] : [UIColor colorWithWhite:0.52 alpha:1.0];
    _partialTextLabel.textColor = dark ? [UIColor whiteColor] : [UIColor colorWithWhite:0.15 alpha:1.0];

    UIColor *keyBg = dark ? [UIColor colorWithWhite:0.32 alpha:1.0] : [UIColor whiteColor];
    UIColor *specKeyBg = dark ? [UIColor colorWithWhite:0.21 alpha:1.0] : [UIColor colorWithRed:0.675 green:0.698 blue:0.745 alpha:1.0];
    UIColor *keyText = dark ? [UIColor whiteColor] : [UIColor blackColor];

    _recCancelBtn.backgroundColor = keyBg;
    [_recCancelBtn setTitleColor:keyText forState:UIControlStateNormal];
    _recCancelBtn.tintColor = keyText;

    _pinyinBackKey.backgroundColor = specKeyBg;
    [_pinyinBackKey setTitleColor:keyText forState:UIControlStateNormal];
    _pinyinBackKey.tintColor = keyText;

    _spaceKey.backgroundColor = keyBg;
    [_spaceKey setTitleColor:keyText forState:UIControlStateNormal];

    _backspaceKey.backgroundColor = specKeyBg;
    [_backspaceKey setTitleColor:keyText forState:UIControlStateNormal];
    _backspaceKey.tintColor = keyText;

    _returnKey.backgroundColor = blueAccent;
    [_returnKey setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];

    _statusTitleLabel.textColor = dark ? [UIColor colorWithWhite:0.9 alpha:1.0] : [UIColor colorWithWhite:0.2 alpha:1.0];
}

- (void)refreshStateUI {
    dispatch_async(dispatch_get_main_queue(), ^{
        TypelessVoiceManager *mgr = [TypelessVoiceManager sharedManager];
        TypelessConfig *cfg = [TypelessConfig sharedConfig];
        NSString *modeTitle = [TypelessConfig titleForMode:cfg.voiceMode];

        self.undoBtn.hidden = !mgr.canUndoLastInsert;
        [self.returnKey setTitle:[mgr currentReturnKeyTitle] forState:UIControlStateNormal];

        // Accessory hint
        if (cfg.voiceMode == TypelessVoiceModeTranslate) {
            self.translateLangPill.hidden = NO;
            self.accessoryHintLabel.hidden = YES;
            [self.translateLangPill setTitle:[NSString stringWithFormat:@"🌐 目标语言: %@ ▾", cfg.targetLanguage ?: @"English"]
                                    forState:UIControlStateNormal];
        } else {
            self.translateLangPill.hidden = YES;
            self.accessoryHintLabel.hidden = NO;

            if (![mgr hasFullAccess]) {
                self.accessoryHintLabel.text = @"请在「系统设置 → 键盘 → Gboard」开启允许完全访问";
            } else if (cfg.voiceMode == TypelessVoiceModeEdit) {
                NSString *sel = [mgr currentSelectedTextPreview];
                if (sel.length > 0) {
                    self.accessoryHintLabel.text = [NSString stringWithFormat:@"已选中 %lu 字，点击麦克风口述改写指令", (unsigned long)sel.length];
                } else {
                    self.accessoryHintLabel.text = @"可直接口述文本，AI 自动润色精简与排版";
                }
            } else if (cfg.voiceMode == TypelessVoiceModeHelpWrite) {
                self.accessoryHintLabel.text = @"口述收件人/要点/语气，AI 直接帮写完整内容";
            } else if ([cfg hasValidApiKey]) {
                NSString *asrDesc = cfg.useAppleASR ? @"Apple听写" : (cfg.asrModel.length > 0 ? cfg.asrModel : @"Whisper");
                self.accessoryHintLabel.text = [NSString stringWithFormat:@"已连接 AI：%@ · %@ (支持智能断句去口癖)", asrDesc, cfg.llmModel];
            } else {
                self.accessoryHintLabel.text = @"免配置 Apple 本地语音就绪 · 点右上角「模型」可配 AI";
            }
        }

        // Toggle center panels
        TypelessSessionState st = mgr.state;
        self.idleContainer.hidden = (st != TypelessSessionStateIdle);
        self.recordingContainer.hidden = (st != TypelessSessionStateRecording);
        self.statusContainer.hidden = (st != TypelessSessionStateTranscribing && st != TypelessSessionStateProcessingAI && st != TypelessSessionStateError);

        if (st == TypelessSessionStateIdle) {
            [self.spinner stopAnimating];
            self.idleTitleLabel.text = [NSString stringWithFormat:@"点击开始「%@」", modeTitle];
            if (self.transientNotice.length > 0) {
                self.idleSubtitleLabel.text = self.transientNotice;
            } else {
                self.idleSubtitleLabel.text = @"左右滑动或点击「手打」切回 Gboard 原生键盘";
            }
        } else if (st == TypelessSessionStateRecording) {
            [self.spinner stopAnimating];
            self.transientNotice = nil;
            self.partialTextLabel.text = [cfg shouldUseWhisperAPI] ? @"正在高清录音，请说话..." : @"正在倾听，请说话...";
            [self configureButton:self.recDoneBtn symbolName:@"stop.fill" title:@"完成 (0.0s)" fontSize:14 weight:UIFontWeightSemibold spacing:6];
        } else if (st == TypelessSessionStateTranscribing) {
            [self.spinner startAnimating];
            self.statusTitleLabel.text = @"正在转写语音...";
            self.statusActionBtn.hidden = NO;
            [self.statusActionBtn setTitle:@"取消" forState:UIControlStateNormal];
            self.statusActionBtn.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.18];
            [self.statusActionBtn setTitleColor:self.statusTitleLabel.textColor forState:UIControlStateNormal];
        } else if (st == TypelessSessionStateProcessingAI) {
            [self.spinner startAnimating];
            self.statusTitleLabel.text = [NSString stringWithFormat:@"AI 正在执行「%@」...", modeTitle];
            self.statusActionBtn.hidden = NO;
            [self.statusActionBtn setTitle:@"取消" forState:UIControlStateNormal];
            self.statusActionBtn.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.18];
            [self.statusActionBtn setTitleColor:self.statusTitleLabel.textColor forState:UIControlStateNormal];
        } else if (st == TypelessSessionStateError) {
            [self.spinner stopAnimating];
            self.statusActionBtn.hidden = NO;
            [self.statusActionBtn setTitle:@"重新尝试" forState:UIControlStateNormal];
            self.statusActionBtn.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];
            [self.statusActionBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        }

        [self applyThemeColors];
        [self setNeedsLayout];
    });
}

- (void)updateAudioLevel:(CGFloat)level elapsedSeconds:(NSTimeInterval)elapsed {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self configureButton:self.recDoneBtn
                   symbolName:@"stop.fill"
                        title:[NSString stringWithFormat:@"完成 (%.1fs)", elapsed]
                     fontSize:14
                       weight:UIFontWeightSemibold
                      spacing:6];

        if (level >= 0) {
            static const CGFloat weights[9] = {0.35, 0.55, 0.78, 0.95, 1.0, 0.95, 0.78, 0.55, 0.35};
            CGFloat clamped = MAX(0.06, MIN(1.0, level));
            [UIView animateWithDuration:0.08 animations:^{
                for (int i = 0; i < (int)self.waveBars.count; i++) {
                    CGFloat h = MAX(8.0, MIN(40.0, 8.0 + clamped * 32.0 * weights[i]));
                    UIView *b = self.waveBars[i];
                    CGRect r = b.frame;
                    r.size.height = h;
                    r.origin.y = (40.0 - h) / 2.0;
                    b.frame = r;
                }
            }];
        }
    });
}

- (void)updatePartialTranscript:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (text.length > 0) {
            self.partialTextLabel.text = text;
        }
    });
}

- (void)showErrorStatus:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self refreshStateUI];
        self.statusTitleLabel.text = message ?: @"发生未知错误";
        self.statusTitleLabel.textColor = [UIColor systemOrangeColor];

        if ([message containsString:@"561145187"] || [message containsString:@"保活"]) {
            self.errorActionKind = 1;
            [self.statusActionBtn setTitle:@"开启后台语音保活" forState:UIControlStateNormal];
        } else if ([message containsString:@"完全访问"] || [message containsString:@"系统设置"] || [message containsString:@"权限"]) {
            self.errorActionKind = 2;
            [self.statusActionBtn setTitle:@"前往系统设置" forState:UIControlStateNormal];
        } else {
            self.errorActionKind = 0;
            [self.statusActionBtn setTitle:@"重新尝试" forState:UIControlStateNormal];
        }
    });
}

- (void)showSuccessNotice:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.transientNotice = message;
        self.idleSubtitleLabel.text = message ?: @"";
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if ([weakSelf.transientNotice isEqualToString:message]) {
                weakSelf.transientNotice = nil;
                [weakSelf refreshStateUI];
            }
        });
    });
}

#pragma mark - Actions

- (void)switchToManualTapped {
    [[TypelessVoiceManager sharedManager] dismissVoiceOverlayAnimated:YES];
}

- (void)modeTabTapped:(UIButton *)sender {
    TypelessConfig *cfg = [TypelessConfig sharedConfig];
    cfg.voiceMode = (TypelessVoiceMode)sender.tag;
    [cfg save];
    [self refreshStateUI];
}

- (void)cycleTranslateLangTapped {
    TypelessConfig *cfg = [TypelessConfig sharedConfig];
    NSArray<NSString *> *langs = [TypelessConfig supportedTargetLanguages];
    NSUInteger idx = [langs indexOfObject:cfg.targetLanguage ?: @"English"];
    NSUInteger nextIdx = (idx == NSNotFound) ? 0 : (idx + 1) % langs.count;
    cfg.targetLanguage = langs[nextIdx];
    [cfg save];
    [self refreshStateUI];
}

- (void)undoTapped {
    [[TypelessVoiceManager sharedManager] undoLastInsert];
}

- (void)openSettingsTapped {
    [[TypelessConfig sharedConfig] load];
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
    [UIView animateWithDuration:0.18 animations:^{
        self.settingsView.alpha = 1.0;
    }];
}

- (void)startRecordingTapped {
    [[TypelessVoiceManager sharedManager] startRecording];
}

- (void)cancelRecordingTapped {
    [[TypelessVoiceManager sharedManager] cancelRecordingAndReset];
}

- (void)finishRecordingTapped {
    [[TypelessVoiceManager sharedManager] finishRecordingAndProcess];
}

- (void)statusActionTapped {
    TypelessVoiceManager *mgr = [TypelessVoiceManager sharedManager];
    if (mgr.state == TypelessSessionStateError) {
        if (self.errorActionKind == 1) {
            [[TypelessHostBridge sharedBridge] openHostKeepAliveFromViewController:mgr.activeInputViewController];
            [mgr cancelRecordingAndReset];
            return;
        }
        if (self.errorActionKind == 2) {
            NSURL *settingsURL = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
            if (settingsURL) {
                UIResponder *resp = mgr.activeInputViewController;
                while (resp) {
                    if ([resp isKindOfClass:[UIApplication class]]) {
                        [(UIApplication *)resp openURL:settingsURL options:@{} completionHandler:nil];
                        break;
                    }
                    resp = [resp nextResponder];
                }
                if (!resp && mgr.activeInputViewController.extensionContext) {
                    [mgr.activeInputViewController.extensionContext openURL:settingsURL completionHandler:nil];
                }
            }
            [mgr cancelRecordingAndReset];
            return;
        }
        [mgr startRecording];
    } else {
        [mgr cancelRecordingAndReset];
    }
}

#pragma mark - Bottom Utility Key Handlers

- (void)spaceTapped {
    [[TypelessVoiceManager sharedManager] insertSpace];
}

- (void)backspaceTouchDown {
    [[TypelessVoiceManager sharedManager] deleteBackwardStep];
    [_backspaceRepeatTimer invalidate];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakSelf.backspaceKey.isHighlighted) {
            weakSelf.backspaceRepeatTimer = [NSTimer scheduledTimerWithTimeInterval:0.085 repeats:YES block:^(NSTimer * _Nonnull timer) {
                if (weakSelf.backspaceKey.isHighlighted) {
                    [[TypelessVoiceManager sharedManager] deleteBackwardStep];
                } else {
                    [timer invalidate];
                    weakSelf.backspaceRepeatTimer = nil;
                }
            }];
        }
    });
}

- (void)backspaceTouchUp {
    [_backspaceRepeatTimer invalidate];
    _backspaceRepeatTimer = nil;
}

- (void)returnTapped {
    [[TypelessVoiceManager sharedManager] insertReturn];
}

#pragma mark - TypelessSettingsViewDelegate

- (void)typelessSettingsDidSave {
    [self typelessSettingsDidClose];
    [self refreshStateUI];
}

- (void)typelessSettingsDidClose {
    if (_settingsView) {
        [UIView animateWithDuration:0.18 animations:^{
            self.settingsView.alpha = 0.0;
        } completion:^(BOOL finished) {
            [self.settingsView removeFromSuperview];
        }];
    }
}

@end
