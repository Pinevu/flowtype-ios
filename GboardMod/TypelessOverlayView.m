#import "TypelessOverlayView.h"
#import "TypelessConfig.h"
#import "TypelessVoiceManager.h"
#import "TypelessHostBridge.h"
#import <QuartzCore/QuartzCore.h>

@interface TypelessOverlayView ()

// Top bar
@property (nonatomic, strong) UIView *topBarView;
@property (nonatomic, strong) UIButton *keyboardBackBtn;
@property (nonatomic, strong) UIScrollView *modeScrollView;
@property (nonatomic, strong) UIStackView *modeStackView;
@property (nonatomic, strong) NSMutableArray<UIButton *> *modeButtons;
@property (nonatomic, strong) UIButton *keepAlivePillBtn;
@property (nonatomic, strong) UIView *keepAliveDotView;

// Dynamic context / option chip bar (Row 2)
@property (nonatomic, strong) UIScrollView *chipScrollView;
@property (nonatomic, strong) UIStackView *chipStackView;

// Main center area: Card + Mic Dock (or History Drawer)
@property (nonatomic, strong) UIView *centerStageContainer;
@property (nonatomic, strong) UIView *statusCardView;
@property (nonatomic, strong) UILabel *statusBadgeLabel;
@property (nonatomic, strong) UILabel *transcriptLabel;
@property (nonatomic, strong) UIButton *cardActionBtn;
@property (nonatomic, strong) UIButton *cardSecondaryBtn;
@property (nonatomic, strong) NSLayoutConstraint *badgeFullTrailingConstraint;
@property (nonatomic, strong) NSLayoutConstraint *badgeErrorTrailingConstraint;

// History drawer view (overlays centerStageContainer cleanly when toggled)
@property (nonatomic, strong) UIView *historyContainerView;
@property (nonatomic, strong) UIStackView *historyListStack;

// Mic dock
@property (nonatomic, strong) UIView *micDockView;
@property (nonatomic, strong) UIButton *cancelBtn;
@property (nonatomic, strong) UIButton *finishBtn;
@property (nonatomic, strong) UIButton *micOrbBtn;
@property (nonatomic, strong) UIView *micHaloView;
@property (nonatomic, strong) UIActivityIndicatorView *aiSpinner;
@property (nonatomic, strong) UILabel *timerLabel;
@property (nonatomic, strong) UILabel *micHintLabel;
@property (nonatomic, strong) UIStackView *leftWaveStack;
@property (nonatomic, strong) UIStackView *rightWaveStack;
@property (nonatomic, strong) NSMutableArray<UIView *> *waveBars;

// Bottom keycap row
@property (nonatomic, strong) UIView *bottomBarView;
@property (nonatomic, strong) UIButton *pinyinBtn;
@property (nonatomic, strong) UIButton *spaceBtn;
@property (nonatomic, strong) UIButton *backspaceBtn;
@property (nonatomic, strong) UIButton *returnBtn;

// State & Timers
@property (nonatomic, assign) BOOL hasActiveError;
@property (nonatomic, copy, nullable) NSString *currentErrorMessage;
@property (nonatomic, assign) BOOL showingHistoryDrawer;
@property (nonatomic, copy, nullable) NSString *noticeOverrideText;
@property (nonatomic, strong, nullable) NSTimer *noticeClearTimer;
@property (nonatomic, strong, nullable) NSTimer *deleteRepeatTimer;
@property (nonatomic, strong, nullable) NSTimer *bridgePollTimer;
@property (nonatomic, strong) UIImpactFeedbackGenerator *haptic;
@property (nonatomic, assign) NSUInteger noticeToken;

@end

@implementation TypelessOverlayView

+ (UIColor *)adaptiveColorLight:(UIColor *)light dark:(UIColor *)dark {
    if (@available(iOS 13.0, *)) {
        return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull trait) {
            return (trait.userInterfaceStyle == UIUserInterfaceStyleDark) ? dark : light;
        }];
    }
    return light;
}

+ (UIColor *)panelBgColor {
    return [self adaptiveColorLight:[UIColor colorWithRed:0.94 green:0.95 blue:0.97 alpha:1.0]
                               dark:[UIColor colorWithRed:0.10 green:0.11 blue:0.13 alpha:1.0]];
}

+ (UIColor *)surfaceCardColor {
    return [self adaptiveColorLight:[UIColor colorWithRed:1.00 green:1.00 blue:1.00 alpha:0.98]
                               dark:[UIColor colorWithRed:0.16 green:0.17 blue:0.20 alpha:1.0]];
}

+ (UIColor *)chipInactiveColor {
    return [self adaptiveColorLight:[UIColor colorWithRed:0.88 green:0.90 blue:0.93 alpha:1.0]
                               dark:[UIColor colorWithRed:0.22 green:0.23 blue:0.27 alpha:1.0]];
}

+ (UIColor *)keycapColor {
    return [self adaptiveColorLight:[UIColor whiteColor]
                               dark:[UIColor colorWithRed:0.26 green:0.27 blue:0.30 alpha:1.0]];
}

+ (UIColor *)primaryTextColor {
    return [self adaptiveColorLight:[UIColor colorWithRed:0.10 green:0.12 blue:0.16 alpha:1.0]
                               dark:[UIColor colorWithRed:0.95 green:0.96 blue:0.98 alpha:1.0]];
}

+ (UIColor *)secondaryTextColor {
    return [self adaptiveColorLight:[UIColor colorWithRed:0.42 green:0.45 blue:0.52 alpha:1.0]
                               dark:[UIColor colorWithRed:0.63 green:0.66 blue:0.73 alpha:1.0]];
}

+ (UIColor *)accentBlue {
    return [UIColor colorWithRed:0.10 green:0.45 blue:0.91 alpha:1.0];
}

+ (UIColor *)borderHairlineColor {
    return [self adaptiveColorLight:[UIColor colorWithWhite:0.0 alpha:0.08]
                               dark:[UIColor colorWithWhite:1.0 alpha:0.10]];
}

#pragma mark - Init & Lifecycle

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [TypelessOverlayView panelBgColor];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _modeButtons = [NSMutableArray array];
        _waveBars = [NSMutableArray array];
        _haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];

        [self buildUI];
        [self refreshStateUI];
    }
    return self;
}

- (void)willMoveToSuperview:(UIView *)newSuperview {
    [super willMoveToSuperview:newSuperview];
    [self.bridgePollTimer invalidate];
    self.bridgePollTimer = nil;
    if (newSuperview != nil) {
        self.showingHistoryDrawer = NO;
        __weak typeof(self) weakSelf = self;
        self.bridgePollTimer = [NSTimer scheduledTimerWithTimeInterval:1.8 repeats:YES block:^(NSTimer * _Nonnull timer) {
            [weakSelf updateKeepAlivePillAppearance];
        }];
        [self updateKeepAlivePillAppearance];
    }
}

- (void)dealloc {
    [self.bridgePollTimer invalidate];
    [self.noticeClearTimer invalidate];
    [self.deleteRepeatTimer invalidate];
}

#pragma mark - Button Builders

- (void)applyPadding:(UIEdgeInsets)insets toButton:(UIButton *)btn {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    btn.contentEdgeInsets = insets;
#pragma clang diagnostic pop
}

- (void)applyContinuousCornersToLayer:(CALayer *)layer {
    if (@available(iOS 13.0, *)) {
        layer.cornerCurve = kCACornerCurveContinuous;
    }
}

