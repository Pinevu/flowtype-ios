#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "TypelessVoiceManager.h"
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

    // When signed with third-party certs (ESign), containerURL returns nil for Google groups.
    // Return a safe persistent directory inside the sandbox so Gboard doesn't crash on nil.
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

    // In third-party certs, initWithSuiteName returns nil for group.com.google.keyboard.
    // Return standardUserDefaults so callers never get a nil instance and do not crash.
    return [NSUserDefaults standardUserDefaults];
}

static void install_sandbox_guards(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSLog(@"[LintypeGboard] Installing AppGroup & NSUserDefaults safety guards...");

        // 1. Hook NSFileManager containerURLForSecurityApplicationGroupIdentifier:
        Method mContainer = class_getInstanceMethod([NSFileManager class], @selector(containerURLForSecurityApplicationGroupIdentifier:));
        if (mContainer) {
            orig_containerURL = (void *)method_getImplementation(mContainer);
            method_setImplementation(mContainer, (IMP)safe_containerURL);
        }

        // 2. Hook NSUserDefaults initWithSuiteName:
        Method mSuite = class_getInstanceMethod([NSUserDefaults class], @selector(initWithSuiteName:));
        if (mSuite) {
            orig_initWithSuiteName = (void *)method_getImplementation(mSuite);
            method_setImplementation(mSuite, (IMP)safe_initWithSuiteName);
        }
    });
}

#pragma mark - Gboard UIInputViewController Hooks

static void (*orig_inputVc_viewDidAppear)(id self, SEL _cmd, BOOL animated) = NULL;
static void my_inputVc_viewDidAppear(UIInputViewController *self, SEL _cmd, BOOL animated) {
    if (orig_inputVc_viewDidAppear) {
        orig_inputVc_viewDidAppear(self, _cmd, animated);
    }

    @try {
        [TypelessVoiceManager sharedManager].activeInputViewController = self;

        static const NSInteger kTypelessMicButtonTag = 987654;
        if (![self.view viewWithTag:kTypelessMicButtonTag]) {
            UIButton *micBtn = [UIButton buttonWithType:UIButtonTypeCustom];
            micBtn.tag = kTypelessMicButtonTag;
            micBtn.frame = CGRectMake(self.view.bounds.size.width - 44, 4, 38, 34);
            micBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
            micBtn.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:0.12];
            micBtn.layer.cornerRadius = 17;
            micBtn.layer.masksToBounds = YES;

            UILabel *iconLabel = [[UILabel alloc] initWithFrame:micBtn.bounds];
            iconLabel.text = @"🎙";
            iconLabel.font = [UIFont systemFontOfSize:17];
            iconLabel.textAlignment = NSTextAlignmentCenter;
            iconLabel.userInteractionEnabled = NO;
            [micBtn addSubview:iconLabel];

            [micBtn addTarget:[TypelessVoiceManager sharedManager] action:@selector(quickMicTapped:) forControlEvents:UIControlEventTouchUpInside];
            [self.view addSubview:micBtn];
            [self.view bringSubviewToFront:micBtn];
        }
    } @catch (NSException *e) {
        NSLog(@"[LintypeGboard] Exception in viewDidAppear: %@", e);
    }
}

static void my_inputVc_startVoiceInput(UIInputViewController *self, SEL _cmd) {
    @try {
        [[TypelessVoiceManager sharedManager] presentVoiceOverlayInViewController:self];
    } @catch (NSException *e) {
        NSLog(@"[LintypeGboard] Exception in startVoiceInput: %@", e);
    }
}

static void my_inputVc_handleVoiceInput(UIInputViewController *self, SEL _cmd) {
    @try {
        [[TypelessVoiceManager sharedManager] presentVoiceOverlayInViewController:self];
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
        [[TypelessVoiceManager sharedManager] presentVoiceOverlayInViewController:vc];
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

    // 3. Hook GKBUIInputViewController for Typeless voice input
    // NOTE: Gboard's native keyboard layouts, 9-key, 26-key, themes, candidates are 100% untouched and preserved!
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

    // 4. Hook GKBVoiceInputLauncher
    Class voiceLauncherCls = objc_getClass("GKBVoiceInputLauncher");
    if (voiceLauncherCls) {
        Method mLaunch = class_getInstanceMethod(voiceLauncherCls, @selector(launchVoiceInput));
        if (mLaunch) {
            method_setImplementation(mLaunch, (IMP)my_voiceLauncher_launchVoiceInput);
        }
    }

    NSLog(@"[LintypeGboard] Gboard Typeless AI Voice Mod initialized successfully (Native Layout 100%% Preserved)!");
}
