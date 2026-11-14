#import "TypelessVoiceManager.h"
#import "TypelessConfig.h"
#import "TypelessOverlayView.h"
#import "TypelessHostBridge.h"
#import <Speech/Speech.h>

@interface TypelessVoiceManager () <AVAudioRecorderDelegate>

@property (nonatomic, assign, readwrite) TypelessSessionState state;
@property (nonatomic, strong, nullable) TypelessOverlayView *overlayView;

@property (nonatomic, strong, nullable) AVAudioRecorder *audioRecorder;
@property (nonatomic, strong, nullable) NSTimer *meterTimer;
@property (nonatomic, strong, nullable) NSURL *recordingFileURL;
@property (nonatomic, strong, nullable) NSDate *recordingStartDate;
@property (nonatomic, assign) BOOL usingHostBridge;

// Apple Native Speech Fallback / Hybrid ASR
@property (nonatomic, strong, nullable) SFSpeechRecognizer *speechRecognizer;
@property (nonatomic, strong, nullable) SFSpeechAudioBufferRecognitionRequest *speechRequest;
@property (nonatomic, strong, nullable) SFSpeechRecognitionTask *speechTask;
@property (nonatomic, strong, nullable) AVAudioEngine *speechAudioEngine;
@property (nonatomic, copy) NSString *liveRecognizedText;
@property (nonatomic, assign) BOOL speechDidFinishFinal;
@property (nonatomic, copy, nullable) void (^pendingSpeechFinalBlock)(NSString *text);

// Session & Undo
@property (nonatomic, assign) NSUInteger sessionToken;
@property (nonatomic, copy) NSString *capturedSelectionText;
@property (nonatomic, assign) NSUInteger lastInsertedCharCount;
@property (nonatomic, copy) NSString *lastReplacedSelectionText;
@property (nonatomic, strong) UIImpactFeedbackGenerator *haptic;

@end

@implementation TypelessVoiceManager

+ (instancetype)sharedManager {
    static TypelessVoiceManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TypelessVoiceManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _state = TypelessSessionStateIdle;
        _liveRecognizedText = @"";
        _capturedSelectionText = @"";
        _lastReplacedSelectionText = @"";
        _haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    }
    return self;
}

- (BOOL)isRecording {
    return self.state == TypelessSessionStateRecording;
}

- (BOOL)canUndoLastInsert {
    return self.lastInsertedCharCount > 0;
}

- (BOOL)isOverlayVisible {
    return self.overlayView != nil && self.overlayView.superview != nil;
}

- (BOOL)hasFullAccess {
    UIInputViewController *vc = self.activeInputViewController;
    if (vc && [vc respondsToSelector:@selector(hasFullAccess)]) {
        return vc.hasFullAccess;
    }
    return YES;
}

- (NSString *)currentSelectedTextPreview {
    id<UITextDocumentProxy> proxy = self.activeInputViewController.textDocumentProxy;
    if (proxy && [proxy respondsToSelector:@selector(selectedText)]) {
        if (@available(iOS 16.0, *)) {
            return proxy.selectedText ?: @"";
        }
    }
    return @"";
}

- (NSString *)currentReturnKeyTitle {
    id<UITextDocumentProxy> proxy = self.activeInputViewController.textDocumentProxy;
    if (!proxy || ![proxy respondsToSelector:@selector(returnKeyType)]) {
        return @"换行";
    }
    switch (proxy.returnKeyType) {
        case UIReturnKeySend:      return @"发送";
        case UIReturnKeySearch:    return @"搜索";
        case UIReturnKeyGo:        return @"前往";
        case UIReturnKeyDone:      return @"完成";
        case UIReturnKeyNext:      return @"下一项";
        case UIReturnKeyJoin:      return @"加入";
        case UIReturnKeyRoute:     return @"路线";
        case UIReturnKeyGoogle:    return @"搜索";
        case UIReturnKeyYahoo:     return @"搜索";
        case UIReturnKeyContinue:  return @"继续";
        default:                   return @"换行";
    }
}

#pragma mark - Presentation

- (void)quickMicTapped:(nullable id)sender {
    [self.haptic impactOccurred];
    [self presentVoiceOverlayInViewController:self.activeInputViewController autoStart:NO];
}

- (void)presentVoiceOverlayInViewController:(nullable UIInputViewController *)viewController {
    [self presentVoiceOverlayInViewController:viewController autoStart:YES];
}

