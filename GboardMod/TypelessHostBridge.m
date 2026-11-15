#import "TypelessHostBridge.h"
#import "TypelessConfig.h"
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <signal.h>
#import <sys/select.h>
#import <sys/socket.h>
#import <unistd.h>

static uint16_t const kLoopbackPort = 48912;

static CFStringRef const kDarwinStartRec   = CFSTR("com.lintype.gboard.bridge.startRec");
static CFStringRef const kDarwinStopRec    = CFSTR("com.lintype.gboard.bridge.stopRec");
static CFStringRef const kDarwinCancelRec  = CFSTR("com.lintype.gboard.bridge.cancelRec");
static CFStringRef const kDarwinRecReady   = CFSTR("com.lintype.gboard.bridge.recReady");

@interface TypelessHostBridge () <AVAudioRecorderDelegate>
@property (nonatomic, assign) CFAbsoluteTime lastConfigSyncAt;
@property (nonatomic, assign) BOOL configSyncInFlight;
@property (nonatomic, assign, readwrite) BOOL isKeepAliveActive;
@property (nonatomic, assign, readwrite) BOOL isPipActive;
@property (nonatomic, assign, readwrite) BOOL isLoopbackServerActive;

// Silent audio keep-alive
@property (nonatomic, strong, nullable) AVAudioPlayer *silentPlayer;
@property (nonatomic, strong, nullable) NSTimer *heartbeatTimer;

// Host PiP keep-alive (iOS 15+)
@property (nonatomic, strong, nullable) UIView *pipHostView;
@property (nonatomic, strong, nullable) AVSampleBufferDisplayLayer *pipDisplayLayer;
@property (nonatomic, strong, nullable) AVPictureInPictureController *pipController;
@property (nonatomic, strong, nullable) NSTimer *pipFrameTimer;
@property (nonatomic, assign) NSInteger pipFrameCounter;

// Host recorder
@property (nonatomic, strong, nullable) AVAudioRecorder *hostRecorder;
@property (nonatomic, strong, nullable) NSTimer *hostLevelTimer;
@property (nonatomic, strong, nullable) NSDate *hostRecordStartDate;
@property (nonatomic, assign) BOOL isHostRecording;
@property (nonatomic, assign) CGFloat hostLastLevel;
@property (nonatomic, assign) NSTimeInterval hostLastElapsed;
@property (nonatomic, copy, nullable) NSString *hostLastError;
@property (nonatomic, strong, nullable) NSData *hostCachedWavData;
@property (nonatomic, copy, nullable) NSString *hostActiveWavPath;

// POSIX loopback server
@property (nonatomic, assign) int listenSock;
@property (nonatomic, strong, nullable) dispatch_queue_t serverAcceptQueue;
@property (nonatomic, strong, nullable) dispatch_queue_t serverClientQueue;

// Extension side
@property (nonatomic, assign) BOOL observersConfigured;
@property (nonatomic, assign) BOOL extUsingHTTPBridge;
@property (nonatomic, assign) CFAbsoluteTime lastAliveCheckTime;
@property (nonatomic, assign) BOOL lastAliveCheckResult;
@property (nonatomic, copy, nullable) TypelessBridgeLevelBlock extLevelBlock;
@property (nonatomic, copy, nullable) TypelessBridgeRecordingCompletion extStopCompletion;
@property (nonatomic, strong, nullable) NSTimer *extPollTimer;
@property (nonatomic, strong, nullable) NSTimer *extStopTimeoutTimer;

- (void)handleDarwinNotification:(NSString *)name;
@end

static void BridgeDarwinCallback(CFNotificationCenterRef center,
                                 void *observer,
                                 CFNotificationName name,
                                 const void *object,
                                 CFDictionaryRef userInfo) {
    TypelessHostBridge *bridge = (__bridge TypelessHostBridge *)observer;
    if (!bridge || !name) return;
    NSString *nameStr = (__bridge NSString *)name;
    dispatch_async(dispatch_get_main_queue(), ^{
        [bridge handleDarwinNotification:nameStr];
    });
}

#pragma mark - Lightweight POSIX Loopback HTTP Helpers

static NSData * _Nullable BuildSilentWavData(void) {
    uint32_t sampleRate = 8000;
    uint32_t numSamples = 8000;
    uint16_t numChannels = 1;
    uint16_t bitsPerSample = 16;
    uint32_t dataBytes = numSamples * numChannels * (bitsPerSample / 8);
    uint32_t riffSize = 36 + dataBytes;
    uint32_t byteRate = sampleRate * numChannels * (bitsPerSample / 8);
    uint16_t blockAlign = numChannels * (bitsPerSample / 8);

    NSMutableData *wav = [NSMutableData dataWithCapacity:44 + dataBytes];
    [wav appendBytes:"RIFF" length:4];
    [wav appendBytes:&riffSize length:4];
    [wav appendBytes:"WAVEfmt " length:8];
    uint32_t fmtSize = 16;
    uint16_t audioFmt = 1;
    [wav appendBytes:&fmtSize length:4];
    [wav appendBytes:&audioFmt length:2];
    [wav appendBytes:&numChannels length:2];
    [wav appendBytes:&sampleRate length:4];
    [wav appendBytes:&byteRate length:4];
    [wav appendBytes:&blockAlign length:2];
    [wav appendBytes:&bitsPerSample length:2];
    [wav appendBytes:"data" length:4];
    [wav appendBytes:&dataBytes length:4];
    NSMutableData *silence = [NSMutableData dataWithLength:dataBytes];
    [wav appendData:silence];
    return wav;
}

