#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TypelessConfig : NSObject

+ (instancetype)sharedConfig;

@property (nonatomic, copy) NSString *baseURL;
@property (nonatomic, copy) NSString *apiKey;
@property (nonatomic, copy) NSString *asrModel;
@property (nonatomic, copy) NSString *llmModel;
@property (nonatomic, copy) NSString *customPrompt;
@property (nonatomic, assign) BOOL isAIPolish;

- (BOOL)hasValidApiKey;
- (void)save;
- (void)resetToDefaults;

@end

NS_ASSUME_NONNULL_END