- (UIButton *)makePillButtonWithFontSize:(CGFloat)fontSize weight:(UIFontWeight)weight {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    btn.titleLabel.font = [UIFont systemFontOfSize:fontSize weight:weight];
    btn.titleLabel.lineBreakMode = NSLineBreakByClipping;
    btn.titleLabel.numberOfLines = 1;
    [self applyContinuousCornersToLayer:btn.layer];
    [btn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [btn setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return btn;
}

#pragma mark - UI Construction

- (void)buildUI {
    // 1. Top Navigation & Mode Row
    self.topBarView = [[UIView alloc] init];
    self.topBarView.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:self.topBarView];

    self.keyboardBackBtn = [self makePillButtonWithFontSize:12.5 weight:UIFontWeightSemibold];
    self.keyboardBackBtn.backgroundColor = [TypelessOverlayView surfaceCardColor];
    [self.keyboardBackBtn setTitleColor:[TypelessOverlayView primaryTextColor] forState:UIControlStateNormal];
    self.keyboardBackBtn.layer.cornerRadius = 15.0;
    self.keyboardBackBtn.layer.borderWidth = 0.5;
    self.keyboardBackBtn.layer.borderColor = [TypelessOverlayView borderHairlineColor].CGColor;
    [self applyPadding:UIEdgeInsetsMake(0, 10, 0, 10) toButton:self.keyboardBackBtn];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold];
        [self.keyboardBackBtn setImage:[UIImage systemImageNamed:@"keyboard.chevron.compact.down" withConfiguration:cfg] forState:UIControlStateNormal];
        self.keyboardBackBtn.tintColor = [TypelessOverlayView accentBlue];
        [self.keyboardBackBtn setTitle:@" 键盘" forState:UIControlStateNormal];
    } else {
        [self.keyboardBackBtn setTitle:@"⌨️ 键盘" forState:UIControlStateNormal];
    }
    [self.keyboardBackBtn addTarget:self action:@selector(onBackToKeyboardTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.topBarView addSubview:self.keyboardBackBtn];

    self.keepAlivePillBtn = [self makePillButtonWithFontSize:11.5 weight:UIFontWeightSemibold];
    self.keepAlivePillBtn.layer.cornerRadius = 14.0;
    [self applyPadding:UIEdgeInsetsMake(0, 18, 0, 10) toButton:self.keepAlivePillBtn];
    [self.keepAlivePillBtn addTarget:self action:@selector(onKeepAlivePillTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.topBarView addSubview:self.keepAlivePillBtn];

    self.keepAliveDotView = [[UIView alloc] init];
    self.keepAliveDotView.translatesAutoresizingMaskIntoConstraints = NO;
    self.keepAliveDotView.layer.cornerRadius = 3.5;
    self.keepAliveDotView.userInteractionEnabled = NO;
    [self.keepAlivePillBtn addSubview:self.keepAliveDotView];

    self.modeScrollView = [[UIScrollView alloc] init];
    self.modeScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.modeScrollView.showsHorizontalScrollIndicator = NO;
    self.modeScrollView.alwaysBounceHorizontal = YES;
    [self.topBarView addSubview:self.modeScrollView];

    self.modeStackView = [[UIStackView alloc] init];
    self.modeStackView.translatesAutoresizingMaskIntoConstraints = NO;
    self.modeStackView.axis = UILayoutConstraintAxisHorizontal;
    self.modeStackView.alignment = UIStackViewAlignmentCenter;
    self.modeStackView.spacing = 6.0;
    [self.modeScrollView addSubview:self.modeStackView];

    NSArray<NSNumber *> *modes = @[
        @(TypelessVoiceModeDictate),
        @(TypelessVoiceModeEdit),
        @(TypelessVoiceModeTranslate),
        @(TypelessVoiceModeHelpWrite)
    ];
    for (NSNumber *m in modes) {
        TypelessVoiceMode mode = (TypelessVoiceMode)[m integerValue];
        UIButton *pill = [self makePillButtonWithFontSize:12.5 weight:UIFontWeightSemibold];
        pill.tag = mode;
        pill.layer.cornerRadius = 15.0;
        [self applyPadding:UIEdgeInsetsMake(0, 12, 0, 12) toButton:pill];
        [pill setTitle:[TypelessConfig titleForMode:mode] forState:UIControlStateNormal];
        [pill addTarget:self action:@selector(onModePillTapped:) forControlEvents:UIControlEventTouchUpInside];
        [pill.heightAnchor constraintEqualToConstant:30.0].active = YES;
        [self.modeStackView addArrangedSubview:pill];
        [self.modeButtons addObject:pill];
    }

    // 2. Dynamic Context / Quick Action Chips (Row 2)
    self.chipScrollView = [[UIScrollView alloc] init];
    self.chipScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.chipScrollView.showsHorizontalScrollIndicator = NO;
    self.chipScrollView.alwaysBounceHorizontal = YES;
    [self addSubview:self.chipScrollView];

    self.chipStackView = [[UIStackView alloc] init];
    self.chipStackView.translatesAutoresizingMaskIntoConstraints = NO;
    self.chipStackView.axis = UILayoutConstraintAxisHorizontal;
    self.chipStackView.alignment = UIStackViewAlignmentCenter;
    self.chipStackView.spacing = 6.0;
    [self.chipScrollView addSubview:self.chipStackView];

    // 3. Center Stage Container (Card + Mic Dock + inline History overlay)
    self.centerStageContainer = [[UIView alloc] init];
    self.centerStageContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:self.centerStageContainer];

    self.statusCardView = [[UIView alloc] init];
    self.statusCardView.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusCardView.backgroundColor = [TypelessOverlayView surfaceCardColor];
    self.statusCardView.layer.cornerRadius = 14.0;
    [self applyContinuousCornersToLayer:self.statusCardView.layer];
    self.statusCardView.layer.borderWidth = 0.8;
    self.statusCardView.layer.borderColor = [TypelessOverlayView borderHairlineColor].CGColor;
    [self.centerStageContainer addSubview:self.statusCardView];

    self.statusBadgeLabel = [[UILabel alloc] init];
    self.statusBadgeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusBadgeLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightBold];
    self.statusBadgeLabel.textColor = [TypelessOverlayView accentBlue];
    [self.statusBadgeLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    [self.statusCardView addSubview:self.statusBadgeLabel];

    self.transcriptLabel = [[UILabel alloc] init];
    self.transcriptLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.transcriptLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
    self.transcriptLabel.textColor = [TypelessOverlayView primaryTextColor];
    self.transcriptLabel.numberOfLines = 0;
    self.transcriptLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.transcriptLabel.adjustsFontSizeToFitWidth = YES;
    self.transcriptLabel.minimumScaleFactor = 0.84;
    [self.statusCardView addSubview:self.transcriptLabel];

    self.cardActionBtn = [self makePillButtonWithFontSize:11.5 weight:UIFontWeightSemibold];
    self.cardActionBtn.backgroundColor = [TypelessOverlayView accentBlue];
    [self.cardActionBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.cardActionBtn.layer.cornerRadius = 12.0;
    self.cardActionBtn.hidden = YES;
    [self applyPadding:UIEdgeInsetsMake(0, 10, 0, 10) toButton:self.cardActionBtn];
    [self.cardActionBtn addTarget:self action:@selector(onCardPrimaryActionTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.statusCardView addSubview:self.cardActionBtn];

    self.cardSecondaryBtn = [self makePillButtonWithFontSize:11.5 weight:UIFontWeightSemibold];
    self.cardSecondaryBtn.backgroundColor = [TypelessOverlayView chipInactiveColor];
    [self.cardSecondaryBtn setTitleColor:[TypelessOverlayView primaryTextColor] forState:UIControlStateNormal];
    self.cardSecondaryBtn.layer.cornerRadius = 12.0;
    self.cardSecondaryBtn.hidden = YES;
    [self applyPadding:UIEdgeInsetsMake(0, 10, 0, 10) toButton:self.cardSecondaryBtn];
    [self.cardSecondaryBtn addTarget:self action:@selector(onCardSecondaryActionTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.statusCardView addSubview:self.cardSecondaryBtn];

    // Inline History Drawer (hidden until toggled via "最近" chip)
    self.historyContainerView = [[UIView alloc] init];
    self.historyContainerView.translatesAutoresizingMaskIntoConstraints = NO;
    self.historyContainerView.backgroundColor = [TypelessOverlayView surfaceCardColor];
    self.historyContainerView.layer.cornerRadius = 14.0;
    [self applyContinuousCornersToLayer:self.historyContainerView.layer];
    self.historyContainerView.layer.borderWidth = 0.8;
    self.historyContainerView.layer.borderColor = [TypelessOverlayView borderHairlineColor].CGColor;
    self.historyContainerView.hidden = YES;
    [self.centerStageContainer addSubview:self.historyContainerView];

    UIView *histHeader = [[UIView alloc] init];
    histHeader.translatesAutoresizingMaskIntoConstraints = NO;
    [self.historyContainerView addSubview:histHeader];

    UILabel *histTitle = [[UILabel alloc] init];
    histTitle.translatesAutoresizingMaskIntoConstraints = NO;
    histTitle.text = @"最近上屏记录（点选即可快速插入）";
    histTitle.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightSemibold];
    histTitle.textColor = [TypelessOverlayView secondaryTextColor];
    [histHeader addSubview:histTitle];

    UIButton *histClose = [self makePillButtonWithFontSize:11.5 weight:UIFontWeightSemibold];
    [histClose setTitle:@"完成" forState:UIControlStateNormal];
    [histClose setTitleColor:[TypelessOverlayView accentBlue] forState:UIControlStateNormal];
    histClose.backgroundColor = [[TypelessOverlayView accentBlue] colorWithAlphaComponent:0.12];
    histClose.layer.cornerRadius = 10.0;
    [self applyPadding:UIEdgeInsetsMake(2, 9, 2, 9) toButton:histClose];
    [histClose addTarget:self action:@selector(onToggleHistoryTapped) forControlEvents:UIControlEventTouchUpInside];
    [histHeader addSubview:histClose];

    UIScrollView *histScroll = [[UIScrollView alloc] init];
    histScroll.translatesAutoresizingMaskIntoConstraints = NO;
    histScroll.showsVerticalScrollIndicator = YES;
    [self.historyContainerView addSubview:histScroll];

    self.historyListStack = [[UIStackView alloc] init];
    self.historyListStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.historyListStack.axis = UILayoutConstraintAxisVertical;
    self.historyListStack.spacing = 6.0;
    [histScroll addSubview:self.historyListStack];

    // Mic Control Dock
    self.micDockView = [[UIView alloc] init];
    self.micDockView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.centerStageContainer addSubview:self.micDockView];

    self.micHaloView = [[UIView alloc] init];
    self.micHaloView.translatesAutoresizingMaskIntoConstraints = NO;
    self.micHaloView.layer.cornerRadius = 32.0;
    self.micHaloView.backgroundColor = [[TypelessOverlayView accentBlue] colorWithAlphaComponent:0.18];
    self.micHaloView.alpha = 0.0;
    self.micHaloView.userInteractionEnabled = NO;
    [self.micDockView addSubview:self.micHaloView];

    self.micOrbBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.micOrbBtn.translatesAutoresizingMaskIntoConstraints = NO;
    self.micOrbBtn.layer.cornerRadius = 27.0;
    self.micOrbBtn.backgroundColor = [TypelessOverlayView accentBlue];
    self.micOrbBtn.layer.shadowColor = [TypelessOverlayView accentBlue].CGColor;
    self.micOrbBtn.layer.shadowOpacity = 0.28;
    self.micOrbBtn.layer.shadowRadius = 8.0;
    self.micOrbBtn.layer.shadowOffset = CGSizeMake(0, 3);
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *sym = [UIImageSymbolConfiguration configurationWithPointSize:21 weight:UIImageSymbolWeightSemibold];
        [self.micOrbBtn setImage:[UIImage systemImageNamed:@"mic.fill" withConfiguration:sym] forState:UIControlStateNormal];
        self.micOrbBtn.tintColor = [UIColor whiteColor];
    } else {
        [self.micOrbBtn setTitle:@"🎙" forState:UIControlStateNormal];
    }
    [self.micOrbBtn addTarget:self action:@selector(onMicOrbTapped) forControlEvents:UIControlEventTouchUpInside];
    UILongPressGestureRecognizer *holdToTalk = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onMicOrbLongPressed:)];
    holdToTalk.minimumPressDuration = 0.28;
    [self.micOrbBtn addGestureRecognizer:holdToTalk];
    [self.micDockView addSubview:self.micOrbBtn];

    if (@available(iOS 13.0, *)) {
        self.aiSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    } else {
        self.aiSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    }
    self.aiSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.aiSpinner.color = [UIColor whiteColor];
    self.aiSpinner.hidesWhenStopped = YES;
    self.aiSpinner.userInteractionEnabled = NO;
    [self.micOrbBtn addSubview:self.aiSpinner];

    // Symmetrical 10-bar Equalizer Waveform flanking Mic Orb
    self.leftWaveStack = [[UIStackView alloc] init];
    self.leftWaveStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.leftWaveStack.axis = UILayoutConstraintAxisHorizontal;
    self.leftWaveStack.alignment = UIStackViewAlignmentCenter;
    self.leftWaveStack.spacing = 4.0;
    [self.micDockView addSubview:self.leftWaveStack];

    self.rightWaveStack = [[UIStackView alloc] init];
    self.rightWaveStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.rightWaveStack.axis = UILayoutConstraintAxisHorizontal;
    self.rightWaveStack.alignment = UIStackViewAlignmentCenter;
    self.rightWaveStack.spacing = 4.0;
    [self.micDockView addSubview:self.rightWaveStack];

    for (NSInteger i = 0; i < 10; i++) {
        UIView *bar = [[UIView alloc] init];
        bar.translatesAutoresizingMaskIntoConstraints = NO;
        bar.layer.cornerRadius = 1.8;
        bar.backgroundColor = [TypelessOverlayView accentBlue];
        bar.alpha = 0.28;
        [bar.widthAnchor constraintEqualToConstant:3.6].active = YES;
        [bar.heightAnchor constraintEqualToConstant:24.0].active = YES;
        bar.transform = CGAffineTransformMakeScale(1.0, 0.25);
        [self.waveBars addObject:bar];
        if (i < 5) {
            [self.leftWaveStack addArrangedSubview:bar];
        } else {
            [self.rightWaveStack addArrangedSubview:bar];
        }
    }

    self.cancelBtn = [self makePillButtonWithFontSize:12.5 weight:UIFontWeightSemibold];
    self.cancelBtn.backgroundColor = [TypelessOverlayView chipInactiveColor];
    [self.cancelBtn setTitle:@"✕ 取消" forState:UIControlStateNormal];
    [self.cancelBtn setTitleColor:[TypelessOverlayView primaryTextColor] forState:UIControlStateNormal];
    self.cancelBtn.layer.cornerRadius = 16.0;
    self.cancelBtn.hidden = YES;
    [self applyPadding:UIEdgeInsetsMake(0, 12, 0, 12) toButton:self.cancelBtn];
    [self.cancelBtn addTarget:self action:@selector(onCancelTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.micDockView addSubview:self.cancelBtn];

    self.finishBtn = [self makePillButtonWithFontSize:12.5 weight:UIFontWeightSemibold];
    self.finishBtn.backgroundColor = [UIColor colorWithRed:0.15 green:0.68 blue:0.38 alpha:1.0];
    [self.finishBtn setTitle:@"✓ 完成" forState:UIControlStateNormal];
    [self.finishBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.finishBtn.layer.cornerRadius = 16.0;
    self.finishBtn.hidden = YES;
    [self applyPadding:UIEdgeInsetsMake(0, 12, 0, 12) toButton:self.finishBtn];
    [self.finishBtn addTarget:self action:@selector(onFinishTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.micDockView addSubview:self.finishBtn];

    self.timerLabel = [[UILabel alloc] init];
    self.timerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.timerLabel.font = [UIFont monospacedDigitSystemFontOfSize:11.5 weight:UIFontWeightSemibold];
    self.timerLabel.textColor = [TypelessOverlayView secondaryTextColor];
    self.timerLabel.text = @"00:00";
    self.timerLabel.hidden = YES;
    [self.micDockView addSubview:self.timerLabel];

    self.micHintLabel = [[UILabel alloc] init];
    self.micHintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.micHintLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightMedium];
    self.micHintLabel.textColor = [TypelessOverlayView secondaryTextColor];
    self.micHintLabel.textAlignment = NSTextAlignmentRight;
    self.micHintLabel.adjustsFontSizeToFitWidth = YES;
    self.micHintLabel.minimumScaleFactor = 0.8;
    [self.micDockView addSubview:self.micHintLabel];

    // 4. Bottom Keycap Bar
    self.bottomBarView = [[UIView alloc] init];
    self.bottomBarView.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:self.bottomBarView];

    self.pinyinBtn = [self makeKeycapButton:@"键盘" bgColor:[TypelessOverlayView chipInactiveColor] textColor:[TypelessOverlayView primaryTextColor]];
    [self.pinyinBtn addTarget:self action:@selector(onBackToKeyboardTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.bottomBarView addSubview:self.pinyinBtn];

    self.spaceBtn = [self makeKeycapButton:@"空格" bgColor:[TypelessOverlayView keycapColor] textColor:[TypelessOverlayView primaryTextColor]];
    [self.spaceBtn addTarget:self action:@selector(onSpaceTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.bottomBarView addSubview:self.spaceBtn];

    self.backspaceBtn = [self makeKeycapButton:@"⌫" bgColor:[TypelessOverlayView chipInactiveColor] textColor:[TypelessOverlayView primaryTextColor]];
    self.backspaceBtn.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightRegular];
    [self.backspaceBtn addTarget:self action:@selector(onBackspaceTapped) forControlEvents:UIControlEventTouchUpInside];
    UILongPressGestureRecognizer *delHold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onBackspaceLongPressed:)];
    delHold.minimumPressDuration = 0.32;
    [self.backspaceBtn addGestureRecognizer:delHold];
    [self.bottomBarView addSubview:self.backspaceBtn];

    self.returnBtn = [self makeKeycapButton:@"换行" bgColor:[TypelessOverlayView accentBlue] textColor:[UIColor whiteColor]];
    [self.returnBtn addTarget:self action:@selector(onReturnTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.bottomBarView addSubview:self.returnBtn];

    // Auto Layout Constraints
    self.badgeFullTrailingConstraint = [self.statusBadgeLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.statusCardView.trailingAnchor constant:-11.0];
    self.badgeErrorTrailingConstraint = [self.statusBadgeLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.cardSecondaryBtn.leadingAnchor constant:-6.0];

    [NSLayoutConstraint activateConstraints:@[
        // Row 1: Top bar
        [self.topBarView.topAnchor constraintEqualToAnchor:self.topAnchor constant:6.0],
        [self.topBarView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10.0],
        [self.topBarView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10.0],
        [self.topBarView.heightAnchor constraintEqualToConstant:34.0],

        [self.keyboardBackBtn.leadingAnchor constraintEqualToAnchor:self.topBarView.leadingAnchor],
        [self.keyboardBackBtn.centerYAnchor constraintEqualToAnchor:self.topBarView.centerYAnchor],
        [self.keyboardBackBtn.heightAnchor constraintEqualToConstant:30.0],

        [self.keepAlivePillBtn.trailingAnchor constraintEqualToAnchor:self.topBarView.trailingAnchor],
        [self.keepAlivePillBtn.centerYAnchor constraintEqualToAnchor:self.topBarView.centerYAnchor],
        [self.keepAlivePillBtn.heightAnchor constraintEqualToConstant:28.0],

        [self.keepAliveDotView.leadingAnchor constraintEqualToAnchor:self.keepAlivePillBtn.leadingAnchor constant:8.0],
        [self.keepAliveDotView.centerYAnchor constraintEqualToAnchor:self.keepAlivePillBtn.centerYAnchor],
        [self.keepAliveDotView.widthAnchor constraintEqualToConstant:7.0],
        [self.keepAliveDotView.heightAnchor constraintEqualToConstant:7.0],

        [self.modeScrollView.leadingAnchor constraintEqualToAnchor:self.keyboardBackBtn.trailingAnchor constant:6.0],
        [self.modeScrollView.trailingAnchor constraintEqualToAnchor:self.keepAlivePillBtn.leadingAnchor constant:-6.0],
        [self.modeScrollView.topAnchor constraintEqualToAnchor:self.topBarView.topAnchor],
        [self.modeScrollView.bottomAnchor constraintEqualToAnchor:self.topBarView.bottomAnchor],

        [self.modeStackView.leadingAnchor constraintEqualToAnchor:self.modeScrollView.contentLayoutGuide.leadingAnchor],
        [self.modeStackView.trailingAnchor constraintEqualToAnchor:self.modeScrollView.contentLayoutGuide.trailingAnchor],
        [self.modeStackView.topAnchor constraintEqualToAnchor:self.modeScrollView.contentLayoutGuide.topAnchor],
        [self.modeStackView.bottomAnchor constraintEqualToAnchor:self.modeScrollView.contentLayoutGuide.bottomAnchor],
        [self.modeStackView.heightAnchor constraintEqualToAnchor:self.modeScrollView.frameLayoutGuide.heightAnchor],

        // Row 2: Context / Quick-action Chips
        [self.chipScrollView.topAnchor constraintEqualToAnchor:self.topBarView.bottomAnchor constant:5.0],
        [self.chipScrollView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10.0],
        [self.chipScrollView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10.0],
        [self.chipScrollView.heightAnchor constraintEqualToConstant:28.0],

        [self.chipStackView.leadingAnchor constraintEqualToAnchor:self.chipScrollView.contentLayoutGuide.leadingAnchor],
        [self.chipStackView.trailingAnchor constraintEqualToAnchor:self.chipScrollView.contentLayoutGuide.trailingAnchor],
        [self.chipStackView.topAnchor constraintEqualToAnchor:self.chipScrollView.contentLayoutGuide.topAnchor],
        [self.chipStackView.bottomAnchor constraintEqualToAnchor:self.chipScrollView.contentLayoutGuide.bottomAnchor],
        [self.chipStackView.heightAnchor constraintEqualToAnchor:self.chipScrollView.frameLayoutGuide.heightAnchor],

        // Row 4: Bottom Keycap Bar
        [self.bottomBarView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8.0],
        [self.bottomBarView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8.0],
        [self.bottomBarView.bottomAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.bottomAnchor constant:-5.0],
        [self.bottomBarView.heightAnchor constraintEqualToConstant:38.0],

        [self.pinyinBtn.leadingAnchor constraintEqualToAnchor:self.bottomBarView.leadingAnchor],
        [self.pinyinBtn.topAnchor constraintEqualToAnchor:self.bottomBarView.topAnchor],
        [self.pinyinBtn.bottomAnchor constraintEqualToAnchor:self.bottomBarView.bottomAnchor],
        [self.pinyinBtn.widthAnchor constraintEqualToConstant:62.0],

        [self.returnBtn.trailingAnchor constraintEqualToAnchor:self.bottomBarView.trailingAnchor],
        [self.returnBtn.topAnchor constraintEqualToAnchor:self.bottomBarView.topAnchor],
        [self.returnBtn.bottomAnchor constraintEqualToAnchor:self.bottomBarView.bottomAnchor],
        [self.returnBtn.widthAnchor constraintEqualToConstant:72.0],

        [self.backspaceBtn.trailingAnchor constraintEqualToAnchor:self.returnBtn.leadingAnchor constant:-6.0],
        [self.backspaceBtn.topAnchor constraintEqualToAnchor:self.bottomBarView.topAnchor],
        [self.backspaceBtn.bottomAnchor constraintEqualToAnchor:self.bottomBarView.bottomAnchor],
        [self.backspaceBtn.widthAnchor constraintEqualToConstant:58.0],

        [self.spaceBtn.leadingAnchor constraintEqualToAnchor:self.pinyinBtn.trailingAnchor constant:6.0],
        [self.spaceBtn.trailingAnchor constraintEqualToAnchor:self.backspaceBtn.leadingAnchor constant:-6.0],
        [self.spaceBtn.topAnchor constraintEqualToAnchor:self.bottomBarView.topAnchor],
        [self.spaceBtn.bottomAnchor constraintEqualToAnchor:self.bottomBarView.bottomAnchor],

        // Row 3: Center Stage Container
        [self.centerStageContainer.topAnchor constraintEqualToAnchor:self.chipScrollView.bottomAnchor constant:5.0],
        [self.centerStageContainer.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10.0],
        [self.centerStageContainer.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10.0],
        [self.centerStageContainer.bottomAnchor constraintEqualToAnchor:self.bottomBarView.topAnchor constant:-5.0],

        // Mic Dock pinned to bottom of Center Stage
        [self.micDockView.leadingAnchor constraintEqualToAnchor:self.centerStageContainer.leadingAnchor],
        [self.micDockView.trailingAnchor constraintEqualToAnchor:self.centerStageContainer.trailingAnchor],
        [self.micDockView.bottomAnchor constraintEqualToAnchor:self.centerStageContainer.bottomAnchor],
        [self.micDockView.heightAnchor constraintEqualToConstant:60.0],

        [self.micOrbBtn.centerXAnchor constraintEqualToAnchor:self.micDockView.centerXAnchor],
        [self.micOrbBtn.centerYAnchor constraintEqualToAnchor:self.micDockView.centerYAnchor],
        [self.micOrbBtn.widthAnchor constraintEqualToConstant:54.0],
        [self.micOrbBtn.heightAnchor constraintEqualToConstant:54.0],

        [self.micHaloView.centerXAnchor constraintEqualToAnchor:self.micOrbBtn.centerXAnchor],
        [self.micHaloView.centerYAnchor constraintEqualToAnchor:self.micOrbBtn.centerYAnchor],
        [self.micHaloView.widthAnchor constraintEqualToConstant:64.0],
        [self.micHaloView.heightAnchor constraintEqualToConstant:64.0],

        [self.aiSpinner.centerXAnchor constraintEqualToAnchor:self.micOrbBtn.centerXAnchor],
        [self.aiSpinner.centerYAnchor constraintEqualToAnchor:self.micOrbBtn.centerYAnchor],

        [self.leftWaveStack.trailingAnchor constraintEqualToAnchor:self.micOrbBtn.leadingAnchor constant:-12.0],
        [self.leftWaveStack.centerYAnchor constraintEqualToAnchor:self.micOrbBtn.centerYAnchor],

        [self.rightWaveStack.leadingAnchor constraintEqualToAnchor:self.micOrbBtn.trailingAnchor constant:12.0],
        [self.rightWaveStack.centerYAnchor constraintEqualToAnchor:self.micOrbBtn.centerYAnchor],

        [self.cancelBtn.leadingAnchor constraintEqualToAnchor:self.micDockView.leadingAnchor],
        [self.cancelBtn.centerYAnchor constraintEqualToAnchor:self.micOrbBtn.centerYAnchor],
        [self.cancelBtn.heightAnchor constraintEqualToConstant:32.0],

        [self.timerLabel.trailingAnchor constraintEqualToAnchor:self.leftWaveStack.leadingAnchor constant:-8.0],
        [self.timerLabel.centerYAnchor constraintEqualToAnchor:self.micOrbBtn.centerYAnchor],

        [self.finishBtn.trailingAnchor constraintEqualToAnchor:self.micDockView.trailingAnchor],
        [self.finishBtn.centerYAnchor constraintEqualToAnchor:self.micOrbBtn.centerYAnchor],
        [self.finishBtn.heightAnchor constraintEqualToConstant:32.0],

        [self.micHintLabel.trailingAnchor constraintEqualToAnchor:self.micDockView.trailingAnchor],
        [self.micHintLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.rightWaveStack.trailingAnchor constant:6.0],
        [self.micHintLabel.centerYAnchor constraintEqualToAnchor:self.micOrbBtn.centerYAnchor],

        // Status Card fills space above Mic Dock cleanly
        [self.statusCardView.topAnchor constraintEqualToAnchor:self.centerStageContainer.topAnchor],
        [self.statusCardView.leadingAnchor constraintEqualToAnchor:self.centerStageContainer.leadingAnchor],
        [self.statusCardView.trailingAnchor constraintEqualToAnchor:self.centerStageContainer.trailingAnchor],
        [self.statusCardView.bottomAnchor constraintEqualToAnchor:self.micDockView.topAnchor constant:-5.0],

        [self.statusBadgeLabel.topAnchor constraintEqualToAnchor:self.statusCardView.topAnchor constant:7.0],
        [self.statusBadgeLabel.leadingAnchor constraintEqualToAnchor:self.statusCardView.leadingAnchor constant:11.0],
        self.badgeFullTrailingConstraint,

        [self.cardActionBtn.topAnchor constraintEqualToAnchor:self.statusCardView.topAnchor constant:6.0],
        [self.cardActionBtn.trailingAnchor constraintEqualToAnchor:self.statusCardView.trailingAnchor constant:-9.0],
        [self.cardActionBtn.heightAnchor constraintEqualToConstant:24.0],

        [self.cardSecondaryBtn.centerYAnchor constraintEqualToAnchor:self.cardActionBtn.centerYAnchor],
        [self.cardSecondaryBtn.trailingAnchor constraintEqualToAnchor:self.cardActionBtn.leadingAnchor constant:-6.0],
        [self.cardSecondaryBtn.heightAnchor constraintEqualToConstant:24.0],

        [self.transcriptLabel.topAnchor constraintEqualToAnchor:self.statusBadgeLabel.bottomAnchor constant:3.0],
        [self.transcriptLabel.leadingAnchor constraintEqualToAnchor:self.statusCardView.leadingAnchor constant:11.0],
        [self.transcriptLabel.trailingAnchor constraintEqualToAnchor:self.statusCardView.trailingAnchor constant:-11.0],
        [self.transcriptLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.statusCardView.bottomAnchor constant:-6.0],

        // Inline History Container overlays full centerStageContainer when active
        [self.historyContainerView.topAnchor constraintEqualToAnchor:self.centerStageContainer.topAnchor],
        [self.historyContainerView.leadingAnchor constraintEqualToAnchor:self.centerStageContainer.leadingAnchor],
        [self.historyContainerView.trailingAnchor constraintEqualToAnchor:self.centerStageContainer.trailingAnchor],
        [self.historyContainerView.bottomAnchor constraintEqualToAnchor:self.centerStageContainer.bottomAnchor],

        [histHeader.topAnchor constraintEqualToAnchor:self.historyContainerView.topAnchor constant:8.0],
        [histHeader.leadingAnchor constraintEqualToAnchor:self.historyContainerView.leadingAnchor constant:10.0],
        [histHeader.trailingAnchor constraintEqualToAnchor:self.historyContainerView.trailingAnchor constant:-10.0],
        [histHeader.heightAnchor constraintEqualToConstant:24.0],

        [histTitle.leadingAnchor constraintEqualToAnchor:histHeader.leadingAnchor],
        [histTitle.centerYAnchor constraintEqualToAnchor:histHeader.centerYAnchor],
        [histClose.trailingAnchor constraintEqualToAnchor:histHeader.trailingAnchor],
        [histClose.centerYAnchor constraintEqualToAnchor:histHeader.centerYAnchor],

        [histScroll.topAnchor constraintEqualToAnchor:histHeader.bottomAnchor constant:6.0],
        [histScroll.leadingAnchor constraintEqualToAnchor:self.historyContainerView.leadingAnchor constant:10.0],
        [histScroll.trailingAnchor constraintEqualToAnchor:self.historyContainerView.trailingAnchor constant:-10.0],
        [histScroll.bottomAnchor constraintEqualToAnchor:self.historyContainerView.bottomAnchor constant:-8.0],

        [self.historyListStack.topAnchor constraintEqualToAnchor:histScroll.contentLayoutGuide.topAnchor],
        [self.historyListStack.leadingAnchor constraintEqualToAnchor:histScroll.contentLayoutGuide.leadingAnchor],
        [self.historyListStack.trailingAnchor constraintEqualToAnchor:histScroll.contentLayoutGuide.trailingAnchor],
        [self.historyListStack.bottomAnchor constraintEqualToAnchor:histScroll.contentLayoutGuide.bottomAnchor],
        [self.historyListStack.widthAnchor constraintEqualToAnchor:histScroll.frameLayoutGuide.widthAnchor]
    ]];
}