static NSData * _Nullable LoopbackHTTPRequest(NSString *method,
                                              NSString *path,
                                              NSTimeInterval timeoutSec,
                                              NSInteger * _Nullable outStatus) {
    if (outStatus) *outStatus = 0;

    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return nil;

    int on = 1;
    setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));

    int flags = fcntl(sock, F_GETFL, 0);
    if (flags >= 0) fcntl(sock, F_SETFL, flags | O_NONBLOCK);

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kLoopbackPort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    int rc = connect(sock, (struct sockaddr *)&addr, sizeof(addr));
    if (rc < 0 && errno != EINPROGRESS) {
        close(sock);
        return nil;
    }

    if (rc != 0) {
        fd_set wset;
        FD_ZERO(&wset);
        FD_SET(sock, &wset);
        struct timeval tv;
        NSTimeInterval cTimeout = MIN(timeoutSec, 0.25);
        tv.tv_sec = (int)cTimeout;
        tv.tv_usec = (int)((cTimeout - tv.tv_sec) * 1000000.0);
        int sel = select(sock + 1, NULL, &wset, NULL, &tv);
        if (sel <= 0) {
            close(sock);
            return nil;
        }
        int sockErr = 0;
        socklen_t errLen = sizeof(sockErr);
        if (getsockopt(sock, SOL_SOCKET, SO_ERROR, &sockErr, &errLen) < 0 || sockErr != 0) {
            close(sock);
            return nil;
        }
    }

    if (flags >= 0) fcntl(sock, F_SETFL, flags);
    struct timeval rtv;
    rtv.tv_sec = (int)timeoutSec;
    rtv.tv_usec = (int)((timeoutSec - rtv.tv_sec) * 1000000.0);
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &rtv, sizeof(rtv));
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &rtv, sizeof(rtv));

    NSString *reqStr = [NSString stringWithFormat:@"%@ %@ HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: 0\r\n\r\n", method, path];
    const char *reqBytes = reqStr.UTF8String;
    size_t reqLen = strlen(reqBytes);
    size_t sent = 0;
    while (sent < reqLen) {
        ssize_t w = send(sock, reqBytes + sent, reqLen - sent, 0);
        if (w <= 0) {
            close(sock);
            return nil;
        }
        sent += (size_t)w;
    }

    NSMutableData *raw = [NSMutableData data];
    uint8_t buf[8192];
    while (1) {
        ssize_t r = recv(sock, buf, sizeof(buf), 0);
        if (r <= 0) break;
        [raw appendBytes:buf length:(NSUInteger)r];
    }
    close(sock);

    NSData *sep = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange hdrEnd = [raw rangeOfData:sep options:0 range:NSMakeRange(0, raw.length)];
    if (hdrEnd.location == NSNotFound) return nil;

    NSString *hdr = [[NSString alloc] initWithData:[raw subdataWithRange:NSMakeRange(0, hdrEnd.location)]
                                          encoding:NSUTF8StringEncoding];
    NSInteger code = 0;
    if (hdr.length > 0) {
        NSArray<NSString *> *parts = [[hdr componentsSeparatedByString:@"\r\n"].firstObject componentsSeparatedByString:@" "];
        if (parts.count >= 2) code = [parts[1] integerValue];
    }
    if (outStatus) *outStatus = code;

    NSUInteger bodyStart = NSMaxRange(hdrEnd);
    return [raw subdataWithRange:NSMakeRange(bodyStart, raw.length - bodyStart)];
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

- (instancetype)init {
    self = [super init];
    if (self) {
        signal(SIGPIPE, SIG_IGN);
        _listenSock = -1;
        _serverAcceptQueue = dispatch_queue_create("com.lintype.bridge.http.accept", DISPATCH_QUEUE_SERIAL);
        _serverClientQueue = dispatch_queue_create("com.lintype.bridge.http.client", DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

- (BOOL)isExtensionProcess {
    return [[[NSBundle mainBundle] bundlePath] hasSuffix:@".appex"];
}

- (BOOL)isMicrophoneAuthorized {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [[AVAudioSession sharedInstance] recordPermission] == AVAudioSessionRecordPermissionGranted;
#pragma clang diagnostic pop
}

- (NSString *)hostBridgeStatusSummary {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (self.isKeepAliveActive) {
        [parts addObject:self.isPipActive ? @"PiP + 音频保活中" : @"后台音频保活中"];
    } else {
        [parts addObject:@"后台保活未启动"];
    }
    if (self.isLoopbackServerActive) {
        [parts addObject:@"127.0.0.1 桥接就绪"];
    }
    if ([[TypelessConfig sharedConfig] hasSharedAppGroup]) {
        [parts addObject:@"AppGroup 已共享"];
    } else {
        [parts addObject:@"免 AppGroup 直连"];
    }
    return [parts componentsJoinedByString:@" · "];
}

#pragma mark - AppGroup Paths (Optional Channel)

- (NSString *)bridgeDirectory {
    NSString *groupPath = [[TypelessConfig sharedConfig] sharedAppGroupPath];
    NSString *dir = nil;
    if (groupPath.length > 0) {
        dir = [groupPath stringByAppendingPathComponent:@"Library/Caches/LintypeBridge"];
    } else {
        dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"LintypeBridge"];
    }
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

- (NSString *)heartbeatFilePath {
    return [[self bridgeDirectory] stringByAppendingPathComponent:@"host_heartbeat.json"];
}

- (NSString *)statusFilePath {
    return [[self bridgeDirectory] stringByAppendingPathComponent:@"host_status.json"];
}

- (NSString *)sharedAudioFilePath {
    return [[self bridgeDirectory] stringByAppendingPathComponent:@"bridge_recording.wav"];
}

- (void)writeJSON:(NSDictionary *)dict toPath:(NSString *)path {
    if (!dict || path.length == 0) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    if (data.length > 0) {
        [data writeToFile:path atomically:YES];
    }
}

- (nullable NSDictionary *)readJSONFromPath:(NSString *)path {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length == 0) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

#pragma mark - Observers

- (void)configureHostObservers {
    if (self.observersConfigured) return;
    self.observersConfigured = YES;

    if (![self isExtensionProcess]) {
        CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
        if (center) {
            CFNotificationCenterAddObserver(center, (__bridge const void *)self, BridgeDarwinCallback, kDarwinStartRec, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(center, (__bridge const void *)self, BridgeDarwinCallback, kDarwinStopRec, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(center, (__bridge const void *)self, BridgeDarwinCallback, kDarwinCancelRec, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        }

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleAudioInterruption:)
                                                     name:AVAudioSessionInterruptionNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleAppDidBecomeActive:)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];

        // Start lightweight loopback server right away while host is open so extension sync works cleanly
        [self startLoopbackServer];

        BOOL autoKeepAlive = [[NSUserDefaults standardUserDefaults] boolForKey:@"LintypeHostKeepAlivePref"];
        if (autoKeepAlive) {
            [self startKeepAliveAndShowToast:NO];
        }
    } else {
        CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
        if (center) {
            CFNotificationCenterAddObserver(center, (__bridge const void *)self, BridgeDarwinCallback, kDarwinRecReady, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        }
    }
}

- (BOOL)handleHostOpenURL:(NSURL *)url {
    if (!url) return NO;
    NSString *abs = [url.absoluteString lowercaseString];
    if ([abs containsString:@"typeless-keepalive"] || [abs containsString:@"keepalive"]) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"LintypeHostKeepAlivePref"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        [self startKeepAliveAndShowToast:YES];
        return YES;
    }
    return NO;
}

- (void)handleAppDidBecomeActive:(NSNotification *)note {
    [self startLoopbackServer];
    if (self.isKeepAliveActive) {
        [self activatePlaybackKeepAliveWithMicGranted:[self isMicrophoneAuthorized]];
        [self updateHostHeartbeat];
        [self startPipSessionIfEnabledAndPossible];
    }
}

- (void)handleAudioInterruption:(NSNotification *)note {
    NSNumber *typeNum = note.userInfo[AVAudioSessionInterruptionTypeKey];
    if (typeNum && [typeNum unsignedIntegerValue] == AVAudioSessionInterruptionTypeEnded && self.isKeepAliveActive) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self activatePlaybackKeepAliveWithMicGranted:[self isMicrophoneAuthorized]];
            [self.silentPlayer play];
        });
    }
}

