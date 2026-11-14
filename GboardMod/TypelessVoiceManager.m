#import "TypelessVoiceManager.h"
#import "TypelessConfig.h"
#import "TypelessOverlayView.h"
#import <Speech/Speech.h>

@interface TypelessVoiceManager () <AVAudioRecorderDelegate>

@property (nonatomic, strong) AVAudioRecorder *audioRecorder;
@property (nonatomic, strong) NSTimer *meterTimer;
@property (nonatomic, copy, nullable) void (^meterLevelHandler)(CGFloat level);
@property (nonatomic, strong) TypelessOverlayView *overlayView;
@property (nonatomic, assign) BOOL isRecording;
@property (nonatomic, strong) NSURL *recordingFileURL;

// Fallback Speech Recognizer
@property (nonatomic, strong) SFSpeechRecognizer *speechRecognizer;
@property (nonatomic, strong) SFSpeechAudioBufferRecognitionRequest *speechRequest;
@property (nonatomic, strong) SFSpeechRecognitionTask *speechTask;
@property (nonatomic, strong) AVAudioEngine *speechAudioEngine;
@property (nonatomic, copy) NSString *fallbackRecognizedText;

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
    return self;
}

- (void)quickMicTapped:(nullable id)sender {
    [self presentVoiceOverlayInViewController:self.activeInputViewController];
}

- (void)presentVoiceOverlayInViewController:(nullable UIInputViewController *)viewController {
    if (!viewController) viewController = self.activeInputViewController;
    if (!viewController || !viewController.view) return;
    self.activeInputViewController = viewController;

    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!self.overlayView) {
                self.overlayView = [[TypelessOverlayView alloc] initWithFrame:viewController.view.bounds];
            } else {
                self.overlayView.frame = viewController.view.bounds;
            }

            [self.overlayView resetForNewRecording];
            self.overlayView.alpha = 0.0;
            [viewController.view addSubview:self.overlayView];
            [viewController.view bringSubviewToFront:self.overlayView];

            [UIView animateWithDuration:0.2 animations:^{
                self.overlayView.alpha = 1.0;
            }];

            [self startRecording];
        } @catch (NSException *e) {
            NSLog(@"[TypelessVoiceManager] Exception presenting overlay: %@", e);
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

- (void)startRecording {
    [self startRecordingWithLevelHandler:^(CGFloat level) {
        [self.overlayView updateAudioLevel:level];
    }];
}

- (void)startRecordingWithLevelHandler:(void (^)(CGFloat level))levelHandler {
    [self stopRecordingInternal];
    self.isRecording = YES;
    self.meterLevelHandler = levelHandler;

    TypelessConfig *cfg = [TypelessConfig sharedConfig];
    if ([cfg hasValidApiKey]) {
        // High quality M4A recording for Whisper / Custom AI endpoint
        [self startAudioRecorderWithLevelHandler:levelHandler];
    } else {
        // Zero-setup iOS native speech recognition fallback
        [self startAppleSpeechWithLevelHandler:levelHandler];
    }
}

- (void)startAudioRecorderWithLevelHandler:(void (^)(CGFloat level))levelHandler {
    @try {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session setCategory:AVAudioSessionCategoryPlayAndRecord withOptions:AVAudioSessionCategoryOptionMixWithOthers | AVAudioSessionCategoryOptionDefaultToSpeaker error:nil];
        [session setActive:YES error:nil];

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
            self.meterTimer = [NSTimer scheduledTimerWithTimeInterval:0.08 target:self selector:@selector(checkMeterPower) userInfo:nil repeats:YES];
        } else {
            NSLog(@"[TypelessVoiceManager] Failed to start audio recorder: %@", error);
        }
    } @catch (NSException *e) {
        NSLog(@"[TypelessVoiceManager] Exception starting recorder: %@", e);
    }
}

- (void)checkMeterPower {
    if (!self.audioRecorder || !self.isRecording) return;
    [self.audioRecorder updateMeters];
    float power = [self.audioRecorder averagePowerForChannel:0];
    CGFloat normalized = MAX(0.05, MIN(1.0, (power + 50.0) / 50.0));
    if (self.meterLevelHandler) {
        self.meterLevelHandler(normalized);
    }
}