- (void)presentVoiceOverlayInViewController:(nullable UIInputViewController *)viewController autoStart:(BOOL)autoStart {
    if (!viewController) viewController = self.activeInputViewController;
    if (!viewController || !viewController.view) return;
    self.activeInputViewController = viewController;
    [[TypelessConfig sharedConfig] load];

    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!self.overlayView) {
                self.overlayView = [[TypelessOverlayView alloc] initWithFrame:viewController.view.bounds];
            } else {
                self.overlayView.frame = viewController.view.bounds;
            }

            if (self.overlayView.superview != viewController.view) {
                self.overlayView.alpha = 0.0;
                [viewController.view addSubview:self.overlayView];
            }
            [viewController.view bringSubviewToFront:self.overlayView];

            if (!autoStart) {
                self.state = TypelessSessionStateIdle;
                [self.overlayView refreshStateUI];
            }

            [UIView animateWithDuration:0.18 animations:^{
                self.overlayView.alpha = 1.0;
            } completion:^(BOOL finished) {
                if (autoStart && self.state == TypelessSessionStateIdle) {
                    [self startRecording];
                }
            }];
        } @catch (NSException *e) {
            NSLog(@"[TypelessVoiceManager] Exception presenting overlay: %@", e);
        }
    });
}

- (void)dismissVoiceOverlayAnimated:(BOOL)animated {
    [self stopAudioCaptureOnly];
    self.sessionToken += 1;
    self.state = TypelessSessionStateIdle;

    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!self.overlayView || !self.overlayView.superview) return;
            if (animated) {
                [UIView animateWithDuration:0.16 animations:^{
                    self.overlayView.alpha = 0.0;
                } completion:^(BOOL finished) {
                    [self.overlayView removeFromSuperview];
                    self.overlayView.alpha = 1.0;
                }];
            } else {
                [self.overlayView removeFromSuperview];
            }
        } @catch (NSException *e) {}
    });
}

#pragma mark - Recording Lifecycle

- (NSString *)friendlyAudioError:(nullable NSError *)err fallback:(NSString *)fallback {
    if (![self hasFullAccess]) {
        return @"请先在「系统设置 → 键盘 → Gboard」开启允许完全访问";
    }
    if (err && (err.code == 561145187 || err.code == 561015905 || [err.localizedDescription containsString:@"561145187"])) {
        return @"iOS 18 限制键盘直接录音（561145187），请点击下方开启后台保活";
    }
    return err.localizedDescription ?: fallback;
}

- (void)startRecording {
    [self.haptic impactOccurred];
    [[TypelessConfig sharedConfig] load];
    [self stopAudioCaptureOnly];
    self.sessionToken += 1;
    NSUInteger token = self.sessionToken;

    self.capturedSelectionText = [self currentSelectedTextPreview];
    self.liveRecognizedText = @"";
    self.speechDidFinishFinal = NO;
    self.pendingSpeechFinalBlock = nil;
    self.usingHostBridge = NO;

    if (![self hasFullAccess]) {
        self.state = TypelessSessionStateError;
        [self.overlayView showErrorStatus:@"请先在「系统设置 → 键盘 → Gboard」开启允许完全访问"];
        return;
    }

    if ([[TypelessHostBridge sharedBridge] isHostBridgeAlive]) {
        [self beginAudioCaptureForToken:token];
        return;
    }

    AVAudioSession *session = [AVAudioSession sharedInstance];
    AVAudioSessionRecordPermission perm = [session recordPermission];
    if (perm == AVAudioSessionRecordPermissionDenied) {
        self.state = TypelessSessionStateError;
        [self.overlayView showErrorStatus:@"麦克风权限被拒绝，请在「系统设置 → Gboard」开启麦克风权限"];
        return;
    }
    if (perm == AVAudioSessionRecordPermissionUndetermined) {
        [session requestRecordPermission:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (token != self.sessionToken) return;
                if (granted) {
                    [self beginAudioCaptureForToken:token];
                } else {
                    self.state = TypelessSessionStateError;
                    [self.overlayView showErrorStatus:@"未授予麦克风权限，无法进行语音输入"];
                }
            });
        }];
        return;
    }

    [self beginAudioCaptureForToken:token];
}