#pragma mark - Host Keep-Alive (Audio + PiP + Loopback HTTP)

- (BOOL)activatePlaybackKeepAliveWithMicGranted:(BOOL)micGranted {
    @try {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        NSError *err = nil;
        if (micGranted) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            AVAudioSessionCategoryOptions opts = AVAudioSessionCategoryOptionMixWithOthers |
                                                 AVAudioSessionCategoryOptionDefaultToSpeaker |
                                                 AVAudioSessionCategoryOptionAllowBluetooth;
#pragma clang diagnostic pop
            [session setCategory:AVAudioSessionCategoryPlayAndRecord
                            mode:AVAudioSessionModeDefault
                         options:opts
                           error:&err];
        } else {
            [session setCategory:AVAudioSessionCategoryPlayback
                            mode:AVAudioSessionModeDefault
                         options:AVAudioSessionCategoryOptionMixWithOthers
                           error:&err];
        }
        [session setActive:YES error:&err];

        if (!self.silentPlayer) {
            NSData *wav = BuildSilentWavData();
            if (wav) {
                self.silentPlayer = [[AVAudioPlayer alloc] initWithData:wav error:&err];
                self.silentPlayer.numberOfLoops = -1;
                self.silentPlayer.volume = 0.005f;
                [self.silentPlayer prepareToPlay];
            }
        }
        if (self.silentPlayer && !self.silentPlayer.isPlaying) {
            [self.silentPlayer play];
        }
        return (err == nil);
    } @catch (NSException *e) {
        return NO;
    }
}

- (void)startKeepAliveAndShowToast:(BOOL)showToast {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"LintypeHostKeepAlivePref"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    [self startLoopbackServer];
    self.isKeepAliveActive = YES;

    AVAudioSession *session = [AVAudioSession sharedInstance];
    BOOL micGranted = [self isMicrophoneAuthorized];
    [self activatePlaybackKeepAliveWithMicGranted:micGranted];

    [self updateHostHeartbeat];
    [self.heartbeatTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s || !s.isKeepAliveActive) return;
        if (s.silentPlayer && !s.silentPlayer.isPlaying && !s.isHostRecording) {
            [s.silentPlayer play];
        }
        [s updateHostHeartbeat];
    }];

    [self startPipSessionIfEnabledAndPossible];

    if (!micGranted) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if ([session recordPermission] == AVAudioSessionRecordPermissionUndetermined) {
            [session requestRecordPermission:^(BOOL granted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (granted && self.isKeepAliveActive) {
                        [self activatePlaybackKeepAliveWithMicGranted:YES];
                        [self updateHostHeartbeat];
                    }
                });
            }];
        }
#pragma clang diagnostic pop
    }

    if (showToast) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self showKeepAliveReadyBanner];
        });
    }
}

- (void)stopKeepAlive {
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"LintypeHostKeepAlivePref"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    self.isKeepAliveActive = NO;
    [self.heartbeatTimer invalidate];
    self.heartbeatTimer = nil;
    [self stopPipSession];

    [self.silentPlayer stop];
    self.silentPlayer = nil;
    @try {
        [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
    } @catch (NSException *e) {}
    [[NSFileManager defaultManager] removeItemAtPath:[self heartbeatFilePath] error:nil];
}

- (void)updateHostHeartbeat {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSDictionary *hb = @{
        @"alive": @(self.isKeepAliveActive),
        @"ts": @(now),
        @"mic": @([self isMicrophoneAuthorized]),
        @"pip": @(self.isPipActive)
    };
    [self writeJSON:hb toPath:[self heartbeatFilePath]];
}

#pragma mark - PiP Keep-Alive (iOS 15+)

- (void)refreshPipSettingIfActive {
    if (!self.isKeepAliveActive) return;
    if ([TypelessConfig sharedConfig].pipKeepAliveEnabled) {
        [self startPipSessionIfEnabledAndPossible];
    } else {
        [self stopPipSession];
    }
}

- (void)startPipManuallyIfPossible {
    [self startPipSessionIfEnabledAndPossible];
    if (@available(iOS 15.0, *)) {
        if (self.pipController && self.pipController.isPictureInPicturePossible && !self.pipController.isPictureInPictureActive) {
            [self.pipController startPictureInPicture];
        }
    }
}

- (UIWindow *)activeHostWindow {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (w.isKeyWindow) return w;
                }
                return ((UIWindowScene *)scene).windows.firstObject;
            }
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [UIApplication sharedApplication].keyWindow ?: [UIApplication sharedApplication].windows.firstObject;
#pragma clang diagnostic pop
}

- (void)startPipSessionIfEnabledAndPossible {
    if ([self isExtensionProcess]) return;
    if (![TypelessConfig sharedConfig].pipKeepAliveEnabled) return;

    if (@available(iOS 15.0, *)) {
        if (![AVPictureInPictureController isPictureInPictureSupported]) return;
        UIWindow *win = [self activeHostWindow];
        if (!win) return;

        @try {
            if (!self.pipHostView) {
                self.pipHostView = [[UIView alloc] initWithFrame:CGRectMake(win.bounds.size.width - 122, 6, 110, 26)];
                self.pipHostView.backgroundColor = [UIColor clearColor];
                self.pipHostView.userInteractionEnabled = NO;
                self.pipHostView.alpha = 0.015;
                [win addSubview:self.pipHostView];

                self.pipDisplayLayer = [[AVSampleBufferDisplayLayer alloc] init];
                self.pipDisplayLayer.frame = self.pipHostView.bounds;
                self.pipDisplayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
                [self.pipHostView.layer addSublayer:self.pipDisplayLayer];
            } else if (self.pipHostView.superview != win) {
                [self.pipHostView removeFromSuperview];
                [win addSubview:self.pipHostView];
            }

            if (!self.pipController) {
                AVPictureInPictureControllerContentSource *src =
                    [[AVPictureInPictureControllerContentSource alloc] initWithSampleBufferDisplayLayer:self.pipDisplayLayer
                                                                                        playbackDelegate:(id)self];
                self.pipController = [[AVPictureInPictureController alloc] initWithContentSource:src];
                self.pipController.delegate = (id)self;
                self.pipController.canStartPictureInPictureAutomaticallyFromInline = YES;
                if (@available(iOS 14.2, *)) {
                    self.pipController.requiresLinearPlayback = NO;
                }
            }

            [self enqueuePipKeepAliveFrame];
            [self.pipFrameTimer invalidate];
            __weak typeof(self) weakSelf = self;
            self.pipFrameTimer = [NSTimer scheduledTimerWithTimeInterval:1.2 repeats:YES block:^(NSTimer * _Nonnull timer) {
                __strong typeof(weakSelf) s = weakSelf;
                if (s && s.isKeepAliveActive && [TypelessConfig sharedConfig].pipKeepAliveEnabled) {
                    [s enqueuePipKeepAliveFrame];
                }
            }];
        } @catch (NSException *e) {
            NSLog(@"[TypelessHostBridge] PiP init exception: %@", e);
        }
    }
}

