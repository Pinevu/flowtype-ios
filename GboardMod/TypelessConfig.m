#import "TypelessConfig.h"
#import <CoreFoundation/CoreFoundation.h>

static NSString *const kAppGroupPrimary = @"group.com.google.keyboard";
static NSString *const kAppGroupSecondary = @"group.com.google.common";
static NSString *const kConfigChangedDarwinName = @"com.lintype.gboard.configChanged";
static NSString *const kConfigFileName = @"typeless_config.json";

static NSString *const kVoiceModeKey = @"Typeless_VoiceMode";
static NSString *const kTargetLangKey = @"Typeless_TargetLang";
static NSString *const kBaseURLKey = @"Typeless_BaseURL";
static NSString *const kApiKeyKey = @"Typeless_ApiKey";
static NSString *const kASRModelKey = @"Typeless_ASRModel";
static NSString *const kLLMModelKey = @"Typeless_LLMModel";
static NSString *const kUseAppleASRKey = @"Typeless_UseAppleASR";
static NSString *const kSmartCleanupKey = @"Typeless_SmartCleanup";
static NSString *const kUpdatedAtKey = @"Typeless_ConfigUpdatedAt";

static NSString *const kPromptDictateKey = @"Typeless_PromptDictate";
static NSString *const kPromptEditKey = @"Typeless_PromptEdit";
static NSString *const kPromptTranslateKey = @"Typeless_PromptTranslate";
static NSString *const kPromptHelpWriteKey = @"Typeless_PromptHelpWrite";

static NSString *const kDefaultDictatePrompt = @"你是一个智能语音听写助手。请修正以下口语转写中的错别字、去除口癖（嗯、啊、那个等）、添加合适的标点符号。保持原意不变，直接输出整理后的纯净文本，不要做额外解释或回复。";
static NSString *const kDefaultEditPrompt = @"你是一个智能文本编辑助手。请根据用户的语音指令，精准修改、润色或改写给定的原始文本。仅输出修改后的最终文本结果，不要输出多余说明。";
static NSString *const kDefaultTranslatePrompt = @"你是一个专业的实时翻译引擎。请将用户的语音文本地道、流畅地翻译为目标语言。直接输出翻译结果，不要附带任何解释或原文。";
static NSString *const kDefaultHelpWritePrompt = @"你是一个高效的内容写作助手。请根据用户的简短口头需求，直接撰写并输出完整、得体、可直接发送的文本内容，不要附带开场白或多余解释。";

static void TypelessConfigDarwinCallback(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[TypelessConfig sharedConfig] load];
    });
}

@implementation TypelessConfig {
    NSTimeInterval _lastLoadedTimestamp;
}

+ (instancetype)sharedConfig {
    static TypelessConfig *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TypelessConfig alloc] init];
    });
    return instance;
}

+ (NSString *)titleForMode:(TypelessVoiceMode)mode {
    switch (mode) {
        case TypelessVoiceModeDictate: return @"润色听写";
        case TypelessVoiceModeEdit: return @"选中改写";
        case TypelessVoiceModeTranslate: return @"实时翻译";
        case TypelessVoiceModeHelpWrite: return @"AI 帮写";
    }
    return @"润色听写";
}

+ (NSArray<NSString *> *)supportedTargetLanguages {
    return @[@"English", @"简体中文", @"繁體中文", @"日本語", @"한국어", @"Français", @"Deutsch", @"Español"];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lastLoadedTimestamp = 0;
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)self,
            TypelessConfigDarwinCallback,
            (__bridge CFStringRef)kConfigChangedDarwinName,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );
        [self load];
    }
    return self;
}

- (nullable NSString *)sharedAppGroupPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *u1 = [fm containerURLForSecurityApplicationGroupIdentifier:kAppGroupPrimary];
    if (u1.path.length > 0) return u1.path;
    NSURL *u2 = [fm containerURLForSecurityApplicationGroupIdentifier:kAppGroupSecondary];
    if (u2.path.length > 0) return u2.path;
    return nil;
}

- (BOOL)hasSharedAppGroup {
    NSString *p = [self sharedAppGroupPath];
    if (p.length == 0) return NO;
    return [p containsString:@"/Shared/AppGroup/"] || [p containsString:@"/ApplicationGroup/"];
}