- (void)beginAudioCaptureForToken:(NSUInteger)token {
    if (token != self.sessionToken) return;

    self.state = TypelessSessionStateRecording;
    self.recordingStartDate = [NSDate date];
    [self.overlayView refreshStateUI];

    TypelessHostBridge *bridge = [TypelessHostBridge sharedBridge];
    if ([bridge isHostBridgeAlive]) {
        NSString *bridgeErr = nil;
        __weak typeof(self) weakSelf = self;
        BOOL started = [bridge startRemoteRecordingWithLevelHandler:^(CGFloat level, NSTimeInterval elapsed) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || token != strongSelf.sessionToken || strongSelf.state != TypelessSessionStateRecording) return;
            [strongSelf.overlayView updateAudioLevel:level elapsedSeconds:elapsed];
        } errorMessage:&bridgeErr];
        if (started) {
            self.usingHostBridge = YES;
            return;
        }
    }

    TypelessConfig *cfg = [TypelessConfig sharedConfig];
    if ([cfg shouldUseWhisperAPI]) {
        [self startWhisperAudioRecorder];
    } else {
        [self startAppleSpeechCaptureForToken:token];
    }
}

- (void)startWhisperAudioRecorder {
    @try {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        NSError *catErr = nil;
        [session setCategory:AVAudioSessionCategoryPlayAndRecord
                 withOptions:AVAudioSessionCategoryOptionMixWithOthers | AVAudioSessionCategoryOptionDefaultToSpeaker | AVAudioSessionCategoryOptionAllowBluetooth
                       error:&catErr];
        [session setActive:YES error:&catErr];
        if (catErr) {
            self.state = TypelessSessionStateError;
            [self.overlayView showErrorStatus:[self friendlyAudioError:catErr fallback:@"无法激活录音音频会话"]];
            return;
        }

        NSString *fileName = [NSString stringWithFormat:@"typeless_rec_%lld.m4a", (long long)([[NSDate date] timeIntervalSince1970] * 1000)];
        self.recordingFileURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:fileName]];

        NSDictionary *recordSettings = @{
            AVFormatIDKey: @(kAudioFormatMPEG4AAC),
            AVSampleRateKey: @(16000.0),
            AVNumberOfChannelsKey: @(1),
            AVEncoderAudioQualityKey: @(AVAudioQualityHigh)
        };

        NSError *error = nil;
        self.audioRecorder = [[AVAudioRecorder alloc] initWithURL:self.recordingFileURL settings:recordSettings error:&error];
        self.audioRecorder.meteringEnabled = YES;
        self.audioRecorder.delegate = self;

        if ([self.audioRecorder record]) {
            __weak typeof(self) weakSelf = self;
            self.meterTimer = [NSTimer scheduledTimerWithTimeInterval:0.08 repeats:YES block:^(NSTimer * _Nonnull timer) {
                [weakSelf updateWhisperMeter];
            }];
        } else {
            self.state = TypelessSessionStateError;
            [self.overlayView showErrorStatus:[self friendlyAudioError:error fallback:@"无法启动麦克风录音（561145187），请开启后台保活"]];
        }
    } @catch (NSException *e) {
        self.state = TypelessSessionStateError;
        [self.overlayView showErrorStatus:e.reason ?: @"录音初始化异常"];
    }
}

- (void)updateWhisperMeter {
    if (!self.audioRecorder || self.state != TypelessSessionStateRecording) return;
    [self.audioRecorder updateMeters];
    float power = [self.audioRecorder averagePowerForChannel:0];
    CGFloat normalized = MAX(0.06, MIN(1.0, (power + 48.0) / 42.0));
    NSTimeInterval elapsed = self.recordingStartDate ? [[NSDate date] timeIntervalSinceDate:self.recordingStartDate] : 0;
    [self.overlayView updateAudioLevel:normalized elapsedSeconds:elapsed];
}

- (void)startAppleSpeechCaptureForToken:(NSUInteger)token {
    @try {
        Class sfClass = NSClassFromString(@"SFSpeechRecognizer");
        if (!sfClass) {
            self.state = TypelessSessionStateError;
            [self.overlayView showErrorStatus:@"系统 Speech 框架不可用，请在右上角「模型」填写 Whisper Key"];
            return;
        }

        SFSpeechRecognizerAuthorizationStatus status = [sfClass authorizationStatus];
        if (status == SFSpeechRecognizerAuthorizationStatusDenied || status == SFSpeechRecognizerAuthorizationStatusRestricted) {
            self.state = TypelessSessionStateError;
            [self.overlayView showErrorStatus:@"语音识别权限已关闭，请前往设置开启或在「模型」填写 Whisper API Key"];
            return;
        }
        if (status == SFSpeechRecognizerAuthorizationStatusNotDetermined) {
            [sfClass requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus newStatus) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (token != self.sessionToken) return;
                    if (newStatus == SFSpeechRecognizerAuthorizationStatusAuthorized) {
                        [self runAppleSpeechEngineForToken:token];
                    } else {
                        self.state = TypelessSessionStateError;
                        [self.overlayView showErrorStatus:@"未获得系统语音识别授权，可在右上角「模型」配置 Whisper API"];
                    }
                });
            }];
            return;
        }

        [self runAppleSpeechEngineForToken:token];
    } @catch (NSException *e) {
        self.state = TypelessSessionStateError;
        [self.overlayView showErrorStatus:e.reason ?: @"语音引擎异常"];
    }
}

