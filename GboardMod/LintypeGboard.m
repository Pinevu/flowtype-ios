#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "TypelessConfig.h"
#import "TypelessVoiceManager.h"
#import "TypelessHostBridge.h"
#import "TypelessAppSettingsViewController.h"

#pragma mark - Safe Runtime Hooking Helpers

static void SafeHookInstanceMethod(Class cls, SEL sel, IMP replacementIMP, IMP _Nullable *outOrigIMP) {
    if (!cls || !sel || !replacementIMP) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP orig = method_getImplementation(m);
    if (outOrigIMP) *outOrigIMP = orig;
    if (!class_addMethod(cls, sel, replacementIMP, method_getTypeEncoding(m))) {
        method_setImplementation(m, replacementIMP);
    }
}

#pragma mark - AppGroup & GKBPreferences Null-Safety Guards

static NSURL *(*orig_containerURL)(id self, SEL _cmd, NSString *groupId) = NULL;
static NSURL *safe_containerURL(id self, SEL _cmd, NSString *groupId) {
    NSURL *url = nil;
    @try {
        if (self && orig_containerURL) {
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

        NSString *safeName = [groupId stringByReplacingOccurrencesOfString:@"/" withString:@"_"] ?: @"default";
        NSString *dir = [base stringByAppendingPathComponent:[NSString stringWithFormat:@"AppGroup_%@", safeName]];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        return [NSURL fileURLWithPath:dir isDirectory:YES];
    } @catch (NSException *e) {
        return [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
    }
}

// Guard GKBPreferences.setUserDefaults: against nil (when ESign strips AppGroup entitlement),
// without swizzling -[NSUserDefaults initWithSuiteName:] under ARC.
static void (*orig_prefs_setUserDefaults)(id self, SEL _cmd, id defs) = NULL;
static void safe_prefs_setUserDefaults(id self, SEL _cmd, NSUserDefaults *defs) {
    if (!defs) {
        defs = [NSUserDefaults standardUserDefaults];
    }
    if (orig_prefs_setUserDefaults) {
        orig_prefs_setUserDefaults(self, _cmd, defs);
    }
}

#pragma mark - Offline Simplified Chinese (zh_hans) Model Helpers

static BOOL IsZhHansLanguage(id lang) {
    if (!lang) return NO;
    @try {
        if ([lang isKindOfClass:[NSString class]]) {
            NSString *s = [(NSString *)lang lowercaseString];
            return [s containsString:@"zh_hans"] || [s containsString:@"zh-hans"];
        }
        if ([lang respondsToSelector:@selector(gboardInternalID)]) {
            NSString *gid = ((id(*)(id, SEL))objc_msgSend)(lang, @selector(gboardInternalID));
            if (gid && [[gid lowercaseString] hasPrefix:@"zh_hans"]) {
                return YES;
            }
        }
        NSString *desc = [[lang description] lowercaseString];
        return [desc containsString:@"zh_hans"] || [desc containsString:@"zh-hans"];
    } @catch (NSException *e) {}
    return NO;
}

static NSString * _Nullable ResolveBundledZhHansLMPath(void) {
    static NSString *cachedPath = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSMutableArray<NSString *> *candidates = [NSMutableArray array];

        Class lmCls = objc_getClass("GKBLanguageModelManager");
        if (lmCls) {
            NSBundle *fwBundle = [NSBundle bundleForClass:lmCls];
            if (fwBundle.bundlePath.length > 0) {
                [candidates addObject:[fwBundle.bundlePath stringByAppendingPathComponent:@"GKBCommonResources.bundle/zh_hans_lm"]];
            }
        }

        NSString *mainPath = [[NSBundle mainBundle] bundlePath];
        if (mainPath.length > 0) {
            [candidates addObject:[mainPath stringByAppendingPathComponent:@"GKBKeyboardResources.bundle/zh_hans_lm"]];
            [candidates addObject:[mainPath stringByAppendingPathComponent:@"Frameworks/gboard_framework.framework/GKBCommonResources.bundle/zh_hans_lm"]];
            [candidates addObject:[mainPath stringByAppendingPathComponent:@"../../Frameworks/gboard_framework.framework/GKBCommonResources.bundle/zh_hans_lm"]];
        }

        for (NSString *cand in candidates) {
            NSString *resolved = [cand stringByStandardizingPath];
            NSString *probe = [resolved stringByAppendingPathComponent:@"zh_t_i0_pinyin/pinyin_system_dictionary"];
            if ([fm fileExistsAtPath:probe]) {
                cachedPath = resolved;
                NSLog(@"[LintypeGboard] Found bundled offline zh_hans LM at %@", resolved);
                break;
            }
        }
    });
    return cachedPath;
}

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