- (UIButton *)makeKeycapButton:(NSString *)title bgColor:(UIColor *)bg textColor:(UIColor *)tc {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    btn.backgroundColor = bg;
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:tc forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
    btn.layer.cornerRadius = 8.0;
    [self applyContinuousCornersToLayer:btn.layer];
    btn.layer.shadowColor = [UIColor blackColor].CGColor;
    btn.layer.shadowOpacity = 0.14;
    btn.layer.shadowOffset = CGSizeMake(0, 1);
    btn.layer.shadowRadius = 0.6;
    return btn;
}

#pragma mark - State Refresh

- (void)refreshStateUI {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshStateUI];
        });
        return;
    }

    TypelessVoiceManager *mgr = [TypelessVoiceManager sharedManager];
    TypelessConfig *cfg = [TypelessConfig sharedConfig];
    [cfg load];

    if (mgr.state != TypelessSessionStateError) {
        self.hasActiveError = NO;
        self.currentErrorMessage = nil;
    }

    // Return key & keep-alive pill
    [self.returnBtn setTitle:[mgr currentReturnKeyTitle] forState:UIControlStateNormal];
    [self updateKeepAlivePillAppearance];

    // Mode pill highlight
    for (UIButton *pill in self.modeButtons) {
        BOOL active = (pill.tag == cfg.voiceMode);
        if (active) {
            pill.backgroundColor = [TypelessOverlayView accentBlue];
            [pill setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        } else {
            pill.backgroundColor = [TypelessOverlayView chipInactiveColor];
            [pill setTitleColor:[TypelessOverlayView primaryTextColor] forState:UIControlStateNormal];
        }
    }

    // Dynamic Row 2 Chips
    [self rebuildContextChipStripWithConfig:cfg manager:mgr];

    // Inline history toggle visibility
    self.historyContainerView.hidden = !self.showingHistoryDrawer;
    if (self.showingHistoryDrawer) {
        [self rebuildHistoryDrawerWithConfig:cfg];
    }

    [self applyVisualStateForManager:mgr config:cfg];
}