- (void)runAppleSpeechEngineForToken:(NSUInteger)token {
    if (token != self.sessionToken) return;
    @try {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        NSError *actErr = nil;
        [session setCategory:AVAudioSessionCategoryPlayAndRecord
                 withOptions:AVAudioSessionCategoryOptionMixWithOthers | AVAudioSessionCategoryOptionDefaultToSpeaker | AVAudioSessionCategoryOptionAllowBluetooth
                       error:&actErr];
        if (!actErr) {
            [session setActive:YES error:&actErr];
        }
        if (actErr) {
            self.state = TypelessSessionStateError;
            [self.overlayView showErrorStatus:[self friendlyAudioError:actErr fallback:@"无法启用麦克风（请开启后台语音保活）"]];
            return;
        }

        Class sfClass = NSClassFromString(@"SFSpeechRecognizer");
        if (!self.speechRecognizer) {
            self.speechRecognizer = [[sfClass alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:@"zh-CN"]];
            if (!self.speechRecognizer) {
                self.speechRecognizer = [[sfClass alloc] initWithLocale:[NSLocale currentLocale]];
            }
        }
        if (!self.speechRecognizer || !self.speechRecognizer.isAvailable) {
            self.state = TypelessSessionStateError;
            [self.overlayView showErrorStatus:@"系统语音识别暂不可用，请检查网络或配置自定义 Whisper API"];
            return;
        }

        self.speechAudioEngine = [[AVAudioEngine alloc] init];
        AVAudioInputNode *inputNode = self.speechAudioEngine.inputNode;
        if (!inputNode) {
            self.state = TypelessSessionStateError;
            [self.overlayView showErrorStatus:@"无法访问设备麦克风输入通道"];
            return;
        }

        self.speechRequest = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
        self.speechRequest.shouldReportPartialResults = YES;

        __weak typeof(self) weakSelf = self;
        self.speechTask = [self.speechRecognizer recognitionTaskWithRequest:self.speechRequest resultHandler:^(SFSpeechRecognitionResult * _Nullable result, NSError * _Nullable error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf || token != strongSelf.sessionToken) return;
                if (result) {
                    NSString *str = result.bestTranscription.formattedString ?: @"";
                    if (str.length > 0) {
                        strongSelf.liveRecognizedText = str;
                        [strongSelf.overlayView updatePartialTranscript:str];
                    }
                    if (result.isFinal) {
                        strongSelf.speechDidFinishFinal = YES;
                        if (strongSelf.pendingSpeechFinalBlock) {
                            void (^blk)(NSString *) = strongSelf.pendingSpeechFinalBlock;
                            strongSelf.pendingSpeechFinalBlock = nil;
                            blk(strongSelf.liveRecognizedText);
                        }
                    }
                }
            });
        }];

        AVAudioFormat *fmt = [inputNode outputFormatForBus:0];
        [inputNode removeTapOnBus:0];
        AVAudioFormat *tapFmt = (fmt && fmt.sampleRate > 0 && fmt.channelCount > 0) ? fmt : nil;
        [inputNode installTapOnBus:0 bufferSize:1024 format:tapFmt block:^(AVAudioPCMBuffer * _Nonnull buffer, AVAudioTime * _Nonnull when) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || token != strongSelf.sessionToken) return;
            [strongSelf.speechRequest appendAudioPCMBuffer:buffer];

            if (buffer.floatChannelData && buffer.frameLength > 0) {
                float *channelData = buffer.floatChannelData[0];
                UInt32 len = buffer.frameLength;
                float sum = 0;
                for (UInt32 i = 0; i < len; i++) sum += channelData[i] * channelData[i];
                float rms = sqrtf(sum / len);
                CGFloat normalized = MAX(0.06, MIN(1.0, rms * 11.0));
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (token == strongSelf.sessionToken && strongSelf.state == TypelessSessionStateRecording) {
                        NSTimeInterval elapsed = strongSelf.recordingStartDate ? [[NSDate date] timeIntervalSinceDate:strongSelf.recordingStartDate] : 0;
                        [strongSelf.overlayView updateAudioLevel:normalized elapsedSeconds:elapsed];
                    }
                });
            }
        }];

        [self.speechAudioEngine prepare];
        NSError *startErr = nil;
        if (![self.speechAudioEngine startAndReturnError:&startErr]) {
            self.state = TypelessSessionStateError;
            [self.overlayView showErrorStatus:[self friendlyAudioError:startErr fallback:@"音频引擎启动失败"]];
            return;
        }

        // Also update elapsed timer smoothly even during silence
        self.meterTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer * _Nonnull timer) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || strongSelf.state != TypelessSessionStateRecording) return;
            NSTimeInterval elapsed = strongSelf.recordingStartDate ? [[NSDate date] timeIntervalSinceDate:strongSelf.recordingStartDate] : 0;
            [strongSelf.overlayView updateAudioLevel:-1 elapsedSeconds:elapsed];
        }];
    } @catch (NSException *e) {
        self.state = TypelessSessionStateError;
        [self.overlayView showErrorStatus:e.reason ?: @"语音引擎运行异常"];
    }
}

