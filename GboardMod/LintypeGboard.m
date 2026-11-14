#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "LintypeVoiceManager.h"
#import "GboardNativeTheme.h"

#pragma mark - GKBUIInputViewController Hooks

static void (*orig_inputVc_viewDidAppear)(id self, SEL _cmd, BOOL animated) = NULL;
static void my_inputVc_viewDidAppear(UIInputViewController *self, SEL _cmd, BOOL animated) {
    if (orig_inputVc_viewDidAppear) {
        orig_inputVc_viewDidAppear(self, _cmd, animated);
    }

    @try {
        [LintypeVoiceManager sharedManager].activeInputViewController = self;

        static const NSInteger kLintypeMicButtonTag = 987654;
        if (![self.view viewWithTag:kLintypeMicButtonTag]) {
            UIButton *micBtn = [UIButton buttonWithType:UIButtonTypeCustom];
            micBtn.tag = kLintypeMicButtonTag;
            micBtn.frame = CGRectMake(self.view.bounds.size.width - 42, 6, 34, 34);
            micBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
            micBtn.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:0.15];
            micBtn.layer.cornerRadius = 17;
            micBtn.layer.masksToBounds = YES;

            UILabel *iconLabel = [[UILabel alloc] initWithFrame:micBtn.bounds];
            iconLabel.text = @"🎙";
            iconLabel.font = [UIFont systemFontOfSize:17];
            iconLabel.textAlignment = NSTextAlignmentCenter;
            iconLabel.userInteractionEnabled = NO;
            [micBtn addSubview:iconLabel];

            [micBtn addTarget:[LintypeVoiceManager sharedManager] action:@selector(quickMicTapped:) forControlEvents:UIControlEventTouchUpInside];
            [self.view addSubview:micBtn];
            [self.view bringSubviewToFront:micBtn];
        }
    } @catch (NSException *e) {
        NSLog(@"[LintypeGboard] Exception in viewDidAppear: %@", e);
    }
}

static void my_inputVc_startVoiceInput(UIInputViewController *self, SEL _cmd) {
    @try {
        [[LintypeVoiceManager sharedManager] presentVoiceOverlayInViewController:self];
    } @catch (NSException *e) {
        NSLog(@"[LintypeGboard] Exception in startVoiceInput: %@", e);
    }
}

static void my_inputVc_handleVoiceInput(UIInputViewController *self, SEL _cmd) {
    @try {
        [[LintypeVoiceManager sharedManager] presentVoiceOverlayInViewController:self];
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
            vc = [LintypeVoiceManager sharedManager].activeInputViewController;
        }
        [[LintypeVoiceManager sharedManager] presentVoiceOverlayInViewController:vc];
    } @catch (NSException *e) {
        NSLog(@"[LintypeGboard] Exception in launchVoiceInput: %@", e);
    }
}

__attribute__((constructor)) static void init_lintype_gboard(void) {
    NSLog(@"[LintypeGboard] Initializing Lintype Gboard Mod...");

    // Only install keyboard hooks inside the Keyboard Extension (.appex)
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    if (![bundlePath hasSuffix:@".appex"]) {
        NSLog(@"[LintypeGboard] Main container app detected, skipping keyboard hooks.");
        return;
    }

    // Install iOS Native Theme hooks for 9-key layout & clean candidates
    [GboardNativeTheme installThemeHooks];

    // Hook GKBUIInputViewController
    Class inputVcCls = objc_getClass("GKBUIInputViewController");
    if (inputVcCls) {
        Method mAppear = class_getInstanceMethod(inputVcCls, @selector(viewDidAppear:));
        if (mAppear) {
            orig_inputVc_viewDidAppear = (void *)method_getImplementation(mAppear);
            method_setImplementation(mAppear, (IMP)my_inputVc_viewDidAppear);
        }

        Method mStart = class_getInstanceMethod(inputVcCls, @selector(startVoiceInput));
        if (mStart) {
            method_setImplementation(mStart, (IMP)my_inputVc_startVoiceInput);
        }

        Method mHandle = class_getInstanceMethod(inputVcCls, @selector(handleVoiceInput));
        if (mHandle) {
            method_setImplementation(mHandle, (IMP)my_inputVc_handleVoiceInput);
        }
    }

    // Hook GKBVoiceInputLauncher
    Class voiceLauncherCls = objc_getClass("GKBVoiceInputLauncher");
    if (voiceLauncherCls) {
        Method mLaunch = class_getInstanceMethod(voiceLauncherCls, @selector(launchVoiceInput));
        if (mLaunch) {
            method_setImplementation(mLaunch, (IMP)my_voiceLauncher_launchVoiceInput);
        }
    }

    NSLog(@"[LintypeGboard] Successfully installed Lintype hooks!");
}
