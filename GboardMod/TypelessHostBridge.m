#import "TypelessHostBridge.h"
#import "TypelessConfig.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreFoundation/CoreFoundation.h>

static NSString *const kBridgeStartCmd = @"com.lintype.gboard.bridge.start";
static NSString *const kBridgeStopCmd = @"com.lintype.gboard.bridge.stop";
static NSString *const kBridgeCancelCmd = @"com.lintype.gboard.bridge.cancel";
static NSString *const kBridgeTickNotify = @"com.lintype.gboard.bridge.tick";
static NSString *const kBridgeDoneNotify = @"com.lintype.gboard.bridge.done";
static NSString *const kBridgeKeepAliveChangedNotification = @"TypelessHostKeepAliveChanged";

static NSString *const kBridgeStateFile = @"lintype_bridge_state.json";
static NSString *const kBridgeAudioFile = @"lintype_bridge_rec.wav";

static NSData *TypelessCreateSilentPCM16WAV(NSTimeInterval seconds) {
    NSUInteger sampleRate = 16000;
    NSUInteger numSamples = (NSUInteger)(sampleRate * seconds);
    uint32_t dataSize = (uint32_t)(numSamples * sizeof(int16_t));
    uint32_t chunkSize = 36 + dataSize;

    NSMutableData *wav = [NSMutableData dataWithCapacity:44 + dataSize];
    [wav appendBytes:"RIFF" length:4];
    [wav appendBytes:&chunkSize length:4];
    [wav appendBytes:"WAVEfmt " length:8];
    uint32_t subchunk1 = 16;
    uint16_t audioFmt = 1, numChannels = 1, bitsPerSample = 16, blockAlign = 2;
    uint32_t sr = (uint32_t)sampleRate, byteRate = sr * 2;
    [wav appendBytes:&subchunk1 length:4];
    [wav appendBytes:&audioFmt length:2];
    [wav appendBytes:&numChannels length:2];
    [wav appendBytes:&sr length:4];
    [wav appendBytes:&byteRate length:4];
    [wav appendBytes:&blockAlign length:2];
    [wav appendBytes:&bitsPerSample length:2];
    [wav appendBytes:"data" length:4];
    [wav appendBytes:&dataSize length:4];
    [wav increaseLengthBy:dataSize];
    return wav;
}

@interface TypelessHostBridge ()
@property (nonatomic, assign, readwrite) BOOL isKeepAliveActive;
@property (nonatomic, strong, nullable) AVAudioPlayer *silentPlayer;
@property (nonatomic, strong, nullable) AVAudioRecorder *hostRecorder;
@property (nonatomic, strong, nullable) NSTimer *heartbeatTimer;
@property (nonatomic, strong, nullable) NSTimer *hostMeterTimer;
@property (nonatomic, strong, nullable) NSTimer *extPollTimer;
@property (nonatomic, strong, nullable) NSDate *hostRecordStart;
@property (nonatomic, copy, nullable) NSString *hostRecordingStatus;

@property (nonatomic, copy, nullable) TypelessBridgeLevelBlock extLevelHandler;
@property (nonatomic, copy, nullable) TypelessBridgeRecordingCompletion extStopCompletion;
@property (nonatomic, assign) BOOL hostObserversConfigured;

- (void)hostHandleStartCommand;
- (void)hostHandleStopCommand;
- (void)hostHandleCancelCommand;
- (void)extPollStateFromDisk;
@end

static void BridgeDarwinCallback(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
    NSString *n = (__bridge NSString *)name;
    dispatch_async(dispatch_get_main_queue(), ^{
        TypelessHostBridge *bridge = [TypelessHostBridge sharedBridge];
        if ([n isEqualToString:kBridgeStartCmd]) {
            [bridge hostHandleStartCommand];
        } else if ([n isEqualToString:kBridgeStopCmd]) {
            [bridge hostHandleStopCommand];
        } else if ([n isEqualToString:kBridgeCancelCmd]) {
            [bridge hostHandleCancelCommand];
        } else if ([n isEqualToString:kBridgeTickNotify] || [n isEqualToString:kBridgeDoneNotify]) {
            [bridge extPollStateFromDisk];
        }
    });
}

