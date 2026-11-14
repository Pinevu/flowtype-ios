#import <UIKit/UIKit.h>
#import "TypelessVoiceManager.h"

NS_ASSUME_NONNULL_BEGIN

@interface TypelessOverlayView : UIView

- (void)refreshStateUI;
- (void)updateAudioLevel:(CGFloat)level elapsedSeconds:(NSTimeInterval)elapsed;
- (void)updatePartialTranscript:(NSString *)text;
- (void)showErrorStatus:(NSString *)message;
- (void)showSuccessNotice:(NSString *)message;

@end

NS_ASSUME_NONNULL_END