- (void)stopPipSession {
    [self.pipFrameTimer invalidate];
    self.pipFrameTimer = nil;
    if (@available(iOS 15.0, *)) {
        @try {
            if (self.pipController.isPictureInPictureActive) {
                [self.pipController stopPictureInPicture];
            }
            self.pipController.canStartPictureInPictureAutomaticallyFromInline = NO;
            self.pipController = nil;
        } @catch (NSException *e) {}
    }
    [self.pipDisplayLayer removeFromSuperlayer];
    self.pipDisplayLayer = nil;
    [self.pipHostView removeFromSuperview];
    self.pipHostView = nil;
    self.isPipActive = NO;
}

- (void)enqueuePipKeepAliveFrame {
    if (!self.pipDisplayLayer) return;
    int width = 320;
    int height = 64;

    NSDictionary *attrs = @{
        (__bridge NSString *)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (__bridge NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attrs, &pixelBuffer);
    if (status != kCVReturnSuccess || !pixelBuffer) return;

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    void *base = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t bpr = CVPixelBufferGetBytesPerRow(pixelBuffer);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(base, (size_t)width, (size_t)height, 8, bpr, cs,
                                             kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    if (ctx) {
        CGContextSetRGBFillColor(ctx, 0.09, 0.11, 0.16, 1.0);
        CGContextFillRect(ctx, CGRectMake(0, 0, width, height));

        // Green status dot
        CGContextSetRGBFillColor(ctx, 0.13, 0.77, 0.37, 1.0);
        CGContextFillEllipseInRect(ctx, CGRectMake(18, 22, 20, 20));

        // Render clean status text via UIKit graphics context
        UIGraphicsPushContext(ctx);
        CGContextTranslateCTM(ctx, 0, height);
        CGContextScaleCTM(ctx, 1.0, -1.0);
        NSDictionary *titleAttr = @{
            NSFontAttributeName: [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold],
            NSForegroundColorAttributeName: [UIColor whiteColor]
        };
        NSString *msg = self.isHostRecording ? @"Lintype AI · 后台收音中" : @"Lintype AI · 语音保活就绪";
        [msg drawAtPoint:CGPointMake(48, 20) withAttributes:titleAttr];
        UIGraphicsPopContext();
        CGContextRelease(ctx);
    }
    CGColorSpaceRelease(cs);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

    CMVideoFormatDescriptionRef fmt = NULL;
    OSStatus fmtErr = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &fmt);
    if (fmtErr == noErr && fmt) {
        self.pipFrameCounter += 1;
        CMSampleTimingInfo timing = kCMTimingInfoInvalid;
        timing.duration = CMTimeMake(1, 1);
        timing.presentationTimeStamp = CMTimeMake(self.pipFrameCounter, 1);
        timing.decodeTimeStamp = kCMTimeInvalid;

        CMSampleBufferRef sample = NULL;
        OSStatus sbErr = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixelBuffer, fmt, &timing, &sample);
        if (sbErr == noErr && sample) {
            CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, YES);
            if (attachments && CFArrayGetCount(attachments) > 0) {
                CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
                CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
            }
            @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                if (self.pipDisplayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
                    [self.pipDisplayLayer flush];
                }
                [self.pipDisplayLayer enqueueSampleBuffer:sample];
#pragma clang diagnostic pop
            } @catch (NSException *e) {}
            CFRelease(sample);
        }
        CFRelease(fmt);
    }
    CVPixelBufferRelease(pixelBuffer);
}

#pragma mark - AVPictureInPictureControllerDelegate & PlaybackDelegate

- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)controller {
    self.isPipActive = YES;
    [self updateHostHeartbeat];
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)controller {
    self.isPipActive = NO;
    [self updateHostHeartbeat];
}

- (void)pictureInPictureController:(AVPictureInPictureController *)controller failedToStartPictureInPictureWithError:(NSError *)error {
    self.isPipActive = NO;
    NSLog(@"[TypelessHostBridge] PiP start failed: %@", error.localizedDescription);
}

- (void)pictureInPictureController:(AVPictureInPictureController *)controller setPlaying:(BOOL)playing {}

- (CMTimeRange)pictureInPictureControllerTimeRangeForPlayback:(AVPictureInPictureController *)controller {
    return CMTimeRangeMake(kCMTimeZero, CMTimeMake(86400, 1));
}

- (BOOL)pictureInPictureControllerIsPlaybackPaused:(AVPictureInPictureController *)controller {
    return NO;
}

- (void)pictureInPictureController:(AVPictureInPictureController *)controller didTransitionToRenderSize:(CMVideoDimensions)newRenderSize {}

- (void)pictureInPictureController:(AVPictureInPictureController *)controller
                     skipByInterval:(CMTime)skipInterval
                  completionHandler:(void (^)(void))completionHandler {
    if (completionHandler) completionHandler();
}

#pragma mark - Toast Banner