- (void)updateKeepAlivePillAppearance {
    BOOL alive = [[TypelessHostBridge sharedBridge] isHostBridgeAlive];
    if (alive) {
        self.keepAliveDotView.backgroundColor = [UIColor colorWithRed:0.16 green:0.78 blue:0.42 alpha:1.0];
        self.keepAlivePillBtn.backgroundColor = [[UIColor colorWithRed:0.16 green:0.78 blue:0.42 alpha:1.0] colorWithAlphaComponent:0.15];
        [self.keepAlivePillBtn setTitle:@"免切" forState:UIControlStateNormal];
        [self.keepAlivePillBtn setTitleColor:[UIColor colorWithRed:0.12 green:0.65 blue:0.35 alpha:1.0] forState:UIControlStateNormal];
    } else {
        self.keepAliveDotView.backgroundColor = [UIColor colorWithRed:0.96 green:0.55 blue:0.12 alpha:1.0];
        self.keepAlivePillBtn.backgroundColor = [[UIColor colorWithRed:0.96 green:0.55 blue:0.12 alpha:1.0] colorWithAlphaComponent:0.15];
        [self.keepAlivePillBtn setTitle:@"保活" forState:UIControlStateNormal];
        [self.keepAlivePillBtn setTitleColor:[UIColor colorWithRed:0.90 green:0.46 blue:0.08 alpha:1.0] forState:UIControlStateNormal];
    }
}

