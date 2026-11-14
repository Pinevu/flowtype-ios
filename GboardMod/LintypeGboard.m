#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "TypelessVoiceManager.h"
#import "TypelessOverlayView.h"
#import "TypelessConfig.h"

#pragma mark - AppGroup & Suite Safety Fallbacks for ESign / TrollStore

static NSURL *(*orig_containerURL)(id self, SEL _cmd, NSString *groupId) = NULL;
static NSURL *safe_containerURL(id self, SEL _cmd, NSString *groupId) {
    NSURL *url = nil;
    @try {
        if (orig_containerURL) {
            url = orig_containerURL(self, _cmd, groupId);
        }
    } @catch (NSException *e) {}

    if (url != nil) {
        return url;
    }

    @try {
        NSString *base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
        if (!base) base = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (!base) base = NSTemporaryDirectory();

        NSString *safeName = [groupId stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
        NSString *dir = [base stringByAppendingPathComponent:[NSString stringWithFormat:@"AppGroup_%@", safeName]];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        return [NSURL fileURLWithPath:dir isDirectory:YES];
    } @catch (NSException *e) {
        return [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
    }
}

static id (*orig_initWithSuiteName)(id self, SEL _cmd, NSString *suiteName) = NULL;
static id safe_initWithSuiteName(id self, SEL _cmd, NSString *suiteName) {
    id res = nil;
    @try {
        if (orig_initWithSuiteName) {
            res = orig_initWithSuiteName(self, _cmd, suiteName);
        }
    } @catch (NSException *e) {}

    if (res != nil) {
        return res;
    }

    return [NSUserDefaults standardUserDefaults];
}

static void SafeHookInstanceMethod(Class cls, SEL sel, IMP replacementIMP, IMP *outOrigIMP) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    const char *types = method_getTypeEncoding(m);
    IMP orig = method_getImplementation(m);
    if (class_addMethod(cls, sel, replacementIMP, types)) {
        if (outOrigIMP) *outOrigIMP = orig;
    } else {
        IMP swapped = method_setImplementation(m, replacementIMP);
        if (outOrigIMP) *outOrigIMP = swapped;
    }
}

static void install_sandbox_guards(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSLog(@"[LintypeGboard] Installing AppGroup & NSUserDefaults safety guards...");
        SafeHookInstanceMethod([NSFileManager class],
                               @selector(containerURLForSecurityApplicationGroupIdentifier:),
                               (IMP)safe_containerURL,
                               (IMP *)&orig_containerURL);
        SafeHookInstanceMethod([NSUserDefaults class],
                               @selector(initWithSuiteName:),
                               (IMP)safe_initWithSuiteName,
                               (IMP *)&orig_initWithSuiteName);
    });
}

#pragma mark - Quick Voice Pill Helper

static const NSInteger kTypelessMicButtonTag = 987654;

static void EnsureQuickVoicePillInController(UIInputViewController *vc) {
    if (!vc || !vc.view) return;
    UIView *container = vc.view;
    UIButton *pillBtn = (UIButton *)[container viewWithTag:kTypelessMicButtonTag];
    if (!pillBtn) {
        pillBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        pillBtn.tag = kTypelessMicButtonTag;
        pillBtn.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:0.15];
        pillBtn.layer.cornerRadius = 14.0;
        pillBtn.layer.masksToBounds = YES;
        pillBtn.layer.borderWidth = 0.5;
        pillBtn.layer.borderColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:0.25].CGColor;
        pillBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;

        UIColor *blueAccent = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];
        [pillBtn setTitle:@"语音" forState:UIControlStateNormal];
        [pillBtn setTitleColor:blueAccent forState:UIControlStateNormal];
        pillBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        pillBtn.tintColor = blueAccent;

        if (@available(iOS 13.0, *)) {
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:11.5 weight:UIImageSymbolWeightSemibold];
            [pillBtn setImage:[UIImage systemImageNamed:@"mic.fill" withConfiguration:cfg] forState:UIControlStateNormal];
            pillBtn.imageEdgeInsets = UIEdgeInsetsMake(0, -2, 0, 2);
            pillBtn.titleEdgeInsets = UIEdgeInsetsMake(0, 2, 0, -2);
        }

        [pillBtn addTarget:[TypelessVoiceManager sharedManager]
                    action:@selector(quickMicTapped:)
          forControlEvents:UIControlEventTouchUpInside];
        [container addSubview:pillBtn];
    }

    CGFloat w = container.bounds.size.width;
    if (w > 80) {
        pillBtn.frame = CGRectMake(w - 70, 5, 62, 28);
    }
    [container bringSubviewToFront:pillBtn];
}

#pragma mark - Gboard UIInputViewController Hooks

static void (*orig_inputVc_viewDidAppear)(id self, SEL _cmd, BOOL animated) = NULL;
static void my_inputVc_viewDidAppear(UIInputViewController *self, SEL _cmd, BOOL animated) {
    if (orig_inputVc_viewDidAppear) {
        orig_inputVc_viewDidAppear(self, _cmd, animated);
    }

    @try {
        [TypelessVoiceManager sharedManager].activeInputViewController = self;
        EnsureQuickVoicePillInController(self);
    } @catch (NSException *e) {
        NSLog(@"[LintypeGboard] Exception in viewDidAppear: %@", e);
    }
}

