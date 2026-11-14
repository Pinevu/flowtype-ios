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

#pragma mark - Keyboard Extension Hooks & Coordinated Header Voice Bar

static NSInteger const kHeaderVoiceBarTag = 99201;

@interface LintypeHeaderBarHelper : NSObject
+ (instancetype)sharedHelper;
- (void)attachOrRefreshInHeaderView:(UIView *)container gButton:(nullable UIView *)gButton;
@end

@implementation LintypeHeaderBarHelper

+ (instancetype)sharedHelper {
    static LintypeHeaderBarHelper *h = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        h = [[LintypeHeaderBarHelper alloc] init];
    });
    return h;
}

- (void)handleVoiceTap:(id)sender {
    TypelessVoiceManager *mgr = [TypelessVoiceManager sharedManager];
    UIInputViewController *inputVC = mgr.activeInputViewController;
    if (inputVC) {
        [mgr presentVoiceOverlayInViewController:inputVC autoStart:YES];
    }
}

- (void)handleKeepAliveTap:(id)sender {
    TypelessVoiceManager *mgr = [TypelessVoiceManager sharedManager];
    TypelessHostBridge *bridge = [TypelessHostBridge sharedBridge];
    if ([bridge isHostBridgeAlive]) {
        if (mgr.activeInputViewController) {
            [mgr presentVoiceOverlayInViewController:mgr.activeInputViewController autoStart:YES];
        }
    } else {
        [bridge openHostKeepAliveFromViewController:mgr.activeInputViewController];
    }
}

- (void)hideRightCornerMicInView:(UIView *)view root:(UIView *)root gButton:(nullable UIView *)gButton depth:(NSInteger)depth {
    if (!view || depth > 3 || view == gButton || view.tag == kHeaderVoiceBarTag) return;
    CGFloat rootW = CGRectGetWidth(root.bounds);
    for (UIView *sub in view.subviews) {
        if (sub == gButton || sub.tag == kHeaderVoiceBarTag) continue;
        CGRect rectInRoot = [sub convertRect:sub.bounds toView:root];
        BOOL isRightCornerSmall = (CGRectGetMidX(rectInRoot) > rootW - 64.0 &&
                                   CGRectGetWidth(rectInRoot) > 8.0 &&
                                   CGRectGetWidth(rectInRoot) <= 56.0 &&
                                   CGRectGetHeight(rectInRoot) > 8.0 &&
                                   CGRectGetHeight(rectInRoot) <= 52.0 &&
                                   CGRectGetMidY(rectInRoot) <= 56.0);
        if (isRightCornerSmall && ([sub isKindOfClass:[UIControl class]] || [sub isKindOfClass:[UIImageView class]])) {
            sub.hidden = YES;
            sub.alpha = 0.0;
            sub.userInteractionEnabled = NO;
            continue;
        }
        [self hideRightCornerMicInView:sub root:root gButton:gButton depth:depth + 1];
    }
}