- (void)stopAudioCaptureOnly {
    if (self.usingHostBridge) {
        [[TypelessHostBridge sharedBridge] cancelRemoteRecording];
        self.usingHostBridge = NO;
    }
    if (self.meterTimer) {
        [self.meterTimer invalidate];
        self.meterTimer = nil;
    }
    if (self.audioRecorder) {
        [self.audioRecorder stop];
        self.audioRecorder = nil;
    }
    if (self.speechAudioEngine) {
        @try {
            [self.speechAudioEngine.inputNode removeTapOnBus:0];
            [self.speechAudioEngine stop];
        } @catch (NSException *e) {}
        self.speechAudioEngine = nil;
    }
    if (self.speechRequest) {
        [self.speechRequest endAudio];
        self.speechRequest = nil;
    }
    if (self.speechTask) {
        [self.speechTask cancel];
        self.speechTask = nil;
    }
    self.pendingSpeechFinalBlock = nil;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        @try {
            [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
        } @catch (NSException *e) {}
    });
}

#pragma mark - Finish & AI Pipeline

- (void)cancelRecordingAndReset {
    [self.haptic impactOccurred];
    self.sessionToken += 1;
    [self stopAudioCaptureOnly];
    if (self.recordingFileURL) {
        [[NSFileManager defaultManager] removeItemAtURL:self.recordingFileURL error:nil];
        self.recordingFileURL = nil;
    }
    self.state = TypelessSessionStateIdle;
    [self.overlayView refreshStateUI];
}

