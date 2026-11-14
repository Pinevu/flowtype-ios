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

static NSDictionary *GetChineseLanguageModelEntryDict(void) {
    return @{
        @"id": @"main:zh_hans_v2",
        @"locale": @"zh_hans_CN",
        @"description": @"简体中文",
        @"filesize": @"9115605",
        @"rawChecksum": @"6e61af57544cbb6dbc07101aba7cf8b7",
        @"checksum": @"6e61af57544cbb6dbc07101aba7cf8b7",
        @"url": @"https://www.gstatic.com/gboard/iOS/gboard_latest/lms/zh_hans.zip",
        @"version": @(13),
        @"compression": @"zip"
    };
}

static void PopulateOfflineChineseLanguageModelsInDir(NSString *baseLmDir) {
    if (!baseLmDir) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:baseLmDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *zhTargetDir = [baseLmDir stringByAppendingPathComponent:@"main:zh_hans_v2"];
    [fm createDirectoryAtPath:zhTargetDir withIntermediateDirectories:YES attributes:nil error:nil];

    // Also write metadata.json so GKBLanguageModelManager can parse it
    NSString *metaPath = [baseLmDir stringByAppendingPathComponent:@"metadata.json"];
    if (![fm fileExistsAtPath:metaPath]) {
        NSArray *arr = @[GetChineseLanguageModelEntryDict()];
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:arr options:NSJSONWritingPrettyPrinted error:nil];
        if (jsonData) {
            [jsonData writeToFile:metaPath atomically:YES];
        }
    }

    // Check if models exist in main:zh_hans_v2
    NSString *pinyinDict = [zhTargetDir stringByAppendingPathComponent:@"zh_t_i0_pinyin/pinyin_system_dictionary"];
    if (![fm fileExistsAtPath:pinyinDict]) {
        // Search pre-extracted assets in App Bundle
        NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
        NSString *bundledLmZh = [bundlePath stringByAppendingPathComponent:@"LanguageModels/main:zh_hans_v2"];
        if ([fm fileExistsAtPath:[bundledLmZh stringByAppendingPathComponent:@"zh_t_i0_pinyin/pinyin_system_dictionary"]]) {
            NSLog(@"[LintypeGboard] Copying bundled pre-extracted models from %@ to %@", bundledLmZh, zhTargetDir);
            NSArray *items = [fm contentsOfDirectoryAtPath:bundledLmZh error:nil];
            for (NSString *item in items) {
                NSString *src = [bundledLmZh stringByAppendingPathComponent:item];
                NSString *dst = [zhTargetDir stringByAppendingPathComponent:item];
                if (![fm fileExistsAtPath:dst]) {
                    [fm copyItemAtPath:src toPath:dst error:nil];
                }
            }
        }
    }
}

static void SetupChinese9KeyOfflineAssets(void) {
    @try {
        // 1. Setup in AppGroup container
        NSURL *container = safe_containerURL(nil, nil, @"group.com.google.keyboard");
        if (container) {
            NSString *lmDir = [container.path stringByAppendingPathComponent:@"LanguageModels"];
            PopulateOfflineChineseLanguageModelsInDir(lmDir);
        }

        // 2. Setup in local sandbox
        NSString *docBase = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (docBase) {
            NSString *localLmDir = [docBase stringByAppendingPathComponent:@"LanguageModels"];
            PopulateOfflineChineseLanguageModelsInDir(localLmDir);
        }
    } @catch (NSException *e) {
        NSLog(@"[LintypeGboard] Exception in SetupChinese9KeyOfflineAssets: %@", e);
    }
}

static void ConfigureDefault9KeyPreferences(void) {
    @try {
        NSDictionary *zhDict = GetChineseLanguageModelEntryDict();
        NSDictionary *localLmMap = @{@"main:zh_hans_v2": zhDict};

        NSArray *defsList = @[
            [NSUserDefaults standardUserDefaults],
            safe_initWithSuiteName(nil, nil, @"group.com.google.keyboard")
        ];

        for (NSUserDefaults *defs in defsList) {
            if (!defs) continue;

            // Register LocalLanguageModels entry
            NSDictionary *currentLms = [defs dictionaryForKey:@"LocalLanguageModels"];
            if (!currentLms || !currentLms[@"main:zh_hans_v2"]) {
                NSMutableDictionary *newMap = [currentLms mutableCopy] ?: [NSMutableDictionary dictionary];
                newMap[@"main:zh_hans_v2"] = zhDict;
                [defs setObject:[newMap copy] forKey:@"LocalLanguageModels"];
            }

            // Set Simplified Chinese as current language and 9-key as variant
            [defs setObject:@[@"zh_hans"] forKey:@"EnabledLanguages"];
            [defs setObject:@"zh_hans" forKey:@"CurrentLanguage"];
            [defs setObject:@"nine_key_zh_hans" forKey:@"zh_hans_varaint"]; // Google typo compatibility
            [defs setObject:@"nine_key_zh_hans" forKey:@"zh_hans_variant"];
            [defs setBool:YES forKey:@"VoiceInputSetting"];
            [defs synchronize];
        }
    } @catch (NSException *e) {
        NSLog(@"[LintypeGboard] Exception in ConfigureDefault9KeyPreferences: %@", e);
    }
}