- (void)rebuildContextChipStripWithConfig:(TypelessConfig *)cfg manager:(TypelessVoiceManager *)mgr {
    for (UIView *v in [self.chipStackView.arrangedSubviews copy]) {
        [self.chipStackView removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    void (^addChip)(NSString *, BOOL, BOOL, SEL, NSInteger) = ^(NSString *title, BOOL selected, BOOL accent, SEL action, NSInteger tag) {
        UIButton *chip = [self makePillButtonWithFontSize:11.5 weight:selected ? UIFontWeightSemibold : UIFontWeightMedium];
        chip.tag = tag;
        chip.layer.cornerRadius = 13.0;
        [self applyPadding:UIEdgeInsetsMake(0, 10, 0, 10) toButton:chip];
        [chip setTitle:title forState:UIControlStateNormal];
        [chip.heightAnchor constraintEqualToConstant:26.0].active = YES;

        if (accent) {
            chip.backgroundColor = [[TypelessOverlayView accentBlue] colorWithAlphaComponent:0.14];
            [chip setTitleColor:[TypelessOverlayView accentBlue] forState:UIControlStateNormal];
        } else if (selected) {
            chip.backgroundColor = [TypelessOverlayView primaryTextColor];
            [chip setTitleColor:[TypelessOverlayView surfaceCardColor] forState:UIControlStateNormal];
        } else {
            chip.backgroundColor = [TypelessOverlayView surfaceCardColor];
            [chip setTitleColor:[TypelessOverlayView secondaryTextColor] forState:UIControlStateNormal];
            chip.layer.borderWidth = 0.5;
            chip.layer.borderColor = [TypelessOverlayView borderHairlineColor].CGColor;
        }
        if (action) {
            [chip addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
        }
        [self.chipStackView addArrangedSubview:chip];
    };

    // Contextual utility chips first when idle & actionable
    if (mgr.state == TypelessSessionStateIdle) {
        if (mgr.canUndoLastInsert) {
            addChip(@"↺ 撤销", NO, YES, @selector(onUndoChipTapped), 0);
        }
        BOOL canReprocess = (cfg.lastRawTranscript.length > 0 || mgr.liveRecognizedPreview.length > 0) &&
                            [cfg hasValidLlmConfig] && cfg.llmModel.length > 0;
        if (canReprocess) {
            addChip(@"✨ 重写上句", NO, YES, @selector(onReprocessChipTapped), 0);
        }
        if (cfg.lastProcessedResult.length > 0 || mgr.liveRecognizedPreview.length > 0) {
            addChip(@"📋 复制", NO, NO, @selector(onCopyChipTapped), 0);
        }
        if (cfg.recentHistory.count > 0) {
            NSString *histTitle = self.showingHistoryDrawer ? @"✕ 关闭历史" : @"🕘 历史";
            addChip(histTitle, self.showingHistoryDrawer, NO, @selector(onToggleHistoryTapped), 0);
        }
    }

    // Mode-specific interactive chips
    if (cfg.voiceMode == TypelessVoiceModeTranslate) {
        for (NSString *lang in [TypelessConfig supportedTargetLanguages]) {
            BOOL selected = [lang isEqualToString:cfg.targetLanguage];
            NSInteger idx = [[TypelessConfig supportedTargetLanguages] indexOfObject:lang];
            addChip(lang, selected, NO, @selector(onLanguageChipTapped:), idx);
        }
    } else {
        if (cfg.voiceMode == TypelessVoiceModeEdit) {
            NSString *sel = [mgr currentSelectedTextPreview];
            NSString *selBadge = sel.length > 0
                ? [NSString stringWithFormat:@"📎 已选「%@」", sel.length > 10 ? [[sel substringToIndex:10] stringByAppendingString:@"…"] : sel]
                : @"📎 请先选中待改文本";
            addChip(selBadge, sel.length > 0, NO, nil, 0);
        }
        NSArray<NSNumber *> *styles = @[
            @(TypelessPolishStyleSmart),
            @(TypelessPolishStyleConcise),
            @(TypelessPolishStyleFormal),
            @(TypelessPolishStyleLight)
        ];
        for (NSNumber *s in styles) {
            TypelessPolishStyle st = (TypelessPolishStyle)[s integerValue];
            addChip([TypelessConfig titleForPolishStyle:st], cfg.polishStyle == st, NO, @selector(onStyleChipTapped:), st);
        }
    }
}

- (void)rebuildHistoryDrawerWithConfig:(TypelessConfig *)cfg {
    for (UIView *v in [self.historyListStack.arrangedSubviews copy]) {
        [self.historyListStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    NSArray<NSString *> *items = cfg.recentHistory;
    if (items.count == 0) {
        UILabel *empty = [[UILabel alloc] init];
        empty.text = @"暂无语音上屏历史记录";
        empty.font = [UIFont systemFontOfSize:12.5];
        empty.textColor = [TypelessOverlayView secondaryTextColor];
        empty.textAlignment = NSTextAlignmentCenter;
        [self.historyListStack addArrangedSubview:empty];
        return;
    }

    for (NSUInteger i = 0; i < items.count; i++) {
        NSString *text = items[i];
        UIButton *row = [UIButton buttonWithType:UIButtonTypeCustom];
        row.tag = (NSInteger)i;
        row.backgroundColor = [TypelessOverlayView chipInactiveColor];
        row.layer.cornerRadius = 10.0;
        row.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        [self applyPadding:UIEdgeInsetsMake(7, 10, 7, 10) toButton:row];
        NSString *preview = [NSString stringWithFormat:@"%lu. %@", (unsigned long)(i + 1), text];
        [row setTitle:preview forState:UIControlStateNormal];
        [row setTitleColor:[TypelessOverlayView primaryTextColor] forState:UIControlStateNormal];
        row.titleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
        row.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [row.heightAnchor constraintGreaterThanOrEqualToConstant:32.0].active = YES;
        [row addTarget:self action:@selector(onHistoryRowTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.historyListStack addArrangedSubview:row];
    }
}

- (void)applyVisualStateForManager:(TypelessVoiceManager *)mgr config:(TypelessConfig *)cfg {
    TypelessSessionState st = mgr.state;
    BOOL isRec = (st == TypelessSessionStateRecording);
    BOOL isBusy = (st == TypelessSessionStateTranscribing || st == TypelessSessionStateProcessingAI);
    BOOL isErr = (st == TypelessSessionStateError && self.hasActiveError && self.currentErrorMessage.length > 0);

    // Card inline action buttons default hidden unless error or actionable state
    self.cardActionBtn.hidden = !isErr;
    self.cardSecondaryBtn.hidden = !isErr;
    self.badgeFullTrailingConstraint.active = !isErr;
    self.badgeErrorTrailingConstraint.active = isErr;
    self.transcriptLabel.lineBreakMode = isRec ? NSLineBreakByTruncatingHead : NSLineBreakByTruncatingTail;

    if (isErr) {
        self.statusCardView.layer.borderColor = [UIColor colorWithRed:0.90 green:0.26 blue:0.24 alpha:0.65].CGColor;
        self.statusBadgeLabel.text = @"需要注意";
        self.statusBadgeLabel.textColor = [UIColor colorWithRed:0.86 green:0.22 blue:0.20 alpha:1.0];
        self.transcriptLabel.text = self.currentErrorMessage;
        self.transcriptLabel.textColor = [TypelessOverlayView primaryTextColor];

        BOOL needKeepAliveOrSettings =
            [self.currentErrorMessage containsString:@"保活"] ||
            [self.currentErrorMessage containsString:@"561145187"] ||
            [self.currentErrorMessage containsString:@"主 App"] ||
            [self.currentErrorMessage containsString:@"权限"] ||
            [self.currentErrorMessage containsString:@"访问"];

        if (needKeepAliveOrSettings) {
            [self.cardActionBtn setTitle:@"开启保活" forState:UIControlStateNormal];
            self.cardActionBtn.hidden = NO;
            [self.cardSecondaryBtn setTitle:@"重试" forState:UIControlStateNormal];
            self.cardSecondaryBtn.hidden = NO;
        } else {
            [self.cardActionBtn setTitle:@"重试录音" forState:UIControlStateNormal];
            self.cardActionBtn.hidden = NO;
            [self.cardSecondaryBtn setTitle:@"打开主App" forState:UIControlStateNormal];
            self.cardSecondaryBtn.hidden = NO;
        }
    } else {
        self.statusCardView.layer.borderColor = [TypelessOverlayView borderHairlineColor].CGColor;
        if (isRec) {
            self.statusBadgeLabel.text = [NSString stringWithFormat:@"● 正在聆听 · %@", [TypelessConfig titleForMode:cfg.voiceMode]];
            self.statusBadgeLabel.textColor = [UIColor colorWithRed:0.92 green:0.24 blue:0.22 alpha:1.0];
            NSString *live = mgr.liveRecognizedPreview;
            if ([cfg shouldUseWhisperAPI]) {
                self.transcriptLabel.text = @"正在高保真录音，点击「✓ 完成」或松手立即识别并智能输出…";
                self.transcriptLabel.textColor = [TypelessOverlayView secondaryTextColor];
            } else {
                self.transcriptLabel.text = live.length > 0 ? live : @"请自然说出你想输入的内容，完成后点「✓ 完成」…";
                self.transcriptLabel.textColor = live.length > 0 ? [TypelessOverlayView primaryTextColor] : [TypelessOverlayView secondaryTextColor];
            }
        } else if (st == TypelessSessionStateTranscribing) {
            self.statusBadgeLabel.text = @"语音识别中…";
            self.statusBadgeLabel.textColor = [TypelessOverlayView accentBlue];
            self.transcriptLabel.text = mgr.liveRecognizedPreview.length > 0 ? mgr.liveRecognizedPreview : @"正在提取语音内容…";
            self.transcriptLabel.textColor = [TypelessOverlayView primaryTextColor];
        } else if (st == TypelessSessionStateProcessingAI) {
            self.statusBadgeLabel.text = [NSString stringWithFormat:@"AI 处理中（%@）…", [TypelessConfig titleForPolishStyle:cfg.polishStyle]];
            self.statusBadgeLabel.textColor = [UIColor colorWithRed:0.45 green:0.32 blue:0.90 alpha:1.0];
            self.transcriptLabel.text = mgr.liveRecognizedPreview.length > 0 ? mgr.liveRecognizedPreview : @"正在按所选模式优化表达…";
            self.transcriptLabel.textColor = [TypelessOverlayView primaryTextColor];
        } else {
            // Idle
            if (self.noticeOverrideText.length > 0) {
                self.statusBadgeLabel.text = @"✓ 完成";
                self.statusBadgeLabel.textColor = [UIColor colorWithRed:0.14 green:0.68 blue:0.38 alpha:1.0];
                self.transcriptLabel.text = self.noticeOverrideText;
                self.transcriptLabel.textColor = [TypelessOverlayView primaryTextColor];
            } else {
                NSString *sub = (cfg.voiceMode == TypelessVoiceModeTranslate)
                    ? [NSString stringWithFormat:@"%@ · 目标：%@", [TypelessConfig titleForMode:cfg.voiceMode], cfg.targetLanguage]
                    : [NSString stringWithFormat:@"%@ · %@", [TypelessConfig titleForMode:cfg.voiceMode], [TypelessConfig titleForPolishStyle:cfg.polishStyle]];
                self.statusBadgeLabel.text = sub;
                self.statusBadgeLabel.textColor = [TypelessOverlayView accentBlue];

                NSString *prev = cfg.lastProcessedResult;
                if (prev.length > 0) {
                    self.transcriptLabel.text = [NSString stringWithFormat:@"上次：%@", prev];
                    self.transcriptLabel.textColor = [TypelessOverlayView secondaryTextColor];
                } else {
                    self.transcriptLabel.text = @"轻点下方蓝键开始说话，或长按对讲（松手即上屏）";
                    self.transcriptLabel.textColor = [TypelessOverlayView secondaryTextColor];
                }
            }
        }
    }

    // Mic Dock Appearance
    self.cancelBtn.hidden = !(isRec || isBusy);
    self.finishBtn.hidden = !isRec;
    self.timerLabel.hidden = !isRec;
    self.micHintLabel.hidden = (isRec || isBusy);

    if (isBusy) {
        self.micOrbBtn.backgroundColor = [UIColor colorWithRed:0.45 green:0.32 blue:0.90 alpha:1.0];
        if (@available(iOS 13.0, *)) {
            [self.micOrbBtn setImage:nil forState:UIControlStateNormal];
        } else {
            [self.micOrbBtn setTitle:@"" forState:UIControlStateNormal];
        }
        [self.aiSpinner startAnimating];
        [self stopPulseAnimation];
        [self resetWaveBars];
    } else if (isRec) {
        [self.aiSpinner stopAnimating];
        self.micOrbBtn.backgroundColor = [UIColor colorWithRed:0.92 green:0.22 blue:0.22 alpha:1.0];
        if (@available(iOS 13.0, *)) {
            UIImageSymbolConfiguration *sym = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightBold];
            [self.micOrbBtn setImage:[UIImage systemImageNamed:@"stop.fill" withConfiguration:sym] forState:UIControlStateNormal];
        }
        [self startPulseAnimation];
    } else {
        [self.aiSpinner stopAnimating];
        self.micOrbBtn.backgroundColor = [TypelessOverlayView accentBlue];
        if (@available(iOS 13.0, *)) {
            UIImageSymbolConfiguration *sym = [UIImageSymbolConfiguration configurationWithPointSize:21 weight:UIImageSymbolWeightSemibold];
            [self.micOrbBtn setImage:[UIImage systemImageNamed:@"mic.fill" withConfiguration:sym] forState:UIControlStateNormal];
        }
        self.timerLabel.text = @"00:00";
        self.micHintLabel.text = [cfg shouldUseWhisperAPI] ? @"Whisper 引擎" : @"系统识别";
        [self stopPulseAnimation];
        [self resetWaveBars];
    }
}

#pragma mark - Animations & Live Telemetry

- (void)startPulseAnimation {
    self.micHaloView.alpha = 1.0;
    if ([self.micHaloView.layer animationForKey:@"pulse"]) return;
    CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    scale.fromValue = @(0.96);
    scale.toValue = @(1.26);
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @(0.65);
    fade.toValue = @(0.05);
    CAAnimationGroup *grp = [CAAnimationGroup animation];
    grp.animations = @[scale, fade];
    grp.duration = 1.1;
    grp.repeatCount = HUGE_VALF;
    [self.micHaloView.layer addAnimation:grp forKey:@"pulse"];
}

- (void)stopPulseAnimation {
    [self.micHaloView.layer removeAnimationForKey:@"pulse"];
    self.micHaloView.alpha = 0.0;
}

- (void)resetWaveBars {
    for (UIView *bar in self.waveBars) {
        bar.backgroundColor = [TypelessOverlayView accentBlue];
        bar.alpha = 0.25;
        bar.transform = CGAffineTransformMakeScale(1.0, 0.22);
    }
}

- (void)updateAudioLevel:(CGFloat)level elapsedSeconds:(NSTimeInterval)elapsed {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateAudioLevel:level elapsedSeconds:elapsed];
        });
        return;
    }
    NSInteger mins = (NSInteger)(elapsed / 60.0);
    NSInteger secs = (NSInteger)elapsed % 60;
    self.timerLabel.text = [NSString stringWithFormat:@"%02ld:%02ld", (long)mins, (long)secs];

    if (level < 0) return;
    CGFloat base = MAX(0.18, MIN(1.0, level));
    UIColor *activeRed = [UIColor colorWithRed:0.94 green:0.26 blue:0.25 alpha:1.0];
    for (NSUInteger i = 0; i < self.waveBars.count; i++) {
        UIView *bar = self.waveBars[i];
        CGFloat distFromCenter = (i < 5) ? (CGFloat)(4 - i) : (CGFloat)(i - 5);
        CGFloat weight = MAX(0.35, 1.0 - distFromCenter * 0.14);
        CGFloat jitter = ((arc4random_uniform(30) / 100.0) - 0.12);
        CGFloat s = MAX(0.22, MIN(1.0, base * weight + jitter));
        bar.backgroundColor = activeRed;
        bar.alpha = 0.88;
        bar.transform = CGAffineTransformMakeScale(1.0, s);
    }
}

- (void)updatePartialTranscript:(NSString *)text {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updatePartialTranscript:text];
        });
        return;
    }
    if (text.length == 0 || self.hasActiveError) return;
    self.transcriptLabel.text = text;
    self.transcriptLabel.textColor = [TypelessOverlayView primaryTextColor];
}