@implementation TypelessHostBridge

+ (instancetype)sharedBridge {
    static TypelessHostBridge *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TypelessHostBridge alloc] init];
    });
    return instance;
}

- (NSString *)stateFilePath {
    return [[[TypelessConfig sharedConfig] sharedConfigDirectory] stringByAppendingPathComponent:kBridgeStateFile];
}

- (NSString *)audioFilePath {
    return [[[TypelessConfig sharedConfig] sharedConfigDirectory] stringByAppendingPathComponent:kBridgeAudioFile];
}

- (NSDictionary *)readBridgeState {
    NSData *data = [NSData dataWithContentsOfFile:[self stateFilePath]];
    if (!data) return @{};
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : @{};
}

- (void)writeBridgeStateAlive:(BOOL)alive status:(NSString *)status level:(CGFloat)level elapsed:(NSTimeInterval)elapsed error:(nullable NSString *)err {
    NSDictionary *dict = @{
        @"alive": @(alive),
        @"heartbeat": @([[NSDate date] timeIntervalSince1970]),
        @"status": status ?: @"idle",
        @"level": @(level),
        @"elapsed": @(elapsed),
        @"error": err ?: @""
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    if (data) {
        [data writeToFile:[self stateFilePath] atomically:YES];
    }
}

#pragma mark - Host App Side

- (void)configureHostObservers {
    if (_hostObserversConfigured) return;
    _hostObserversConfigured = YES;

    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
    for (NSString *n in @[kBridgeStartCmd, kBridgeStopCmd, kBridgeCancelCmd]) {
        CFNotificationCenterAddObserver(center, (__bridge const void *)self, BridgeDarwinCallback, (__bridge CFStringRef)n, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }

    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"Typeless_AutoKeepAlive"]) {
        [self startKeepAliveAndShowToast:NO];
    }
}

- (BOOL)handleHostOpenURL:(NSURL *)url {
    if (!url) return NO;
    NSString *host = url.host.lowercaseString ?: @"";
    NSString *abs = url.absoluteString.lowercaseString ?: @"";
    if ([host containsString:@"typeless-keepalive"] || [abs containsString:@"typeless-keepalive"]) {
        [self startKeepAliveAndShowToast:YES];
        return YES;
    }
    return NO;
}

- (void)startKeepAliveAndShowToast:(BOOL)showToast {
    dispatch_async(dispatch_get_main_queue(), ^{
        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session requestRecordPermission:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self activatePlaybackKeepAliveWithMicGranted:granted showToast:showToast];
            });
        }];
    });
}

- (void)activatePlaybackKeepAliveWithMicGranted:(BOOL)granted showToast:(BOOL)showToast {
    @try {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        NSError *err = nil;
        [session setCategory:AVAudioSessionCategoryPlayback
                 withOptions:AVAudioSessionCategoryOptionMixWithOthers
                       error:&err];
        [session setActive:YES error:&err];

        if (!_silentPlayer) {
            NSData *wav = TypelessCreateSilentPCM16WAV(1.0);
            _silentPlayer = [[AVAudioPlayer alloc] initWithData:wav error:nil];
            _silentPlayer.numberOfLoops = -1;
            _silentPlayer.volume = 0.001f;
            [_silentPlayer prepareToPlay];
        }
        [_silentPlayer play];

        self.isKeepAliveActive = YES;
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"Typeless_AutoKeepAlive"];
        [[NSUserDefaults standardUserDefaults] synchronize];

        _hostRecordingStatus = @"idle";
        [self writeBridgeStateAlive:YES status:@"idle" level:0 elapsed:0 error:(granted ? nil : @"未授予麦克风权限")];

        [_heartbeatTimer invalidate];
        _heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(NSTimer * _Nonnull timer) {
            if (!self.isKeepAliveActive) return;
            NSTimeInterval el = self.hostRecordStart ? [[NSDate date] timeIntervalSinceDate:self.hostRecordStart] : 0;
            [self writeBridgeStateAlive:YES status:self.hostRecordingStatus ?: @"idle" level:0 elapsed:el error:nil];
        }];

        [[NSNotificationCenter defaultCenter] postNotificationName:kBridgeKeepAliveChangedNotification object:self];

        if (showToast) {
            [self showHostToast:(granted
                ? @"✓ 后台语音保活已开启！请点左上角返回原应用继续说话"
                : @"⚠️ 请在系统设置允许 Gboard 使用麦克风权限")];
        }
    } @catch (NSException *e) {
        NSLog(@"[TypelessHostBridge] activateKeepAlive exception: %@", e);
    }
}