- (void)startAppleSpeechWithLevelHandler:(void (^)(CGFloat level))levelHandler {
    @try {
        Class sfClass = NSClassFromString(@"SFSpeechRecognizer");
        if (!sfClass) return;

        NSLocale *locale = [NSLocale localeWithLocaleIdentifier:@"zh-CN"];
        self.speechRecognizer = [[sfClass alloc] initWithLocale:locale];
        if (!self.speechRecognizer) {
            self.speechRecognizer = [[sfClass alloc] initWithLocale:[NSLocale currentLocale]];
        }

        self.speechAudioEngine = [[AVAudioEngine alloc] init];
        AVAudioInputNode *inputNode = self.speechAudioEngine.inputNode;
        if (!inputNode) return;

        self.speechRequest = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
        self.speechRequest.shouldReportPartialResults = YES;

        self.fallbackRecognizedText = @"";
        __weak typeof(self) weakSelf = self;
        self.speechTask = [self.speechRecognizer recognitionTaskWithRequest:self.speechRequest resultHandler:^(SFSpeechRecognitionResult * _Nullable result, NSError * _Nullable error) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (result) {
                strongSelf.fallbackRecognizedText = result.bestTranscription.formattedString ?: @"";
                dispatch_async(dispatch_get_main_queue(), ^{
                    [strongSelf.overlayView updateTranscriptText:strongSelf.fallbackRecognizedText];
                });
            }
        }];

        AVAudioFormat *fmt = [inputNode outputFormatForBus:0];
        [inputNode removeTapOnBus:0];
        [inputNode installTapOnBus:0 bufferSize:1024 format:fmt block:^(AVAudioPCMBuffer * _Nonnull buffer, AVAudioTime * _Nonnull when) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.speechRequest) return;
            [strongSelf.speechRequest appendAudioPCMBuffer:buffer];

            if (levelHandler && buffer.floatChannelData) {
                float *channelData = buffer.floatChannelData[0];
                UInt32 len = buffer.frameLength;
                if (len > 0) {
                    float sum = 0;
                    for (UInt32 i = 0; i < len; i++) sum += channelData[i] * channelData[i];
                    float rms = sqrtf(sum / len);
                    CGFloat normalized = MIN(1.0, rms * 10.0);
                    levelHandler(normalized);
                }
            }
        }];

        [self.speechAudioEngine prepare];
        [self.speechAudioEngine startAndReturnError:nil];
    } @catch (NSException *e) {
        NSLog(@"[TypelessVoiceManager] Exception starting fallback speech: %@", e);
    }
}

- (void)stopRecordingInternal {
    self.isRecording = NO;
    if (self.meterTimer) {
        [self.meterTimer invalidate];
        self.meterTimer = nil;
    }
    if (self.audioRecorder) {
        [self.audioRecorder stop];
        self.audioRecorder = nil;
    }
    if (self.speechAudioEngine) {
        [self.speechAudioEngine.inputNode removeTapOnBus:0];
        [self.speechAudioEngine stop];
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
}

- (void)stopRecordingAndProcessWithStatusHandler:(void (^)(NSString *status))statusHandler
                               completionHandler:(void (^)(NSString * _Nullable text, NSError * _Nullable error))completionHandler {
    self.isRecording = NO;
    if (self.meterTimer) {
        [self.meterTimer invalidate];
        self.meterTimer = nil;
    }

    TypelessConfig *cfg = [TypelessConfig sharedConfig];
    if ([cfg hasValidApiKey]) {
        if (self.audioRecorder) {
            [self.audioRecorder stop];
            self.audioRecorder = nil;
        }

        if (statusHandler) statusHandler(@"AI 识别中...");

        [self requestWhisperTranscriptionWithFileURL:self.recordingFileURL
                                              config:cfg
                                   completionHandler:^(NSString * _Nullable rawText, NSError * _Nullable asrError) {
            if (asrError || !rawText || rawText.length == 0) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completionHandler) completionHandler(nil, asrError ?: [NSError errorWithDomain:@"Typeless" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"未识别到有效语音"}]);
                });
                return;
            }

            if (cfg.isAIPolish) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (statusHandler) statusHandler(@"AI 润色中...");
                });
                [self requestLLMPolishWithRawText:rawText config:cfg completionHandler:^(NSString * _Nullable polishedText, NSError * _Nullable llmError) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (completionHandler) {
                            completionHandler(polishedText ?: rawText, nil);
                        }
                    });
                }];
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completionHandler) completionHandler(rawText, nil);
                });
            }
        }];
    } else {
        // Stop Apple Speech
        [self stopRecordingInternal];
        NSString *result = self.fallbackRecognizedText ?: @"";
        if (completionHandler) {
            completionHandler(result, nil);
        }
    }
}