- (NSString *)sharedConfigDirectory {
    NSString *groupPath = [self sharedAppGroupPath];
    NSString *dir = nil;
    if (groupPath.length > 0) {
        dir = [groupPath stringByAppendingPathComponent:@"Library/Application Support"];
    } else {
        dir = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
        if (dir.length == 0) dir = NSTemporaryDirectory();
    }
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

- (nullable NSUserDefaults *)sharedUserDefaults {
    @try {
        NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kAppGroupPrimary];
        if (d) return d;
        d = [[NSUserDefaults alloc] initWithSuiteName:kAppGroupSecondary];
        if (d) return d;
    } @catch (NSException *e) {}
    return nil;
}

- (nullable NSDictionary *)readConfigJSONAtDirectory:(NSString *)dir {
    if (dir.length == 0) return nil;
    NSString *path = [dir stringByAppendingPathComponent:kConfigFileName];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

- (void)applyFromDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return;

    NSNumber *modeNum = dict[@"voiceMode"];
    if (modeNum) {
        NSInteger m = modeNum.integerValue;
        _voiceMode = (m >= TypelessVoiceModeDictate && m <= TypelessVoiceModeHelpWrite) ? (TypelessVoiceMode)m : TypelessVoiceModeDictate;
    }
    if ([dict[@"targetLanguage"] isKindOfClass:[NSString class]] && [dict[@"targetLanguage"] length] > 0) {
        _targetLanguage = [dict[@"targetLanguage"] copy];
    }
    if ([dict[@"baseURL"] isKindOfClass:[NSString class]]) {
        _baseURL = [dict[@"baseURL"] copy];
    }
    if ([dict[@"apiKey"] isKindOfClass:[NSString class]]) {
        _apiKey = [dict[@"apiKey"] copy];
    }
    if ([dict[@"asrModel"] isKindOfClass:[NSString class]]) {
        _asrModel = [dict[@"asrModel"] copy];
    }
    if ([dict[@"llmModel"] isKindOfClass:[NSString class]]) {
        _llmModel = [dict[@"llmModel"] copy];
    }
    if (dict[@"useAppleASR"] != nil) {
        _useAppleASR = [dict[@"useAppleASR"] boolValue];
    }
    if (dict[@"smartDictationCleanup"] != nil) {
        _smartDictationCleanup = [dict[@"smartDictationCleanup"] boolValue];
    }
    if ([dict[@"customPromptDictate"] isKindOfClass:[NSString class]] && [dict[@"customPromptDictate"] length] > 0) {
        _customPromptDictate = [dict[@"customPromptDictate"] copy];
    }
    if ([dict[@"customPromptEdit"] isKindOfClass:[NSString class]] && [dict[@"customPromptEdit"] length] > 0) {
        _customPromptEdit = [dict[@"customPromptEdit"] copy];
    }
    if ([dict[@"customPromptTranslate"] isKindOfClass:[NSString class]] && [dict[@"customPromptTranslate"] length] > 0) {
        _customPromptTranslate = [dict[@"customPromptTranslate"] copy];
    }
    if ([dict[@"customPromptHelpWrite"] isKindOfClass:[NSString class]] && [dict[@"customPromptHelpWrite"] length] > 0) {
        _customPromptHelpWrite = [dict[@"customPromptHelpWrite"] copy];
    }
}

- (void)applyFromUserDefaults:(NSUserDefaults *)defs {
    if (!defs) return;
    NSInteger modeInt = [defs integerForKey:kVoiceModeKey];
    if (modeInt >= TypelessVoiceModeDictate && modeInt <= TypelessVoiceModeHelpWrite) {
        _voiceMode = (TypelessVoiceMode)modeInt;
    }
    if ([defs stringForKey:kTargetLangKey].length > 0) _targetLanguage = [defs stringForKey:kTargetLangKey];
    if ([defs objectForKey:kBaseURLKey]) _baseURL = [defs stringForKey:kBaseURLKey] ?: @"https://api.openai.com/v1";
    if ([defs objectForKey:kApiKeyKey]) _apiKey = [defs stringForKey:kApiKeyKey] ?: @"";
    if ([defs objectForKey:kASRModelKey]) _asrModel = [defs stringForKey:kASRModelKey] ?: @"whisper-1";
    if ([defs objectForKey:kLLMModelKey]) _llmModel = [defs stringForKey:kLLMModelKey] ?: @"gpt-4o-mini";
    if ([defs objectForKey:kUseAppleASRKey]) _useAppleASR = [defs boolForKey:kUseAppleASRKey];
    if ([defs objectForKey:kSmartCleanupKey]) _smartDictationCleanup = [defs boolForKey:kSmartCleanupKey];
    if ([defs stringForKey:kPromptDictateKey].length > 0) _customPromptDictate = [defs stringForKey:kPromptDictateKey];
    if ([defs stringForKey:kPromptEditKey].length > 0) _customPromptEdit = [defs stringForKey:kPromptEditKey];
    if ([defs stringForKey:kPromptTranslateKey].length > 0) _customPromptTranslate = [defs stringForKey:kPromptTranslateKey];
    if ([defs stringForKey:kPromptHelpWriteKey].length > 0) _customPromptHelpWrite = [defs stringForKey:kPromptHelpWriteKey];
}

