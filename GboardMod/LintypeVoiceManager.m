#import "LintypeVoiceManager.h"
#import "LintypeVoiceOverlayView.h"

@interface LintypeVoiceManager () <LintypeVoiceOverlayViewDelegate>

@property (nonatomic, strong) AVAudioEngine *audioEngine;
@property (nonatomic, strong) SFSpeechRecognizer *speechRecognizer;
@property (nonatomic, strong) SFSpeechAudioBufferRecognitionRequest *recognitionRequest;
@property (nonatomic, strong) SFSpeechRecognitionTask *recognitionTask;
@property (nonatomic, strong) LintypeVoiceOverlayView *overlayView;
@property (nonatomic, assign) BOOL isRecording;
@property (nonatomic, copy) NSString *latestRecognizedText;

@end

@implementation LintypeVoiceManager

+ (instancetype)sharedManager {
    static LintypeVoiceManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[LintypeVoiceManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    // Keep lightweight: DO NOT initialize speechRecognizer here to prevent startup crash
    return self;
}

- (void)quickMicTapped:(id)sender {
    [self presentVoiceOverlayInViewController:self.activeInputViewController];
}

- (void)presentVoiceOverlayInViewController:(nullable UIInputViewController *)viewController {
    if (!viewController) {
        viewController = self.activeInputViewController;
    }
    if (!viewController || !viewController.view) return;
    self.activeInputViewController = viewController;

    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!self.overlayView) {
                self.overlayView = [[LintypeVoiceOverlayView alloc] initWithFrame:viewController.view.bounds];
                self.overlayView.delegate = self;
            } else {
                self.overlayView.frame = viewController.view.bounds;
            }

            [self.overlayView reset];
            self.overlayView.alpha = 0.0;
            [viewController.view addSubview:self.overlayView];
            [viewController.view bringSubviewToFront:self.overlayView];

            [UIView animateWithDuration:0.2 animations:^{
                self.overlayView.alpha = 1.0;
            }];

            [self startListening];
        } @catch (NSException *e) {
            NSLog(@"[LintypeVoiceManager] Exception presenting voice overlay: %@", e);
        }
    });
}

- (void)dismissVoiceOverlayAnimated:(BOOL)animated {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!self.overlayView || !self.overlayView.superview) return;
            if (animated) {
                [UIView animateWithDuration:0.2 animations:^{
                    self.overlayView.alpha = 0.0;
                } completion:^(BOOL finished) {
                    [self.overlayView removeFromSuperview];
                }];
            } else {
                [self.overlayView removeFromSuperview];
            }
        } @catch (NSException *e) {}
    });
}

- (void)startListening {
    [self startListeningWithLevelHandler:^(CGFloat level) {
        [self.overlayView updateAudioLevel:level];
    } partialTextHandler:^(NSString *text) {
        [self.overlayView updateTranscriptText:text];
    } finalTextHandler:^(NSString *text, NSError *error) {
        if (error) {
            [self.overlayView setStatusText:[NSString stringWithFormat:@"提示: %@", error.localizedDescription]];
        } else if (text.length > 0) {
            [self.overlayView updateTranscriptText:text];
        }
    }];
}

- (void)startListeningWithLevelHandler:(void (^)(CGFloat level))levelHandler
                    partialTextHandler:(void (^)(NSString *text))partialHandler
                      finalTextHandler:(void (^)(NSString *text, NSError *error))finalHandler {
    [self stopAudioEngineInternal];

    self.latestRecognizedText = @"";
    self.isRecording = YES;

    // Lazily initialize speech recognizer
    @try {
        if (!self.speechRecognizer) {
            NSLocale *locale = [NSLocale localeWithLocaleIdentifier:@"zh-CN"];
            self.speechRecognizer = [[SFSpeechRecognizer alloc] initWithLocale:locale];
            if (!self.speechRecognizer) {
                self.speechRecognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale currentLocale]];
            }
        }
    } @catch (NSException *e) {
        if (finalHandler) {
            NSError *err = [NSError errorWithDomain:@"LintypeVoice" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"语音引擎初始化失败"}];
            finalHandler(@"", err);
        }
        return;
    }

    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (status != SFSpeechRecognizerAuthorizationStatusAuthorized) {
                if (finalHandler) {
                    NSError *err = [NSError errorWithDomain:@"LintypeVoice" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"请在系统设置中允许麦克风及语音识别"}];
                    finalHandler(@"", err);
                }
                return;
            }

            @try {
                [self setupAndStartAudioPipelineWithLevelHandler:levelHandler
                                                  partialHandler:partialHandler
                                                    finalHandler:finalHandler];
            } @catch (NSException *e) {
                if (finalHandler) {
                    NSError *err = [NSError errorWithDomain:@"LintypeVoice" code:-4 userInfo:@{NSLocalizedDescriptionKey: e.reason ?: @"音频通道错误"}];
                    finalHandler(@"", err);
                }
            }
        });
    }];
}