- (void)finishRecordingAndProcess {
    [self.haptic impactOccurred];
    if (self.state != TypelessSessionStateRecording) return;

    NSUInteger token = self.sessionToken;
    TypelessConfig *cfg = [TypelessConfig sharedConfig];

    if (self.meterTimer) {
        [self.meterTimer invalidate];
        self.meterTimer = nil;
    }

    if (self.usingHostBridge) {
        self.usingHostBridge = NO;
        self.state = TypelessSessionStateTranscribing;
        [self.overlayView refreshStateUI];

        __weak typeof(self) weakSelf = self;
        [[TypelessHostBridge sharedBridge] stopRemoteRecordingWithCompletion:^(NSString * _Nullable wavPath, NSString * _Nullable errorMessage) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || token != strongSelf.sessionToken) return;
            if (errorMessage || wavPath.length == 0) {
                strongSelf.state = TypelessSessionStateError;
                [strongSelf.overlayView showErrorStatus:errorMessage ?: @"后台录音获取失败"];
                return;
            }
            NSURL *wavURL = [NSURL fileURLWithPath:wavPath];
            if ([cfg shouldUseWhisperAPI]) {
                [strongSelf requestWhisperTranscriptionWithFileURL:wavURL
                                                            config:cfg
                                                 completionHandler:^(NSString * _Nullable rawText, NSError * _Nullable asrError) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        __strong typeof(weakSelf) s2 = weakSelf;
                        if (!s2 || token != s2.sessionToken) return;
                        if (asrError || rawText.length == 0) {
                            s2.state = TypelessSessionStateError;
                            [s2.overlayView showErrorStatus:asrError.localizedDescription ?: @"未识别到有效语音"];
                            return;
                        }
                        [s2 handleTranscribedText:rawText config:cfg token:token];
                    });
                }];
            } else {
                Class sfClass = NSClassFromString(@"SFSpeechRecognizer");
                Class reqClass = NSClassFromString(@"SFSpeechURLRecognitionRequest");
                if (!sfClass || !reqClass || [sfClass authorizationStatus] != SFSpeechRecognizerAuthorizationStatusAuthorized) {
                    strongSelf.state = TypelessSessionStateError;
                    [strongSelf.overlayView showErrorStatus:@"未授权 Apple 语音识别，请在「模型」配置 Whisper API Key 或开启权限"];
                    return;
                }
                SFSpeechRecognizer *rec = [[sfClass alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:@"zh-CN"]];
                if (!rec) rec = [[sfClass alloc] initWithLocale:[NSLocale currentLocale]];
                if (!rec || !rec.isAvailable) {
                    strongSelf.state = TypelessSessionStateError;
                    [strongSelf.overlayView showErrorStatus:@"系统语音识别暂不可用，请改用 Whisper API"];
                    return;
                }
                SFSpeechURLRecognitionRequest *req = [[reqClass alloc] initWithURL:wavURL];
                [rec recognitionTaskWithRequest:req resultHandler:^(SFSpeechRecognitionResult * _Nullable result, NSError * _Nullable err) {
                    if (!result && !err) return;
                    if (err || (result && result.isFinal)) {
                        NSString *text = result ? result.bestTranscription.formattedString : @"";
                        dispatch_async(dispatch_get_main_queue(), ^{
                            __strong typeof(weakSelf) s2 = weakSelf;
                            if (!s2 || token != s2.sessionToken) return;
                            if (text.length == 0) {
                                s2.state = TypelessSessionStateError;
                                [s2.overlayView showErrorStatus:err.localizedDescription ?: @"未识别到有效语音"];
                                return;
                            }
                            [s2 handleTranscribedText:text config:cfg token:token];
                        });
                    }
                }];
            }
        }];
        return;
    }

    if ([cfg shouldUseWhisperAPI]) {
        if (self.audioRecorder) {
            [self.audioRecorder stop];
            self.audioRecorder = nil;
        }
        self.state = TypelessSessionStateTranscribing;
        [self.overlayView refreshStateUI];

        __weak typeof(self) weakSelf = self;
        [self requestWhisperTranscriptionWithFileURL:self.recordingFileURL
                                              config:cfg
                                   completionHandler:^(NSString * _Nullable rawText, NSError * _Nullable asrError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf || token != strongSelf.sessionToken) return;
                if (asrError || !rawText || rawText.length == 0) {
                    strongSelf.state = TypelessSessionStateError;
                    [strongSelf.overlayView showErrorStatus:asrError.localizedDescription ?: @"未识别到有效语音"];
                    return;
                }
                [strongSelf handleTranscribedText:rawText config:cfg token:token];
            });
        }];
    } else {
        // Apple Speech: stop engine & flush endAudio, wait briefly for final word before cancelling
        if (self.speechAudioEngine) {
            @try {
                [self.speechAudioEngine.inputNode removeTapOnBus:0];
                [self.speechAudioEngine stop];
            } @catch (NSException *e) {}
            self.speechAudioEngine = nil;
        }
        if (self.speechRequest) {
            [self.speechRequest endAudio];
            self.speechRequest = nil;
        }

        self.state = TypelessSessionStateTranscribing;
        [self.overlayView refreshStateUI];

        __weak typeof(self) weakSelf = self;
        void (^proceedWithText)(NSString *) = ^(NSString *text) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || token != strongSelf.sessionToken) return;
            if (strongSelf.speechTask) {
                [strongSelf.speechTask cancel];
                strongSelf.speechTask = nil;
            }
            NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (trimmed.length == 0) {
                strongSelf.state = TypelessSessionStateError;
                [strongSelf.overlayView showErrorStatus:@"未识别到语音内容，请重试"];
                return;
            }
            [strongSelf handleTranscribedText:trimmed config:cfg token:token];
        };

        if (self.speechDidFinishFinal) {
            proceedWithText(self.liveRecognizedText);
        } else {
            self.pendingSpeechFinalBlock = proceedWithText;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.38 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf || token != strongSelf.sessionToken) return;
                if (strongSelf.pendingSpeechFinalBlock) {
                    void (^blk)(NSString *) = strongSelf.pendingSpeechFinalBlock;
                    strongSelf.pendingSpeechFinalBlock = nil;
                    blk(strongSelf.liveRecognizedText);
                }
            });
        }
    }
}