- (void)stopKeepAlive {
    [_heartbeatTimer invalidate];
    _heartbeatTimer = nil;
    [_hostMeterTimer invalidate];
    _hostMeterTimer = nil;
    [_hostRecorder stop];
    _hostRecorder = nil;
    [_silentPlayer stop];
    _silentPlayer = nil;

    self.isKeepAliveActive = NO;
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"Typeless_AutoKeepAlive"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self writeBridgeStateAlive:NO status:@"stopped" level:0 elapsed:0 error:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:kBridgeKeepAliveChangedNotification object:self];
}

- (void)hostHandleStartCommand {
    if (!self.isKeepAliveActive) return;
    @try {
        [_hostMeterTimer invalidate];
        _hostMeterTimer = nil;
        if (_hostRecorder.isRecording) [_hostRecorder stop];

        AVAudioSession *session = [AVAudioSession sharedInstance];
        NSError *err = nil;
        [session setCategory:AVAudioSessionCategoryPlayAndRecord
                 withOptions:AVAudioSessionCategoryOptionMixWithOthers | AVAudioSessionCategoryOptionDefaultToSpeaker | AVAudioSessionCategoryOptionAllowBluetooth
                       error:&err];
        [session setActive:YES error:&err];
        if (err) {
            [self writeBridgeStateAlive:YES status:@"error" level:0 elapsed:0 error:err.localizedDescription];
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)kBridgeTickNotify, NULL, NULL, YES);
            return;
        }

        NSString *wavPath = [self audioFilePath];
        [[NSFileManager defaultManager] removeItemAtPath:wavPath error:nil];

        NSDictionary *settings = @{
            AVFormatIDKey: @(kAudioFormatLinearPCM),
            AVSampleRateKey: @16000.0,
            AVNumberOfChannelsKey: @1,
            AVLinearPCMBitDepthKey: @16,
            AVLinearPCMIsFloatKey: @NO
        };
        _hostRecorder = [[AVAudioRecorder alloc] initWithURL:[NSURL fileURLWithPath:wavPath] settings:settings error:&err];
        _hostRecorder.meteringEnabled = YES;
        if (!_hostRecorder || ![_hostRecorder prepareToRecord] || ![_hostRecorder record]) {
            [self writeBridgeStateAlive:YES status:@"error" level:0 elapsed:0 error:(err.localizedDescription ?: @"主程序启动录音失败")];
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)kBridgeTickNotify, NULL, NULL, YES);
            return;
        }

        _hostRecordStart = [NSDate date];
        _hostRecordingStatus = @"recording";
        [self writeBridgeStateAlive:YES status:@"recording" level:0.1 elapsed:0 error:nil];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)kBridgeTickNotify, NULL, NULL, YES);

        _hostMeterTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer * _Nonnull timer) {
            if (!self.hostRecorder.isRecording) return;
            [self.hostRecorder updateMeters];
            float db = [self.hostRecorder averagePowerForChannel:0];
            CGFloat level = MAX(0.05, MIN(1.0, (db + 52.0f) / 48.0f));
            NSTimeInterval el = [[NSDate date] timeIntervalSinceDate:self.hostRecordStart];
            [self writeBridgeStateAlive:YES status:@"recording" level:level elapsed:el error:nil];
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)kBridgeTickNotify, NULL, NULL, YES);
        }];
    } @catch (NSException *e) {
        [self writeBridgeStateAlive:YES status:@"error" level:0 elapsed:0 error:e.reason];
    }
}