static id _Nullable CreateBundledZhHansResourceEntry(void) {
    NSString *lmPath = ResolveBundledZhHansLMPath();
    if (lmPath.length == 0) return nil;

    Class entryCls = objc_getClass("GKBLanguageResourceEntry");
    if (!entryCls) return nil;

    id entry = nil;
    if ([entryCls respondsToSelector:@selector(entryFromMetaDataEntry:)]) {
        entry = ((id(*)(Class, SEL, id))objc_msgSend)(entryCls, @selector(entryFromMetaDataEntry:), GetChineseLanguageModelEntryDict());
    }
    if (!entry) {
        entry = [[entryCls alloc] init];
    }
    if (!entry) return nil;

    if ([entry respondsToSelector:@selector(setID:)]) {
        ((void(*)(id, SEL, id))objc_msgSend)(entry, @selector(setID:), @"main:zh_hans_v2");
    }
    if ([entry respondsToSelector:@selector(setLocalPath:)]) {
        ((void(*)(id, SEL, id))objc_msgSend)(entry, @selector(setLocalPath:), lmPath);
    }
    if ([entry respondsToSelector:@selector(setVersion:)]) {
        ((void(*)(id, SEL, NSUInteger))objc_msgSend)(entry, @selector(setVersion:), (NSUInteger)13);
    }
    if ([entry respondsToSelector:@selector(setIsBundled:)]) {
        ((void(*)(id, SEL, BOOL))objc_msgSend)(entry, @selector(setIsBundled:), YES);
    }
    return entry;
}

#pragma mark - Offline Chinese Language Model & 9-Key Default Hooks

static id (*orig_bestAvailableLocalEntryForLanguage)(id self, SEL _cmd, id lang) = NULL;
static id my_bestAvailableLocalEntryForLanguage(id self, SEL _cmd, id lang) {
    id entry = nil;
    if (orig_bestAvailableLocalEntryForLanguage) {
        entry = orig_bestAvailableLocalEntryForLanguage(self, _cmd, lang);
    }
    if (IsZhHansLanguage(lang)) {
        BOOL valid = NO;
        if (entry && [entry respondsToSelector:@selector(localPath)]) {
            NSString *lp = ((id(*)(id, SEL))objc_msgSend)(entry, @selector(localPath));
            if (lp.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:[lp stringByAppendingPathComponent:@"zh_t_i0_pinyin/pinyin_system_dictionary"]]) {
                valid = YES;
            }
        }
        if (!valid) {
            id bundledEntry = CreateBundledZhHansResourceEntry();
            if (bundledEntry) return bundledEntry;
        }
    }
    return entry;
}

static NSString *(*orig_mainLanguageModelIDForLanguage)(id self, SEL _cmd, id lang) = NULL;
static NSString *my_mainLanguageModelIDForLanguage(id self, SEL _cmd, id lang) {
    if (IsZhHansLanguage(lang)) {
        return @"main:zh_hans_v2";
    }
    return orig_mainLanguageModelIDForLanguage ? orig_mainLanguageModelIDForLanguage(self, _cmd, lang) : @"main:zh_hans_v2";
}

static BOOL (*orig_shouldUpdateForLanguage)(id self, SEL _cmd, id lang) = NULL;
static BOOL my_shouldUpdateForLanguage(id self, SEL _cmd, id lang) {
    if (IsZhHansLanguage(lang) && ResolveBundledZhHansLMPath() != nil) {
        return NO;
    }
    return orig_shouldUpdateForLanguage ? orig_shouldUpdateForLanguage(self, _cmd, lang) : NO;
}