- (void)showKeepAliveReadyBanner {
    UIWindow *win = [self activeHostWindow];
    if (!win) return;

    UIView *old = [win viewWithTag:89012];
    [old removeFromSuperview];

    CGFloat safeTop = 54;
    if (@available(iOS 11.0, *)) {
        safeTop = MAX(54, win.safeAreaInsets.top + 8);
    }

    UIView *banner = [[UIView alloc] initWithFrame:CGRectMake(20, safeTop, win.bounds.size.width - 40, 62)];
    banner.tag = 89012;
    banner.backgroundColor = [UIColor colorWithRed:0.07 green:0.46 blue:0.95 alpha:0.97];
    banner.layer.cornerRadius = 16;
    banner.layer.shadowColor = [UIColor blackColor].CGColor;
    banner.layer.shadowOpacity = 0.22;
    banner.layer.shadowRadius = 12;
    banner.layer.shadowOffset = CGSizeMake(0, 4);

    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, banner.bounds.size.width - 32, 46)];
    lbl.numberOfLines = 2;
    lbl.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
    lbl.textColor = [UIColor whiteColor];
    lbl.text = @"后台语音保活已开启！可直接切回原 App 使用键盘说话。";
    [banner addSubview:lbl];

    [win addSubview:banner];
    banner.alpha = 0;
    [UIView animateWithDuration:0.25 animations:^{ banner.alpha = 1; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.25 animations:^{ banner.alpha = 0; } completion:^(BOOL finished) {
            [banner removeFromSuperview];
        }];
    });
}

#pragma mark - POSIX Loopback HTTP Server (Host App)

- (void)startLoopbackServer {
    if ([self isExtensionProcess] || self.listenSock >= 0) return;

    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return;

    int on = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    setsockopt(s, SOL_SOCKET, SO_REUSEPORT, &on, sizeof(on));
    setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kLoopbackPort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (bind(s, (struct sockaddr *)&addr, sizeof(addr)) < 0 || listen(s, 16) < 0) {
        NSLog(@"[TypelessHostBridge] Loopback server bind/listen failed errno=%d", errno);
        close(s);
        return;
    }

    self.listenSock = s;
    self.isLoopbackServerActive = YES;

    __weak typeof(self) weakSelf = self;
    dispatch_async(self.serverAcceptQueue, ^{
        while (1) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || strongSelf.listenSock < 0) break;
            struct sockaddr_in clientAddr;
            socklen_t len = sizeof(clientAddr);
            int cs = accept(strongSelf.listenSock, (struct sockaddr *)&clientAddr, &len);
            if (cs < 0) {
                if (errno == EINTR) continue;
                break;
            }
            dispatch_async(strongSelf.serverClientQueue, ^{
                [strongSelf handleHTTPClientSocket:cs];
            });
        }
    });
}

- (void)sendHTTPResponseOnSocket:(int)cs status:(NSInteger)status contentType:(NSString *)ctype body:(NSData *)body {
    NSString *statusText = (status == 200) ? @"OK" : @"Not Found";
    NSString *hdr = [NSString stringWithFormat:@"HTTP/1.1 %ld %@\r\nContent-Type: %@\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",
                     (long)status, statusText, ctype ?: @"application/octet-stream", (unsigned long)body.length];
    NSData *hdrData = [hdr dataUsingEncoding:NSUTF8StringEncoding];
    if (hdrData.length > 0) {
        send(cs, hdrData.bytes, hdrData.length, 0);
    }
    if (body.length > 0) {
        const uint8_t *bytes = body.bytes;
        size_t remaining = body.length;
        size_t offset = 0;
        while (remaining > 0) {
            ssize_t w = send(cs, bytes + offset, remaining, 0);
            if (w <= 0) break;
            offset += (size_t)w;
            remaining -= (size_t)w;
        }
    }
}

- (void)handleHTTPClientSocket:(int)cs {
    int on = 1;
    setsockopt(cs, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));

    char buf[2048];
    ssize_t n = recv(cs, buf, sizeof(buf) - 1, 0);
    if (n <= 0) {
        close(cs);
        return;
    }
    buf[n] = '\0';
    NSString *req = [NSString stringWithUTF8String:buf] ?: @"";
    NSString *firstLine = [req componentsSeparatedByString:@"\r\n"].firstObject ?: @"";
    NSArray<NSString *> *parts = [firstLine componentsSeparatedByString:@" "];
    NSString *method = parts.count > 0 ? parts[0] : @"";
    NSString *path = parts.count > 1 ? parts[1] : @"/";

    __block NSInteger status = 200;
    __block NSString *ctype = @"application/json; charset=utf-8";
    __block NSData *respData = nil;

    if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/status"]) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            NSDictionary *d = @{
                @"alive": @(self.isKeepAliveActive || self.isPipActive || self.isLoopbackServerActive),
                @"keepAlive": @(self.isKeepAliveActive),
                @"pip": @(self.isPipActive),
                @"recording": @(self.isHostRecording),
                @"mic": @([self isMicrophoneAuthorized]),
                @"level": @(self.hostLastLevel),
                @"elapsed": @(self.hostLastElapsed),
                @"error": self.hostLastError ?: @""
            };
            respData = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
        });
    } else if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/config"]) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            NSDictionary *cfg = [[TypelessConfig sharedConfig] exportConfigDictionary];
            respData = [NSJSONSerialization dataWithJSONObject:cfg options:0 error:nil];
        });
    } else if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/start"]) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            self.hostLastError = nil;
            self.hostCachedWavData = nil;
            if (!self.isKeepAliveActive) {
                [self startKeepAliveAndShowToast:NO];
            }
            [self hostStartRecording];
            NSDictionary *d = @{
                @"ok": @(self.isHostRecording),
                @"error": self.hostLastError ?: @""
            };
            respData = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
        });
    } else if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/stop"]) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self hostStopRecordingAndFinalize];
            NSDictionary *d = @{
                @"ok": @(self.hostCachedWavData.length > 44),
                @"size": @(self.hostCachedWavData.length),
                @"error": self.hostLastError ?: @""
            };
            respData = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
        });
    } else if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/audio.wav"]) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            if (self.hostCachedWavData.length > 0) {
                ctype = @"audio/wav";
                respData = self.hostCachedWavData;
            } else {
                status = 404;
                respData = [@"{\"error\":\"no audio\"}" dataUsingEncoding:NSUTF8StringEncoding];
            }
        });
    } else if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/cancel"]) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self hostCancelRecording];
            respData = [@"{\"ok\":true}" dataUsingEncoding:NSUTF8StringEncoding];
        });
    } else {
        status = 404;
        respData = [@"{\"error\":\"not found\"}" dataUsingEncoding:NSUTF8StringEncoding];
    }

    [self sendHTTPResponseOnSocket:cs status:status contentType:ctype body:respData ?: [NSData data]];
    close(cs);
}

#pragma mark - Host Audio Capture