- (void)hostHandleStopCommand {
    [_hostMeterTimer invalidate];
    _hostMeterTimer = nil;

    NSTimeInterval el = _hostRecordStart ? [[NSDate date] timeIntervalSinceDate:_hostRecordStart] : 0;
    if (_hostRecorder.isRecording) {
        [_hostRecorder stop];
    }
    _hostRecorder = nil;
    _hostRecordStart = nil;

    // Return audio session cleanly to passive playback so the orange mic dot disappears immediately
    @try {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
        [session setActive:YES error:nil];
        [_silentPlayer play];
    } @catch (NSException *e) {}

    _hostRecordingStatus = @"ready";
    [self writeBridgeStateAlive:YES status:@"ready" level:0 elapsed:el error:nil];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)kBridgeDoneNotify, NULL, NULL, YES);
}

- (void)hostHandleCancelCommand {
    [_hostMeterTimer invalidate];
    _hostMeterTimer = nil;
    if (_hostRecorder.isRecording) [_hostRecorder stop];
    _hostRecorder = nil;
    _hostRecordStart = nil;
    [[NSFileManager defaultManager] removeItemAtPath:[self audioFilePath] error:nil];

    @try {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
        [session setActive:YES error:nil];
        [_silentPlayer play];
    } @catch (NSException *e) {}

    _hostRecordingStatus = @"idle";
    [self writeBridgeStateAlive:YES status:@"idle" level:0 elapsed:0 error:nil];
}

- (void)showHostToast:(NSString *)text {
    UIWindow *win = nil;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in scene.windows) {
                    if (w.isKeyWindow) { win = w; break; }
                }
            }
            if (win) break;
        }
    }
    if (!win) win = [UIApplication sharedApplication].keyWindow;
    if (!win) return;

    UIView *banner = [[UIView alloc] initWithFrame:CGRectMake(16, -60, win.bounds.size.width - 32, 52)];
    banner.backgroundColor = [UIColor colorWithRed:0.08 green:0.55 blue:0.28 alpha:0.96];
    banner.layer.cornerRadius = 14;
    banner.layer.shadowColor = [UIColor blackColor].CGColor;
    banner.layer.shadowOpacity = 0.2;
    banner.layer.shadowRadius = 8;

    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(14, 6, banner.bounds.size.width - 28, 40)];
    lbl.text = text;
    lbl.textColor = [UIColor whiteColor];
    lbl.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    lbl.numberOfLines = 2;
    lbl.textAlignment = NSTextAlignmentCenter;
    [banner addSubview:lbl];
    [win addSubview:banner];

    CGFloat topY = 54;
    if (@available(iOS 11.0, *)) {
        topY = MAX(win.safeAreaInsets.top + 8, 28);
    }
    [UIView animateWithDuration:0.3 animations:^{
        banner.frame = CGRectMake(16, topY, win.bounds.size.width - 32, 52);
    } completion:^(BOOL finished) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.3 animations:^{
                banner.alpha = 0;
            } completion:^(BOOL f2) {
                [banner removeFromSuperview];
            }];
        });
    }];
}

#pragma mark - Keyboard Extension Side

- (BOOL)isHostBridgeAlive {
    if (![[TypelessConfig sharedConfig] hasSharedAppGroup]) return NO;
    NSDictionary *state = [self readBridgeState];
    if (![state[@"alive"] boolValue]) return NO;
    NSTimeInterval hb = [state[@"heartbeat"] doubleValue];
    NSTimeInterval age = [[NSDate date] timeIntervalSince1970] - hb;
    return age >= -2.0 && age < 8.0;
}