#pragma mark - GKBLanguageModelManager Hooks (Never prompt '下载简体中文')

static BOOL (*orig_isLanguageModelAvailable)(id self, SEL _cmd, id lang) = NULL;
static BOOL my_isLanguageModelAvailable(id self, SEL _cmd, id lang) {
    NSString *desc = [[lang description] lowercaseString];
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

static BOOL my_shouldUpdateForLanguage(id self, SEL _cmd, id lang) {
    return NO;
}

static id (*orig_bestAvailableLocalEntryForLanguage)(id self, SEL _cmd, id lang) = NULL;
static id my_bestAvailableLocalEntryForLanguage(id self, SEL _cmd, id lang) {
    id entry = nil;
    if (orig_bestAvailableLocalEntryForLanguage) {
        entry = orig_bestAvailableLocalEntryForLanguage(self, _cmd, lang);
    }
    if (!entry) {
        NSString *desc = [[lang description] lowercaseString];
        if ([desc containsString:@"zh"] || [desc containsString:@"hans"] || [desc containsString:@"pinyin"]) {
            return GetChineseLanguageModelEntryDict();
        }
    }
    return entry;
}

static NSString *(*orig_mainLanguageModelIDForLanguage)(id self, SEL _cmd, id lang) = NULL;
static NSString *my_mainLanguageModelIDForLanguage(id self, SEL _cmd, id lang) {
    NSString *desc = [[lang description] lowercaseString];
    if ([desc containsString:@"zh"] || [desc containsString:@"hans"] || [desc containsString:@"pinyin"]) {
        return @"main:zh_hans_v2";
    }
    if (orig_mainLanguageModelIDForLanguage) {
        return orig_mainLanguageModelIDForLanguage(self, _cmd, lang);
    }
    return @"main:zh_hans_v2";
}

#pragma mark - Main App GKBSettingsViewController Hooks (Safe & Crash-Free)

static void TypelessOpenSettingsAction(UIViewController *vc) {
    if (!vc) return;
    TypelessAppSettingsViewController *settingsVC = [[TypelessAppSettingsViewController alloc] init];
    if (vc.navigationController) {
        [vc.navigationController pushViewController:settingsVC animated:YES];
    } else {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:settingsVC];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        [vc presentViewController:nav animated:YES completion:nil];
    }
}

static const NSInteger kTypelessSettingsBannerTag = 887766;