- (void)setupAndStartAudioPipelineWithLevelHandler:(void (^)(CGFloat level))levelHandler
                                   partialHandler:(void (^)(NSString *text))partialHandler
                                     finalHandler:(void (^)(NSString *text, NSError *error))finalHandler {
    @try {
        AVAudioSession *audioSession = [AVAudioSession sharedInstance];
        NSError *error = nil;
        [audioSession setCategory:AVAudioSessionCategoryPlayAndRecord
                      withOptions:AVAudioSessionCategoryOptionMixWithOthers |
                                  AVAudioSessionCategoryOptionDefaultToSpeaker
                            error:&error];
        [audioSession setMode:AVAudioSessionModeMeasurement error:&error];
        [audioSession setActive:YES withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&error];

        self.audioEngine = [[AVAudioEngine alloc] init];
        AVAudioInputNode *inputNode = self.audioEngine.inputNode;
        if (!inputNode) {
            if (finalHandler) {
                NSError *err = [NSError errorWithDomain:@"LintypeVoice" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"无法访问音频输入设备"}];
                finalHandler(@"", err);
            }
            return;
        }

        self.recognitionRequest = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
        self.recognitionRequest.shouldReportPartialResults = YES;

        __weak typeof(self) weakSelf = self;
        self.recognitionTask = [self.speechRecognizer recognitionTaskWithRequest:self.recognitionRequest
                                                                   resultHandler:^(SFSpeechRecognitionResult * _Nullable result, NSError * _Nullable taskError) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            if (result) {
                NSString *transcript = result.bestTranscription.formattedString;
                strongSelf.latestRecognizedText = transcript;
                if (partialHandler) {
                    partialHandler(transcript);
                }
                if (result.isFinal) {
                    if (finalHandler) {
                        finalHandler(transcript, nil);
                    }
                }
            }
            if (taskError && strongSelf.isRecording) {
                if (finalHandler) {
                    finalHandler(strongSelf.latestRecognizedText ?: @"", taskError);
                }
            }
        }];

        AVAudioFormat *recordingFormat = [inputNode outputFormatForBus:0];
        [inputNode removeTapOnBus:0];
        [inputNode installTapOnBus:0 bufferSize:1024 format:recordingFormat block:^(AVAudioPCMBuffer * _Nonnull buffer, AVAudioTime * _Nonnull when) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.recognitionRequest) return;
            [strongSelf.recognitionRequest appendAudioPCMBuffer:buffer];

            if (levelHandler && buffer.floatChannelData) {
                float *channelData = buffer.floatChannelData[0];
                UInt32 frameLength = buffer.frameLength;
                if (frameLength > 0) {
                    float sum = 0;
                    for (UInt32 i = 0; i < frameLength; i++) {
                        sum += channelData[i] * channelData[i];
                    }
                    float rms = sqrtf(sum / frameLength);
                    CGFloat normalized = (CGFloat)MIN(1.0, rms * 10.0);
                    levelHandler(normalized);
                }
            }
        }];

        [self.audioEngine prepare];
        NSError *startError = nil;
        [self.audioEngine startAndReturnError:&startError];
        if (startError && finalHandler) {
            finalHandler(@"", startError);
        }
    } @catch (NSException *e) {
        if (finalHandler) {
            NSError *err = [NSError errorWithDomain:@"LintypeVoice" code:-5 userInfo:@{NSLocalizedDescriptionKey: e.reason ?: @"音频采集启动异常"}];
            finalHandler(@"", err);
        }
    }
}

- (void)stopAudioEngineInternal {
    self.isRecording = NO;
    @try {
        if (self.audioEngine) {
            [self.audioEngine.inputNode removeTapOnBus:0];
            [self.audioEngine stop];
            self.audioEngine = nil;
        }
        if (self.recognitionRequest) {
            [self.recognitionRequest endAudio];
            self.recognitionRequest = nil;
        }
        if (self.recognitionTask) {
            [self.recognitionTask cancel];
            self.recognitionTask = nil;
        }
    } @catch (NSException *e) {}
}

- (void)stopListeningAndCommitText:(nullable NSString *)manualText {
    NSString *textToCommit = (manualText.length > 0) ? manualText : self.latestRecognizedText;
    [self stopAudioEngineInternal];
    [self dismissVoiceOverlayAnimated:YES];

    if (textToCommit.length > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                id<UITextDocumentProxy> proxy = self.activeInputViewController.textDocumentProxy;
                if (proxy) {
                    [proxy insertText:textToCommit];
                }
            } @catch (NSException *e) {}
        });
    }
}

- (void)cancelListening {
    [self stopAudioEngineInternal];
    [self dismissVoiceOverlayAnimated:YES];
}

#pragma mark - LintypeVoiceOverlayViewDelegate

- (void)voiceOverlayDidTapDone:(NSString *)text {
    [self stopListeningAndCommitText:text];
}

- (void)voiceOverlayDidTapCancel {
    [self cancelListening];
}

- (void)voiceOverlayDidTapRetry {
    [self startListening];
}

@end
