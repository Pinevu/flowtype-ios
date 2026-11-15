#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TypelessVoiceMode) {
    TypelessVoiceModeDictate = 0,
    TypelessVoiceModeEdit = 1,
    TypelessVoiceModeTranslate = 2,
    TypelessVoiceModeHelpWrite = 3
};

typedef NS_ENUM(NSInteger, TypelessPolishStyle) {
    TypelessPolishStyleSmart = 0,
    TypelessPolishStyleConcise = 1,
    TypelessPolishStyleFormal = 2,
    TypelessPolishStyleLight = 3
};

typedef NS_ENUM(NSInteger, TypelessLaunchInterface) {
    TypelessLaunchInterfaceKeyboard = 0,
    TypelessLaunchInterfaceVoice = 1
};

@interface TypelessConfig : NSObject

+ (instancetype)sharedConfig;
+ (NSString *)titleForMode:(TypelessVoiceMode)mode;
+ (NSArray<NSString *> *)supportedTargetLanguages;
+ (NSString *)titleForPolishStyle:(TypelessPolishStyle)style;

@property (nonatomic, assign) TypelessVoiceMode voiceMode;
@property (nonatomic, copy) NSString *targetLanguage;
@property (nonatomic, assign) TypelessPolishStyle polishStyle;
@property (nonatomic, assign) BOOL pipKeepAliveEnabled;
@property (nonatomic, assign) TypelessLaunchInterface launchInterface;

// Separated Voice Model (ASR) configuration
@property (nonatomic, copy) NSString *asrBaseURL;
@property (nonatomic, copy) NSString *asrApiKey;
@property (nonatomic, copy) NSString *asrModel;
@property (nonatomic, assign) BOOL useAppleASR;

// Separated Text Model (LLM) configuration
@property (nonatomic, copy) NSString *llmBaseURL;
@property (nonatomic, copy) NSString *llmApiKey;
@property (nonatomic, copy) NSString *llmModel;
@property (nonatomic, assign) BOOL smartDictationCleanup;

// Backward compatibility aliases mapped to LLM (with ASR fallback on read)
@property (nonatomic, copy) NSString *baseURL;
@property (nonatomic, copy) NSString *apiKey;

@property (nonatomic, copy) NSString *customPromptDictate;
@property (nonatomic, copy) NSString *customPromptEdit;
@property (nonatomic, copy) NSString *customPromptTranslate;
@property (nonatomic, copy) NSString *customPromptHelpWrite;

// Backward compatibility property mapping to current mode's prompt
@property (nonatomic, copy) NSString *customPrompt;
@property (nonatomic, assign) BOOL isAIPolish;

// Session & recent result helpers for interactive overlay
@property (nonatomic, copy) NSString *lastRawTranscript;
@property (nonatomic, copy) NSString *lastProcessedResult;
@property (nonatomic, copy) NSArray<NSString *> *recentHistory;

- (NSString *)promptForMode:(TypelessVoiceMode)mode;
- (NSString *)effectivePromptForMode:(TypelessVoiceMode)mode;
- (BOOL)hasValidAsrConfig;
- (BOOL)hasValidLlmConfig;
- (BOOL)hasValidApiKey;
- (BOOL)shouldUseWhisperAPI;

- (BOOL)hasSharedAppGroup;
- (nullable NSString *)detectedAppGroupIdentifier;
- (nullable NSString *)sharedAppGroupPath;
- (NSString *)sharedConfigDirectory;

- (void)recordHistoryResult:(NSString *)result rawText:(nullable NSString *)rawText;
- (NSDictionary<NSString *, id> *)exportConfigDictionary;
- (BOOL)applyConfigDictionary:(NSDictionary<NSString *, id> *)dict persist:(BOOL)persist;

- (void)load;
- (void)save;
- (void)resetToDefaults;

@end

NS_ASSUME_NONNULL_END