- (void)handleTranscribedText:(NSString *)rawText config:(TypelessConfig *)cfg token:(NSUInteger)token {
    BOOL shouldCallLLM = [cfg hasValidApiKey] && cfg.llmModel.length > 0 &&
                         (cfg.voiceMode != TypelessVoiceModeDictate || cfg.smartDictationCleanup);

    if (!shouldCallLLM) {
        [self commitRecognizedResult:rawText];
        return;
    }

    self.state = TypelessSessionStateProcessingAI;
    [self.overlayView refreshStateUI];

    __weak typeof(self) weakSelf = self;
    [self requestLLMPolishWithRawText:rawText
                        selectedText:self.capturedSelectionText
                              config:cfg
                   completionHandler:^(NSString * _Nullable polishedText, NSError * _Nullable llmError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || token != strongSelf.sessionToken) return;
            NSString *finalText = (polishedText && polishedText.length > 0) ? polishedText : rawText;
            [strongSelf commitRecognizedResult:finalText];
        });
    }];
}

- (void)commitRecognizedResult:(NSString *)text {
    if (text.length == 0) {
        self.state = TypelessSessionStateIdle;
        [self.overlayView refreshStateUI];
        return;
    }

    @try {
        id<UITextDocumentProxy> proxy = self.activeInputViewController.textDocumentProxy;
        if (proxy) {
            self.lastReplacedSelectionText = self.capturedSelectionText ?: @"";
            self.lastInsertedCharCount = [self countGraphemeClustersInString:text];
            [proxy insertText:text];
        }
    } @catch (NSException *e) {
        NSLog(@"[TypelessVoiceManager] Error inserting text: %@", e);
    }

    self.state = TypelessSessionStateIdle;
    [self.overlayView refreshStateUI];
    [self.overlayView showSuccessNotice:@"已上屏（可点右上角撤销或继续说话）"];
}

- (NSUInteger)countGraphemeClustersInString:(NSString *)str {
    __block NSUInteger count = 0;
    [str enumerateSubstringsInRange:NSMakeRange(0, str.length)
                            options:NSStringEnumerationByComposedCharacterSequences
                         usingBlock:^(NSString * _Nullable substring, NSRange substringRange, NSRange enclosingRange, BOOL * _Nonnull stop) {
        count++;
    }];
    return count;
}

#pragma mark - Network Requests

