#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TypelessVoiceManager : NSObject

+ (instancetype)sharedManager;

@property (nonatomic, weak, nullable) UIInputViewController *activeInputViewController;
@property (nonatomic, readonly) BOOL isRecording;

- (void)presentVoiceOverlayInViewController:(nullable UIInputViewController *)viewController;
- (void)dismissVoiceOverlayAnimated:(BOOL)animated;

- (void)startRecordingWithLevelHandler:(void (^)(CGFloat level))levelHandler;
- (void)stopRecordingAndProcessWithStatusHandler:(void (^)(NSString *status))statusHandler
                               completionHandler:(void (^)(NSString * _Nullable text, NSError * _Nullable error))completionHandler;
- (void)cancelRecording;
- (void)commitTextDirectly:(NSString *)text;
- (void)quickMicTapped:(nullable id)sender;

@end

NS_ASSUME_NONNULL_END
