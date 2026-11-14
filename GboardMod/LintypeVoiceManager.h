#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>

NS_ASSUME_NONNULL_BEGIN

@interface LintypeVoiceManager : NSObject

+ (instancetype)sharedManager;

@property (nonatomic, weak, nullable) UIInputViewController *activeInputViewController;
@property (nonatomic, readonly) BOOL isRecording;

- (void)presentVoiceOverlayInViewController:(nullable UIInputViewController *)viewController;
- (void)dismissVoiceOverlayAnimated:(BOOL)animated;

- (void)startListeningWithLevelHandler:(void (^)(CGFloat level))levelHandler
                    partialTextHandler:(void (^)(NSString *text))partialHandler
                      finalTextHandler:(void (^)(NSString *text, NSError * _Nullable error))finalHandler;
- (void)stopListeningAndCommitText:(nullable NSString *)manualText;
- (void)cancelListening;

@end

NS_ASSUME_NONNULL_END