- (void)requestWhisperTranscriptionWithFileURL:(NSURL *)fileURL
                                        config:(TypelessConfig *)config
                             completionHandler:(void (^)(NSString * _Nullable text, NSError * _Nullable error))completionHandler {
    NSData *audioData = fileURL ? [NSData dataWithContentsOfURL:fileURL] : nil;
    if (fileURL) {
        [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];
    }
    if (!audioData || audioData.length == 0) {
        if (completionHandler) completionHandler(nil, [NSError errorWithDomain:@"Typeless" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"录音数据为空"}]);
        return;
    }

    NSString *cleanBase = [config.baseURL stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    NSString *endpoint = [cleanBase stringByAppendingString:@"/audio/transcriptions"];
    NSURL *url = [NSURL URLWithString:endpoint];
    if (!url) {
        if (completionHandler) completionHandler(nil, [NSError errorWithDomain:@"Typeless" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"无效的 API 地址"}]);
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 25.0;
    [req setValue:[NSString stringWithFormat:@"Bearer %@", config.apiKey] forHTTPHeaderField:@"Authorization"];

    NSString *boundary = [NSString stringWithFormat:@"Boundary-%@", [[NSUUID UUID] UUIDString]];
    [req setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary] forHTTPHeaderField:@"Content-Type"];

    NSMutableData *body = [NSMutableData data];
    [body appendData:[[NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n%@\r\n", boundary, config.asrModel ?: @"whisper-1"] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.m4a\"\r\nContent-Type: audio/m4a\r\n\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:audioData];
    [body appendData:[[NSString stringWithFormat:@"\r\n--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    req.HTTPBody = body;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error) {
            if (completionHandler) completionHandler(nil, error);
            return;
        }
        @try {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data ?: [NSData data] options:0 error:nil];
            NSString *transcription = json[@"text"];
            if ([transcription isKindOfClass:[NSString class]] && transcription.length > 0) {
                if (completionHandler) completionHandler(transcription, nil);
            } else {
                NSString *errMsg = nil;
                if ([json[@"error"] isKindOfClass:[NSDictionary class]]) {
                    errMsg = json[@"error"][@"message"];
                }
                if (!errMsg) errMsg = @"语音接口未返回有效内容（纯对话接口请开启 Apple 本地听写）";
                if (completionHandler) completionHandler(nil, [NSError errorWithDomain:@"Typeless" code:-4 userInfo:@{NSLocalizedDescriptionKey: errMsg}]);
            }
        } @catch (NSException *e) {
            if (completionHandler) completionHandler(nil, [NSError errorWithDomain:@"Typeless" code:-5 userInfo:@{NSLocalizedDescriptionKey: @"解析语音响应失败"}]);
        }
    }];
    [task resume];
}

- (void)requestLLMPolishWithRawText:(NSString *)rawText
                       selectedText:(NSString *)selectedText
                             config:(TypelessConfig *)config
                  completionHandler:(void (^)(NSString * _Nullable polishedText, NSError * _Nullable error))completionHandler {
    NSString *cleanBase = [config.baseURL stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    NSString *endpoint = [cleanBase stringByAppendingString:@"/chat/completions"];
    NSURL *url = [NSURL URLWithString:endpoint];
    if (!url) {
        if (completionHandler) completionHandler(rawText, nil);
        return;
    }

    NSString *systemPrompt = [config promptForMode:config.voiceMode];
    NSString *userContent = rawText;
    if (config.voiceMode == TypelessVoiceModeEdit && selectedText.length > 0) {
        userContent = [NSString stringWithFormat:@"【待修改文本】\n%@\n\n【语音修改指令】\n%@", selectedText, rawText];
    } else if (config.voiceMode == TypelessVoiceModeTranslate) {
        userContent = [NSString stringWithFormat:@"请将以下口述内容翻译为 %@：\n%@", config.targetLanguage ?: @"English", rawText];
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 25.0;
    [req setValue:[NSString stringWithFormat:@"Bearer %@", config.apiKey] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSDictionary *payload = @{
        @"model": config.llmModel ?: @"gpt-4o-mini",
        @"messages": @[
            @{@"role": @"system", @"content": systemPrompt},
            @{@"role": @"user", @"content": userContent}
        ],
        @"temperature": @(0.25)
    };
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error) {
            if (completionHandler) completionHandler(rawText, nil);
            return;
        }
        @try {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data ?: [NSData data] options:0 error:nil];
            NSArray *choices = json[@"choices"];
            NSString *content = nil;
            if ([choices isKindOfClass:[NSArray class]] && choices.count > 0) {
                content = choices.firstObject[@"message"][@"content"];
            }
            if ([content isKindOfClass:[NSString class]] && content.length > 0) {
                NSString *trimmed = [content stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (completionHandler) completionHandler(trimmed, nil);
            } else {
                if (completionHandler) completionHandler(rawText, nil);
            }
        } @catch (NSException *e) {
            if (completionHandler) completionHandler(rawText, nil);
        }
    }];
    [task resume];
}

#pragma mark - Bottom Key Actions & Undo

- (void)insertSpace {
    [self.haptic impactOccurred];
    id<UITextDocumentProxy> proxy = self.activeInputViewController.textDocumentProxy;
    if (proxy) {
        [proxy insertText:@" "];
    }
    self.lastInsertedCharCount = 0;
}

- (void)deleteBackwardStep {
    id<UITextDocumentProxy> proxy = self.activeInputViewController.textDocumentProxy;
    if (proxy) {
        [proxy deleteBackward];
    }
    self.lastInsertedCharCount = 0;
}

- (void)insertReturn {
    [self.haptic impactOccurred];
    id<UITextDocumentProxy> proxy = self.activeInputViewController.textDocumentProxy;
    if (proxy) {
        [proxy insertText:@"\n"];
    }
    self.lastInsertedCharCount = 0;
}

- (void)undoLastInsert {
    if (self.lastInsertedCharCount == 0) return;
    [self.haptic impactOccurred];
    id<UITextDocumentProxy> proxy = self.activeInputViewController.textDocumentProxy;
    if (proxy) {
        for (NSUInteger i = 0; i < self.lastInsertedCharCount; i++) {
            [proxy deleteBackward];
        }
        if (self.lastReplacedSelectionText.length > 0) {
            [proxy insertText:self.lastReplacedSelectionText];
        }
    }
    self.lastInsertedCharCount = 0;
    self.lastReplacedSelectionText = @"";
    [self.overlayView refreshStateUI];
    [self.overlayView showSuccessNotice:@"已撤销上一次语音上屏"];
}

@end
