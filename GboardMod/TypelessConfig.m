#import "TypelessConfig.h"

static NSString *const kVoiceModeKey          = @"Typeless_VoiceMode";
static NSString *const kTargetLangKey         = @"Typeless_TargetLang";
static NSString *const kBaseURLKey            = @"Typeless_BaseURL";
static NSString *const kApiKeyKey             = @"Typeless_ApiKey";
static NSString *const kASRModelKey           = @"Typeless_ASRModel";
static NSString *const kLLMModelKey           = @"Typeless_LLMModel";
static NSString *const kUseAppleASRKey        = @"Typeless_UseAppleASR";
static NSString *const kSmartCleanupKey       = @"Typeless_SmartCleanup";
static NSString *const kPromptDictateKey      = @"Typeless_PromptDictate";
static NSString *const kPromptEditKey         = @"Typeless_PromptEdit";
static NSString *const kPromptTranslateKey    = @"Typeless_PromptTranslate";
static NSString *const kPromptHelpWriteKey    = @"Typeless_PromptHelpWrite";

static NSString *const kDefaultDictatePrompt = @"你是智能语音听写润色助手。请将用户的口述识别原文整理成自然、通顺、可直接发送的书面文字：\n1. 去除“嗯、呃、啊、那个、就是说”等无意义口头禅和重复卡顿。\n2. 识别用户中途改口或自我纠正（如“明天三点……不对改到四点半”），只保留最终真实意图。\n3. 自动补充准确的标点符号。\n4. 只输出整理后的最终文本，不要加任何解释、引号或前缀。";

static NSString *const kDefaultEditPrompt = @"你是智能语音文本编辑助手。用户会提供【待修改文本】或【口述内容】以及【修改/润色指令】。\n请严格按照要求对文本进行修改（如调整语气、精简、扩写、改错别字或格式整理）。\n只输出修改后的最终文本，不要输出解释性说明。";

static NSString *const kDefaultTranslatePrompt = @"你是母语级实时口语翻译助手。请先去除口述中的口头禅与中途改口，然后将其自然、地道地翻译成目标语言。\n保持原意与说话语气，只输出译文。";

static NSString *const kDefaultHelpWritePrompt = @"你是高效写作助手。根据用户口述的简短意图（收件人、核心信息、风格要求），直接生成完整、得体、可直接发送的邮件、消息或文案。\n只输出最终正文内容，不要多余说明。";

@implementation TypelessConfig

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
        case TypelessVoiceModeDictate:   return @"听写";
        case TypelessVoiceModeEdit:      return @"改写";
        case TypelessVoiceModeTranslate: return @"翻译";
        case TypelessVoiceModeHelpWrite: return @"帮写";
    }
    return @"听写";
}

+ (NSArray<NSString *> *)supportedTargetLanguages {
    return @[@"English", @"简体中文", @"繁體中文", @"日本語", @"한국어", @"Español", @"Français"];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self load];
    }
    return self;
}

- (void)load {
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    NSInteger modeInt = [defs integerForKey:kVoiceModeKey];
    if (modeInt < TypelessVoiceModeDictate || modeInt > TypelessVoiceModeHelpWrite) {
        modeInt = TypelessVoiceModeDictate;
    }
    _voiceMode = (TypelessVoiceMode)modeInt;
    _targetLanguage = [defs stringForKey:kTargetLangKey] ?: @"English";
    _baseURL = [defs stringForKey:kBaseURLKey] ?: @"https://api.openai.com/v1";
    _apiKey = [defs stringForKey:kApiKeyKey] ?: @"";
    _asrModel = [defs stringForKey:kASRModelKey] ?: @"whisper-1";
    _llmModel = [defs stringForKey:kLLMModelKey] ?: @"gpt-4o-mini";
    _useAppleASR = [defs boolForKey:kUseAppleASRKey];
    _smartDictationCleanup = ([defs objectForKey:kSmartCleanupKey] != nil) ? [defs boolForKey:kSmartCleanupKey] : YES;

    _customPromptDictate = [defs stringForKey:kPromptDictateKey] ?: kDefaultDictatePrompt;
    _customPromptEdit = [defs stringForKey:kPromptEditKey] ?: kDefaultEditPrompt;
    _customPromptTranslate = [defs stringForKey:kPromptTranslateKey] ?: kDefaultTranslatePrompt;
    _customPromptHelpWrite = [defs stringForKey:kPromptHelpWriteKey] ?: kDefaultHelpWritePrompt;
}