- (void)showErrorStatus:(NSString *)message {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showErrorStatus:message];
        });
        return;
    }
    [self.noticeClearTimer invalidate];
    self.noticeClearTimer = nil;
    self.noticeOverrideText = nil;
    self.showingHistoryDrawer = NO;
    self.hasActiveError = YES;
    self.currentErrorMessage = message.length > 0 ? message : @"发生未知异常，请重试";
    [self refreshStateUI];
}

- (void)showSuccessNotice:(NSString *)message {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showSuccessNotice:message];
        });
        return;
    }
    self.hasActiveError = NO;
    self.currentErrorMessage = nil;
    self.noticeOverrideText = message;
    self.noticeToken += 1;
    NSUInteger myToken = self.noticeToken;
    [self refreshStateUI];

    [self.noticeClearTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.noticeClearTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:NO block:^(NSTimer * _Nonnull timer) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s || myToken != s.noticeToken) return;
        s.noticeOverrideText = nil;
        [s refreshStateUI];
    }];
}

#pragma mark - Actions

- (void)onBackToKeyboardTapped {
    [self.haptic impactOccurred];
    [[TypelessVoiceManager sharedManager] dismissVoiceOverlayAnimated:YES];
}

- (void)onKeepAlivePillTapped {
    [self.haptic impactOccurred];
    if ([[TypelessHostBridge sharedBridge] isHostBridgeAlive]) {
        [self showSuccessNotice:@"免切后台通道正常运行中（可在主App管理）"];
    } else {
        [[TypelessHostBridge sharedBridge] openHostKeepAliveFromViewController:[TypelessVoiceManager sharedManager].activeInputViewController];
    }
}

