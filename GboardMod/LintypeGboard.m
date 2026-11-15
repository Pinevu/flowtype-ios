#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
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

static NSString *const kUserChoseLanguageKey = @"LintypeUserChoseLanguage_v8";
static NSString *const kUserChoseZhVariantKey = @"LintypeUserChoseZhVariant_v8";
static BOOL sInAutoVariantFallback = NO;

static id CreateZhHansLanguageID(void) {
    Class langIdCls = objc_getClass("GKBLanguageID");
    if (langIdCls && [langIdCls respondsToSelector:@selector(languageIDFromString:)]) {
        return ((id(*)(Class, SEL, id))objc_msgSend)(langIdCls, @selector(languageIDFromString:), @"zh_hans");
    }
    return nil;
}

static void EnsureDefaultZhHans9KeyPreferencesIfNeeded(void) {
    static NSString *const kInitFlagKey = @"LintypeZh9KeyInit_v8";
    @try {
        Class prefsCls = objc_getClass("GKBPreferences");
        if (!prefsCls || ![prefsCls respondsToSelector:@selector(sharedInstance)]) return;
        id prefs = ((id(*)(Class, SEL))objc_msgSend)(prefsCls, @selector(sharedInstance));
        if (!prefs) return;

        BOOL alreadyInit = NO;
        if ([prefs respondsToSelector:@selector(boolPreferenceForKey:)]) {
            alreadyInit = ((BOOL(*)(id, SEL, id))objc_msgSend)(prefs, @selector(boolPreferenceForKey:), kInitFlagKey);
        }
        NSUserDefaults *std = [NSUserDefaults standardUserDefaults];
        BOOL stdInit = [std boolForKey:kInitFlagKey];

        NSArray *enabled = nil;
        if ([prefs respondsToSelector:@selector(arrayPreferenceForKey:)]) {
            enabled = ((id(*)(id, SEL, id))objc_msgSend)(prefs, @selector(arrayPreferenceForKey:), @"EnabledLanguages");
        }
        BOOL hasZhHans = NO;
        for (id item in enabled) {
            if (IsZhHansLanguage(item)) {
                hasZhHans = YES;
                break;
            }
        }

        NSString *curLang = nil;
        if ([prefs respondsToSelector:@selector(stringPreferenceForKey:)]) {
            curLang = ((id(*)(id, SEL, id))objc_msgSend)(prefs, @selector(stringPreferenceForKey:), @"CurrentLanguage");
        }
        BOOL userChoseLang = [std boolForKey:kUserChoseLanguageKey];

        if (!alreadyInit || !stdInit || !hasZhHans || (!userChoseLang && !IsZhHansLanguage(curLang))) {
            NSMutableArray *newEnabled = [NSMutableArray arrayWithObject:@"zh_hans"];
            for (id item in enabled) {
                if ([item isKindOfClass:[NSString class]] && !IsZhHansLanguage(item)) {
                    [newEnabled addObject:item];
                }
            }
            if (![newEnabled containsObject:@"en_us"]) {
                [newEnabled addObject:@"en_us"];
            }

            if ([prefs respondsToSelector:@selector(setObjectPreferenceWithValue:forKey:)]) {
                ((void(*)(id, SEL, id, id))objc_msgSend)(prefs, @selector(setObjectPreferenceWithValue:forKey:), newEnabled, @"EnabledLanguages");
                ((void(*)(id, SEL, id, id))objc_msgSend)(prefs, @selector(setObjectPreferenceWithValue:forKey:), @"zh_hans", @"CurrentLanguage");
                ((void(*)(id, SEL, id, id))objc_msgSend)(prefs, @selector(setObjectPreferenceWithValue:forKey:), @"nine_key_zh_hans", @"zh_hans_varaint");
                ((void(*)(id, SEL, id, id))objc_msgSend)(prefs, @selector(setObjectPreferenceWithValue:forKey:), @"nine_key_zh_hans", @"zh_hans_variant");
            }
            if ([prefs respondsToSelector:@selector(setBoolPreferenceWithValue:forKey:)]) {
                ((void(*)(id, SEL, BOOL, id))objc_msgSend)(prefs, @selector(setBoolPreferenceWithValue:forKey:), NO, @"AlwaysUseSystemPreferredLanguage");
                ((void(*)(id, SEL, BOOL, id))objc_msgSend)(prefs, @selector(setBoolPreferenceWithValue:forKey:), YES, @"VoiceInputSetting");
                ((void(*)(id, SEL, BOOL, id))objc_msgSend)(prefs, @selector(setBoolPreferenceWithValue:forKey:), YES, kInitFlagKey);
            }

            [std setObject:newEnabled forKey:@"EnabledLanguages"];
            [std setObject:@"zh_hans" forKey:@"CurrentLanguage"];
            [std setObject:@"nine_key_zh_hans" forKey:@"zh_hans_varaint"];
            [std setObject:@"nine_key_zh_hans" forKey:@"zh_hans_variant"];
            [std setBool:YES forKey:kInitFlagKey];
            [std synchronize];
        }

        Class curLangMgrCls = objc_getClass("GKBCurrentLanguageManager");
        if (curLangMgrCls && [curLangMgrCls respondsToSelector:@selector(sharedInstance)]) {
            id clm = ((id(*)(Class, SEL))objc_msgSend)(curLangMgrCls, @selector(sharedInstance));
            if (clm && [clm respondsToSelector:@selector(setAlwaysUseSystemPreferredLanguage:)]) {
                ((void(*)(id, SEL, BOOL))objc_msgSend)(clm, @selector(setAlwaysUseSystemPreferredLanguage:), NO);
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[LintypeGboard] EnsureDefaultZhHans9KeyPreferencesIfNeeded error: %@", e);
    }
}

static BOOL (*orig_curLangMgr_alwaysSystem)(id self, SEL _cmd) = NULL;
static BOOL my_curLangMgr_alwaysSystem(id self, SEL _cmd) {
    return NO;
}

static BOOL (*orig_langMgr_alwaysSystem)(id self, SEL _cmd) = NULL;
static BOOL my_langMgr_alwaysSystem(id self, SEL _cmd) {
    return NO;
}

static id (*orig_langMgr_defaultEnabledLanguage)(id self, SEL _cmd) = NULL;
static id my_langMgr_defaultEnabledLanguage(id self, SEL _cmd) {
    id zh = CreateZhHansLanguageID();
    if (zh) return zh;
    return orig_langMgr_defaultEnabledLanguage ? orig_langMgr_defaultEnabledLanguage(self, _cmd) : nil;
}

static id (*orig_langMgr_currentLanguage)(id self, SEL _cmd) = NULL;
static id my_langMgr_currentLanguage(id self, SEL _cmd) {
    id res = orig_langMgr_currentLanguage ? orig_langMgr_currentLanguage(self, _cmd) : nil;
    if (![[NSUserDefaults standardUserDefaults] boolForKey:kUserChoseLanguageKey]) {
        if (!res || !IsZhHansLanguage(res)) {
            id zh = CreateZhHansLanguageID();
            if (zh) return zh;
        }
    }
    return res;
}

static void (*orig_langMgr_setCurrentLanguage)(id self, SEL _cmd, id lang) = NULL;
static void my_langMgr_setCurrentLanguage(id self, SEL _cmd, id lang) {
    if (lang && !IsZhHansLanguage(lang)) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kUserChoseLanguageKey];
    }
    if (orig_langMgr_setCurrentLanguage) {
        orig_langMgr_setCurrentLanguage(self, _cmd, lang);
    }
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
    sInAutoVariantFallback = YES;
    id res = orig_langMgr_enabledVariant ? orig_langMgr_enabledVariant(self, _cmd, lang) : nil;
    sInAutoVariantFallback = NO;

    if (IsZhHansLanguage(lang)) {
        BOOL userChoseVar = [[NSUserDefaults standardUserDefaults] boolForKey:kUserChoseZhVariantKey];
        if (!res || ![res isKindOfClass:[NSString class]] || [(NSString *)res length] == 0 ||
            (!userChoseVar && ![(NSString *)res isEqualToString:@"nine_key_zh_hans"])) {
            return @"nine_key_zh_hans";
        }
    }
    return res;
}

static void (*orig_langMgr_setEnabledVariant)(id self, SEL _cmd, id variant, id lang) = NULL;
static void my_langMgr_setEnabledVariant(id self, SEL _cmd, id variant, id lang) {
    if (!sInAutoVariantFallback && IsZhHansLanguage(lang) && [variant isKindOfClass:[NSString class]]) {
        if (![(NSString *)variant isEqualToString:@"nine_key_zh_hans"]) {
            [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kUserChoseZhVariantKey];
        }
    }
    if (orig_langMgr_setEnabledVariant) {
        orig_langMgr_setEnabledVariant(self, _cmd, variant, lang);
    }
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
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:settingsVC];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    UIViewController *presenter = vc.navigationController ?: vc;
    [presenter presentViewController:nav animated:YES completion:nil];
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

#pragma mark - Keyboard Extension UI, iOS Native 9-Key Style & Inline Controls

typedef NS_ENUM(NSInteger, LintypeKeyRole) {
    LintypeKeyRoleIgnore = 0,
    LintypeKeyRolePrimary = 1,
    LintypeKeyRoleFunction = 2,
    LintypeKeyRoleReturn = 3
};

typedef NS_ENUM(NSInteger, LintypeKeyAction) {
    LintypeKeyActionNone = 0,
    LintypeKeyActionVoice = 1,
    LintypeKeyActionSwitchToEnglish = 2,
    LintypeKeyActionSwitchToChinese = 3
};