- (void)attachOrRefreshInHeaderView:(UIView *)container gButton:(nullable UIView *)gButton {
    if (!container || CGRectGetWidth(container.bounds) < 160) return;

    // Hide Gboard's mismatched small corner gray mic button while leaving G button & candidates intact
    [self hideRightCornerMicInView:container root:container gButton:gButton depth:0];

    UIView *pill = [container viewWithTag:kHeaderVoiceBarTag];
    BOOL dark = NO;
    if (@available(iOS 13.0, *)) {
        dark = (container.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    }
    BOOL alive = [[TypelessHostBridge sharedBridge] isHostBridgeAlive];

    if (!pill) {
        pill = [[UIView alloc] initWithFrame:CGRectZero];
        pill.tag = kHeaderVoiceBarTag;
        pill.translatesAutoresizingMaskIntoConstraints = NO;
        pill.layer.cornerRadius = 16.0;
        pill.layer.borderWidth = 0.6;
        [container addSubview:pill];

        UIButton *voiceBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        voiceBtn.tag = 99202;
        voiceBtn.translatesAutoresizingMaskIntoConstraints = NO;
        voiceBtn.titleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
        voiceBtn.contentEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 8);
        if (@available(iOS 13.0, *)) {
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold];
            [voiceBtn setImage:[UIImage systemImageNamed:@"waveform.circle.fill" withConfiguration:cfg] forState:UIControlStateNormal];
            voiceBtn.imageEdgeInsets = UIEdgeInsetsMake(0, -3, 0, 3);
        }
        [voiceBtn setTitle:@"AI 语音" forState:UIControlStateNormal];
        [voiceBtn addTarget:self action:@selector(handleVoiceTap:) forControlEvents:UIControlEventTouchUpInside];
        [pill addSubview:voiceBtn];

        UIView *sep = [[UIView alloc] initWithFrame:CGRectZero];
        sep.tag = 99203;
        sep.translatesAutoresizingMaskIntoConstraints = NO;
        [pill addSubview:sep];

        UIButton *kaBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        kaBtn.tag = 99204;
        kaBtn.translatesAutoresizingMaskIntoConstraints = NO;
        kaBtn.titleLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightMedium];
        kaBtn.contentEdgeInsets = UIEdgeInsetsMake(0, 7, 0, 10);
        [kaBtn addTarget:self action:@selector(handleKeepAliveTap:) forControlEvents:UIControlEventTouchUpInside];
        [pill addSubview:kaBtn];

        NSLayoutYAxisAnchor *centerAnchor = gButton ? gButton.centerYAnchor : container.centerYAnchor;
        [NSLayoutConstraint activateConstraints:@[
            [pill.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-10.0],
            [pill.centerYAnchor constraintEqualToAnchor:centerAnchor],
            [pill.heightAnchor constraintEqualToConstant:32.0],

            [voiceBtn.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor],
            [voiceBtn.topAnchor constraintEqualToAnchor:pill.topAnchor],
            [voiceBtn.bottomAnchor constraintEqualToAnchor:pill.bottomAnchor],

            [sep.leadingAnchor constraintEqualToAnchor:voiceBtn.trailingAnchor],
            [sep.centerYAnchor constraintEqualToAnchor:pill.centerYAnchor],
            [sep.widthAnchor constraintEqualToConstant:1.0 / [UIScreen mainScreen].scale],
            [sep.heightAnchor constraintEqualToConstant:14.0],

            [kaBtn.leadingAnchor constraintEqualToAnchor:sep.trailingAnchor],
            [kaBtn.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor],
            [kaBtn.topAnchor constraintEqualToAnchor:pill.topAnchor],
            [kaBtn.bottomAnchor constraintEqualToAnchor:pill.bottomAnchor],
        ]];
    }

    pill.backgroundColor = dark
        ? [UIColor colorWithRed:0.14 green:0.18 blue:0.26 alpha:0.94]
        : [UIColor colorWithRed:0.94 green:0.96 blue:1.00 alpha:0.96];
    pill.layer.borderColor = dark
        ? [UIColor colorWithRed:0.28 green:0.44 blue:0.78 alpha:0.45].CGColor
        : [UIColor colorWithRed:0.23 green:0.51 blue:0.96 alpha:0.25].CGColor;

    UIButton *voiceBtn = (UIButton *)[pill viewWithTag:99202];
    UIView *sep = [pill viewWithTag:99203];
    UIButton *kaBtn = (UIButton *)[pill viewWithTag:99204];

    UIColor *accent = dark
        ? [UIColor colorWithRed:0.42 green:0.68 blue:1.00 alpha:1.0]
        : [UIColor colorWithRed:0.10 green:0.43 blue:0.94 alpha:1.0];
    voiceBtn.tintColor = accent;
    [voiceBtn setTitleColor:accent forState:UIControlStateNormal];

    sep.backgroundColor = dark
        ? [UIColor colorWithWhite:1.0 alpha:0.16]
        : [UIColor colorWithWhite:0.0 alpha:0.12];

    UIColor *kaColor = alive
        ? [UIColor colorWithRed:0.05 green:0.62 blue:0.42 alpha:1.0]
        : [UIColor colorWithRed:0.85 green:0.47 blue:0.05 alpha:1.0];
    kaBtn.tintColor = kaColor;
    [kaBtn setTitleColor:kaColor forState:UIControlStateNormal];
    [kaBtn setTitle:(alive ? @"● 免切" : @"⚡ 保活") forState:UIControlStateNormal];

    [container bringSubviewToFront:pill];
}

@end