- (void)onModePillTapped:(UIButton *)sender {
    [self.haptic impactOccurred];
    TypelessConfig *cfg = [TypelessConfig sharedConfig];
    cfg.voiceMode = (TypelessVoiceMode)sender.tag;
    [cfg save];
    self.showingHistoryDrawer = NO;
    [self refreshStateUI];
}

- (void)onStyleChipTapped:(UIButton *)sender {
    [self.haptic impactOccurred];
    TypelessConfig *cfg = [TypelessConfig sharedConfig];
    cfg.polishStyle = (TypelessPolishStyle)sender.tag;
    [cfg save];
    self.showingHistoryDrawer = NO;
    [self refreshStateUI];
}

- (void)onLanguageChipTapped:(UIButton *)sender {
    [self.haptic impactOccurred];
    NSArray<NSString *> *langs = [TypelessConfig supportedTargetLanguages];
    if (sender.tag >= 0 && (NSUInteger)sender.tag < langs.count) {
        TypelessConfig *cfg = [TypelessConfig sharedConfig];
        cfg.targetLanguage = langs[(NSUInteger)sender.tag];
        [cfg save];
        self.showingHistoryDrawer = NO;
        [self refreshStateUI];
    }
}

- (void)onUndoChipTapped {
    [[TypelessVoiceManager sharedManager] undoLastInsert];
}