#pragma mark - AI Network Pipelines

- (void)requestWhisperTranscriptionWithFileURL:(NSURL *)fileURL
                                        config:(TypelessConfig *)config
                             completionHandler:(void (^)(NSString * _Nullable text, NSError * _Nullable error))completionHandler {
    NSData *audioData = [NSData dataWithContentsOfURL:fileURL];
    if (!audioData || audioData.length == 0) {
        if (completionHandler) completionHandler(nil, [NSError errorWithDomain:@"Typeless" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"音频数据为空"}]);
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
    // model param
    [body appendData:[[NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n%@\r\n", boundary, config.asrModel ?: @"whisper-1"] dataUsingEncoding:NSUTF8StringEncoding]];
    // language param
    [body appendData:[[NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\nzh\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    // file param
    [body appendData:[[NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.m4a\"\r\nContent-Type: audio/m4a\r\n\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:audioData];
    [body appendData:[[NSString stringWithFormat:@"\r\n--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    req.HTTPBody = body;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        // Clean temporary audio file
        [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];

        if (error) {
            if (completionHandler) completionHandler(nil, error);
            return;
        }

        @try {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data ?: [NSData data] options:0 error:nil];
            NSString *transcription = json[@"text"];
            if (transcription && transcription.length > 0) {
                if (completionHandler) completionHandler(transcription, nil);
            } else {
                NSString *errMsg = json[@"error"][@"message"] ?: @"语音接口未返回有效内容";
                if (completionHandler) completionHandler(nil, [NSError errorWithDomain:@"Typeless" code:-4 userInfo:@{NSLocalizedDescriptionKey: errMsg}]);
            }
        } @catch (NSException *e) {
            if (completionHandler) completionHandler(nil, [NSError errorWithDomain:@"Typeless" code:-5 userInfo:@{NSLocalizedDescriptionKey: @"解析响应数据失败"}]);
        }
    }];
    [task resume];
}

- (void)requestLLMPolishWithRawText:(NSString *)rawText
                             config:(TypelessConfig *)config
                  completionHandler:(void (^)(NSString * _Nullable polishedText, NSError * _Nullable error))completionHandler {
    NSString *cleanBase = [config.baseURL stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    NSString *endpoint = [cleanBase stringByAppendingString:@"/chat/completions"];
    NSURL *url = [NSURL URLWithString:endpoint];
    if (!url) {
        if (completionHandler) completionHandler(rawText, nil);
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 20.0;
    [req setValue:[NSString stringWithFormat:@"Bearer %@", config.apiKey] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSDictionary *payload = @{
        @"model": config.llmModel ?: @"gpt-4o-mini",
        @"messages": @[
            @{@"role": @"system", @"content": config.customPrompt ?: @"请将口述文字整理为自然流畅的书面语，修正标点与错别字，保持原意，直接输出结果。"},
            @{@"role": @"user", @"content": rawText}
        ],
        @"temperature": @(0.3)
    };

    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error) {
            // Graceful fallback: return raw transcription on LLM failure
            if (completionHandler) completionHandler(rawText, nil);
            return;
        }

        @try {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data ?: [NSData data] options:0 error:nil];
            NSArray *choices = json[@"choices"];
            NSString *content = choices.firstObject[@"message"][@"content"];
            if (content && content.length > 0) {
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

- (void)cancelRecording {
    [self stopRecordingInternal];
    [self dismissVoiceOverlayAnimated:YES];
}

- (void)commitTextDirectly:(NSString *)text {
    [self stopRecordingInternal];
    [self dismissVoiceOverlayAnimated:YES];

    if (text.length > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                id<UITextDocumentProxy> proxy = self.activeInputViewController.textDocumentProxy;
                if (proxy) {
                    [proxy insertText:text];
                }
            } @catch (NSException *e) {
                NSLog(@"[TypelessVoiceManager] Error inserting text: %@", e);
            }
        });
    }
}

@end