- (void)handleDarwinNotification:(NSString *)name {
    if (![self isExtensionProcess]) {
        if ([name isEqualToString:(__bridge NSString *)kDarwinStartRec]) {
            [self hostStartRecording];
        } else if ([name isEqualToString:(__bridge NSString *)kDarwinStopRec]) {
            [self hostStopRecordingAndFinalize];
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), kDarwinRecReady, NULL, NULL, true);
        } else if ([name isEqualToString:(__bridge NSString *)kDarwinCancelRec]) {
            [self hostCancelRecording];
        }
    } else {
        if ([name isEqualToString:(__bridge NSString *)kDarwinRecReady]) {
            [self handleExtensionRecordingReadyFromAppGroup];
        }
    }
}

- (void)hostStartRecording {
    self.hostLastError = nil;
    self.hostLastLevel = 0.08f;
    self.hostLastElapsed = 0;

    if (![self isMicrophoneAuthorized]) {
        self.isHostRecording = NO;
        self.hostLastError = @"主应用缺少麦克风权限，请在「系统设置 - Gboard」中开启麦克风。";
        [self writeJSON:@{@"state": @"error", @"error": self.hostLastError} toPath:[self statusFilePath]];
        return;
    }

    @try {
        [self.silentPlayer pause];

        AVAudioSession *session = [AVAudioSession sharedInstance];
        NSError *err = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        AVAudioSessionCategoryOptions opts = AVAudioSessionCategoryOptionMixWithOthers |
                                             AVAudioSessionCategoryOptionDefaultToSpeaker |
                                             AVAudioSessionCategoryOptionAllowBluetooth;
#pragma clang diagnostic pop
        [session setCategory:AVAudioSessionCategoryPlayAndRecord
                        mode:AVAudioSessionModeMeasurement
                     options:opts
                       error:&err];
        [session setActive:YES error:&err];

        NSString *wavPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"lintype_host_capture.wav"];
        [[NSFileManager defaultManager] removeItemAtPath:wavPath error:nil];
        self.hostActiveWavPath = wavPath;

        NSDictionary *settings = @{
            AVFormatIDKey: @(kAudioFormatLinearPCM),
            AVSampleRateKey: @(16000.0),
            AVNumberOfChannelsKey: @(1),
            AVLinearPCMBitDepthKey: @(16),
            AVLinearPCMIsFloatKey: @NO,
            AVLinearPCMIsBigEndianKey: @NO
        };

        NSURL *url = [NSURL fileURLWithPath:wavPath];
        self.hostRecorder = [[AVAudioRecorder alloc] initWithURL:url settings:settings error:&err];
        self.hostRecorder.meteringEnabled = YES;
        self.hostRecorder.delegate = self;

        if (!self.hostRecorder || ![self.hostRecorder prepareToRecord] || ![self.hostRecorder record]) {
            self.isHostRecording = NO;
            self.hostLastError = err.localizedDescription ?: @"主应用后台启动录音器失败";
            [self writeJSON:@{@"state": @"error", @"error": self.hostLastError} toPath:[self statusFilePath]];
            return;
        }

        self.isHostRecording = YES;
        self.hostRecordStartDate = [NSDate date];
        [self writeJSON:@{@"state": @"recording", @"level": @(0.1), @"elapsed": @(0)} toPath:[self statusFilePath]];

        [self.hostLevelTimer invalidate];
        __weak typeof(self) weakSelf = self;
        self.hostLevelTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer * _Nonnull timer) {
            __strong typeof(weakSelf) s = weakSelf;
            if (!s || !s.hostRecorder || !s.hostRecorder.isRecording) return;
            [s.hostRecorder updateMeters];
            float db = [s.hostRecorder averagePowerForChannel:0];
            CGFloat level = MAX(0.06, MIN(1.0, (db + 52.0f) / 52.0f));
            NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:s.hostRecordStartDate];
            s.hostLastLevel = level;
            s.hostLastElapsed = elapsed;
            [s writeJSON:@{@"state": @"recording", @"level": @(level), @"elapsed": @(elapsed)} toPath:[s statusFilePath]];
        }];
    } @catch (NSException *e) {
        self.isHostRecording = NO;
        self.hostLastError = e.reason ?: @"主应用录音异常";
        [self writeJSON:@{@"state": @"error", @"error": self.hostLastError} toPath:[self statusFilePath]];
    }
}

- (void)hostStopRecordingAndFinalize {
    [self.hostLevelTimer invalidate];
    self.hostLevelTimer = nil;
    self.isHostRecording = NO;

    NSString *wavPath = self.hostActiveWavPath;
    if (self.hostRecorder) {
        if (self.hostRecorder.isRecording) {
            [self.hostRecorder stop];
        }
        self.hostRecorder = nil;
    }

    NSData *wavData = wavPath.length > 0 ? [NSData dataWithContentsOfFile:wavPath] : nil;
    self.hostCachedWavData = wavData;
    if (wavData.length > 44 && [[TypelessConfig sharedConfig] hasSharedAppGroup]) {
        [wavData writeToFile:[self sharedAudioFilePath] atomically:YES];
    }

    if (wavData.length > 44) {
        [self writeJSON:@{@"state": @"ready"} toPath:[self statusFilePath]];
    } else {
        self.hostLastError = self.hostLastError ?: @"未录到有效音频，请再说一次";
        [self writeJSON:@{@"state": @"error", @"error": self.hostLastError} toPath:[self statusFilePath]];
    }

    if (self.isKeepAliveActive) {
        [self activatePlaybackKeepAliveWithMicGranted:[self isMicrophoneAuthorized]];
    }
}

- (void)hostCancelRecording {
    [self.hostLevelTimer invalidate];
    self.hostLevelTimer = nil;
    self.isHostRecording = NO;
    if (self.hostRecorder) {
        [self.hostRecorder stop];
        self.hostRecorder = nil;
    }
    self.hostCachedWavData = nil;
    if (self.hostActiveWavPath) {
        [[NSFileManager defaultManager] removeItemAtPath:self.hostActiveWavPath error:nil];
    }
    if ([[TypelessConfig sharedConfig] hasSharedAppGroup]) {
        [[NSFileManager defaultManager] removeItemAtPath:[self sharedAudioFilePath] error:nil];
    }
    [self writeJSON:@{@"state": @"idle"} toPath:[self statusFilePath]];
    if (self.isKeepAliveActive) {
        [self activatePlaybackKeepAliveWithMicGranted:[self isMicrophoneAuthorized]];
    }
}

#pragma mark - Extension Remote Client (AppGroup + 127.0.0.1 HTTP Fallback)