static void InjectSettingsCardIntoView(UIViewController *vc) {
    if (!vc || !vc.view) return;

    // 1. Add Navigation Bar Right Button (Always accessible)
    if (!vc.navigationItem.rightBarButtonItem) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        [btn setTitle:@"⚙️ AI模型" forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        [btn sizeToFit];
        objc_setAssociatedObject(btn, "typeless_parent_vc", vc, OBJC_ASSOCIATION_ASSIGN);
        [btn addTarget:vc action:@selector(typeless_handleNavBarBtnTap:) forControlEvents:UIControlEventTouchUpInside];
        vc.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:btn];
    }

    // 2. Add Top Banner Card inside TableView if available
    UITableView *tableView = nil;
    for (UIView *sub in vc.view.subviews) {
        if ([sub isKindOfClass:[UITableView class]]) {
            tableView = (UITableView *)sub;
            break;
        }
    }

    if (tableView && ![tableView viewWithTag:kTypelessSettingsBannerTag]) {
        CGFloat cardW = tableView.bounds.size.width > 0 ? (tableView.bounds.size.width - 32) : 340;
        UIView *banner = [[UIView alloc] initWithFrame:CGRectMake(16, 8, cardW, 64)];
        banner.tag = kTypelessSettingsBannerTag;
        banner.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:0.08];
        banner.layer.cornerRadius = 14.0;
        banner.layer.borderWidth = 1.0;
        banner.layer.borderColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:0.25].CGColor;
        banner.layer.masksToBounds = YES;

        // Icon
        UILabel *iconLbl = [[UILabel alloc] initWithFrame:CGRectMake(14, 16, 32, 32)];
        iconLbl.text = @"🤖";
        iconLbl.font = [UIFont systemFontOfSize:24];
        [banner addSubview:iconLbl];

        // Title & Subtitle
        UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(56, 12, cardW - 80, 20)];
        titleLbl.text = @"AI 语音与模型配置";
        titleLbl.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
        titleLbl.textColor = [UIColor colorWithRed:0.05 green:0.4 blue:0.9 alpha:1.0];
        [banner addSubview:titleLbl];

        UILabel *subLbl = [[UILabel alloc] initWithFrame:CGRectMake(56, 34, cardW - 80, 16)];
        subLbl.text = @"OpenAI / DeepSeek / 语音识别与模型";
        subLbl.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
        subLbl.textColor = [UIColor darkGrayColor];
        [banner addSubview:subLbl];

        // Arrow >
        UILabel *arrowLbl = [[UILabel alloc] initWithFrame:CGRectMake(cardW - 24, 22, 16, 20)];
        arrowLbl.text = @">";
        arrowLbl.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        arrowLbl.textColor = [UIColor lightGrayColor];
        [banner addSubview:arrowLbl];

        // Tap Gesture
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:vc action:@selector(typeless_handleCardTap:)];
        [banner addGestureRecognizer:tap];
        banner.userInteractionEnabled = YES;

        UIView *existingHeader = tableView.tableHeaderView;
        if (existingHeader) {
            UIView *wrapHeader = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, existingHeader.bounds.size.height + 76)];
            existingHeader.frame = CGRectMake(0, 0, tableView.bounds.size.width, existingHeader.bounds.size.height);
            [wrapHeader addSubview:existingHeader];
            banner.frame = CGRectMake(16, existingHeader.bounds.size.height + 6, cardW, 64);
            [wrapHeader addSubview:banner];
            tableView.tableHeaderView = wrapHeader;
        } else {
            UIView *headerWrap = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, 80)];
            banner.frame = CGRectMake(16, 8, cardW, 64);
            [headerWrap addSubview:banner];
            tableView.tableHeaderView = headerWrap;
        }
    }
}

static void (*orig_settings_viewWillAppear)(UIViewController *self, SEL _cmd, BOOL animated) = NULL;
static void my_settings_viewWillAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    if (orig_settings_viewWillAppear) {
        orig_settings_viewWillAppear(self, _cmd, animated);
    }
    @try {
        InjectSettingsCardIntoView(self);
    } @catch (NSException *e) {
        NSLog(@"[LintypeGboard] Error injecting settings card: %@", e);
    }
}

static void typeless_handleNavBarBtnTap(id self, SEL _cmd, UIButton *sender) {
    UIViewController *vc = objc_getAssociatedObject(sender, "typeless_parent_vc");
    if (!vc && [self isKindOfClass:[UIViewController class]]) {
        vc = (UIViewController *)self;
    }
    TypelessOpenSettingsAction(vc);
}

static void typeless_handleCardTap(id self, SEL _cmd, UITapGestureRecognizer *gesture) {
    if ([self isKindOfClass:[UIViewController class]]) {
        TypelessOpenSettingsAction((UIViewController *)self);
    }
}

#pragma mark - Gboard UIInputViewController Hooks

static void (*orig_inputVc_viewDidAppear)(UIInputViewController *self, SEL _cmd, BOOL animated) = NULL;
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

static void (*orig_inputVc_viewDidLayoutSubviews)(UIInputViewController *self, SEL _cmd) = NULL;
static void my_inputVc_viewDidLayoutSubviews(UIInputViewController *self, SEL _cmd) {
    if (orig_inputVc_viewDidLayoutSubviews) {
        orig_inputVc_viewDidLayoutSubviews(self, _cmd);
    }
}

static void (*orig_inputVc_viewWillDisappear)(UIInputViewController *self, SEL _cmd, BOOL animated) = NULL;
static void my_inputVc_viewWillDisappear(UIInputViewController *self, SEL _cmd, BOOL animated) {
    @try {
        [[TypelessVoiceManager sharedManager] dismissVoiceOverlayAnimated:NO];
    } @catch (NSException *e) {}

    if (orig_inputVc_viewWillDisappear) {
        orig_inputVc_viewWillDisappear(self, _cmd, animated);
    }
}

#pragma mark - GKBVoiceInputLauncher Hooks