static void (*orig_inputVc_viewDidLayoutSubviews)(id self, SEL _cmd) = NULL;
static void my_inputVc_viewDidLayoutSubviews(UIInputViewController *self, SEL _cmd) {
    if (orig_inputVc_viewDidLayoutSubviews) {
        orig_inputVc_viewDidLayoutSubviews(self, _cmd);
    }

    @try {
        EnsureQuickVoicePillInController(self);
        TypelessVoiceManager *mgr = [TypelessVoiceManager sharedManager];
        if (mgr.isOverlayVisible) {
            for (UIView *sub in self.view.subviews) {
                if ([sub isKindOfClass:[TypelessOverlayView class]]) {
                    sub.frame = self.view.bounds;
                    [self.view bringSubviewToFront:sub];
                    break;
                }
            }
        }
    } @catch (NSException *e) {}
}

static void (*orig_inputVc_selectionDidChange)(id self, SEL _cmd, id<UITextInput> textInput) = NULL;
static void my_inputVc_selectionDidChange(UIInputViewController *self, SEL _cmd, id<UITextInput> textInput) {
    if (orig_inputVc_selectionDidChange) {
        orig_inputVc_selectionDidChange(self, _cmd, textInput);
    }

    @try {
        TypelessVoiceManager *mgr = [TypelessVoiceManager sharedManager];
        if (mgr.isOverlayVisible && mgr.state == TypelessSessionStateIdle) {
            for (UIView *sub in self.view.subviews) {
                if ([sub isKindOfClass:[TypelessOverlayView class]]) {
                    [(TypelessOverlayView *)sub refreshStateUI];
                    break;
                }
            }
        }
    } @catch (NSException *e) {}
}

static void my_inputVc_startVoiceInput(UIInputViewController *self, SEL _cmd) {
    @try {
        [[TypelessVoiceManager sharedManager] presentVoiceOverlayInViewController:self autoStart:YES];
    } @catch (NSException *e) {
        NSLog(@"[LintypeGboard] Exception in startVoiceInput: %@", e);
    }
}

static void my_inputVc_handleVoiceInput(UIInputViewController *self, SEL _cmd) {
    @try {
        [[TypelessVoiceManager sharedManager] presentVoiceOverlayInViewController:self autoStart:YES];
    } @catch (NSException *e) {
        NSLog(@"[LintypeGboard] Exception in handleVoiceInput: %@", e);
    }
}

static void my_voiceLauncher_launchVoiceInput(id self, SEL _cmd) {
    @try {
        id delegate = nil;
        @try {
            delegate = [self valueForKey:@"delegate"];
        } @catch (NSException *e) {}

        UIInputViewController *vc = nil;
        if ([delegate isKindOfClass:[UIInputViewController class]]) {
            vc = (UIInputViewController *)delegate;
        } else {
            vc = [TypelessVoiceManager sharedManager].activeInputViewController;
        }
        [[TypelessVoiceManager sharedManager] presentVoiceOverlayInViewController:vc autoStart:YES];
    } @catch (NSException *e) {
        NSLog(@"[LintypeGboard] Exception in launchVoiceInput: %@", e);
    }
}

__attribute__((constructor)) static void init_lintype_gboard(void) {
    NSLog(@"[LintypeGboard] Initializing Gboard Typeless AI Voice Input Mod...");

    // 1. Install AppGroup and NSUserDefaults guards in both Main App and Extension
    install_sandbox_guards();

    // 2. Only install keyboard extension hooks inside .appex
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    if (![bundlePath hasSuffix:@".appex"]) {
        NSLog(@"[LintypeGboard] Main container app detected, sandbox guards active.");
        return;
    }

    // 3. Hook GKBUIInputViewController safely while leaving 100% of Gboard's native layout untouched
    Class inputVcCls = objc_getClass("GKBUIInputViewController");
    if (inputVcCls) {
        SafeHookInstanceMethod(inputVcCls, @selector(viewDidAppear:), (IMP)my_inputVc_viewDidAppear, (IMP *)&orig_inputVc_viewDidAppear);
        SafeHookInstanceMethod(inputVcCls, @selector(viewDidLayoutSubviews), (IMP)my_inputVc_viewDidLayoutSubviews, (IMP *)&orig_inputVc_viewDidLayoutSubviews);
        SafeHookInstanceMethod(inputVcCls, @selector(selectionDidChange:), (IMP)my_inputVc_selectionDidChange, (IMP *)&orig_inputVc_selectionDidChange);

        Method mStart = class_getInstanceMethod(inputVcCls, @selector(startVoiceInput));
        if (mStart) {
            method_setImplementation(mStart, (IMP)my_inputVc_startVoiceInput);
        }

        Method mHandle = class_getInstanceMethod(inputVcCls, @selector(handleVoiceInput));
        if (mHandle) {
            method_setImplementation(mHandle, (IMP)my_inputVc_handleVoiceInput);
        }
    }

    // 4. Hook GKBVoiceInputLauncher
    Class voiceLauncherCls = objc_getClass("GKBVoiceInputLauncher");
    if (voiceLauncherCls) {
        Method mLaunch = class_getInstanceMethod(voiceLauncherCls, @selector(launchVoiceInput));
        if (mLaunch) {
            method_setImplementation(mLaunch, (IMP)my_voiceLauncher_launchVoiceInput);
        }
    }

    NSLog(@"[LintypeGboard] Gboard Typeless AI Voice Mod initialized successfully (UI Aligned & Native Layout 100%% Preserved)!");
}