- (BOOL)isAppGroupBridgeAlive {
    if (![[TypelessConfig sharedConfig] hasSharedAppGroup]) return NO;
    NSDictionary *hb = [self readJSONFromPath:[self heartbeatFilePath]];
    if (![hb[@"alive"] boolValue]) return NO;
    NSTimeInterval ts = [hb[@"ts"] doubleValue];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    return (now - ts) < 7.0;
}

- (nullable NSDictionary *)fetchLoopbackJSONPath:(NSString *)path method:(NSString *)method timeout:(NSTimeInterval)timeout {
    NSInteger code = 0;
    NSData *data = LoopbackHTTPRequest(method, path, timeout, &code);
    if (code != 200 || data.length == 0) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

- (BOOL)isHostBridgeAlive {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if ((now - self.lastAliveCheckTime) < 0.5) {
        return self.lastAliveCheckResult;
    }
    BOOL alive = [self isAppGroupBridgeAlive];
    if (!alive) {
        NSDictionary *st = [self fetchLoopbackJSONPath:@"/status" method:@"GET" timeout:0.15];
        alive = [st[@"alive"] boolValue];
    }
    self.lastAliveCheckTime = now;
    self.lastAliveCheckResult = alive;
    return alive;
}

- (BOOL)syncConfigFromHostIfNeeded {
    NSDictionary *remoteCfg = [self fetchLoopbackJSONPath:@"/config" method:@"GET" timeout:0.25];
    if (!remoteCfg) return NO;
    self.lastConfigSyncAt = CFAbsoluteTimeGetCurrent();
    return [[TypelessConfig sharedConfig] applyConfigDictionary:remoteCfg persist:YES];
}

- (void)syncConfigFromHostAsyncWithCompletion:(void (^ _Nullable)(BOOL updated))completion {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (self.configSyncInFlight || (now - self.lastConfigSyncAt) < 1.2) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
        }
        return;
    }
    self.configSyncInFlight = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *remoteCfg = [self fetchLoopbackJSONPath:@"/config" method:@"GET" timeout:0.22];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.configSyncInFlight = NO;
            self.lastConfigSyncAt = CFAbsoluteTimeGetCurrent();
            BOOL updated = NO;
            if ([remoteCfg isKindOfClass:[NSDictionary class]] && remoteCfg.count > 0) {
                self.lastAliveCheckTime = self.lastConfigSyncAt;
                self.lastAliveCheckResult = YES;
                updated = [[TypelessConfig sharedConfig] applyConfigDictionary:remoteCfg persist:YES];
            }
            if (completion) completion(updated);
        });
    });
}

- (void)startExtHTTPPollTimer {
    __weak typeof(self) weakSelf = self;
    self.extPollTimer = [NSTimer scheduledTimerWithTimeInterval:0.12 repeats:YES block:^(NSTimer * _Nonnull timer) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSDictionary *st = [s fetchLoopbackJSONPath:@"/status" method:@"GET" timeout:0.25];
            if (!st) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (s.extLevelBlock) {
                    s.extLevelBlock([st[@"level"] doubleValue], [st[@"elapsed"] doubleValue]);
                }
            });
        });
    }];
}

- (void)startRemoteRecordingWithLevelHandler:(TypelessBridgeLevelBlock)levelBlock
                                  completion:(void (^)(BOOL started, BOOL hostAlive, NSString * _Nullable errorMessage))completion {
    [self configureHostObservers];
    [self.extPollTimer invalidate];
    [self.extStopTimeoutTimer invalidate];
    self.extStopTimeoutTimer = nil;
    self.extStopCompletion = nil;
    self.extLevelBlock = levelBlock;
    self.extUsingHTTPBridge = NO;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *startResp = [self fetchLoopbackJSONPath:@"/start" method:@"POST" timeout:0.65];
        BOOL appGroupAlive = NO;
        NSDictionary *hb = nil;
        if (!startResp) {
            appGroupAlive = [self isAppGroupBridgeAlive];
            if (appGroupAlive) {
                hb = [self readJSONFromPath:[self heartbeatFilePath]];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (startResp) {
                self.lastAliveCheckTime = now;
                self.lastAliveCheckResult = YES;
                if ([startResp[@"ok"] boolValue]) {
                    self.extUsingHTTPBridge = YES;
                    [self startExtHTTPPollTimer];
                    if (completion) completion(YES, YES, nil);
                } else {
                    NSString *err = startResp[@"error"];
                    NSString *msg = err.length > 0 ? err : @"主应用启动后台录音失败";
                    if (completion) completion(NO, YES, msg);
                }
                return;
            }

            if (appGroupAlive) {
                self.lastAliveCheckTime = now;
                self.lastAliveCheckResult = YES;
                if (![hb[@"mic"] boolValue]) {
                    if (completion) completion(NO, YES, @"主应用尚未授予麦克风权限，请打开 Gboard 主应用并点击开启保活。");
                    return;
                }
                [[NSFileManager defaultManager] removeItemAtPath:[self sharedAudioFilePath] error:nil];
                [self writeJSON:@{@"state": @"starting"} toPath:[self statusFilePath]];
                CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), kDarwinStartRec, NULL, NULL, true);

                __weak typeof(self) weakSelf = self;
                self.extPollTimer = [NSTimer scheduledTimerWithTimeInterval:0.12 repeats:YES block:^(NSTimer * _Nonnull timer) {
                    __strong typeof(weakSelf) s = weakSelf;
                    if (!s) return;
                    NSDictionary *st = [s readJSONFromPath:[s statusFilePath]];
                    if ([st[@"state"] isEqualToString:@"recording"] && s.extLevelBlock) {
                        s.extLevelBlock([st[@"level"] doubleValue], [st[@"elapsed"] doubleValue]);
                    }
                }];
                if (completion) completion(YES, YES, nil);
                return;
            }

            self.lastAliveCheckTime = now;
            self.lastAliveCheckResult = NO;
            if (completion) completion(NO, NO, @"主应用后台语音保活未运行");
        });
    });
}