- (void)load {
    // Initialize baseline defaults first
    _voiceMode = TypelessVoiceModeDictate;
    _targetLanguage = @"English";
    _baseURL = @"https://api.openai.com/v1";
    _apiKey = @"";
    _asrModel = @"whisper-1";
    _llmModel = @"gpt-4o-mini";
    _useAppleASR = NO;
    _smartDictationCleanup = YES;
    _customPromptDictate = kDefaultDictatePrompt;
    _customPromptEdit = kDefaultEditPrompt;
    _customPromptTranslate = kDefaultTranslatePrompt;
    _customPromptHelpWrite = kDefaultHelpWritePrompt;

    NSUserDefaults *std = [NSUserDefaults standardUserDefaults];
    NSUserDefaults *grp = [self sharedUserDefaults];

    // Pick newest source by updatedAt timestamp across local/shared defaults & JSON files
    NSString *localDir = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *sharedDir = [self sharedConfigDirectory];

    NSDictionary *localJSON = [self readConfigJSONAtDirectory:localDir];
    NSDictionary *sharedJSON = (![sharedDir isEqualToString:localDir]) ? [self readConfigJSONAtDirectory:sharedDir] : nil;

    NSTimeInterval tsStd = [std doubleForKey:kUpdatedAtKey];
    NSTimeInterval tsGrp = grp ? [grp doubleForKey:kUpdatedAtKey] : 0;
    NSTimeInterval tsLocalJSON = [localJSON[@"updatedAt"] doubleValue];
    NSTimeInterval tsSharedJSON = [sharedJSON[@"updatedAt"] doubleValue];

    // Apply in ascending order of freshness so newest wins
    typedef struct { NSTimeInterval ts; int kind; } ConfigSource;
    ConfigSource sources[4] = {
        { tsStd, 0 },
        { tsLocalJSON, 1 },
        { tsGrp, 2 },
        { tsSharedJSON, 3 }
    };
    for (int i = 0; i < 4; i++) {
        for (int j = i + 1; j < 4; j++) {
            if (sources[j].ts < sources[i].ts) {
                ConfigSource tmp = sources[i];
                sources[i] = sources[j];
                sources[j] = tmp;
            }
        }
    }

    for (int i = 0; i < 4; i++) {
        switch (sources[i].kind) {
            case 0: [self applyFromUserDefaults:std]; break;
            case 1: [self applyFromDictionary:localJSON]; break;
            case 2: [self applyFromUserDefaults:grp]; break;
            case 3: [self applyFromDictionary:sharedJSON]; break;
        }
    }
    _lastLoadedTimestamp = sources[3].ts;
}

- (NSDictionary *)serializedDictionaryWithTimestamp:(NSTimeInterval)ts {
    return @{
        @"voiceMode": @(_voiceMode),
        @"targetLanguage": _targetLanguage ?: @"English",
        @"baseURL": _baseURL ?: @"https://api.openai.com/v1",
        @"apiKey": _apiKey ?: @"",
        @"asrModel": _asrModel ?: @"whisper-1",
        @"llmModel": _llmModel ?: @"gpt-4o-mini",
        @"useAppleASR": @(_useAppleASR),
        @"smartDictationCleanup": @(_smartDictationCleanup),
        @"customPromptDictate": _customPromptDictate ?: kDefaultDictatePrompt,
        @"customPromptEdit": _customPromptEdit ?: kDefaultEditPrompt,
        @"customPromptTranslate": _customPromptTranslate ?: kDefaultTranslatePrompt,
        @"customPromptHelpWrite": _customPromptHelpWrite ?: kDefaultHelpWritePrompt,
        @"updatedAt": @(ts)
    };
}