static const void *kKeyPosIdAssocKey = &kKeyPosIdAssocKey;
static const void *kKeyActionAssocKey = &kKeyActionAssocKey;
static const void *kKeyBasePadAssocKey = &kKeyBasePadAssocKey;
static const void *kKeySpaceExtraPadAssocKey = &kKeySpaceExtraPadAssocKey;
static const void *kKeyLastShadowSizeAssocKey = &kKeyLastShadowSizeAssocKey;
static const void *kKeyThemeSigAssocKey = &kKeyThemeSigAssocKey;
static const void *kKeyHighlightStateAssocKey = &kKeyHighlightStateAssocKey;
static const void *kBadgeStateSigAssocKey = &kBadgeStateSigAssocKey;

static NSInteger const kCustomKeyContentTag = 99510;
static NSInteger const kInlineLangBtnTag = 99511;
static NSInteger const kInlineVoiceBtnTag = 99512;

static BOOL sAppliedLaunchInterfaceThisAppear = NO;
static NSMapTable<UITouch *, UIView *> *sActiveCustomTouches = nil;

static NSString * _Nullable ExtractViewTextRecursively(UIView *view, NSInteger depth) {
    if (!view || depth > 5 || view.tag == kCustomKeyContentTag) return nil;
    if ([view isKindOfClass:[UILabel class]]) {
        NSString *t = ((UILabel *)view).text;
        if (t.length > 0) return t;
    }
    for (UIView *sub in view.subviews) {
        NSString *t = ExtractViewTextRecursively(sub, depth + 1);
        if (t.length > 0) return t;
    }
    return nil;
}

static void HideOriginalKeyContentsRecursively(UIView *view, UIView *keepRoot, NSInteger depth) {
    if (!view || depth > 5 || view.tag == kCustomKeyContentTag) return;
    if (view != keepRoot) {
        if ([view isKindOfClass:[UILabel class]]) {
            ((UILabel *)view).alpha = 0.0;
        } else if ([view isKindOfClass:[UIImageView class]]) {
            ((UIImageView *)view).alpha = 0.0;
        }
    } else {
        if ([view isKindOfClass:[UILabel class]]) {
            ((UILabel *)view).text = @"";
        } else if ([view isKindOfClass:[UIImageView class]]) {
            ((UIImageView *)view).image = nil;
        }
    }
    for (UIView *sub in view.subviews) {
        HideOriginalKeyContentsRecursively(sub, keepRoot, depth + 1);
    }
}

static void RestoreOriginalKeyContentsRecursively(UIView *view, NSInteger depth) {
    if (!view || depth > 5 || view.tag == kCustomKeyContentTag) return;
    if ([view isKindOfClass:[UILabel class]] || [view isKindOfClass:[UIImageView class]]) {
        if (view.alpha < 0.99) view.alpha = 1.0;
    }
    for (UIView *sub in view.subviews) {
        RestoreOriginalKeyContentsRecursively(sub, depth + 1);
    }
}

static void ApplyForegroundColorRecursively(UIView *view, UIColor *fg, NSInteger depth) {
    if (!view || depth > 5 || view.tag == kCustomKeyContentTag) return;
    if ([view respondsToSelector:@selector(setForegroundColor:)]) {
        ((void(*)(id, SEL, id))objc_msgSend)(view, @selector(setForegroundColor:), fg);
    }
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *lbl = (UILabel *)view;
        if (![lbl.textColor isEqual:fg]) {
            lbl.textColor = fg;
        }
    } else if ([view isKindOfClass:[UIImageView class]]) {
        if (![view.tintColor isEqual:fg]) {
            view.tintColor = fg;
        }
    }
    for (UIView *sub in view.subviews) {
        ApplyForegroundColorRecursively(sub, fg, depth + 1);
    }
}

static BOOL IsKeyboardDarkAppearance(UIView * _Nullable refView) {
    UIInputViewController *vc = [TypelessVoiceManager sharedManager].activeInputViewController;
    if (vc) {
        UIKeyboardAppearance app = vc.textDocumentProxy.keyboardAppearance;
        if (app == UIKeyboardAppearanceDark) return YES;
        if (app == UIKeyboardAppearanceLight) return NO;
    }
    if (@available(iOS 13.0, *)) {
        UIView *check = refView ?: vc.view;
        if (check && check.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return YES;
        }
    }
    return NO;
}

static UIColor *IOSKeyboardBgColor(BOOL dark) {
    return dark
        ? [UIColor colorWithRed:0.110 green:0.110 blue:0.118 alpha:1.0]  // #1C1C1E
        : [UIColor colorWithRed:0.820 green:0.831 blue:0.851 alpha:1.0]; // #D1D4D9
}

static UIColor *IOSKeyBgColor(LintypeKeyRole role, BOOL dark, BOOL highlighted) {
    switch (role) {
        case LintypeKeyRoleReturn:
            if (dark) {
                return highlighted
                    ? [UIColor colorWithRed:0.000 green:0.376 blue:0.875 alpha:1.0]
                    : [UIColor colorWithRed:0.039 green:0.518 blue:1.000 alpha:1.0]; // #0A84FF
            }
            return highlighted
                ? [UIColor colorWithRed:0.000 green:0.384 blue:0.800 alpha:1.0]
                : [UIColor colorWithRed:0.000 green:0.478 blue:1.000 alpha:1.0]; // #007AFF
        case LintypeKeyRoleFunction:
            if (dark) {
                return highlighted
                    ? [UIColor colorWithRed:0.329 green:0.329 blue:0.345 alpha:1.0]
                    : [UIColor colorWithRed:0.227 green:0.227 blue:0.235 alpha:1.0]; // #3A3A3C
            }
            return highlighted
                ? [UIColor colorWithRed:0.580 green:0.604 blue:0.651 alpha:1.0]
                : [UIColor colorWithRed:0.675 green:0.694 blue:0.733 alpha:1.0]; // #ACB1BB
        case LintypeKeyRolePrimary:
        default:
            if (dark) {
                return highlighted
                    ? [UIColor colorWithRed:0.282 green:0.282 blue:0.290 alpha:1.0]
                    : [UIColor colorWithRed:0.388 green:0.388 blue:0.400 alpha:1.0]; // #636366
            }
            return highlighted
                ? [UIColor colorWithRed:0.824 green:0.839 blue:0.871 alpha:1.0]
                : [UIColor colorWithWhite:1.0 alpha:1.0];                          // #FFFFFF
    }
}

static UIColor *IOSKeyFgColor(LintypeKeyRole role, BOOL dark) {
    if (role == LintypeKeyRoleReturn) return [UIColor whiteColor];
    return dark ? [UIColor whiteColor] : [UIColor blackColor];
}

static LintypeKeyRole RoleForKeyPosId(NSString * _Nullable keyId, LintypeKeyAction action) {
    if (action != LintypeKeyActionNone) {
        return LintypeKeyRoleFunction;
    }
    if (![keyId isKindOfClass:[NSString class]] || keyId.length == 0) {
        return LintypeKeyRoleIgnore;
    }
    if (![keyId hasPrefix:@"key_pos_"] ||
        [keyId hasPrefix:@"key_pos_candidate"] ||
        [keyId hasPrefix:@"key_pos_menu"]) {
        return LintypeKeyRoleIgnore;
    }
    if ([keyId isEqualToString:@"key_pos_9keys_return"] ||
        [keyId isEqualToString:@"key_pos_action"] ||
        [keyId isEqualToString:@"key_pos_small_return"] ||
        [keyId isEqualToString:@"key_pos_twitter_action"] ||
        [keyId isEqualToString:@"key_pos_websearch_action"]) {
        return LintypeKeyRoleReturn;
    }
    if ([keyId isEqualToString:@"key_pos_9keys_left_1"] ||
        [keyId isEqualToString:@"key_pos_9keys_left_2"] ||
        [keyId isEqualToString:@"key_pos_9keys_left_3"] ||
        [keyId isEqualToString:@"key_pos_9keys_left_4"] ||
        [keyId isEqualToString:@"key_pos_9keys_del"] ||
        [keyId isEqualToString:@"key_pos_9keys_emoji"] ||
        [keyId isEqualToString:@"key_pos_9keys_symbols"] ||
        [keyId isEqualToString:@"key_pos_shift"] ||
        [keyId isEqualToString:@"key_pos_shift_right"] ||
        [keyId isEqualToString:@"key_pos_del"] ||
        [keyId isEqualToString:@"key_pos_switch_to_symbol"] ||
        [keyId isEqualToString:@"key_pos_switch_to_symbol_right"] ||
        [keyId isEqualToString:@"key_pos_switch_to_digit"] ||
        [keyId isEqualToString:@"key_pos_switch_to_prime"] ||
        [keyId isEqualToString:@"key_pos_globe"] ||
        [keyId isEqualToString:@"key_pos_emoji"] ||
        [keyId isEqualToString:@"key_pos_hide_keyboard"] ||
        [keyId isEqualToString:@"key_pos_one_hand_mode"] ||
        [keyId hasSuffix:@"_left"] ||
        [keyId hasPrefix:@"key_pos_4_left"] ||
        [keyId hasPrefix:@"key_pos_5_left"] ||
        [keyId isEqualToString:@"key_pos_1_right"] ||
        [keyId isEqualToString:@"key_pos_2_right"] ||
        [keyId isEqualToString:@"key_pos_3_right"] ||
        [keyId isEqualToString:@"key_pos_4_right"]) {
        return LintypeKeyRoleFunction;
    }
    return LintypeKeyRolePrimary;
}

