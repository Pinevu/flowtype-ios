#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AppGroupFix : NSObject

+ (void)installAppGroupHooks;
+ (nullable NSString *)detectedValidAppGroup;

@end

NS_ASSUME_NONNULL_END