- (void)writeToUserDefaults:(NSUserDefaults *)defs timestamp:(NSTimeInterval)ts {
    if (!defs) return;
    [defs setInteger:_voiceMode forKey:kVoiceModeKey];
    [defs setObject:_targetLanguage ?: @"English" forKey:kTargetLangKey];
    [defs setObject:_baseURL ?: @"https://api.openai.com/v1" forKey:kBaseURLKey];
    [defs setObject:_apiKey ?: @"" forKey:kApiKeyKey];
    [defs setObject:_asrModel ?: @"whisper-1" forKey:kASRModelKey];
    [defs setObject:_llmModel ?: @"gpt-4o-mini" forKey:kLLMModelKey];
    [defs setBool:_useAppleASR forKey:kUseAppleASRKey];
    [defs setBool:_smartDictationCleanup forKey:kSmartCleanupKey];
    [defs setObject:_customPromptDictate ?: kDefaultDictatePrompt forKey:kPromptDictateKey];
    [defs setObject:_customPromptEdit ?: kDefaultEditPrompt forKey:kPromptEditKey];
    [defs setObject:_customPromptTranslate ?: kDefaultTranslatePrompt forKey:kPromptTranslateKey];
    [defs setObject:_customPromptHelpWrite ?: kDefaultHelpWritePrompt forKey:kPromptHelpWriteKey];
    [defs setDouble:ts forKey:kUpdatedAtKey];
    [defs synchronize];
}

- (void)save {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    _lastLoadedTimestamp = now;

    [self writeToUserDefaults:[NSUserDefaults standardUserDefaults] timestamp:now];
    [self writeToUserDefaults:[self sharedUserDefaults] timestamp:now];

    NSDictionary *dict = [self serializedDictionaryWithTimestamp:now];
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:nil];
    if (jsonData) {
        NSString *sharedDir = [self sharedConfigDirectory];
        [jsonData writeToFile:[sharedDir stringByAppendingPathComponent:kConfigFileName] atomically:YES];

        NSString *localDir = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
        if (localDir.length > 0 && ![localDir isEqualToString:sharedDir]) {
            [[NSFileManager defaultManager] createDirectoryAtPath:localDir withIntermediateDirectories:YES attributes:nil error:nil];
            [jsonData writeToFile:[localDir stringByAppendingPathComponent:kConfigFileName] atomically:YES];
        }
    }

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)kConfigChangedDarwinName,
        NULL,
        NULL,
        YES
    );
}

- (void)resetToDefaults {
    _voiceMode = TypelessVoiceModeDictate;
    _targetLanguage = @"English";
    _baseURL = @"https://api.openai.com/v1";
    _apiKey = @"";
    _asrModel = @"whisper-1";
    _llmModel = @"gpt-4o-mini";
    _useAppleASR = NO;
    _smartDictationCleanup = YES;
    _customPromptDictate = kDefaultDictatePrompt;
    _customPromptEdit = kDefaultEditPrompt;
    _customPromptTranslate = kDefaultTranslatePrompt;
    _customPromptHelpWrite = kDefaultHelpWritePrompt;
    [self save];
}

- (NSString *)promptForMode:(TypelessVoiceMode)mode {
    switch (mode) {
        case TypelessVoiceModeDictate: return _customPromptDictate ?: kDefaultDictatePrompt;
        case TypelessVoiceModeEdit: return _customPromptEdit ?: kDefaultEditPrompt;
        case TypelessVoiceModeTranslate: return _customPromptTranslate ?: kDefaultTranslatePrompt;
        case TypelessVoiceModeHelpWrite: return _customPromptHelpWrite ?: kDefaultHelpWritePrompt;
    }
    return _customPromptDictate ?: kDefaultDictatePrompt;
}

- (NSString *)customPrompt {
    return [self promptForMode:_voiceMode];
}

- (void)setCustomPrompt:(NSString *)customPrompt {
    NSString *val = customPrompt.length > 0 ? customPrompt : [self promptForMode:_voiceMode];
    switch (_voiceMode) {
        case TypelessVoiceModeDictate: _customPromptDictate = [val copy]; break;
        case TypelessVoiceModeEdit: _customPromptEdit = [val copy]; break;
        case TypelessVoiceModeTranslate: _customPromptTranslate = [val copy]; break;
        case TypelessVoiceModeHelpWrite: _customPromptHelpWrite = [val copy]; break;
    }
}

- (BOOL)isAIPolish {
    return _smartDictationCleanup;
}

- (void)setIsAIPolish:(BOOL)isAIPolish {
    _smartDictationCleanup = isAIPolish;
}

- (BOOL)hasValidApiKey {
    return [[_apiKey stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length] > 0;
}

- (BOOL)shouldUseWhisperAPI {
    return !_useAppleASR && [self hasValidApiKey];
}

@end