static void ExecuteCustomKeyAction(LintypeKeyAction action) {
    @try {
        UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [haptic impactOccurred];
    } @catch (NSException *e) {}

    if (action == LintypeKeyActionVoice) {
        TypelessVoiceManager *mgr = [TypelessVoiceManager sharedManager];
        UIInputViewController *inputVC = mgr.activeInputViewController;
        if (inputVC) {
            // Never auto-record when switching to voice view; wait for manual user tap/hold.
            [mgr presentVoiceOverlayInViewController:inputVC autoStart:NO];
        }
        return;
    }

    NSString *targetLangStr = (action == LintypeKeyActionSwitchToEnglish) ? @"en_us" : @"zh_hans";
    @try {
        Class langIdCls = objc_getClass("GKBLanguageID");
        Class langMgrCls = objc_getClass("GKBLanguageManager");
        if (!langIdCls || ![langIdCls respondsToSelector:@selector(languageIDFromString:)]) return;
        id targetLang = ((id(*)(Class, SEL, id))objc_msgSend)(langIdCls, @selector(languageIDFromString:), targetLangStr);
        if (!targetLang) return;

        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kUserChoseLanguageKey];
        [[NSUserDefaults standardUserDefaults] synchronize];

        if (langMgrCls && [langMgrCls respondsToSelector:@selector(sharedInstance)]) {
            id lm = ((id(*)(Class, SEL))objc_msgSend)(langMgrCls, @selector(sharedInstance));
            if (lm) {
                if ([lm respondsToSelector:@selector(enabledLanguages)] && [lm respondsToSelector:@selector(enableLanguage:)]) {
                    NSArray *enabled = ((id(*)(id, SEL))objc_msgSend)(lm, @selector(enabledLanguages));
                    if (![enabled containsObject:targetLang]) {
                        ((void(*)(id, SEL, id))objc_msgSend)(lm, @selector(enableLanguage:), targetLang);
                    }
                }
                if ([targetLangStr isEqualToString:@"en_us"] && [lm respondsToSelector:@selector(setEnabledKeyboardVariant:forLanguage:)]) {
                    ((void(*)(id, SEL, id, id))objc_msgSend)(lm, @selector(setEnabledKeyboardVariant:forLanguage:), @"qwerty", targetLang);
                }
            }
        }

        UIInputViewController *inputVC = [TypelessVoiceManager sharedManager].activeInputViewController;
        if (inputVC && [inputVC respondsToSelector:@selector(inputBundleManager)]) {
            id bundleMgr = ((id(*)(id, SEL))objc_msgSend)(inputVC, @selector(inputBundleManager));
            if (bundleMgr && [bundleMgr respondsToSelector:@selector(currentInputBundle)]) {
                id bundle = ((id(*)(id, SEL))objc_msgSend)(bundleMgr, @selector(currentInputBundle));
                if (bundle && [bundle respondsToSelector:@selector(switchToLanguage:)]) {
                    ((void(*)(id, SEL, id))objc_msgSend)(bundle, @selector(switchToLanguage:), targetLang);
                    return;
                }
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[LintypeGboard] Switch language exception: %@", e);
    }
}

static void RenderCustomKeyBadgeInContainer(UIView *container, LintypeKeyAction action, BOOL dark, BOOL highlighted) {
    if (!container || CGRectGetWidth(container.bounds) < 12 || CGRectGetHeight(container.bounds) < 12) return;
    CGFloat w = CGRectGetWidth(container.bounds);
    CGFloat h = CGRectGetHeight(container.bounds);
    NSString *badgeSig = [NSString stringWithFormat:@"%ld|%d|%.0f|%.0f", (long)action, (int)dark, w, h];

    UIView *badge = [container viewWithTag:kCustomKeyContentTag];
    if (badge) {
        NSString *prevSig = objc_getAssociatedObject(badge, kBadgeStateSigAssocKey);
        if ([prevSig isEqualToString:badgeSig] && badge.subviews.count > 0) {
            badge.hidden = NO;
            if (!CGRectEqualToRect(badge.frame, container.bounds)) {
                badge.frame = container.bounds;
            }
            (void)highlighted;
            return;
        }
        for (UIView *sub in [badge.subviews copy]) {
            [sub removeFromSuperview];
        }
    } else {
        badge = [[UIView alloc] initWithFrame:container.bounds];
        badge.tag = kCustomKeyContentTag;
        badge.userInteractionEnabled = NO;
        badge.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [container addSubview:badge];
    }
    badge.frame = container.bounds;
    badge.hidden = NO;
    objc_setAssociatedObject(badge, kBadgeStateSigAssocKey, badgeSig, OBJC_ASSOCIATION_COPY_NONATOMIC);

    UIColor *fg = IOSKeyFgColor(LintypeKeyRoleFunction, dark);

    if (action == LintypeKeyActionVoice) {
        if (@available(iOS 13.0, *)) {
            CGFloat iconPt = (w >= 54.0 && h >= 44.0) ? 15.0 : 17.5;
            UIImageSymbolConfiguration *sym = [UIImageSymbolConfiguration configurationWithPointSize:iconPt weight:UIImageSymbolWeightMedium];
            UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"mic.fill" withConfiguration:sym]];
            iv.contentMode = UIViewContentModeScaleAspectFit;
            iv.tintColor = fg;
            if (w >= 54.0 && h >= 44.0) {
                iv.frame = CGRectMake(0, MAX(4.0, h * 0.5 - 14.0), w, 17.0);
                UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(2, CGRectGetMaxY(iv.frame) + 1.0, w - 4, 12.0)];
                lbl.text = @"语音";
                lbl.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightMedium];
                lbl.textColor = fg;
                lbl.textAlignment = NSTextAlignmentCenter;
                [badge addSubview:lbl];
            } else {
                iv.frame = CGRectInset(badge.bounds, 6, 6);
            }
            [badge addSubview:iv];
        } else {
            UILabel *lbl = [[UILabel alloc] initWithFrame:badge.bounds];
            lbl.text = @"语音";
            lbl.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightMedium];
            lbl.textColor = fg;
            lbl.textAlignment = NSTextAlignmentCenter;
            [badge addSubview:lbl];
        }
    } else if (action == LintypeKeyActionSwitchToEnglish || action == LintypeKeyActionSwitchToChinese) {
        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectInset(badge.bounds, 2, 2)];
        lbl.text = (action == LintypeKeyActionSwitchToEnglish) ? @"英文" : @"中";
        lbl.font = [UIFont systemFontOfSize:(action == LintypeKeyActionSwitchToEnglish ? 14.5 : 15.5) weight:UIFontWeightMedium];
        lbl.textColor = fg;
        lbl.textAlignment = NSTextAlignmentCenter;
        lbl.adjustsFontSizeToFitWidth = YES;
        lbl.minimumScaleFactor = 0.75;
        [badge addSubview:lbl];
    }

    (void)highlighted;
    [container bringSubviewToFront:badge];
}