- (BOOL)startRemoteRecordingWithLevelHandler:(TypelessBridgeLevelBlock)levelBlock
                                errorMessage:(NSString * _Nullable __autoreleasing *)outError {
    [self configureHostObservers];
    [self.extPollTimer invalidate];
    [self.extStopTimeoutTimer invalidate];
    self.extStopTimeoutTimer = nil;
    self.extStopCompletion = nil;
    self.extLevelBlock = levelBlock;
    self.extUsingHTTPBridge = NO;

    // Prefer HTTP loopback when server responds (works both with and without AppGroup!)
    NSDictionary *startResp = [self fetchLoopbackJSONPath:@"/start" method:@"POST" timeout:0.8];
    if (startResp) {
        if ([startResp[@"ok"] boolValue]) {
            self.extUsingHTTPBridge = YES;
            __weak typeof(self) weakSelf = self;
            self.extPollTimer = [NSTimer scheduledTimerWithTimeInterval:0.12 repeats:YES block:^(NSTimer * _Nonnull timer) {
                __strong typeof(weakSelf) s = weakSelf;
                if (!s) return;
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    NSDictionary *st = [s fetchLoopbackJSONPath:@"/status" method:@"GET" timeout:0.25];
                    if (!st) return;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (s.extLevelBlock) {
                            s.extLevelBlock([st[@"level"] doubleValue], [st[@"elapsed"] doubleValue]);
                        }
                    });
                });
            }];
            return YES;
        } else {
            NSString *err = startResp[@"error"];
            if (outError) *outError = err.length > 0 ? err : @"主应用启动后台录音失败";
            return NO;
        }
    }

    // Fallback to AppGroup + Darwin notify if host responds via AppGroup only
    if ([self isAppGroupBridgeAlive]) {
        NSDictionary *hb = [self readJSONFromPath:[self heartbeatFilePath]];
        if (![hb[@"mic"] boolValue]) {
            if (outError) *outError = @"主应用尚未授予麦克风权限，请打开 Gboard 主应用并点击开启保活。";
            return NO;
        }
        [[NSFileManager defaultManager] removeItemAtPath:[self sharedAudioFilePath] error:nil];
        [self writeJSON:@{@"state": @"starting"} toPath:[self statusFilePath]];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), kDarwinStartRec, NULL, NULL, true);

        __weak typeof(self) weakSelf = self;
        self.extPollTimer = [NSTimer scheduledTimerWithTimeInterval:0.12 repeats:YES block:^(NSTimer * _Nonnull timer) {
            __strong typeof(weakSelf) s = weakSelf;
            if (!s) return;
            NSDictionary *st = [s readJSONFromPath:[s statusFilePath]];
            if ([st[@"state"] isEqualToString:@"recording"] && s.extLevelBlock) {
                s.extLevelBlock([st[@"level"] doubleValue], [st[@"elapsed"] doubleValue]);
            }
        }];
        return YES;
    }

    if (outError) *outError = @"主应用后台语音保活未运行";
    return NO;
}

- (void)stopRemoteRecordingWithCompletion:(TypelessBridgeRecordingCompletion)completion {
    [self.extPollTimer invalidate];
    self.extPollTimer = nil;
    self.extLevelBlock = nil;
    self.extStopCompletion = completion;

    if (self.extUsingHTTPBridge) {
        self.extUsingHTTPBridge = NO;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            NSDictionary *stopResp = [self fetchLoopbackJSONPath:@"/stop" method:@"POST" timeout:1.5];
            NSInteger wavStatus = 0;
            NSData *wavData = nil;
            if (stopResp && [stopResp[@"ok"] boolValue]) {
                wavData = LoopbackHTTPRequest(@"GET", @"/audio.wav", 1.5, &wavStatus);
            }
            NSString *localPath = nil;
            NSString *errMsg = nil;
            if (wavStatus == 200 && wavData.length > 44) {
                localPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                             [NSString stringWithFormat:@"typeless_bridge_%@.wav", [[NSUUID UUID] UUIDString]]];
                [wavData writeToFile:localPath atomically:YES];
            } else {
                errMsg = [stopResp[@"error"] length] > 0 ? stopResp[@"error"] : @"从主应用获取录音失败";
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                TypelessBridgeRecordingCompletion cb = self.extStopCompletion;
                self.extStopCompletion = nil;
                if (cb) cb(localPath, errMsg);
            });
        });
        return;
    }

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), kDarwinStopRec, NULL, NULL, true);

    __weak typeof(self) weakSelf = self;
    self.extStopTimeoutTimer = [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:YES block:^(NSTimer * _Nonnull timer) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s || !s.extStopCompletion) {
            [timer invalidate];
            return;
        }
        NSDictionary *st = [s readJSONFromPath:[s statusFilePath]];
        if ([st[@"state"] isEqualToString:@"ready"] || [st[@"state"] isEqualToString:@"error"]) {
            [s handleExtensionRecordingReadyFromAppGroup];
        }
    }];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.extStopCompletion) {
            [self.extStopTimeoutTimer invalidate];
            self.extStopTimeoutTimer = nil;
            TypelessBridgeRecordingCompletion cb = self.extStopCompletion;
            self.extStopCompletion = nil;
            cb(nil, @"获取后台录音超时，请确认 Gboard 保活运行中。");
        }
    });
}

- (void)handleExtensionRecordingReadyFromAppGroup {
    if (!self.extStopCompletion) return;
    [self.extStopTimeoutTimer invalidate];
    self.extStopTimeoutTimer = nil;

    TypelessBridgeRecordingCompletion cb = self.extStopCompletion;
    self.extStopCompletion = nil;

    NSDictionary *st = [self readJSONFromPath:[self statusFilePath]];
    if ([st[@"state"] isEqualToString:@"error"]) {
        cb(nil, st[@"error"] ?: @"后台录音异常");
        return;
    }

    NSString *wavPath = [self sharedAudioFilePath];
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:wavPath error:nil];
    if ([attrs fileSize] > 44) {
        cb(wavPath, nil);
    } else {
        cb(nil, @"未检测到有效录音数据");
    }
}

- (void)cancelRemoteRecording {
    [self.extPollTimer invalidate];
    self.extPollTimer = nil;
    [self.extStopTimeoutTimer invalidate];
    self.extStopTimeoutTimer = nil;
    self.extLevelBlock = nil;
    self.extStopCompletion = nil;

    if (self.extUsingHTTPBridge) {
        self.extUsingHTTPBridge = NO;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            LoopbackHTTPRequest(@"POST", @"/cancel", 0.5, nil);
        });
    } else {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), kDarwinCancelRec, NULL, NULL, true);
    }
}

- (void)openHostKeepAliveFromViewController:(UIInputViewController *)inputVC {
    NSURL *url = [NSURL URLWithString:@"gboard://typeless-keepalive"];
    if (!url) return;

    UIResponder *resp = inputVC;
    while (resp) {
        if ([resp respondsToSelector:@selector(openURL:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [resp performSelector:@selector(openURL:) withObject:url];
#pragma clang diagnostic pop
            return;
        }
        resp = resp.nextResponder;
    }

    if (inputVC.extensionContext) {
        [inputVC.extensionContext openURL:url completionHandler:nil];
    }
}

@end
