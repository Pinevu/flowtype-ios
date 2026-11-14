#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "LintypeVoiceManager.h"
#import "GboardNativeTheme.h"

static void SwizzleMethod(Class cls, SEL origSel, SEL newSel) {
    if (!cls) return;
    Method origMethod = class_getInstanceMethod(cls, origSel);
    Method newMethod = class_getInstanceMethod(cls, newSel);
    if (!origMethod || !newMethod) return;
    if (class_addMethod(cls, origSel, method_getImplementation(newMethod), method_getTypeEncoding(newMethod))) {
        class_replaceMethod(cls, newSel, method_getImplementation(origMethod), method_getTypeEncoding(origMethod));
    } else {
        method_exchangeImplementations(origMethod, newMethod);
    }
}

@interface GKBVoiceInputLauncher : NSObject
@property (nonatomic, weak) id delegate;
@property (nonatomic, strong) id textDocumentProxy;
- (void)launchVoiceInput;
@end

@interface UIInputViewController (LintypeHooks)
- (void)lintype_viewDidAppear:(BOOL)animated;
- (void)lintype_startVoiceInput;
- (void)lintype_handleVoiceInput;
@end

@implementation UIInputViewController (LintypeHooks)

- (void)lintype_viewDidAppear:(BOOL)animated {
    [self lintype_viewDidAppear:animated];

    [LintypeVoiceManager sharedManager].activeInputViewController = self;

    // Add a convenient floating Lintype voice button on top right of keyboard
    static const NSInteger kLintypeMicButtonTag = 987654;
    UIView *existing = [self.view viewWithTag:kLintypeMicButtonTag];
    if (!existing) {
        UIButton *micBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        micBtn.tag = kLintypeMicButtonTag;
        micBtn.frame = CGRectMake(self.view.bounds.size.width - 42, 6, 34, 34);
        micBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
        micBtn.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:0.15];
        micBtn.layer.cornerRadius = 17;
        micBtn.layer.masksToBounds = YES;
        
        // Microphone glyph
        UILabel *iconLabel = [[UILabel alloc] initWithFrame:micBtn.bounds];
        iconLabel.text = @"🎙";
        iconLabel.font = [UIFont systemFontOfSize:17];
        iconLabel.textAlignment = NSTextAlignmentCenter;
        iconLabel.userInteractionEnabled = NO;
        [micBtn addSubview:iconLabel];

        [micBtn addTarget:self action:@selector(lintype_quickMicTapped) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:micBtn];
        [self.view bringSubviewToFront:micBtn];
    }
}

- (void)lintype_quickMicTapped {
    [[LintypeVoiceManager sharedManager] presentVoiceOverlayInViewController:self];
}

- (void)lintype_startVoiceInput {
    // Intercept Gboard's native startVoiceInput and invoke Lintype Voice
    [[LintypeVoiceManager sharedManager] presentVoiceOverlayInViewController:self];
}

- (void)lintype_handleVoiceInput {
    // Intercept Gboard's native handleVoiceInput and invoke Lintype Voice
    [[LintypeVoiceManager sharedManager] presentVoiceOverlayInViewController:self];
}

@end

@interface GKBVoiceInputLauncher (LintypeLauncherHooks)
- (void)lintype_launchVoiceInput;
@end

@implementation GKBVoiceInputLauncher (LintypeLauncherHooks)

- (void)lintype_launchVoiceInput {
    UIInputViewController *vc = nil;
    if ([self.delegate isKindOfClass:[UIInputViewController class]]) {
        vc = (UIInputViewController *)self.delegate;
    } else {
        vc = [LintypeVoiceManager sharedManager].activeInputViewController;
    }
    [[LintypeVoiceManager sharedManager] presentVoiceOverlayInViewController:vc];
}

@end

__attribute__((constructor)) static void init_lintype_gboard(void) {
    NSLog(@"[LintypeGboard] Initializing Lintype Gboard Mod...");

    // Install iOS Native Theme hooks for 9-key layout & clean candidates
    [GboardNativeTheme installThemeHooks];

    // Install Voice Input Hooks
    Class inputVcCls = objc_getClass("GKBUIInputViewController");
    if (inputVcCls) {
        SwizzleMethod(inputVcCls, @selector(viewDidAppear:), @selector(lintype_viewDidAppear:));
        SwizzleMethod(inputVcCls, @selector(startVoiceInput), @selector(lintype_startVoiceInput));
        SwizzleMethod(inputVcCls, @selector(handleVoiceInput), @selector(lintype_handleVoiceInput));
    }

    Class voiceLauncherCls = objc_getClass("GKBVoiceInputLauncher");
    if (voiceLauncherCls) {
        SwizzleMethod(voiceLauncherCls, @selector(launchVoiceInput), @selector(lintype_launchVoiceInput));
    }

    NSLog(@"[LintypeGboard] Successfully hooked voice input and native iOS theme!");
}