static void StyleIOSFloatingKeyView(UIView *keyView) {
    if (!keyView) return;
    NSString *keyId = objc_getAssociatedObject(keyView, kKeyPosIdAssocKey);
    LintypeKeyAction action = (LintypeKeyAction)[objc_getAssociatedObject(keyView, kKeyActionAssocKey) integerValue];
    LintypeKeyRole role = RoleForKeyPosId(keyId, action);
    if (role == LintypeKeyRoleIgnore) return;

    // Record base nib padding once before customizing
    NSValue *basePadVal = objc_getAssociatedObject(keyView, kKeyBasePadAssocKey);
    UIEdgeInsets basePad = UIEdgeInsetsZero;
    if (!basePadVal) {
        if ([keyView respondsToSelector:@selector(paddingLeft)]) {
            basePad.left = ((double(*)(id, SEL))objc_msgSend)(keyView, @selector(paddingLeft));
            basePad.top = ((double(*)(id, SEL))objc_msgSend)(keyView, @selector(paddingTop));
            basePad.right = ((double(*)(id, SEL))objc_msgSend)(keyView, @selector(paddingRight));
            basePad.bottom = ((double(*)(id, SEL))objc_msgSend)(keyView, @selector(paddingBottom));
        }
        objc_setAssociatedObject(keyView, kKeyBasePadAssocKey, [NSValue valueWithUIEdgeInsets:basePad], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        basePad = [basePadVal UIEdgeInsetsValue];
    }

    BOOL is9Key = [keyId hasPrefix:@"key_pos_9keys_"];
    UIEdgeInsets targetPad = basePad;
    if (is9Key) {
        targetPad = UIEdgeInsetsMake(3.4, 2.6, 3.4, 2.6);
    } else if ([keyId isEqualToString:@"key_pos_space"]) {
        NSValue *extraVal = objc_getAssociatedObject(keyView, kKeySpaceExtraPadAssocKey);
        UIEdgeInsets extra = extraVal ? [extraVal UIEdgeInsetsValue] : UIEdgeInsetsZero;
        targetPad = UIEdgeInsetsMake(MAX(basePad.top, 3.5), MAX(basePad.left, 2.4) + extra.left,
                                     MAX(basePad.bottom, 4.0), MAX(basePad.right, 2.4) + extra.right);
    } else {
        targetPad = UIEdgeInsetsMake(MAX(basePad.top, 3.2), MAX(basePad.left, 2.2),
                                     MAX(basePad.bottom, 3.8), MAX(basePad.right, 2.2));
    }

    if ([keyView respondsToSelector:@selector(setPaddingLeft:)]) {
        double curL = [keyView respondsToSelector:@selector(paddingLeft)] ? ((double(*)(id, SEL))objc_msgSend)(keyView, @selector(paddingLeft)) : -1.0;
        double curT = [keyView respondsToSelector:@selector(paddingTop)] ? ((double(*)(id, SEL))objc_msgSend)(keyView, @selector(paddingTop)) : -1.0;
        double curR = [keyView respondsToSelector:@selector(paddingRight)] ? ((double(*)(id, SEL))objc_msgSend)(keyView, @selector(paddingRight)) : -1.0;
        double curB = [keyView respondsToSelector:@selector(paddingBottom)] ? ((double(*)(id, SEL))objc_msgSend)(keyView, @selector(paddingBottom)) : -1.0;
        if (fabs(curL - targetPad.left) > 0.05) ((void(*)(id, SEL, double))objc_msgSend)(keyView, @selector(setPaddingLeft:), targetPad.left);
        if (fabs(curT - targetPad.top) > 0.05) ((void(*)(id, SEL, double))objc_msgSend)(keyView, @selector(setPaddingTop:), targetPad.top);
        if (fabs(curR - targetPad.right) > 0.05) ((void(*)(id, SEL, double))objc_msgSend)(keyView, @selector(setPaddingRight:), targetPad.right);
        if (fabs(curB - targetPad.bottom) > 0.05) ((void(*)(id, SEL, double))objc_msgSend)(keyView, @selector(setPaddingBottom:), targetPad.bottom);
    }

    if (![keyView respondsToSelector:@selector(hostView)]) return;
    UIView *hostView = ((id(*)(id, SEL))objc_msgSend)(keyView, @selector(hostView));
    if (!hostView) return;
    UIView *firstChild = hostView.subviews.firstObject;
    if (!firstChild) return;

    BOOL dark = IsKeyboardDarkAppearance(keyView);
    BOOL highlighted = [keyView respondsToSelector:@selector(isHighlighted)]
        ? ((BOOL(*)(id, SEL))objc_msgSend)(keyView, @selector(isHighlighted))
        : NO;

    NSString *childText = [firstChild isKindOfClass:[UILabel class]] ? (((UILabel *)firstChild).text ?: @"") : @"";
    CGSize childSize = firstChild.bounds.size;
    NSString *themeSig = [NSString stringWithFormat:@"%@|%ld|%ld|%d|%.0f|%.0f|%@",
                          keyId ?: @"", (long)action, (long)role, (int)dark,
                          childSize.width, childSize.height, childText];
    NSString *prevThemeSig = objc_getAssociatedObject(keyView, kKeyThemeSigAssocKey);
    NSNumber *prevHlNum = objc_getAssociatedObject(keyView, kKeyHighlightStateAssocKey);
    BOOL themeUnchanged = [prevThemeSig isEqualToString:themeSig];
    if (themeUnchanged && prevHlNum != nil && [prevHlNum boolValue] == highlighted) {
        // Fast path: key geometry, theme, text, and highlight are identical.
        if (action == LintypeKeyActionNone || [firstChild viewWithTag:kCustomKeyContentTag] != nil) {
            return;
        }
    }

    UIColor *bg = IOSKeyBgColor(role, dark, highlighted);
    if (themeUnchanged) {
        // Highlight-only toggle: swap fill color without touching shadows or subviews.
        firstChild.backgroundColor = bg;
        if ([firstChild respondsToSelector:@selector(backgroundLayer)]) {
            CALayer *bgLayer = ((id(*)(id, SEL))objc_msgSend)(firstChild, @selector(backgroundLayer));
            if (bgLayer) bgLayer.backgroundColor = bg.CGColor;
        }
        objc_setAssociatedObject(keyView, kKeyHighlightStateAssocKey, @(highlighted), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    UIColor *normalBg = IOSKeyBgColor(role, dark, NO);
    UIColor *hlBg = IOSKeyBgColor(role, dark, YES);
    UIColor *fg = IOSKeyFgColor(role, dark);

    firstChild.backgroundColor = bg;
    if (firstChild.clipsToBounds) firstChild.clipsToBounds = NO;
    firstChild.layer.cornerRadius = 5.5;
    firstChild.layer.borderWidth = 0.0;
    firstChild.layer.shadowColor = [UIColor blackColor].CGColor;
    firstChild.layer.shadowOpacity = dark ? 0.36f : 0.28f;
    firstChild.layer.shadowOffset = CGSizeMake(0.0, 1.0);
    firstChild.layer.shadowRadius = 0.0;
    if (!CGRectIsEmpty(firstChild.bounds)) {
        NSValue *prevShadowVal = objc_getAssociatedObject(firstChild, kKeyLastShadowSizeAssocKey);
        CGSize prevShadowSize = prevShadowVal ? [prevShadowVal CGSizeValue] : CGSizeZero;
        if (!CGSizeEqualToSize(prevShadowSize, firstChild.bounds.size) || firstChild.layer.shadowPath == NULL) {
            firstChild.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:firstChild.bounds cornerRadius:5.5].CGPath;
            objc_setAssociatedObject(firstChild, kKeyLastShadowSizeAssocKey, [NSValue valueWithCGSize:firstChild.bounds.size], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }

    if ([firstChild respondsToSelector:@selector(backgroundLayer)]) {
        CALayer *bgLayer = ((id(*)(id, SEL))objc_msgSend)(firstChild, @selector(backgroundLayer));
        if (bgLayer) {
            if ([bgLayer respondsToSelector:@selector(setImage:)]) {
                ((void(*)(id, SEL, id))objc_msgSend)(bgLayer, @selector(setImage:), nil);
            }
            if ([bgLayer respondsToSelector:@selector(setHighlightedImage:)]) {
                ((void(*)(id, SEL, id))objc_msgSend)(bgLayer, @selector(setHighlightedImage:), nil);
            }
            if ([bgLayer respondsToSelector:@selector(setBgColor:)]) {
                ((void(*)(id, SEL, id))objc_msgSend)(bgLayer, @selector(setBgColor:), normalBg);
            }
            if ([bgLayer respondsToSelector:@selector(setHighlightedBgColor:)]) {
                ((void(*)(id, SEL, id))objc_msgSend)(bgLayer, @selector(setHighlightedBgColor:), hlBg);
            }
            if ([bgLayer respondsToSelector:@selector(setBdWidth:)]) {
                ((void(*)(id, SEL, double))objc_msgSend)(bgLayer, @selector(setBdWidth:), 0.0);
            }
            bgLayer.cornerRadius = 5.5;
            bgLayer.masksToBounds = YES;
            bgLayer.backgroundColor = bg.CGColor;
        }
    }

    if (action != LintypeKeyActionNone) {
        HideOriginalKeyContentsRecursively(hostView, firstChild, 0);
        RenderCustomKeyBadgeInContainer(firstChild, action, dark, highlighted);
    } else {
        UIView *oldBadge = [firstChild viewWithTag:kCustomKeyContentTag];
        if (oldBadge && !oldBadge.hidden) oldBadge.hidden = YES;
        RestoreOriginalKeyContentsRecursively(hostView, 0);
        ApplyForegroundColorRecursively(hostView, fg, 0);

        // Native iOS 9-key dialpad formatting: uppercase ABC..WXYZ, '分词' & '空格'
        if (is9Key && [firstChild isKindOfClass:[UILabel class]]) {
            UILabel *lbl = (UILabel *)firstChild;
            NSString *txt = lbl.text;
            if (txt.length > 0) {
                NSString *low = [txt lowercaseString];
                if ([keyId hasPrefix:@"key_pos_9keys_1_"] ||
                    [keyId hasPrefix:@"key_pos_9keys_2_"] ||
                    [keyId hasPrefix:@"key_pos_9keys_3_"]) {
                    if ([keyId isEqualToString:@"key_pos_9keys_1_1"]) {
                        if ([low containsString:@"词"] || [txt isEqualToString:@"'"]) {
                            if (![lbl.text isEqualToString:@"分词"]) lbl.text = @"分词";
                            lbl.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightRegular];
                        }
                    } else if ([low isEqualToString:@"abc"] || [low isEqualToString:@"def"] ||
                               [low isEqualToString:@"ghi"] || [low isEqualToString:@"jkl"] ||
                               [low isEqualToString:@"mno"] || [low isEqualToString:@"pqrs"] ||
                               [low isEqualToString:@"tuv"] || [low isEqualToString:@"wxyz"]) {
                        NSString *up = [txt uppercaseString];
                        if (![lbl.text isEqualToString:up]) lbl.text = up;
                        lbl.font = [UIFont systemFontOfSize:18.0 weight:UIFontWeightRegular];
                    }
                } else if ([keyId isEqualToString:@"key_pos_9keys_4_2"]) {
                    if ([low containsString:@"gboard"] || [low containsString:@"space"] || [txt containsString:@"空格"]) {
                        if (![lbl.text isEqualToString:@"空格"]) lbl.text = @"空格";
                        lbl.font = [UIFont systemFontOfSize:15.5 weight:UIFontWeightRegular];
                    }
                } else if ([keyId isEqualToString:@"key_pos_9keys_left_1"] ||
                           [keyId isEqualToString:@"key_pos_9keys_left_3"]) {
                    lbl.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightRegular];
                }
            }
        }
    }

    NSString *finalText = [firstChild isKindOfClass:[UILabel class]] ? (((UILabel *)firstChild).text ?: @"") : @"";
    NSString *finalSig = [NSString stringWithFormat:@"%@|%ld|%ld|%d|%.0f|%.0f|%@",
                          keyId ?: @"", (long)action, (long)role, (int)dark,
                          childSize.width, childSize.height, finalText];
    objc_setAssociatedObject(keyView, kKeyThemeSigAssocKey, finalSig, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(keyView, kKeyHighlightStateAssocKey, @(highlighted), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void StyleInlineButton(UIView *btn, LintypeKeyAction action, BOOL dark, BOOL highlighted) {
    UIColor *bg = IOSKeyBgColor(LintypeKeyRoleFunction, dark, highlighted);
    btn.backgroundColor = bg;
    btn.layer.cornerRadius = 5.5;
    btn.layer.borderWidth = 0.0;
    btn.layer.shadowColor = [UIColor blackColor].CGColor;
    btn.layer.shadowOpacity = dark ? 0.36f : 0.28f;
    btn.layer.shadowOffset = CGSizeMake(0.0, 1.0);
    btn.layer.shadowRadius = 0.0;
    if (!CGRectIsEmpty(btn.bounds)) {
        NSValue *prevVal = objc_getAssociatedObject(btn, kKeyLastShadowSizeAssocKey);
        CGSize prevSize = prevVal ? [prevVal CGSizeValue] : CGSizeZero;
        if (!CGSizeEqualToSize(prevSize, btn.bounds.size) || btn.layer.shadowPath == NULL) {
            btn.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:btn.bounds cornerRadius:5.5].CGPath;
            objc_setAssociatedObject(btn, kKeyLastShadowSizeAssocKey, [NSValue valueWithCGSize:btn.bounds.size], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    RenderCustomKeyBadgeInContainer(btn, action, dark, highlighted);
}

static void HideNineKeySeparatorLinesInView(UIView *root, NSInteger depth) {
    if (!root || depth > 3) return;
    Class softKeyCls = objc_getClass("GKBSoftKeyView");
    for (UIView *sub in root.subviews) {
        if (softKeyCls && [sub isKindOfClass:softKeyCls]) continue;
        if (sub.tag == kInlineLangBtnTag || sub.tag == kInlineVoiceBtnTag) continue;
        CGFloat w = CGRectGetWidth(sub.bounds);
        CGFloat h = CGRectGetHeight(sub.bounds);
        BOOL isHairline = ((w > 0 && w <= 2.5 && h > 16.0) || (h > 0 && h <= 2.5 && w > 16.0));
        if (isHairline && sub.subviews.count == 0) {
            sub.hidden = YES;
            sub.alpha = 0.0;
            continue;
        }
        HideNineKeySeparatorLinesInView(sub, depth + 1);
    }
}

static void UpdateInlineKey(UIView *parentView, NSInteger tag, BOOL show, CGRect frame, LintypeKeyAction action, BOOL dark) {
    UIView *btn = [parentView viewWithTag:tag];
    if (!show) {
        if (btn) btn.hidden = YES;
        return;
    }
    if (!btn) {
        btn = [[UIView alloc] initWithFrame:frame];
        btn.tag = tag;
        btn.userInteractionEnabled = YES;
        [parentView addSubview:btn];
    }
    btn.hidden = NO;
    if (!CGRectEqualToRect(btn.frame, frame)) {
        btn.frame = frame;
    }
    objc_setAssociatedObject(btn, kKeyActionAssocKey, @(action), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    StyleInlineButton(btn, action, dark, NO);
    [parentView bringSubviewToFront:btn];
}

static void ConfigureAndStyleKeyboardView(UIView *kbdView) {
    if (!kbdView || ![kbdView respondsToSelector:@selector(allSoftKeys)]) return;
    NSDictionary<NSString *, UIView *> *allSoftKeys = ((id(*)(id, SEL))objc_msgSend)(kbdView, @selector(allSoftKeys));
    if (![allSoftKeys isKindOfClass:[NSDictionary class]] || allSoftKeys.count == 0) return;

    BOOL dark = IsKeyboardDarkAppearance(kbdView);
    kbdView.backgroundColor = IOSKeyboardBgColor(dark);

    Class nineKeyCls = objc_getClass("GKB9KeysSoftKeyboardView");
    BOOL isNineKeyView = (nineKeyCls && [kbdView isKindOfClass:nineKeyCls]) || (allSoftKeys[@"key_pos_9keys_1_2"] != nil);

    BOOL isPinyin9KeyPrime = NO;
    if (isNineKeyView) {
        UIView *k12 = allSoftKeys[@"key_pos_9keys_1_2"];
        NSString *t12 = [[ExtractViewTextRecursively(k12, 0) ?: @"" lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *defId = @"";
        if (k12 && [k12 respondsToSelector:@selector(softKeyDef)]) {
            id def = ((id(*)(id, SEL))objc_msgSend)(k12, @selector(softKeyDef));
            if (def && [def respondsToSelector:@selector(id_p)]) {
                defId = [((id(*)(id, SEL))objc_msgSend)(def, @selector(id_p)) lowercaseString] ?: @"";
            }
        }
        if ([t12 isEqualToString:@"abc"] || [defId containsString:@"alpha_a"] || [defId isEqualToString:@"softkey_9keys_2"]) {
            isPinyin9KeyPrime = YES;
        }
        HideNineKeySeparatorLinesInView(kbdView, 0);
    }

    // Determine whether we are in English QWERTY letter layout
    BOOL isEnglishQwertyPrime = NO;
    if (!isNineKeyView) {
        UIView *k11 = allSoftKeys[@"key_pos_1_1"];
        NSString *t11 = [[ExtractViewTextRecursively(k11, 0) ?: @"" lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (k11 && !k11.hidden && [t11 isEqualToString:@"q"] && allSoftKeys[@"key_pos_space"] != nil) {
            isEnglishQwertyPrime = YES;
        }
    }

    UIView *spaceKey = allSoftKeys[@"key_pos_space"];
    UIView *globeKey = allSoftKeys[@"key_pos_globe"];
    UIView *emojiKey = allSoftKeys[@"key_pos_emoji"];
    BOOL globeVisible = (globeKey && !globeKey.hidden && CGRectGetWidth(globeKey.frame) >= 24.0);
    BOOL inlineLangMode = NO;
    BOOL inlineVoiceMode = NO;
    CGRect inlineLangFrame = CGRectZero;
    CGRect inlineVoiceFrame = CGRectZero;

    if (isEnglishQwertyPrime && spaceKey && !spaceKey.hidden && spaceKey.superview) {
        CGRect sf = spaceKey.frame;
        CGFloat sw = CGRectGetWidth(sf);
        CGFloat sh = CGRectGetHeight(sf);
        if (globeVisible) {
            // Convert visible globe key directly to Chinese switch; carve 40pt on right side of space for Voice
            if (sw >= 135.0 && sh >= 32.0) {
                inlineVoiceMode = YES;
                inlineVoiceFrame = CGRectMake(CGRectGetMaxX(sf) - 41.5, CGRectGetMinY(sf) + 3.2, 39.5, sh - 7.0);
                objc_setAssociatedObject(spaceKey, kKeySpaceExtraPadAssocKey,
                                         [NSValue valueWithUIEdgeInsets:UIEdgeInsetsMake(0, 0, 0, 44.0)],
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            } else {
                objc_setAssociatedObject(spaceKey, kKeySpaceExtraPadAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        } else {
            // Modern iPhones (system globe lives in bottom chin): keep emoji AND carve symmetric [中] + [🎙] around space
            if (sw >= 175.0 && sh >= 32.0) {
                inlineLangMode = YES;
                inlineVoiceMode = YES;
                inlineLangFrame = CGRectMake(CGRectGetMinX(sf) + 2.0, CGRectGetMinY(sf) + 3.2, 39.5, sh - 7.0);
                inlineVoiceFrame = CGRectMake(CGRectGetMaxX(sf) - 41.5, CGRectGetMinY(sf) + 3.2, 39.5, sh - 7.0);
                objc_setAssociatedObject(spaceKey, kKeySpaceExtraPadAssocKey,
                                         [NSValue valueWithUIEdgeInsets:UIEdgeInsetsMake(0, 44.0, 0, 44.0)],
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            } else if (sw >= 135.0 && sh >= 32.0) {
                // Compact screen fallback: turn emoji slot into [中] and place [🎙] right of space
                inlineVoiceMode = YES;
                inlineVoiceFrame = CGRectMake(CGRectGetMaxX(sf) - 41.5, CGRectGetMinY(sf) + 3.2, 39.5, sh - 7.0);
                objc_setAssociatedObject(spaceKey, kKeySpaceExtraPadAssocKey,
                                         [NSValue valueWithUIEdgeInsets:UIEdgeInsetsMake(0, 0, 0, 44.0)],
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            } else {
                objc_setAssociatedObject(spaceKey, kKeySpaceExtraPadAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    } else if (spaceKey) {
        objc_setAssociatedObject(spaceKey, kKeySpaceExtraPadAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    for (NSString *keyId in allSoftKeys) {
        UIView *keyView = allSoftKeys[keyId];
        if (![keyView isKindOfClass:[UIView class]]) continue;

        objc_setAssociatedObject(keyView, kKeyPosIdAssocKey, keyId, OBJC_ASSOCIATION_COPY_NONATOMIC);

        LintypeKeyAction action = LintypeKeyActionNone;
        if (isPinyin9KeyPrime) {
            if ([keyId isEqualToString:@"key_pos_9keys_left_2"]) {
                action = LintypeKeyActionSwitchToEnglish;
            } else if ([keyId isEqualToString:@"key_pos_9keys_left_4"]) {
                action = LintypeKeyActionVoice;
            }
        } else if (isEnglishQwertyPrime) {
            if (globeVisible && keyView == globeKey) {
                action = LintypeKeyActionSwitchToChinese;
            } else if (!globeVisible && !inlineLangMode && emojiKey && keyView == emojiKey) {
                action = LintypeKeyActionSwitchToChinese;
            }
        }
        objc_setAssociatedObject(keyView, kKeyActionAssocKey, @(action), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        StyleIOSFloatingKeyView(keyView);
        if ([keyView respondsToSelector:@selector(layoutSublayersOfLayer:)]) {
            ((void(*)(id, SEL, id))objc_msgSend)(keyView, @selector(layoutSublayersOfLayer:), keyView.layer);
        }
    }

    UIView *inlineParent = spaceKey.superview ?: kbdView;
    UpdateInlineKey(inlineParent, kInlineLangBtnTag, inlineLangMode, inlineLangFrame, LintypeKeyActionSwitchToChinese, dark);
    UpdateInlineKey(inlineParent, kInlineVoiceBtnTag, inlineVoiceMode, inlineVoiceFrame, LintypeKeyActionVoice, dark);
}

static void StyleCandidateAndHeaderChrome(UIView *root, NSInteger depth) {
    if (!root || depth > 6) return;
    NSString *clsName = NSStringFromClass([root class]);
    if ([clsName isEqualToString:@"GKBHeaderLogoView"]) {
        root.hidden = YES;
        root.alpha = 0.0;
        root.userInteractionEnabled = NO;
        return;
    }
    if ([clsName isEqualToString:@"GKBFixedNumberCandidatesView"]) {
        if ([root respondsToSelector:@selector(voiceInputButton)]) {
            UIView *vbtn = ((id(*)(id, SEL))objc_msgSend)(root, @selector(voiceInputButton));
            if (vbtn) {
                vbtn.hidden = YES;
                vbtn.alpha = 0.0;
                vbtn.userInteractionEnabled = NO;
            }
        }
        if ([root respondsToSelector:@selector(voiceInputWidthConstraint)]) {
            NSLayoutConstraint *wc = ((id(*)(id, SEL))objc_msgSend)(root, @selector(voiceInputWidthConstraint));
            if ([wc isKindOfClass:[NSLayoutConstraint class]]) {
                wc.constant = 0.0;
            }
        }
    }

    BOOL dark = IsKeyboardDarkAppearance(root);
    if ([clsName isEqualToString:@"GKBKeyboardViewContainerView"] ||
        [root.accessibilityIdentifier isEqualToString:@"combined_search_header"] ||
        [clsName isEqualToString:@"GKBFixedNumberCandidatesView"]) {
        root.backgroundColor = IOSKeyboardBgColor(dark);
    }

    for (UIView *sub in root.subviews) {
        StyleCandidateAndHeaderChrome(sub, depth + 1);
    }
}

#pragma mark - Header & Candidate Bar Hooks (Clean Native iOS Top Strip)

static void (*orig_candidates_configureVoiceBtn)(id self, SEL _cmd) = NULL;
static void my_candidates_configureVoiceBtn(UIView *self, SEL _cmd) {
    if (orig_candidates_configureVoiceBtn) orig_candidates_configureVoiceBtn(self, _cmd);
    @try {
        if ([self respondsToSelector:@selector(voiceInputButton)]) {
            UIView *vbtn = ((id(*)(id, SEL))objc_msgSend)(self, @selector(voiceInputButton));
            if (vbtn) {
                vbtn.hidden = YES;
                vbtn.alpha = 0.0;
                vbtn.userInteractionEnabled = NO;
            }
        }
        if ([self respondsToSelector:@selector(voiceInputWidthConstraint)]) {
            NSLayoutConstraint *wc = ((id(*)(id, SEL))objc_msgSend)(self, @selector(voiceInputWidthConstraint));
            if ([wc isKindOfClass:[NSLayoutConstraint class]]) {
                wc.constant = 0.0;
            }
        }
    } @catch (NSException *e) {}
}

static void (*orig_candidates_show)(id self, SEL _cmd) = NULL;
static void my_candidates_show(UIView *self, SEL _cmd) {
    if (orig_candidates_show) orig_candidates_show(self, _cmd);
    @try {
        self.backgroundColor = IOSKeyboardBgColor(IsKeyboardDarkAppearance(self));
        if ([self respondsToSelector:@selector(voiceInputButton)]) {
            UIView *vbtn = ((id(*)(id, SEL))objc_msgSend)(self, @selector(voiceInputButton));
            if (vbtn) { vbtn.hidden = YES; vbtn.alpha = 0.0; }
        }
        if ([self respondsToSelector:@selector(voiceInputWidthConstraint)]) {
            NSLayoutConstraint *wc = ((id(*)(id, SEL))objc_msgSend)(self, @selector(voiceInputWidthConstraint));
            if ([wc isKindOfClass:[NSLayoutConstraint class]]) wc.constant = 0.0;
        }
    } @catch (NSException *e) {}
}

static void (*orig_logo_didMoveToWindow)(UIView *self, SEL _cmd) = NULL;
static void my_logo_didMoveToWindow(UIView *self, SEL _cmd) {
    if (orig_logo_didMoveToWindow) orig_logo_didMoveToWindow(self, _cmd);
    self.hidden = YES;
    self.alpha = 0.0;
    self.userInteractionEnabled = NO;
}

static void HideExtensionSearchHeaderChrome(id headerVC) {
    @try {
        if (!headerVC) return;
        UIView *gBtn = [headerVC respondsToSelector:@selector(GButton)]
            ? ((id(*)(id, SEL))objc_msgSend)(headerVC, @selector(GButton))
            : nil;
        UIView *searchBox = [headerVC respondsToSelector:@selector(searchBoxView)]
            ? ((id(*)(id, SEL))objc_msgSend)(headerVC, @selector(searchBoxView))
            : nil;
        UIView *searchBar = [headerVC respondsToSelector:@selector(searchBarView)]
            ? ((id(*)(id, SEL))objc_msgSend)(headerVC, @selector(searchBarView))
            : nil;
        UIView *container = [headerVC respondsToSelector:@selector(headerContainerView)]
            ? ((id(*)(id, SEL))objc_msgSend)(headerVC, @selector(headerContainerView))
            : nil;
        UIView *root = [headerVC respondsToSelector:@selector(view)]
            ? ((id(*)(id, SEL))objc_msgSend)(headerVC, @selector(view))
            : nil;

        if (gBtn) { gBtn.hidden = YES; gBtn.alpha = 0.0; gBtn.userInteractionEnabled = NO; }
        if (searchBox) { searchBox.hidden = YES; searchBox.alpha = 0.0; searchBox.userInteractionEnabled = NO; }
        if (searchBar) { searchBar.hidden = YES; searchBar.alpha = 0.0; searchBar.userInteractionEnabled = NO; }

        BOOL dark = IsKeyboardDarkAppearance(root ?: container);
        UIColor *bg = IOSKeyboardBgColor(dark);
        if (container) container.backgroundColor = bg;
        if (root) root.backgroundColor = bg;
    } @catch (NSException *e) {}
}

static void (*orig_headerVc_viewWillAppear)(UIViewController *self, SEL _cmd, BOOL animated) = NULL;
static void my_headerVc_viewWillAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    if (orig_headerVc_viewWillAppear) orig_headerVc_viewWillAppear(self, _cmd, animated);
    HideExtensionSearchHeaderChrome(self);
}

static void (*orig_headerVc_viewDidAppear)(UIViewController *self, SEL _cmd, BOOL animated) = NULL;
static void my_headerVc_viewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    if (orig_headerVc_viewDidAppear) orig_headerVc_viewDidAppear(self, _cmd, animated);
    HideExtensionSearchHeaderChrome(self);
}

#pragma mark - SoftKey & SoftKeyboard Layout Hooks

static void (*orig_softKeyboard_setSoftKeyDefs)(id self, SEL _cmd, id defs, id viewId) = NULL;
static void my_softKeyboard_setSoftKeyDefs(UIView *self, SEL _cmd, id defs, NSString *viewId) {
    if (orig_softKeyboard_setSoftKeyDefs) {
        orig_softKeyboard_setSoftKeyDefs(self, _cmd, defs, viewId);
    }
    @try {
        if ([self respondsToSelector:@selector(allSoftKeys)]) {
            NSDictionary *all = ((id(*)(id, SEL))objc_msgSend)(self, @selector(allSoftKeys));
            UIView *kv = ([viewId isKindOfClass:[NSString class]]) ? all[viewId] : nil;
            if (kv) {
                objc_setAssociatedObject(kv, kKeyPosIdAssocKey, viewId, OBJC_ASSOCIATION_COPY_NONATOMIC);
            }
        }
        [self setNeedsLayout];
    } @catch (NSException *e) {}
}

static void (*orig_softKeyboard_layoutSubviews)(UIView *self, SEL _cmd) = NULL;
static void my_softKeyboard_layoutSubviews(UIView *self, SEL _cmd) {
    if (orig_softKeyboard_layoutSubviews) {
        orig_softKeyboard_layoutSubviews(self, _cmd);
    }
    @try {
        ConfigureAndStyleKeyboardView(self);
    } @catch (NSException *e) {}
}

static void (*orig_fixedKeyboard_layoutSubviews)(UIView *self, SEL _cmd) = NULL;
static void my_fixedKeyboard_layoutSubviews(UIView *self, SEL _cmd) {
    if (orig_fixedKeyboard_layoutSubviews) {
        orig_fixedKeyboard_layoutSubviews(self, _cmd);
    }
    @try {
        ConfigureAndStyleKeyboardView(self);
    } @catch (NSException *e) {}
}

static void (*orig_softKey_layoutSublayers)(UIView *self, SEL _cmd, CALayer *layer) = NULL;
static void my_softKey_layoutSublayers(UIView *self, SEL _cmd, CALayer *layer) {
    if (orig_softKey_layoutSublayers) {
        orig_softKey_layoutSublayers(self, _cmd, layer);
    }
    @try {
        StyleIOSFloatingKeyView(self);
        // Re-center spacebar label if only trailing side was padded on compact QWERTY
        NSString *keyId = objc_getAssociatedObject(self, kKeyPosIdAssocKey);
        if ([keyId isEqualToString:@"key_pos_space"] && [self respondsToSelector:@selector(hostView)]) {
            UIView *hostView = ((id(*)(id, SEL))objc_msgSend)(self, @selector(hostView));
            UIView *firstChild = hostView.subviews.firstObject;
            if (firstChild) {
                for (UIView *sub in firstChild.subviews) {
                    if ([sub isKindOfClass:[UILabel class]] && sub.tag != kCustomKeyContentTag) {
                        sub.center = CGPointMake(CGRectGetMidX(firstChild.bounds), CGRectGetMidY(firstChild.bounds));
                    }
                }
            }
        }
    } @catch (NSException *e) {}
}

static void (*orig_softKey_updateView)(UIView *self, SEL _cmd) = NULL;
static void my_softKey_updateView(UIView *self, SEL _cmd) {
    if (orig_softKey_updateView) {
        orig_softKey_updateView(self, _cmd);
    }
    @try {
        objc_setAssociatedObject(self, kKeyThemeSigAssocKey, nil, OBJC_ASSOCIATION_ASSIGN);
        StyleIOSFloatingKeyView(self);
    } @catch (NSException *e) {}
}

static void (*orig_softKey_setHighlighted)(UIView *self, SEL _cmd, BOOL highlighted) = NULL;
static void my_softKey_setHighlighted(UIView *self, SEL _cmd, BOOL highlighted) {
    if (orig_softKey_setHighlighted) {
        orig_softKey_setHighlighted(self, _cmd, highlighted);
    }
    @try {
        StyleIOSFloatingKeyView(self);
    } @catch (NSException *e) {}
}

#pragma mark - Container Touch Interception for Custom In-Keyboard Keys

static UIView * _Nullable FindCustomActionTargetForTouch(UIView *container, UITouch *touch, UIEvent *event) {
    if (!container || !touch) return nil;
    CGPoint pt = [touch locationInView:container];

    // Check inline English QWERTY buttons first (they sit inside spaceKey's padding region!)
    UIView *inlineLang = [container viewWithTag:kInlineLangBtnTag];
    if (inlineLang && !inlineLang.hidden && inlineLang.alpha > 0.05) {
        CGRect r = [inlineLang convertRect:inlineLang.bounds toView:container];
        if (CGRectContainsPoint(r, pt)) return inlineLang;
    }
    UIView *inlineVoice = [container viewWithTag:kInlineVoiceBtnTag];
    if (inlineVoice && !inlineVoice.hidden && inlineVoice.alpha > 0.05) {
        CGRect r = [inlineVoice convertRect:inlineVoice.bounds toView:container];
        if (CGRectContainsPoint(r, pt)) return inlineVoice;
    }

    UIView *hit = [container hitTest:pt withEvent:event];
    Class softKeyCls = objc_getClass("GKBSoftKeyView");
    UIView *cur = hit;
    while (cur && cur != container) {
        LintypeKeyAction act = (LintypeKeyAction)[objc_getAssociatedObject(cur, kKeyActionAssocKey) integerValue];
        if (act != LintypeKeyActionNone && (!softKeyCls || [cur isKindOfClass:softKeyCls])) {
            return cur;
        }
        cur = cur.superview;
    }
    return nil;
}

static void SetCustomKeyViewHighlighted(UIView *target, BOOL highlighted) {
    if (!target) return;
    if (target.tag == kInlineLangBtnTag || target.tag == kInlineVoiceBtnTag) {
        LintypeKeyAction act = (LintypeKeyAction)[objc_getAssociatedObject(target, kKeyActionAssocKey) integerValue];
        StyleInlineButton(target, act, IsKeyboardDarkAppearance(target), highlighted);
    } else if ([target respondsToSelector:@selector(setIsHighlighted:)]) {
        ((void(*)(id, SEL, BOOL))objc_msgSend)(target, @selector(setIsHighlighted:), highlighted);
    }
}

static void EnsureActiveTouchTable(void) {
    if (!sActiveCustomTouches) {
        sActiveCustomTouches = [NSMapTable strongToStrongObjectsMapTable];
    }
}

static void (*orig_container_touchesBegan)(UIView *self, SEL _cmd, NSSet<UITouch *> *touches, UIEvent *event) = NULL;
static void my_container_touchesBegan(UIView *self, SEL _cmd, NSSet<UITouch *> *touches, UIEvent *event) {
    EnsureActiveTouchTable();
    NSMutableSet<UITouch *> *passthrough = [NSMutableSet set];
    for (UITouch *t in touches) {
        UIView *customTarget = FindCustomActionTargetForTouch(self, t, event);
        if (customTarget) {
            [sActiveCustomTouches setObject:customTarget forKey:t];
            SetCustomKeyViewHighlighted(customTarget, YES);
        } else {
            [passthrough addObject:t];
        }
    }
    if (passthrough.count > 0 && orig_container_touchesBegan) {
        orig_container_touchesBegan(self, _cmd, passthrough, event);
    }
}

static void (*orig_container_touchesMoved)(UIView *self, SEL _cmd, NSSet<UITouch *> *touches, UIEvent *event) = NULL;
static void my_container_touchesMoved(UIView *self, SEL _cmd, NSSet<UITouch *> *touches, UIEvent *event) {
    EnsureActiveTouchTable();
    NSMutableSet<UITouch *> *passthrough = [NSMutableSet set];
    for (UITouch *t in touches) {
        UIView *customTarget = [sActiveCustomTouches objectForKey:t];
        if (customTarget) {
            CGPoint pt = [t locationInView:customTarget];
            BOOL inside = CGRectContainsPoint(CGRectInset(customTarget.bounds, -14.0, -14.0), pt);
            SetCustomKeyViewHighlighted(customTarget, inside);
        } else {
            [passthrough addObject:t];
        }
    }
    if (passthrough.count > 0 && orig_container_touchesMoved) {
        orig_container_touchesMoved(self, _cmd, passthrough, event);
    }
}

static void (*orig_container_touchesEnded)(UIView *self, SEL _cmd, NSSet<UITouch *> *touches, UIEvent *event) = NULL;
static void my_container_touchesEnded(UIView *self, SEL _cmd, NSSet<UITouch *> *touches, UIEvent *event) {
    EnsureActiveTouchTable();
    NSMutableSet<UITouch *> *passthrough = [NSMutableSet set];
    for (UITouch *t in touches) {
        UIView *customTarget = [sActiveCustomTouches objectForKey:t];
        if (customTarget) {
            [sActiveCustomTouches removeObjectForKey:t];
            CGPoint pt = [t locationInView:customTarget];
            BOOL inside = CGRectContainsPoint(CGRectInset(customTarget.bounds, -14.0, -14.0), pt);
            SetCustomKeyViewHighlighted(customTarget, NO);
            if (inside) {
                LintypeKeyAction act = (LintypeKeyAction)[objc_getAssociatedObject(customTarget, kKeyActionAssocKey) integerValue];
                if (act != LintypeKeyActionNone) {
                    ExecuteCustomKeyAction(act);
                }
            }
        } else {
            [passthrough addObject:t];
        }
    }
    if (passthrough.count > 0 && orig_container_touchesEnded) {
        orig_container_touchesEnded(self, _cmd, passthrough, event);
    }
}

static void (*orig_container_touchesCancelled)(UIView *self, SEL _cmd, NSSet<UITouch *> *touches, UIEvent *event) = NULL;
static void my_container_touchesCancelled(UIView *self, SEL _cmd, NSSet<UITouch *> *touches, UIEvent *event) {
    EnsureActiveTouchTable();
    NSMutableSet<UITouch *> *passthrough = [NSMutableSet set];
    for (UITouch *t in touches) {
        UIView *customTarget = [sActiveCustomTouches objectForKey:t];
        if (customTarget) {
            [sActiveCustomTouches removeObjectForKey:t];
            SetCustomKeyViewHighlighted(customTarget, NO);
        } else {
            [passthrough addObject:t];
        }
    }
    if (passthrough.count > 0 && orig_container_touchesCancelled) {
        orig_container_touchesCancelled(self, _cmd, passthrough, event);
    }
}

#pragma mark - InputViewController Lifecycle & Launch Interface Routing

static void ApplyLaunchInterfacePreferenceIfNeeded(UIInputViewController *inputVC) {
    if (sAppliedLaunchInterfaceThisAppear || !inputVC) return;
    TypelessConfig *cfg = [TypelessConfig sharedConfig];
    if (cfg.launchInterface == TypelessLaunchInterfaceVoice) {
        sAppliedLaunchInterfaceThisAppear = YES;
        // Open voice interface in Idle/Ready state only; never auto-start recording.
        [[TypelessVoiceManager sharedManager] presentVoiceOverlayInViewController:inputVC autoStart:NO];
    } else {
        sAppliedLaunchInterfaceThisAppear = YES;
    }
}

static void RefreshAllKeyboardViewsInTree(UIView *root, NSInteger depth) {
    if (!root || depth > 7) return;
    if ([root respondsToSelector:@selector(allSoftKeys)]) {
        ConfigureAndStyleKeyboardView(root);
    }
    for (UIView *sub in root.subviews) {
        RefreshAllKeyboardViewsInTree(sub, depth + 1);
    }
}

static void (*orig_inputVc_viewWillAppear)(UIInputViewController *self, SEL _cmd, BOOL animated) = NULL;
static void my_inputVc_viewWillAppear(UIInputViewController *self, SEL _cmd, BOOL animated) {
    @try {
        sAppliedLaunchInterfaceThisAppear = NO;
        [[TypelessConfig sharedConfig] load];
        [[TypelessHostBridge sharedBridge] syncConfigFromHostAsyncWithCompletion:nil];
        EnsureDefaultZhHans9KeyPreferencesIfNeeded();
        [TypelessVoiceManager sharedManager].activeInputViewController = self;
    } @catch (NSException *e) {}
    if (orig_inputVc_viewWillAppear) {
        orig_inputVc_viewWillAppear(self, _cmd, animated);
    }
}

static void (*orig_inputVc_viewDidAppear)(UIInputViewController *self, SEL _cmd, BOOL animated) = NULL;
static void my_inputVc_viewDidAppear(UIInputViewController *self, SEL _cmd, BOOL animated) {
    if (orig_inputVc_viewDidAppear) {
        orig_inputVc_viewDidAppear(self, _cmd, animated);
    }
    @try {
        [[TypelessConfig sharedConfig] load];
        [TypelessVoiceManager sharedManager].activeInputViewController = self;
        StyleCandidateAndHeaderChrome(self.view, 0);
        RefreshAllKeyboardViewsInTree(self.view, 0);

        // Apply configured launch interface immediately on fresh keyboard presentation
        ApplyLaunchInterfacePreferenceIfNeeded(self);

        // Also sync from host loopback asynchronously and only re-apply styling/launch mode if config changed
        __weak UIInputViewController *weakSelf = self;
        TypelessLaunchInterface before = [TypelessConfig sharedConfig].launchInterface;
        [[TypelessHostBridge sharedBridge] syncConfigFromHostAsyncWithCompletion:^(BOOL updated) {
            UIInputViewController *strongVC = weakSelf;
            if (!strongVC || !updated) return;
            StyleCandidateAndHeaderChrome(strongVC.view, 0);
            RefreshAllKeyboardViewsInTree(strongVC.view, 0);
            TypelessLaunchInterface after = [TypelessConfig sharedConfig].launchInterface;
            if (before != after && after == TypelessLaunchInterfaceVoice &&
                ![TypelessVoiceManager sharedManager].isOverlayVisible) {
                [[TypelessVoiceManager sharedManager] presentVoiceOverlayInViewController:strongVC autoStart:NO];
            }
        }];
    } @catch (NSException *e) {}
}

static void (*orig_inputVc_viewWillDisappear)(UIInputViewController *self, SEL _cmd, BOOL animated) = NULL;
static void my_inputVc_viewWillDisappear(UIInputViewController *self, SEL _cmd, BOOL animated) {
    @try {
        sAppliedLaunchInterfaceThisAppear = NO;
        [sActiveCustomTouches removeAllObjects];
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
            [mgr presentVoiceOverlayInViewController:inputVC autoStart:NO];
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
    NSLog(@"[LintypeGboard] Initializing v1.0.9 iOS native 9-key & Typeless hooks...");

    // 1. Safe AppGroup container & GKBPreferences null-safety
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

    Class curLangMgrCls = objc_getClass("GKBCurrentLanguageManager");
    if (curLangMgrCls) {
        SafeHookInstanceMethod(curLangMgrCls, @selector(alwaysUseSystemPreferredLanguage), (IMP)my_curLangMgr_alwaysSystem, (IMP *)&orig_curLangMgr_alwaysSystem);
    }

    Class langMgrCls = objc_getClass("GKBLanguageManager");
    if (langMgrCls) {
        SafeHookInstanceMethod(langMgrCls, @selector(alwaysUseSystemPreferredLanguage), (IMP)my_langMgr_alwaysSystem, (IMP *)&orig_langMgr_alwaysSystem);
        SafeHookInstanceMethod(langMgrCls, @selector(defaultEnabledLanguage), (IMP)my_langMgr_defaultEnabledLanguage, (IMP *)&orig_langMgr_defaultEnabledLanguage);
        SafeHookInstanceMethod(langMgrCls, @selector(currentLanguage), (IMP)my_langMgr_currentLanguage, (IMP *)&orig_langMgr_currentLanguage);
        SafeHookInstanceMethod(langMgrCls, @selector(setCurrentLanguage:), (IMP)my_langMgr_setCurrentLanguage, (IMP *)&orig_langMgr_setCurrentLanguage);
        SafeHookInstanceMethod(langMgrCls, @selector(reloadData), (IMP)my_langMgr_reloadData, (IMP *)&orig_langMgr_reloadData);
        SafeHookInstanceMethod(langMgrCls, @selector(enabledKeyboardVariantForLanguage:), (IMP)my_langMgr_enabledVariant, (IMP *)&orig_langMgr_enabledVariant);
        SafeHookInstanceMethod(langMgrCls, @selector(setEnabledKeyboardVariant:forLanguage:), (IMP)my_langMgr_setEnabledVariant, (IMP *)&orig_langMgr_setEnabledVariant);
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
        SafeHookInstanceMethod(inputVcCls, @selector(viewWillAppear:), (IMP)my_inputVc_viewWillAppear, (IMP *)&orig_inputVc_viewWillAppear);
        SafeHookInstanceMethod(inputVcCls, @selector(viewDidAppear:), (IMP)my_inputVc_viewDidAppear, (IMP *)&orig_inputVc_viewDidAppear);
        SafeHookInstanceMethod(inputVcCls, @selector(viewWillDisappear:), (IMP)my_inputVc_viewWillDisappear, (IMP *)&orig_inputVc_viewWillDisappear);
    }

    Class headerVcCls = objc_getClass("GKBExtensionHeaderViewController");
    if (headerVcCls) {
        SafeHookInstanceMethod(headerVcCls, @selector(viewWillAppear:), (IMP)my_headerVc_viewWillAppear, (IMP *)&orig_headerVc_viewWillAppear);
        SafeHookInstanceMethod(headerVcCls, @selector(viewDidAppear:), (IMP)my_headerVc_viewDidAppear, (IMP *)&orig_headerVc_viewDidAppear);
    }

    Class candCls = objc_getClass("GKBFixedNumberCandidatesView");
    if (candCls) {
        SafeHookInstanceMethod(candCls, @selector(configureVoiceInputButton), (IMP)my_candidates_configureVoiceBtn, (IMP *)&orig_candidates_configureVoiceBtn);
        SafeHookInstanceMethod(candCls, @selector(show), (IMP)my_candidates_show, (IMP *)&orig_candidates_show);
    }

    Class logoCls = objc_getClass("GKBHeaderLogoView");
    if (logoCls) {
        SafeHookInstanceMethod(logoCls, @selector(didMoveToWindow), (IMP)my_logo_didMoveToWindow, (IMP *)&orig_logo_didMoveToWindow);
    }

    Class softKbdCls = objc_getClass("GKBSoftKeyboardView");
    if (softKbdCls) {
        SafeHookInstanceMethod(softKbdCls, @selector(setSoftKeyDefs:toViewWithId:), (IMP)my_softKeyboard_setSoftKeyDefs, (IMP *)&orig_softKeyboard_setSoftKeyDefs);
        SafeHookInstanceMethod(softKbdCls, @selector(layoutSubviews), (IMP)my_softKeyboard_layoutSubviews, (IMP *)&orig_softKeyboard_layoutSubviews);
    }

    Class fixedKbdCls = objc_getClass("GKBSoftKeyboardViewWithFixedLayout");
    if (fixedKbdCls) {
        SafeHookInstanceMethod(fixedKbdCls, @selector(layoutSubviews), (IMP)my_fixedKeyboard_layoutSubviews, (IMP *)&orig_fixedKeyboard_layoutSubviews);
    }

    Class softKeyCls = objc_getClass("GKBSoftKeyView");
    if (softKeyCls) {
        SafeHookInstanceMethod(softKeyCls, @selector(layoutSublayersOfLayer:), (IMP)my_softKey_layoutSublayers, (IMP *)&orig_softKey_layoutSublayers);
        SafeHookInstanceMethod(softKeyCls, @selector(updateView), (IMP)my_softKey_updateView, (IMP *)&orig_softKey_updateView);
        SafeHookInstanceMethod(softKeyCls, @selector(setIsHighlighted:), (IMP)my_softKey_setHighlighted, (IMP *)&orig_softKey_setHighlighted);
    }

    Class containerCls = objc_getClass("GKBKeyboardViewContainerView");
    if (containerCls) {
        SafeHookInstanceMethod(containerCls, @selector(touchesBegan:withEvent:), (IMP)my_container_touchesBegan, (IMP *)&orig_container_touchesBegan);
        SafeHookInstanceMethod(containerCls, @selector(touchesMoved:withEvent:), (IMP)my_container_touchesMoved, (IMP *)&orig_container_touchesMoved);
        SafeHookInstanceMethod(containerCls, @selector(touchesEnded:withEvent:), (IMP)my_container_touchesEnded, (IMP *)&orig_container_touchesEnded);
        SafeHookInstanceMethod(containerCls, @selector(touchesCancelled:withEvent:), (IMP)my_container_touchesCancelled, (IMP *)&orig_container_touchesCancelled);
    }

    Class voiceLauncherCls = objc_getClass("GKBVoiceInputLauncher");
    if (voiceLauncherCls) {
        SafeHookInstanceMethod(voiceLauncherCls, @selector(launchVoiceInput), (IMP)my_voiceLauncher_launchVoiceInput, (IMP *)&orig_voiceLauncher_launchVoiceInput);
    }
}