- (void)ensureExtObservers {
    static BOOL extReg = NO;
    if (extReg) return;
    extReg = YES;
    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(center, (__bridge const void *)self, BridgeDarwinCallback, (__bridge CFStringRef)kBridgeTickNotify, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(center, (__bridge const void *)self, BridgeDarwinCallback, (__bridge CFStringRef)kBridgeDoneNotify, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}

- (BOOL)startRemoteRecordingWithLevelHandler:(TypelessBridgeLevelBlock)levelBlock errorMessage:(NSString * _Nullable __autoreleasing *)outError {
    if (![self isHostBridgeAlive]) {
        if (outError) *outError = @"主程序后台语音未运行";
        return NO;
    }
    [self ensureExtObservers];
    self.extLevelHandler = levelBlock;
    self.extStopCompletion = nil;

    [self writeBridgeStateAlive:YES status:@"starting" level:0 elapsed:0 error:nil];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)kBridgeStartCmd, NULL, NULL, YES);

    [_extPollTimer invalidate];
    _extPollTimer = [NSTimer scheduledTimerWithTimeInterval:0.12 repeats:YES block:^(NSTimer * _Nonnull timer) {
        [self extPollStateFromDisk];
    }];
    return YES;
}

- (void)stopRemoteRecordingWithCompletion:(TypelessBridgeRecordingCompletion)completion {
    self.extStopCompletion = completion;
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)kBridgeStopCmd, NULL, NULL, YES);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.extStopCompletion) {
            [self extPollStateFromDisk];
            if (self.extStopCompletion) {
                TypelessBridgeRecordingCompletion cb = self.extStopCompletion;
                self.extStopCompletion = nil;
                [self.extPollTimer invalidate];
                self.extPollTimer = nil;
                NSString *wavPath = [self audioFilePath];
                if ([[NSFileManager defaultManager] fileExistsAtPath:wavPath]) {
                    cb(wavPath, nil);
                } else {
                    cb(nil, @"主程序音频回传超时");
                }
            }
        }
    });
}

- (void)cancelRemoteRecording {
    [_extPollTimer invalidate];
    _extPollTimer = nil;
    self.extLevelHandler = nil;
    self.extStopCompletion = nil;
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)kBridgeCancelCmd, NULL, NULL, YES);
}

- (void)extPollStateFromDisk {
    NSDictionary *state = [self readBridgeState];
    NSString *status = state[@"status"] ?: @"";
    if ([status isEqualToString:@"recording"] && self.extLevelHandler) {
        CGFloat lv = [state[@"level"] doubleValue];
        NSTimeInterval el = [state[@"elapsed"] doubleValue];
        self.extLevelHandler(lv, el);
    } else if ([status isEqualToString:@"ready"] && self.extStopCompletion) {
        TypelessBridgeRecordingCompletion cb = self.extStopCompletion;
        self.extStopCompletion = nil;
        [_extPollTimer invalidate];
        _extPollTimer = nil;
        NSString *wavPath = [self audioFilePath];
        if ([[NSFileManager defaultManager] fileExistsAtPath:wavPath]) {
            cb(wavPath, nil);
        } else {
            cb(nil, @"未检测到录音文件");
        }
    } else if ([status isEqualToString:@"error"] && self.extStopCompletion) {
        TypelessBridgeRecordingCompletion cb = self.extStopCompletion;
        self.extStopCompletion = nil;
        [_extPollTimer invalidate];
        _extPollTimer = nil;
        cb(nil, state[@"error"] ?: @"主程序录音出错");
    }
}

- (void)openHostKeepAliveFromViewController:(UIInputViewController *)inputVC {
    NSURL *url = [NSURL URLWithString:@"gboard://typeless-keepalive"];
    if (!url || !inputVC) return;

    // 1. Try UIApplication responder chain (works reliably in iOS Keyboard Extensions)
    UIResponder *responder = inputVC;
    while (responder) {
        if ([responder isKindOfClass:[UIApplication class]]) {
            UIApplication *app = (UIApplication *)responder;
            [app openURL:url options:@{} completionHandler:nil];
            return;
        }
        responder = [responder nextResponder];
    }

    // 2. Fallback to extensionContext
    if (inputVC.extensionContext) {
        [inputVC.extensionContext openURL:url completionHandler:nil];
    }
}

@end
