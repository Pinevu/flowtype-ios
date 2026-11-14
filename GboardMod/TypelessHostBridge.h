#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^TypelessBridgeLevelBlock)(CGFloat level, NSTimeInterval elapsed);
typedef void (^TypelessBridgeRecordingCompletion)(NSString * _Nullable wavPath, NSString * _Nullable errorMessage);

@interface TypelessHostBridge : NSObject

+ (instancetype)sharedBridge;

// Host app API (Gboard.app)
@property (nonatomic, readonly) BOOL isKeepAliveActive;
- (void)configureHostObservers;
- (BOOL)handleHostOpenURL:(NSURL *)url;
- (void)startKeepAliveAndShowToast:(BOOL)showToast;
- (void)stopKeepAlive;

// Extension API (Gboard.appex)
- (BOOL)isHostBridgeAlive;
- (BOOL)startRemoteRecordingWithLevelHandler:(nullable TypelessBridgeLevelBlock)levelBlock
                                errorMessage:(NSString * _Nullable * _Nullable)outError;
- (void)stopRemoteRecordingWithCompletion:(TypelessBridgeRecordingCompletion)completion;
- (void)cancelRemoteRecording;
- (void)openHostKeepAliveFromViewController:(nullable UIInputViewController *)inputVC;

@end

NS_ASSUME_NONNULL_END
