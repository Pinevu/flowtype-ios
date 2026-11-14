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
    if (self) {
        NSLocale *locale = [NSLocale localeWithLocaleIdentifier:@"zh-CN"];
        _speechRecognizer = [[SFSpeechRecognizer alloc] initWithLocale:locale];
        if (!_speechRecognizer || !_speechRecognizer.isAvailable) {
            _speechRecognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale currentLocale]];
        }
    }
    return self;
}

- (void)presentVoiceOverlayInViewController:(UIInputViewController *)viewController {
    if (!viewController) return;
    self.activeInputViewController = viewController;

    dispatch_async(dispatch_get_main_queue(), ^{
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

        [UIView animateWithDuration:0.25 animations:^{
            self.overlayView.alpha = 1.0;
        }];

        [self startListening];
    });
}

- (void)dismissVoiceOverlayAnimated:(BOOL)animated {
    dispatch_async(dispatch_get_main_queue(), ^{
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
    });
}

- (void)startListening {
    [self startListeningWithLevelHandler:^(CGFloat level) {
        [self.overlayView updateAudioLevel:level];
    } partialTextHandler:^(NSString *text) {
        [self.overlayView updateTranscriptText:text];
    } finalTextHandler:^(NSString *text, NSError *error) {
        if (error) {
            [self.overlayView setStatusText:[NSString stringWithFormat:@"识别提示: %@", error.localizedDescription]];
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

    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        if (status != SFSpeechRecognizerAuthorizationStatusAuthorized) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (finalHandler) {
                    NSError *err = [NSError errorWithDomain:@"LintypeVoice" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"请在设置中开启语音识别权限"}];
                    finalHandler(@"", err);
                }
            });
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self setupAndStartAudioPipelineWithLevelHandler:levelHandler
                                              partialHandler:partialHandler
                                                finalHandler:finalHandler];
        });
    }];
}

- (void)setupAndStartAudioPipelineWithLevelHandler:(void (^)(CGFloat level))levelHandler
                                   partialHandler:(void (^)(NSString *text))partialHandler
                                     finalHandler:(void (^)(NSString *text, NSError *error))finalHandler {
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    NSError *error = nil;
    [audioSession setCategory:AVAudioSessionCategoryPlayAndRecord
                  withOptions:AVAudioSessionCategoryOptionMixWithOthers |
                              AVAudioSessionCategoryOptionDefaultToSpeaker |
                              AVAudioSessionCategoryOptionAllowBluetooth
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

    // Check if on-device recognition supported
    if (@available(iOS 13.0, *)) {
        if (self.speechRecognizer.supportsOnDeviceRecognition) {
            self.recognitionRequest.requiresOnDeviceRecognition = NO; // allow both on-device & server for best accuracy
        }
    }

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
            // Calculate RMS
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
}

- (void)stopAudioEngineInternal {
    self.isRecording = NO;
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
}

- (void)stopListeningAndCommitText:(nullable NSString *)manualText {
    NSString *textToCommit = (manualText.length > 0) ? manualText : self.latestRecognizedText;
    [self stopAudioEngineInternal];
    [self dismissVoiceOverlayAnimated:YES];

    if (textToCommit.length > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            id<UITextDocumentProxy> proxy = self.activeInputViewController.textDocumentProxy;
            if (proxy) {
                [proxy insertText:textToCommit];
            }
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
