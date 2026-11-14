#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TypelessVoiceMode) {
    TypelessVoiceModeDictate = 0,
    TypelessVoiceModeEdit = 1,
    TypelessVoiceModeTranslate = 2,
    TypelessVoiceModeHelpWrite = 3
};

@interface TypelessConfig : NSObject

+ (instancetype)sharedConfig;
+ (NSString *)titleForMode:(TypelessVoiceMode)mode;
+ (NSArray<NSString *> *)supportedTargetLanguages;

@property (nonatomic, assign) TypelessVoiceMode voiceMode;
@property (nonatomic, copy) NSString *targetLanguage;

@property (nonatomic, copy) NSString *baseURL;
@property (nonatomic, copy) NSString *apiKey;
@property (nonatomic, copy) NSString *asrModel;
@property (nonatomic, copy) NSString *llmModel;
@property (nonatomic, assign) BOOL useAppleASR;
@property (nonatomic, assign) BOOL smartDictationCleanup;

@property (nonatomic, copy) NSString *customPromptDictate;
@property (nonatomic, copy) NSString *customPromptEdit;
@property (nonatomic, copy) NSString *customPromptTranslate;
@property (nonatomic, copy) NSString *customPromptHelpWrite;

// Backward compatibility property mapping to current mode's prompt
@property (nonatomic, copy) NSString *customPrompt;
@property (nonatomic, assign) BOOL isAIPolish;

- (NSString *)promptForMode:(TypelessVoiceMode)mode;
- (BOOL)hasValidApiKey;
- (BOOL)shouldUseWhisperAPI;
- (void)load;
- (void)save;
- (void)resetToDefaults;

@end

NS_ASSUME_NONNULL_END