- (void)save {
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    [defs setInteger:self.voiceMode forKey:kVoiceModeKey];
    [defs setObject:self.targetLanguage ?: @"English" forKey:kTargetLangKey];
    [defs setObject:self.baseURL ?: @"https://api.openai.com/v1" forKey:kBaseURLKey];
    [defs setObject:self.apiKey ?: @"" forKey:kApiKeyKey];
    [defs setObject:self.asrModel ?: @"whisper-1" forKey:kASRModelKey];
    [defs setObject:self.llmModel ?: @"gpt-4o-mini" forKey:kLLMModelKey];
    [defs setBool:self.useAppleASR forKey:kUseAppleASRKey];
    [defs setBool:self.smartDictationCleanup forKey:kSmartCleanupKey];
    [defs setObject:self.customPromptDictate ?: kDefaultDictatePrompt forKey:kPromptDictateKey];
    [defs setObject:self.customPromptEdit ?: kDefaultEditPrompt forKey:kPromptEditKey];
    [defs setObject:self.customPromptTranslate ?: kDefaultTranslatePrompt forKey:kPromptTranslateKey];
    [defs setObject:self.customPromptHelpWrite ?: kDefaultHelpWritePrompt forKey:kPromptHelpWriteKey];
    [defs synchronize];
}

- (void)resetToDefaults {
    self.voiceMode = TypelessVoiceModeDictate;
    self.targetLanguage = @"English";
    self.baseURL = @"https://api.openai.com/v1";
    self.apiKey = @"";
    self.asrModel = @"whisper-1";
    self.llmModel = @"gpt-4o-mini";
    self.useAppleASR = NO;
    self.smartDictationCleanup = YES;
    self.customPromptDictate = kDefaultDictatePrompt;
    self.customPromptEdit = kDefaultEditPrompt;
    self.customPromptTranslate = kDefaultTranslatePrompt;
    self.customPromptHelpWrite = kDefaultHelpWritePrompt;
    [self save];
}

- (NSString *)promptForMode:(TypelessVoiceMode)mode {
    switch (mode) {
        case TypelessVoiceModeDictate:
            return self.customPromptDictate.length > 0 ? self.customPromptDictate : kDefaultDictatePrompt;
        case TypelessVoiceModeEdit:
            return self.customPromptEdit.length > 0 ? self.customPromptEdit : kDefaultEditPrompt;
        case TypelessVoiceModeTranslate: {
            NSString *base = self.customPromptTranslate.length > 0 ? self.customPromptTranslate : kDefaultTranslatePrompt;
            return [NSString stringWithFormat:@"%@\n目标语言：%@", base, self.targetLanguage ?: @"English"];
        }
        case TypelessVoiceModeHelpWrite:
            return self.customPromptHelpWrite.length > 0 ? self.customPromptHelpWrite : kDefaultHelpWritePrompt;
    }
    return kDefaultDictatePrompt;
}

- (NSString *)customPrompt {
    return [self promptForMode:self.voiceMode];
}

- (void)setCustomPrompt:(NSString *)customPrompt {
    NSString *val = customPrompt ?: @"";
    switch (self.voiceMode) {
        case TypelessVoiceModeDictate:   self.customPromptDictate = val; break;
        case TypelessVoiceModeEdit:      self.customPromptEdit = val; break;
        case TypelessVoiceModeTranslate: self.customPromptTranslate = val; break;
        case TypelessVoiceModeHelpWrite: self.customPromptHelpWrite = val; break;
    }
}

- (BOOL)isAIPolish {
    if (self.voiceMode == TypelessVoiceModeDictate) {
        return self.smartDictationCleanup;
    }
    return YES;
}

- (void)setIsAIPolish:(BOOL)isAIPolish {
    self.smartDictationCleanup = isAIPolish;
}

- (BOOL)hasValidApiKey {
    return self.apiKey && self.apiKey.length > 5;
}

- (BOOL)shouldUseWhisperAPI {
    return [self hasValidApiKey] && !self.useAppleASR && self.asrModel.length > 0;
}

@end
