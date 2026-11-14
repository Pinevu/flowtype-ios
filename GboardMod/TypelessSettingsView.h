#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol TypelessSettingsViewDelegate <NSObject>
- (void)typelessSettingsDidSave;
- (void)typelessSettingsDidClose;
@end

@interface TypelessSettingsView : UIView

@property (nonatomic, weak, nullable) id<TypelessSettingsViewDelegate> delegate;

- (void)reloadConfig;

@end

NS_ASSUME_NONNULL_END