static BOOL (*orig_dl_isLanguageModelAvailable)(id self, SEL _cmd, id lang) = NULL;
static BOOL my_dl_isLanguageModelAvailable(id self, SEL _cmd, id lang) {
    if (IsZhHansLanguage(lang) && ResolveBundledZhHansLMPath() != nil) {
        return YES;
    }
    return orig_dl_isLanguageModelAvailable ? orig_dl_isLanguageModelAvailable(self, _cmd, lang) : NO;
}

static BOOL (*orig_dl_shouldShowUpdatePrompt)(id self, SEL _cmd) = NULL;
static BOOL my_dl_shouldShowUpdatePrompt(id self, SEL _cmd) {
    if (ResolveBundledZhHansLMPath() != nil) {
        return NO;
    }
    return orig_dl_shouldShowUpdatePrompt ? orig_dl_shouldShowUpdatePrompt(self, _cmd) : NO;
}

static BOOL (*orig_dl_isLanguageResourceAvailable)(id self, SEL _cmd) = NULL;
static BOOL my_dl_isLanguageResourceAvailable(id self, SEL _cmd) {
    if (orig_dl_isLanguageResourceAvailable && orig_dl_isLanguageResourceAvailable(self, _cmd)) {
        return YES;
    }
    Class langIdCls = objc_getClass("GKBLanguageID");
    if (langIdCls && [langIdCls respondsToSelector:@selector(currentLanguage)]) {
        id cur = ((id(*)(Class, SEL))objc_msgSend)(langIdCls, @selector(currentLanguage));
        if (IsZhHansLanguage(cur) && ResolveBundledZhHansLMPath() != nil) {
            return YES;
        }
    }
    return NO;
}

static void (*orig_dl_downloadResourcesForLanguage)(id self, SEL _cmd, id lang) = NULL;
static void my_dl_downloadResourcesForLanguage(id self, SEL _cmd, id lang) {
    if (IsZhHansLanguage(lang) && ResolveBundledZhHansLMPath() != nil) {
        return;
    }
    if (orig_dl_downloadResourcesForLanguage) {
        orig_dl_downloadResourcesForLanguage(self, _cmd, lang);
    }
}

static void (*orig_dl_downloadCurrentIfNecessary)(id self, SEL _cmd) = NULL;
static void my_dl_downloadCurrentIfNecessary(id self, SEL _cmd) {
    Class langIdCls = objc_getClass("GKBLanguageID");
    if (langIdCls && [langIdCls respondsToSelector:@selector(currentLanguage)]) {
        id cur = ((id(*)(Class, SEL))objc_msgSend)(langIdCls, @selector(currentLanguage));
        if (IsZhHansLanguage(cur) && ResolveBundledZhHansLMPath() != nil) {
            return;
        }
    }
    if (orig_dl_downloadCurrentIfNecessary) {
        orig_dl_downloadCurrentIfNecessary(self, _cmd);
    }
}

static BOOL (*orig_layout_isBundled)(id self, SEL _cmd, id lang) = NULL;
static BOOL my_layout_isBundled(id self, SEL _cmd, id lang) {
    if (IsZhHansLanguage(lang)) {
        return YES;
    }
    return orig_layout_isBundled ? orig_layout_isBundled(self, _cmd, lang) : NO;
}

