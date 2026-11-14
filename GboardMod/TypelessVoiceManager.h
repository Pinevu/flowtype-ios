#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TypelessSessionState) {
    TypelessSessionStateIdle = 0,
    TypelessSessionStateRecording = 1,
    TypelessSessionStateTranscribing = 2,
    TypelessSessionStateProcessingAI = 3,
    TypelessSessionStateError = 4
};

@interface TypelessVoiceManager : NSObject

+ (instancetype)sharedManager;

@property (nonatomic, weak, nullable) UIInputViewController *activeInputViewController;
@property (nonatomic, readonly) TypelessSessionState state;
@property (nonatomic, readonly) BOOL isRecording;
@property (nonatomic, readonly) BOOL canUndoLastInsert;
@property (nonatomic, readonly) BOOL isOverlayVisible;

- (void)presentVoiceOverlayInViewController:(nullable UIInputViewController *)viewController;
- (void)presentVoiceOverlayInViewController:(nullable UIInputViewController *)viewController autoStart:(BOOL)autoStart;
- (void)dismissVoiceOverlayAnimated:(BOOL)animated;

- (void)startRecording;
- (void)finishRecordingAndProcess;
- (void)cancelRecordingAndReset;
- (void)quickMicTapped:(nullable id)sender;

// Keyboard Utility Key Actions
- (void)insertSpace;
- (void)deleteBackwardStep;
- (void)insertReturn;
- (void)undoLastInsert;
- (NSString *)currentReturnKeyTitle;
- (NSString *)currentSelectedTextPreview;
- (BOOL)hasFullAccess;

@end

NS_ASSUME_NONNULL_END
