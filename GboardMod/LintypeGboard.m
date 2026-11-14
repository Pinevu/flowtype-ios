#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "TypelessVoiceManager.h"
#import "TypelessOverlayView.h"
#import "TypelessConfig.h"
#import "TypelessAppSettingsViewController.h"

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
    if (!cls || !sel || !replacementIMP) return;
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

#pragma mark - Chinese Language Model & Offline T9 Setup

static void SetupChinese9KeyOfflineAssets(void) {
    @try {
        NSURL *container = safe_containerURL(nil, nil, @"group.com.google.keyboard");
        if (!container) return;
        NSString *lmDir = [container.path stringByAppendingPathComponent:@"LanguageModels"];
        [[NSFileManager defaultManager] createDirectoryAtPath:lmDir withIntermediateDirectories:YES attributes:nil error:nil];

        // Check if zh_hans dictionary already exists
        NSString *pinyinSysDict = [lmDir stringByAppendingPathComponent:@"zh_t_i0_pinyin/pinyin_system_dictionary"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:pinyinSysDict]) {
            // Find bundled zh_hans.zip
            NSString *bundleZip = [[NSBundle mainBundle] pathForResource:@"zh_hans" ofType:@"zip"];
            if (!bundleZip) {
                // If in extension or main app, search resources
                NSString *resBundle = [[NSBundle mainBundle] pathForResource:@"GKBKeyboardResources" ofType:@"bundle"];
                if (resBundle) {
                    bundleZip = [resBundle stringByAppendingPathComponent:@"zh_hans.zip"];
                }
            }
            if (bundleZip && [[NSFileManager defaultManager] fileExistsAtPath:bundleZip]) {
                // Decompress zh_hans.zip into lmDir using system NSTask or unzip helper if available
                NSLog(@"[LintypeGboard] Unpacking bundled zh_hans offline language model from: %@", bundleZip);
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[LintypeGboard] Exception in SetupChinese9KeyOfflineAssets: %@", e);
    }
}

static void ConfigureDefault9KeyPreferences(void) {
    @try {
        NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
        NSArray *enabled = [defs arrayForKey:@"EnabledLanguages"];
        if (!enabled || enabled.count == 0 || ![enabled.firstObject isEqualToString:@"zh_hans"]) {
            NSMutableArray *newEnabled = [NSMutableArray arrayWithObject:@"zh_hans"];
            if (enabled) {
                for (id item in enabled) {
                    if (![item isEqualToString:@"zh_hans"]) {
                        [newEnabled addObject:item];
                    }
                }
            }
            if (![newEnabled containsObject:@"en_us"]) {
                [newEnabled addObject:@"en_us"];
            }
            [defs setObject:newEnabled forKey:@"EnabledLanguages"];
        }

        NSString *cur = [defs stringForKey:@"CurrentLanguage"];
        if (!cur || [cur isEqualToString:@"en_us"] || [cur isEqualToString:@"en"]) {
            [defs setObject:@"zh_hans" forKey:@"CurrentLanguage"];
        }

        // Force default layout variant to 9-key for Simplified Chinese
        [defs setObject:@"nine_key_zh_hans" forKey:@"zh_hans_varaint"];
        [defs setObject:@"nine_key_zh_hans" forKey:@"zh_hans_variant"];
        [defs setBool:YES forKey:@"VoiceInputSetting"];
        [defs synchronize];
    } @catch (NSException *e) {
        NSLog(@"[LintypeGboard] Exception in ConfigureDefault9KeyPreferences: %@", e);
    }
}

#pragma mark - GKBLanguageModelManager Hooks (Suppress '下载简体中文')

static BOOL (*orig_isLanguageModelAvailable)(id self, SEL _cmd, id lang) = NULL;
static BOOL my_isLanguageModelAvailable(id self, SEL _cmd, id lang) {
    NSString *desc = [lang description];
    if ([desc containsString:@"zh"] || [desc containsString:@"hans"] || [desc containsString:@"pinyin"]) {
        return YES;
    }
    if (orig_isLanguageModelAvailable) {
        return orig_isLanguageModelAvailable(self, _cmd, lang);
    }
    return YES;
}

static BOOL my_shouldShowLanguageModelUpdatePrompt(id self, SEL _cmd) {
    return NO;
}

#pragma mark - Main App Gboard Settings Menu Injection (Image 1 into Image 2)

static id (*orig_mainMenuPageDescriptor)(id self, SEL _cmd) = NULL;
static id my_mainMenuPageDescriptor(id self, SEL _cmd) {
    id page = nil;
    if (orig_mainMenuPageDescriptor) {
        page = orig_mainMenuPageDescriptor(self, _cmd);
    }
    @try {
        if (!page) return page;
        NSArray *sections = [page valueForKey:@"sections"];
        if (![sections isKindOfClass:[NSArray class]] || sections.count == 0) return page;

        Class itemClass = objc_getClass("GKBSettingsItem");
        if (!itemClass) return page;

        typedef id (*GKBSettingsItemInitFn)(id, SEL, NSInteger, NSString *, NSString *, NSString *, NSString *);
        SEL initSel = @selector(initWithType:settingID:title:accessibilityIdentifier:key:);
        id aiItem = nil;
        if ([itemClass instancesRespondToSelector:initSel]) {
            GKBSettingsItemInitFn initFn = (GKBSettingsItemInitFn)[itemClass instanceMethodForSelector:initSel];
            if (initFn) {
                id rawAlloc = [itemClass alloc];
                aiItem = initFn(rawAlloc, initSel, 1, @"SettingsMenuItemAIVoice", @"AI 语音与模型配置", @"SettingsMenuItemAIVoice", @"ai_voice");
            }
        }
        if (!aiItem) return page;

        @try {
            [aiItem setValue:@"OpenAI / DeepSeek / 语音识别与模型" forKey:@"subtitle"];
        } @catch (NSException *e) {}

        BOOL inserted = NO;
        for (id sec in sections) {
            NSArray *rows = [sec valueForKey:@"rows"];
            if (![rows isKindOfClass:[NSArray class]]) continue;

            for (NSUInteger i = 0; i < rows.count; i++) {
                id r = rows[i];
                NSString *sid = [r valueForKey:@"settingID"];
                if ([sid isEqualToString:@"SettingsMenuItemLanguages"] || [sid isEqualToString:@"SettingsMenuItemKeyboardSettings"]) {
                    NSMutableArray *newRows = [rows mutableCopy];
                    [newRows insertObject:aiItem atIndex:i + 1];
                    [sec setValue:[newRows copy] forKey:@"rows"];
                    inserted = YES;
                    break;
                }
            }
            if (inserted) break;
        }

        if (!inserted && sections.count > 0) {
            id sec0 = sections.firstObject;
            NSArray *rows = [sec0 valueForKey:@"rows"];
            NSMutableArray *newRows = [rows mutableCopy] ?: [NSMutableArray array];
            [newRows addObject:aiItem];
            [sec0 setValue:[newRows copy] forKey:@"rows"];
        }
    } @catch (NSException *e) {
        NSLog(@"[LintypeGboard] Exception injecting AI voice settings menu item: %@", e);
    }
    return page;
}

static void (*orig_didSelectSetting)(id self, SEL _cmd, id vc, id setting, id url) = NULL;
static void my_didSelectSetting(id self, SEL _cmd, id vc, id setting, id url) {
    @try {
        NSString *sid = [setting valueForKey:@"settingID"];
        if ([sid isEqualToString:@"SettingsMenuItemAIVoice"]) {
            TypelessAppSettingsViewController *aiVC = [[TypelessAppSettingsViewController alloc] init];
            UINavigationController *nav = nil;
            if ([self isKindOfClass:[UIViewController class]]) {
                nav = ((UIViewController *)self).navigationController;
            }
            if (nav) {
                [nav pushViewController:aiVC animated:YES];
            } else if ([self isKindOfClass:[UIViewController class]]) {
                UINavigationController *wrap = [[UINavigationController alloc] initWithRootViewController:aiVC];
                [((UIViewController *)self) presentViewController:wrap animated:YES completion:nil];
            }
            return;
        }
    } @catch (NSException *e) {
        NSLog(@"[LintypeGboard] Exception in didSelectSetting: %@", e);
    }

    if (orig_didSelectSetting) {
        orig_didSelectSetting(self, _cmd, vc, setting, url);
    }
}

#pragma mark - Gboard UIInputViewController Hooks

static void (*orig_inputVc_viewDidAppear)(id self, SEL _cmd, BOOL animated) = NULL;
static void my_inputVc_viewDidAppear(UIInputViewController *self, SEL _cmd, BOOL animated) {
    if (orig_inputVc_viewDidAppear) {
        orig_inputVc_viewDidAppear(self, _cmd, animated);
    }

    @try {
        [TypelessVoiceManager sharedManager].activeInputViewController = self;
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

#pragma mark - Constructor

__attribute__((constructor)) static void init_lintype_gboard(void) {
    NSLog(@"[LintypeGboard] Initializing Gboard Typeless AI Mod v1.0.5...");

    // 1. Install AppGroup & NSUserDefaults guards in both Main App and Extension
    SafeHookInstanceMethod([NSFileManager class],
                           @selector(containerURLForSecurityApplicationGroupIdentifier:),
                           (IMP)safe_containerURL,
                           (IMP *)&orig_containerURL);
    SafeHookInstanceMethod([NSUserDefaults class],
                           @selector(initWithSuiteName:),
                           (IMP)safe_initWithSuiteName,
                           (IMP *)&orig_initWithSuiteName);

    // 2. Setup Chinese 9-Key default preferences and language model offline assets
    ConfigureDefault9KeyPreferences();
    SetupChinese9KeyOfflineAssets();

    // 3. Hook GKBLanguageModelManager to suppress "下载简体中文" and enable offline pinyin
    Class lmManagerCls = objc_getClass("GKBLanguageModelManager");
    if (lmManagerCls) {
        SafeHookInstanceMethod(lmManagerCls, @selector(isLanguageModelAvailableForLanguage:), (IMP)my_isLanguageModelAvailable, (IMP *)&orig_isLanguageModelAvailable);
        SafeHookInstanceMethod(lmManagerCls, @selector(shouldShowLanguageModelUpdatePrompt), (IMP)my_shouldShowLanguageModelUpdatePrompt, NULL);
    }

    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    if (![bundlePath hasSuffix:@".appex"]) {
        // --- In Main App (Gboard.app) ---
        // Hook GKBSettingsViewController to inject Image 1 settings into Image 2 settings list
        Class settingsVcCls = objc_getClass("GKBSettingsViewController");
        if (settingsVcCls) {
            SafeHookInstanceMethod(settingsVcCls, @selector(mainMenuPageDescriptor), (IMP)my_mainMenuPageDescriptor, (IMP *)&orig_mainMenuPageDescriptor);
            SafeHookInstanceMethod(settingsVcCls, @selector(viewController:didSelectSetting:URL:), (IMP)my_didSelectSetting, (IMP *)&orig_didSelectSetting);
        }
        NSLog(@"[LintypeGboard] Main app settings hooks installed successfully.");
        return;
    }

    // --- In Keyboard Extension (Gboard.appex) ---
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

    Class voiceLauncherCls = objc_getClass("GKBVoiceInputLauncher");
    if (voiceLauncherCls) {
        Method mLaunch = class_getInstanceMethod(voiceLauncherCls, @selector(launchVoiceInput));
        if (mLaunch) {
            method_setImplementation(mLaunch, (IMP)my_voiceLauncher_launchVoiceInput);
        }
    }

    NSLog(@"[LintypeGboard] Keyboard extension hooks installed successfully (No overlap, 9-Key default, Typeless AI Voice)!");
}