static void EnsureDefaultZhHans9KeyPreferencesIfNeeded(void) {
    static NSString *const kInitFlagKey = @"LintypeZh9KeyInit_v7";
    @try {
        Class prefsCls = objc_getClass("GKBPreferences");
        if (!prefsCls || ![prefsCls respondsToSelector:@selector(sharedInstance)]) return;
        id prefs = ((id(*)(Class, SEL))objc_msgSend)(prefsCls, @selector(sharedInstance));
        if (!prefs) return;

        BOOL alreadyInit = NO;
        if ([prefs respondsToSelector:@selector(boolPreferenceForKey:)]) {
            alreadyInit = ((BOOL(*)(id, SEL, id))objc_msgSend)(prefs, @selector(boolPreferenceForKey:), kInitFlagKey);
        }
        NSArray *enabled = nil;
        if ([prefs respondsToSelector:@selector(arrayPreferenceForKey:)]) {
            enabled = ((id(*)(id, SEL, id))objc_msgSend)(prefs, @selector(arrayPreferenceForKey:), @"EnabledLanguages");
        }

        if (!alreadyInit || enabled.count == 0) {
            if ([prefs respondsToSelector:@selector(setObjectPreferenceWithValue:forKey:)]) {
                ((void(*)(id, SEL, id, id))objc_msgSend)(prefs, @selector(setObjectPreferenceWithValue:forKey:), @[@"zh_hans"], @"EnabledLanguages");
                ((void(*)(id, SEL, id, id))objc_msgSend)(prefs, @selector(setObjectPreferenceWithValue:forKey:), @"zh_hans", @"CurrentLanguage");
                ((void(*)(id, SEL, id, id))objc_msgSend)(prefs, @selector(setObjectPreferenceWithValue:forKey:), @"nine_key_zh_hans", @"zh_hans_varaint");
                ((void(*)(id, SEL, id, id))objc_msgSend)(prefs, @selector(setObjectPreferenceWithValue:forKey:), @"nine_key_zh_hans", @"zh_hans_variant");
            }
            if ([prefs respondsToSelector:@selector(setBoolPreferenceWithValue:forKey:)]) {
                ((void(*)(id, SEL, BOOL, id))objc_msgSend)(prefs, @selector(setBoolPreferenceWithValue:forKey:), YES, @"VoiceInputSetting");
                ((void(*)(id, SEL, BOOL, id))objc_msgSend)(prefs, @selector(setBoolPreferenceWithValue:forKey:), YES, kInitFlagKey);
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[LintypeGboard] EnsureDefaultZhHans9KeyPreferencesIfNeeded error: %@", e);
    }
}

static id (*orig_langMgr_defaultEnabledLanguage)(id self, SEL _cmd) = NULL;
static id my_langMgr_defaultEnabledLanguage(id self, SEL _cmd) {
    Class langIdCls = objc_getClass("GKBLanguageID");
    if (langIdCls && [langIdCls respondsToSelector:@selector(languageIDFromString:)]) {
        id zh = ((id(*)(Class, SEL, id))objc_msgSend)(langIdCls, @selector(languageIDFromString:), @"zh_hans");
        if (zh) return zh;
    }
    return orig_langMgr_defaultEnabledLanguage ? orig_langMgr_defaultEnabledLanguage(self, _cmd) : nil;
}

static void (*orig_langMgr_reloadData)(id self, SEL _cmd) = NULL;
static void my_langMgr_reloadData(id self, SEL _cmd) {
    EnsureDefaultZhHans9KeyPreferencesIfNeeded();
    if (orig_langMgr_reloadData) {
        orig_langMgr_reloadData(self, _cmd);
    }
}

static id (*orig_langMgr_enabledVariant)(id self, SEL _cmd, id lang) = NULL;
static id my_langMgr_enabledVariant(id self, SEL _cmd, id lang) {
    id res = orig_langMgr_enabledVariant ? orig_langMgr_enabledVariant(self, _cmd, lang) : nil;
    if ((!res || ![res isKindOfClass:[NSString class]] || [(NSString *)res length] == 0) && IsZhHansLanguage(lang)) {
        return @"nine_key_zh_hans";
    }
    return res;
}

#pragma mark - Main App GKBSettingsViewController Native Integration (Crash-Free)

static NSString *const kAIVoiceSettingKey = @"SettingsMenuItemAIVoice";

static id (*orig_settings_mainMenuPageDescriptor)(id self, SEL _cmd) = NULL;
static id my_settings_mainMenuPageDescriptor(id self, SEL _cmd) {
    id page = orig_settings_mainMenuPageDescriptor ? orig_settings_mainMenuPageDescriptor(self, _cmd) : nil;
    @try {
        Class itemCls = objc_getClass("GKBSettingsItem");
        Class sectionCls = objc_getClass("GKBSettingsSection");
        if (!page || !itemCls || !sectionCls) return page;

        SEL menuSel = @selector(menuWithTitle:accessibilityIdentifier:key:);
        SEL secSel = @selector(sectionWithRows:);
        if (![itemCls respondsToSelector:menuSel] || ![sectionCls respondsToSelector:secSel]) return page;

        id aiItem = ((id(*)(Class, SEL, id, id, id))objc_msgSend)(
            itemCls, menuSel, @"AI 语音与模型设置", kAIVoiceSettingKey, kAIVoiceSettingKey
        );
        if (!aiItem) return page;

        id aiSection = ((id(*)(Class, SEL, id))objc_msgSend)(sectionCls, secSel, @[aiItem]);
        if (!aiSection) return page;

        NSArray *existing = [page respondsToSelector:@selector(sections)] ? ((id(*)(id, SEL))objc_msgSend)(page, @selector(sections)) : nil;
        NSMutableArray *updated = existing ? [existing mutableCopy] : [NSMutableArray array];

        // Place cleanly at index 0 (or after onboarding full-access prompt if present)
        NSUInteger insertIdx = 0;
        if (updated.count > 0) {
            id firstSec = updated[0];
            NSArray *firstRows = [firstSec respondsToSelector:@selector(rows)] ? ((id(*)(id, SEL))objc_msgSend)(firstSec, @selector(rows)) : nil;
            id firstRow = firstRows.firstObject;
            NSString *firstKey = [firstRow respondsToSelector:@selector(key)] ? ((id(*)(id, SEL))objc_msgSend)(firstRow, @selector(key)) : nil;
            if ([firstKey isEqualToString:@"SettingsMenuItemTutorials"] || [firstKey isEqualToString:@"SettingsMenuItemEnableFullAccess"]) {
                insertIdx = 1;
            }
        }
        [updated insertObject:aiSection atIndex:MIN(insertIdx, updated.count)];

        if ([page respondsToSelector:@selector(setSections:)]) {
            ((void(*)(id, SEL, id))objc_msgSend)(page, @selector(setSections:), updated);
        }
    } @catch (NSException *e) {
        NSLog(@"[LintypeGboard] Error injecting native menu item: %@", e);
    }
    return page;
}

static void TypelessPushSettingsFromVC(UIViewController *vc) {
    if (!vc) return;
    TypelessAppSettingsViewController *settingsVC = [[TypelessAppSettingsViewController alloc] init];
    if (vc.navigationController) {
        [vc.navigationController pushViewController:settingsVC animated:YES];
    } else if ([vc respondsToSelector:@selector(pushController:animated:)]) {
        ((void(*)(id, SEL, id, BOOL))objc_msgSend)(vc, @selector(pushController:animated:), settingsVC, YES);
    } else {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:settingsVC];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        [vc presentViewController:nav animated:YES completion:nil];
    }
}

// Exact ObjC signature: v40@0:8@16q24@32 (param2 is NSInteger settingID!)
static void (*orig_settings_didSelectSetting)(id self, SEL _cmd, id vc, NSInteger settingID, id url) = NULL;
static void my_settings_didSelectSetting(id self, SEL _cmd, id vc, NSInteger settingID, id url) {
    @try {
        Class itemCls = objc_getClass("GKBSettingsItem");
        if (itemCls && [itemCls respondsToSelector:@selector(itemForID:)]) {
            id item = ((id(*)(Class, SEL, NSInteger))objc_msgSend)(itemCls, @selector(itemForID:), settingID);
            NSString *key = [item respondsToSelector:@selector(key)] ? ((id(*)(id, SEL))objc_msgSend)(item, @selector(key)) : nil;
            if ([key isEqualToString:kAIVoiceSettingKey]) {
                TypelessPushSettingsFromVC([self isKindOfClass:[UIViewController class]] ? (UIViewController *)self : nil);
                return;
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[LintypeGboard] Exception in didSelectSetting: %@", e);
    }

    if (orig_settings_didSelectSetting) {
        orig_settings_didSelectSetting(self, _cmd, vc, settingID, url);
    }
}

#pragma mark - Main App AppDelegate Hooks (Audio Keep-Alive & URL Scheme)

static BOOL (*orig_appDelegate_didFinishLaunching)(id self, SEL _cmd, id app, id opts) = NULL;
static BOOL my_appDelegate_didFinishLaunching(id self, SEL _cmd, UIApplication *app, NSDictionary *opts) {
    BOOL res = orig_appDelegate_didFinishLaunching ? orig_appDelegate_didFinishLaunching(self, _cmd, app, opts) : YES;
    @try {
        [[TypelessHostBridge sharedBridge] configureHostObservers];
    } @catch (NSException *e) {}
    return res;
}

static BOOL (*orig_appDelegate_openURL)(id self, SEL _cmd, id app, id url, id opts) = NULL;
static BOOL my_appDelegate_openURL(id self, SEL _cmd, UIApplication *app, NSURL *url, NSDictionary *opts) {
    @try {
        if ([[TypelessHostBridge sharedBridge] handleHostOpenURL:url]) {
            return YES;
        }
    } @catch (NSException *e) {}
    return orig_appDelegate_openURL ? orig_appDelegate_openURL(self, _cmd, app, url, opts) : NO;
}

#pragma mark - Keyboard Extension Hooks

static void (*orig_inputVc_viewDidAppear)(UIInputViewController *self, SEL _cmd, BOOL animated) = NULL;
static void my_inputVc_viewDidAppear(UIInputViewController *self, SEL _cmd, BOOL animated) {
    if (orig_inputVc_viewDidAppear) {
        orig_inputVc_viewDidAppear(self, _cmd, animated);
    }
    @try {
        [[TypelessConfig sharedConfig] load];
        [TypelessVoiceManager sharedManager].activeInputViewController = self;
    } @catch (NSException *e) {}
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

static void (*orig_voiceLauncher_launchVoiceInput)(id self, SEL _cmd) = NULL;
static void my_voiceLauncher_launchVoiceInput(id self, SEL _cmd) {
    @try {
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

#pragma mark - Constructor (Lightweight Swizzles Only)

__attribute__((constructor)) static void init_lintype_gboard(void) {
    NSLog(@"[LintypeGboard] Initializing v1.0.7 lightweight safe hooks...");

    // 1. Safe AppGroup container & GKBPreferences null-safety (NO init-method ARC bugs)
    SafeHookInstanceMethod([NSFileManager class],
                           @selector(containerURLForSecurityApplicationGroupIdentifier:),
                           (IMP)safe_containerURL,
                           (IMP *)&orig_containerURL);

    Class prefsCls = objc_getClass("GKBPreferences");
    if (prefsCls) {
        SafeHookInstanceMethod(prefsCls, @selector(setUserDefaults:), (IMP)safe_prefs_setUserDefaults, (IMP *)&orig_prefs_setUserDefaults);
    }

    // 2. Offline Simplified Chinese LM & Downloader hooks
    Class lmMgrCls = objc_getClass("GKBLanguageModelManager");
    if (lmMgrCls) {
        SafeHookInstanceMethod(lmMgrCls, @selector(bestAvailableLocalEntryForLanguage:), (IMP)my_bestAvailableLocalEntryForLanguage, (IMP *)&orig_bestAvailableLocalEntryForLanguage);
        SafeHookInstanceMethod(lmMgrCls, @selector(mainLanguageModelIDForLanguage:), (IMP)my_mainLanguageModelIDForLanguage, (IMP *)&orig_mainLanguageModelIDForLanguage);
        SafeHookInstanceMethod(lmMgrCls, @selector(shouldUpdateForLanguage:), (IMP)my_shouldUpdateForLanguage, (IMP *)&orig_shouldUpdateForLanguage);
    }

    Class dlCls = objc_getClass("GKBLanguageDownloader");
    if (dlCls) {
        SafeHookInstanceMethod(dlCls, @selector(isLanguageModelAvailableForLanguage:), (IMP)my_dl_isLanguageModelAvailable, (IMP *)&orig_dl_isLanguageModelAvailable);
        SafeHookInstanceMethod(dlCls, @selector(shouldShowLanguageModelUpdatePrompt), (IMP)my_dl_shouldShowUpdatePrompt, (IMP *)&orig_dl_shouldShowUpdatePrompt);
        SafeHookInstanceMethod(dlCls, @selector(isLanguageResourceAvailable), (IMP)my_dl_isLanguageResourceAvailable, (IMP *)&orig_dl_isLanguageResourceAvailable);
        SafeHookInstanceMethod(dlCls, @selector(downloadResourcesForLanguage:), (IMP)my_dl_downloadResourcesForLanguage, (IMP *)&orig_dl_downloadResourcesForLanguage);
        SafeHookInstanceMethod(dlCls, @selector(downloadCurrentLanguageResourceIfNecessary), (IMP)my_dl_downloadCurrentIfNecessary, (IMP *)&orig_dl_downloadCurrentIfNecessary);
    }

    Class layoutMgrCls = objc_getClass("GKBLanguageLayoutManager");
    if (layoutMgrCls) {
        SafeHookInstanceMethod(layoutMgrCls, @selector(isLayoutBundledForLanguage:), (IMP)my_layout_isBundled, (IMP *)&orig_layout_isBundled);
    }

    Class langMgrCls = objc_getClass("GKBLanguageManager");
    if (langMgrCls) {
        SafeHookInstanceMethod(langMgrCls, @selector(defaultEnabledLanguage), (IMP)my_langMgr_defaultEnabledLanguage, (IMP *)&orig_langMgr_defaultEnabledLanguage);
        SafeHookInstanceMethod(langMgrCls, @selector(reloadData), (IMP)my_langMgr_reloadData, (IMP *)&orig_langMgr_reloadData);
        SafeHookInstanceMethod(langMgrCls, @selector(enabledKeyboardVariantForLanguage:), (IMP)my_langMgr_enabledVariant, (IMP *)&orig_langMgr_enabledVariant);
    }

    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    if (![bundlePath hasSuffix:@".appex"]) {
        // --- Main App (Gboard.app) ---
        Class settingsVcCls = objc_getClass("GKBSettingsViewController");
        if (settingsVcCls) {
            SafeHookInstanceMethod(settingsVcCls, @selector(mainMenuPageDescriptor), (IMP)my_settings_mainMenuPageDescriptor, (IMP *)&orig_settings_mainMenuPageDescriptor);
            SafeHookInstanceMethod(settingsVcCls, @selector(viewController:didSelectSetting:URL:), (IMP)my_settings_didSelectSetting, (IMP *)&orig_settings_didSelectSetting);
        }

        Class appDelCls = objc_getClass("AppDelegate");
        if (appDelCls) {
            SafeHookInstanceMethod(appDelCls, @selector(application:didFinishLaunchingWithOptions:), (IMP)my_appDelegate_didFinishLaunching, (IMP *)&orig_appDelegate_didFinishLaunching);
            SafeHookInstanceMethod(appDelCls, @selector(application:openURL:options:), (IMP)my_appDelegate_openURL, (IMP *)&orig_appDelegate_openURL);
        }
        return;
    }

    // --- Keyboard Extension (Gboard.appex) ---
    Class inputVcCls = objc_getClass("GKBUIInputViewController");
    if (inputVcCls) {
        SafeHookInstanceMethod(inputVcCls, @selector(viewDidAppear:), (IMP)my_inputVc_viewDidAppear, (IMP *)&orig_inputVc_viewDidAppear);
        SafeHookInstanceMethod(inputVcCls, @selector(viewWillDisappear:), (IMP)my_inputVc_viewWillDisappear, (IMP *)&orig_inputVc_viewWillDisappear);
    }

    Class voiceLauncherCls = objc_getClass("GKBVoiceInputLauncher");
    if (voiceLauncherCls) {
        SafeHookInstanceMethod(voiceLauncherCls, @selector(launchVoiceInput), (IMP)my_voiceLauncher_launchVoiceInput, (IMP *)&orig_voiceLauncher_launchVoiceInput);
    }
}
