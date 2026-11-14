#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TypelessOverlayView : UIView

- (void)updateAudioLevel:(CGFloat)level;
- (void)updateTranscriptText:(NSString *)text;
- (void)setStatusText:(NSString *)status;
- (void)resetForNewRecording;

@end

NS_ASSUME_NONNULL_END