static void (*orig_voiceLauncher_launchVoiceInput)(id self, SEL _cmd) = NULL;
static void my_voiceLauncher_launchVoiceInput(id self, SEL _cmd) {
    @try {
        NSLog(@"[LintypeGboard] GKBVoiceInputLauncher launchVoiceInput triggered!");
        TypelessVoiceManager *mgr = [TypelessVoiceManager sharedManager];
        UIInputViewController *inputVC = mgr.activeInputViewController;

        if (inputVC) {
            [mgr presentVoiceOverlayInViewController:inputVC autoStart:YES];
            return;
        }
    } @catch (NSException *e) {
        NSLog(@"[LintypeGboard] Exception in launchVoiceInput: %@", e);
    }

    if (orig_voiceLauncher_launchVoiceInput) {
        orig_voiceLauncher_launchVoiceInput(self, _cmd);
    }
}

#pragma mark - Constructor

__attribute__((constructor)) static void init_lintype_gboard(void) {
    NSLog(@"[LintypeGboard] Initializing Gboard Typeless AI Mod (Stable & Crash-Free)...");

    // 1. Install AppGroup & NSUserDefaults guards
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

    // 3. Hook GKBLanguageModelManager: offline pinyin support & suppress download prompt
    Class lmManagerCls = objc_getClass("GKBLanguageModelManager");
    if (lmManagerCls) {
        SafeHookInstanceMethod(lmManagerCls, @selector(isLanguageModelAvailableForLanguage:), (IMP)my_isLanguageModelAvailable, (IMP *)&orig_isLanguageModelAvailable);
        SafeHookInstanceMethod(lmManagerCls, @selector(shouldShowLanguageModelUpdatePrompt), (IMP)my_shouldShowLanguageModelUpdatePrompt, NULL);
        SafeHookInstanceMethod(lmManagerCls, @selector(shouldUpdateForLanguage:), (IMP)my_shouldUpdateForLanguage, NULL);
        SafeHookInstanceMethod(lmManagerCls, @selector(bestAvailableLocalEntryForLanguage:), (IMP)my_bestAvailableLocalEntryForLanguage, (IMP *)&orig_bestAvailableLocalEntryForLanguage);
        SafeHookInstanceMethod(lmManagerCls, @selector(mainLanguageModelIDForLanguage:), (IMP)my_mainLanguageModelIDForLanguage, (IMP *)&orig_mainLanguageModelIDForLanguage);
    }

    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    if (![bundlePath hasSuffix:@".appex"]) {
        // --- In Main App (Gboard.app) ---
        Class settingsVcCls = objc_getClass("GKBSettingsViewController");
        if (settingsVcCls) {
            class_addMethod(settingsVcCls, @selector(typeless_handleNavBarBtnTap:), (IMP)typeless_handleNavBarBtnTap, "v@:@");
            class_addMethod(settingsVcCls, @selector(typeless_handleCardTap:), (IMP)typeless_handleCardTap, "v@:@");
            SafeHookInstanceMethod(settingsVcCls, @selector(viewWillAppear:), (IMP)my_settings_viewWillAppear, (IMP *)&orig_settings_viewWillAppear);
        }
        NSLog(@"[LintypeGboard] Main app safe UI hooks installed successfully.");
        return;
    }

    // --- In Keyboard Extension (Gboard.appex) ---
    Class inputVcCls = objc_getClass("GKBUIInputViewController");
    if (inputVcCls) {
        SafeHookInstanceMethod(inputVcCls, @selector(viewDidAppear:), (IMP)my_inputVc_viewDidAppear, (IMP *)&orig_inputVc_viewDidAppear);
        SafeHookInstanceMethod(inputVcCls, @selector(viewDidLayoutSubviews), (IMP)my_inputVc_viewDidLayoutSubviews, (IMP *)&orig_inputVc_viewDidLayoutSubviews);
        SafeHookInstanceMethod(inputVcCls, @selector(viewWillDisappear:), (IMP)my_inputVc_viewWillDisappear, (IMP *)&orig_inputVc_viewWillDisappear);
    }

    Class voiceLauncherCls = objc_getClass("GKBVoiceInputLauncher");
    if (voiceLauncherCls) {
        Method mLaunch = class_getInstanceMethod(voiceLauncherCls, @selector(launchVoiceInput));
        if (mLaunch) {
            orig_voiceLauncher_launchVoiceInput = (void (*)(id, SEL))method_getImplementation(mLaunch);
            method_setImplementation(mLaunch, (IMP)my_voiceLauncher_launchVoiceInput);
        }
    }

    NSLog(@"[LintypeGboard] Keyboard extension hooks installed successfully (No overlap, 9-Key default, Typeless AI Voice)!");
}
