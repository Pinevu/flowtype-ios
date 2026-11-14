#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol LintypeVoiceOverlayViewDelegate <NSObject>
- (void)voiceOverlayDidTapDone:(NSString *)text;
- (void)voiceOverlayDidTapCancel;
- (void)voiceOverlayDidTapRetry;
@end

@interface LintypeVoiceOverlayView : UIView

@property (nonatomic, weak, nullable) id<LintypeVoiceOverlayViewDelegate> delegate;

- (void)updateAudioLevel:(CGFloat)level;
- (void)updateTranscriptText:(NSString *)text;
- (void)setStatusText:(NSString *)status;
- (void)reset;

@end

NS_ASSUME_NONNULL_END
