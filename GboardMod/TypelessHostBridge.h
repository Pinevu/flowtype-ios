#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^TypelessBridgeLevelBlock)(CGFloat level, NSTimeInterval elapsed);
typedef void (^TypelessBridgeRecordingCompletion)(NSString * _Nullable wavPath, NSString * _Nullable errorMessage);

@interface TypelessHostBridge : NSObject

+ (instancetype)sharedBridge;

// Host app API (Gboard.app)
@property (nonatomic, readonly) BOOL isKeepAliveActive;
@property (nonatomic, readonly) BOOL isPipActive;
@property (nonatomic, readonly) BOOL isLoopbackServerActive;
@property (nonatomic, copy, readonly) NSString *hostBridgeStatusSummary;

- (void)configureHostObservers;
- (BOOL)handleHostOpenURL:(NSURL *)url;
- (void)startKeepAliveAndShowToast:(BOOL)showToast;
- (void)stopKeepAlive;
- (void)refreshPipSettingIfActive;
- (void)startPipManuallyIfPossible;

// Extension API (Gboard.appex)
- (BOOL)isHostBridgeAlive;
- (BOOL)syncConfigFromHostIfNeeded;
- (void)syncConfigFromHostAsyncWithCompletion:(void (^ _Nullable)(BOOL updated))completion;
- (BOOL)startRemoteRecordingWithLevelHandler:(nullable TypelessBridgeLevelBlock)levelBlock
                                errorMessage:(NSString * _Nullable * _Nullable)outError;
- (void)startRemoteRecordingWithLevelHandler:(nullable TypelessBridgeLevelBlock)levelBlock
                                  completion:(void (^)(BOOL started, BOOL hostAlive, NSString * _Nullable errorMessage))completion;
- (void)stopRemoteRecordingWithCompletion:(TypelessBridgeRecordingCompletion)completion;
- (void)cancelRemoteRecording;
- (void)openHostKeepAliveFromViewController:(nullable UIInputViewController *)inputVC;

@end

NS_ASSUME_NONNULL_END