static void RefreshHeaderVoicePillForVC(id headerVC) {
    @try {
        if (!headerVC) return;
        UIView *container = nil;
        if ([headerVC respondsToSelector:@selector(headerContainerView)]) {
            container = ((id(*)(id, SEL))objc_msgSend)(headerVC, @selector(headerContainerView));
        }
        if (!container && [headerVC respondsToSelector:@selector(view)]) {
            container = ((id(*)(id, SEL))objc_msgSend)(headerVC, @selector(view));
        }
        UIView *gBtn = nil;
        if ([headerVC respondsToSelector:@selector(GButton)]) {
            gBtn = ((id(*)(id, SEL))objc_msgSend)(headerVC, @selector(GButton));
        }
        if (container) {
            [[LintypeHeaderBarHelper sharedHelper] attachOrRefreshInHeaderView:container gButton:gBtn];
        }
    } @catch (NSException *e) {}
}

static void (*orig_headerVc_viewWillAppear)(UIViewController *self, SEL _cmd, BOOL animated) = NULL;
static void my_headerVc_viewWillAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    if (orig_headerVc_viewWillAppear) orig_headerVc_viewWillAppear(self, _cmd, animated);
    dispatch_async(dispatch_get_main_queue(), ^{
        RefreshHeaderVoicePillForVC(self);
    });
}

static void (*orig_headerVc_viewDidAppear)(UIViewController *self, SEL _cmd, BOOL animated) = NULL;
static void my_headerVc_viewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    if (orig_headerVc_viewDidAppear) orig_headerVc_viewDidAppear(self, _cmd, animated);
    RefreshHeaderVoicePillForVC(self);
}

static void (*orig_inputVc_viewWillAppear)(UIInputViewController *self, SEL _cmd, BOOL animated) = NULL;
static void my_inputVc_viewWillAppear(UIInputViewController *self, SEL _cmd, BOOL animated) {
    @try {
        [[TypelessConfig sharedConfig] load];
        [[TypelessHostBridge sharedBridge] syncConfigFromHostIfNeeded];
        EnsureDefaultZhHans9KeyPreferencesIfNeeded();
        [TypelessVoiceManager sharedManager].activeInputViewController = self;
    } @catch (NSException *e) {}
    if (orig_inputVc_viewWillAppear) {
        orig_inputVc_viewWillAppear(self, _cmd, animated);
    }
}

static UIView * _Nullable FindHeaderViewInHierarchy(UIView *root, NSInteger depth) {
    if (!root || depth > 5) return nil;
    if ([root.accessibilityIdentifier isEqualToString:@"combined_search_header"]) {
        return root;
    }
    for (UIView *sub in root.subviews) {
        UIView *hit = FindHeaderViewInHierarchy(sub, depth + 1);
        if (hit) return hit;
    }
    return nil;
}

static void (*orig_inputVc_viewDidAppear)(UIInputViewController *self, SEL _cmd, BOOL animated) = NULL;
static void my_inputVc_viewDidAppear(UIInputViewController *self, SEL _cmd, BOOL animated) {
    if (orig_inputVc_viewDidAppear) {
        orig_inputVc_viewDidAppear(self, _cmd, animated);
    }
    @try {
        [[TypelessConfig sharedConfig] load];
        [TypelessVoiceManager sharedManager].activeInputViewController = self;
        BOOL attached = NO;
        for (UIViewController *child in self.childViewControllers) {
            if ([NSStringFromClass([child class]) containsString:@"Header"]) {
                RefreshHeaderVoicePillForVC(child);
                attached = YES;
            }
        }
        if (!attached) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                UIView *hdr = FindHeaderViewInHierarchy(self.view, 0);
                if (hdr) {
                    [[LintypeHeaderBarHelper sharedHelper] attachOrRefreshInHeaderView:hdr gButton:nil];
                }
            });
        }
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
    NSLog(@"[LintypeGboard] Initializing v1.0.8 lightweight safe hooks...");

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

    Class voiceLauncherCls = objc_getClass("GKBVoiceInputLauncher");
    if (voiceLauncherCls) {
        SafeHookInstanceMethod(voiceLauncherCls, @selector(launchVoiceInput), (IMP)my_voiceLauncher_launchVoiceInput, (IMP *)&orig_voiceLauncher_launchVoiceInput);
    }
}
