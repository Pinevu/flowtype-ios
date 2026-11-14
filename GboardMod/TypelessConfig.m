#import "TypelessConfig.h"

static NSString *const kBaseURLKey    = @"Typeless_BaseURL";
static NSString *const kApiKeyKey     = @"Typeless_ApiKey";
static NSString *const kASRModelKey   = @"Typeless_ASRModel";
static NSString *const kLLMModelKey   = @"Typeless_LLMModel";
static NSString *const kPromptKey     = @"Typeless_Prompt";
static NSString *const kIsAIPolishKey = @"Typeless_IsAIPolish";

static NSString *const kDefaultPrompt = @"你是一个专业的文字润色助手。请将用户的口述文字整理为自然、通顺、清晰的书面表达，修正错别字与口误，合理添加标点符号，去除多余的'嗯'、'啊'等语气助词。保持原意，不要添加多余解释，直接输出润色后的结果。";

@implementation TypelessConfig

+ (instancetype)sharedConfig {
    static TypelessConfig *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TypelessConfig alloc] init];
    });
    return instance;
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
    _baseURL = [defs stringForKey:kBaseURLKey] ?: @"https://api.openai.com/v1";
    _apiKey = [defs stringForKey:kApiKeyKey] ?: @"";
    _asrModel = [defs stringForKey:kASRModelKey] ?: @"whisper-1";
    _llmModel = [defs stringForKey:kLLMModelKey] ?: @"gpt-4o-mini";
    _customPrompt = [defs stringForKey:kPromptKey] ?: kDefaultPrompt;
    _isAIPolish = [defs boolForKey:kIsAIPolishKey];
}

- (void)save {
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    [defs setObject:self.baseURL forKey:kBaseURLKey];
    [defs setObject:self.apiKey forKey:kApiKeyKey];
    [defs setObject:self.asrModel forKey:kASRModelKey];
    [defs setObject:self.llmModel forKey:kLLMModelKey];
    [defs setObject:self.customPrompt forKey:kPromptKey];
    [defs setBool:self.isAIPolish forKey:kIsAIPolishKey];
    [defs synchronize];
}

- (void)resetToDefaults {
    self.baseURL = @"https://api.openai.com/v1";
    self.apiKey = @"";
    self.asrModel = @"whisper-1";
    self.llmModel = @"gpt-4o-mini";
    self.customPrompt = kDefaultPrompt;
    self.isAIPolish = NO;
    [self save];
}

- (BOOL)hasValidApiKey {
    return self.apiKey && self.apiKey.length > 5;
}

@end