- (void)onReprocessChipTapped {
    self.showingHistoryDrawer = NO;
    [[TypelessVoiceManager sharedManager] reprocessLastResult];
}

- (void)onCopyChipTapped {
    [[TypelessVoiceManager sharedManager] copyLastResultToPasteboard];
}

- (void)onToggleHistoryTapped {
    [self.haptic impactOccurred];
    self.showingHistoryDrawer = !self.showingHistoryDrawer;
    [self refreshStateUI];
}

- (void)onHistoryRowTapped:(UIButton *)sender {
    TypelessConfig *cfg = [TypelessConfig sharedConfig];
    if (sender.tag >= 0 && (NSUInteger)sender.tag < cfg.recentHistory.count) {
        NSString *item = cfg.recentHistory[(NSUInteger)sender.tag];
        self.showingHistoryDrawer = NO;
        [[TypelessVoiceManager sharedManager] insertHistoryText:item];
    }
}

- (void)onCardPrimaryActionTapped {
    [self.haptic impactOccurred];
    TypelessVoiceManager *mgr = [TypelessVoiceManager sharedManager];
    if ([self.cardActionBtn.currentTitle containsString:@"保活"]) {
        [[TypelessHostBridge sharedBridge] openHostKeepAliveFromViewController:mgr.activeInputViewController];
    } else {
        [mgr retryAfterError];
    }
}

- (void)onCardSecondaryActionTapped {
    [self.haptic impactOccurred];
    TypelessVoiceManager *mgr = [TypelessVoiceManager sharedManager];
    if ([self.cardSecondaryBtn.currentTitle containsString:@"重试"]) {
        [mgr retryAfterError];
    } else {
        [[TypelessHostBridge sharedBridge] openHostKeepAliveFromViewController:mgr.activeInputViewController];
    }
}

- (void)onMicOrbTapped {
    TypelessVoiceManager *mgr = [TypelessVoiceManager sharedManager];
    if (mgr.isRecording) {
        [mgr finishRecordingAndProcess];
    } else if (mgr.state == TypelessSessionStateIdle || mgr.state == TypelessSessionStateError) {
        self.showingHistoryDrawer = NO;
        [mgr startRecording];
    }
}

- (void)onMicOrbLongPressed:(UILongPressGestureRecognizer *)gr {
    TypelessVoiceManager *mgr = [TypelessVoiceManager sharedManager];
    if (gr.state == UIGestureRecognizerStateBegan) {
        if (!mgr.isRecording && (mgr.state == TypelessSessionStateIdle || mgr.state == TypelessSessionStateError)) {
            self.showingHistoryDrawer = NO;
            [mgr startRecording];
        }
    } else if (gr.state == UIGestureRecognizerStateEnded || gr.state == UIGestureRecognizerStateCancelled) {
        if (mgr.isRecording) {
            [mgr finishRecordingAndProcess];
        }
    }
}

- (void)onCancelTapped {
    [[TypelessVoiceManager sharedManager] cancelRecordingAndReset];
}

- (void)onFinishTapped {
    [[TypelessVoiceManager sharedManager] finishRecordingAndProcess];
}

- (void)onSpaceTapped {
    [[TypelessVoiceManager sharedManager] insertSpace];
}

- (void)onBackspaceTapped {
    [self.haptic impactOccurred];
    [[TypelessVoiceManager sharedManager] deleteBackwardStep];
}

- (void)onBackspaceLongPressed:(UILongPressGestureRecognizer *)gr {
    if (gr.state == UIGestureRecognizerStateBegan) {
        [self.deleteRepeatTimer invalidate];
        self.deleteRepeatTimer = [NSTimer scheduledTimerWithTimeInterval:0.085 repeats:YES block:^(NSTimer * _Nonnull timer) {
            [[TypelessVoiceManager sharedManager] deleteBackwardStep];
        }];
    } else if (gr.state == UIGestureRecognizerStateEnded || gr.state == UIGestureRecognizerStateCancelled) {
        [self.deleteRepeatTimer invalidate];
        self.deleteRepeatTimer = nil;
    }
}

- (void)onReturnTapped {
    [[TypelessVoiceManager sharedManager] insertReturn];
}

@end
