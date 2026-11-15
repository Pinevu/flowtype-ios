#import "TypelessConfig.h"
#import <Security/Security.h>

static NSString *const kAppGroupPrimary = @"group.com.google.keyboard";
static NSString *const kAppGroupSecondary = @"group.com.google.common";
static NSString *const kConfigFileName = @"typeless_config_v2.json";
static NSString *const kLegacyConfigFileName = @"typeless_config.json";
static NSString *const kConfigDictKey = @"LintypeTypelessConfigDictV2";
static NSString *const kKeychainService = @"com.lintype.gboard.config";
static NSString *const kKeychainAccount = @"shared_config_v2";
static CFStringRef const kConfigDidChangeDarwinName = CFSTR("com.lintype.gboard.configDidChange");

static NSString *const kDefaultAsrBaseURL = @"https://api.openai.com/v1";
static NSString *const kDefaultLlmBaseURL = @"https://api.openai.com/v1";
static NSString *const kDefaultAsrModel = @"whisper-1";
static NSString *const kDefaultLlmModel = @"gpt-4o-mini";

static NSString *const kDefaultPromptDictate =
    @"你是一个严谨、高效的语音输入排版与润色助手。"
    @"请将用户的语音转写文本中的口语废话、卡顿重复（如“嗯”、“那个”、“就是说”等）和明显的同音错别字进行清理，"
    @"补充合理的中文或英文标点符号，保持说话者的原始语义和语气不变。"
    @"只输出整理后的纯文本结果，绝对不要加任何解释、前缀、引号或额外内容。";

static NSString *const kDefaultPromptEdit =
    @"你是一个专业的文字修改与润色助手。"
    @"用户当前已在输入框中选中了一段文本，随后说出了一段修改指令。"
    @"请严格按照用户的口述修改要求，对原选中文本进行改写、删减、扩写或语病修正。"
    @"只输出修改后的最终完整文本，不要输出“好的”、“修改如下”或任何多余解释。";

static NSString *const kDefaultPromptTranslate =
    @"你是一个精通多国语言的专业同声传译。"
    @"请将用户输入的语音转写文本准确、地道、自然地翻译成目标语言，保留原有语气和专业词汇准确性。"
    @"只输出翻译后的纯文本结果，绝对不要附带任何原文、音标或额外说明。";

static NSString *const kDefaultPromptHelpWrite =
    @"你是一个聪明得体的 AI 写作与回复助手。"
    @"请根据用户的语音指令或要点草稿，直接帮用户撰写成结构清晰、表达流畅、得体自然的完整文本（如邮件、微信回复、汇报总结等）。"
    @"只输出最终可直接发送的正文内容，不要包含“为你生成如下”等多余客套话。";

@interface TypelessConfig ()
@property (nonatomic, copy, nullable) NSString *cachedDetectedGroupID;
@property (nonatomic, copy, nullable) NSString *cachedGroupPath;
@property (nonatomic, assign) BOOL didProbeAppGroups;
@property (nonatomic, assign) NSTimeInterval lastUpdatedAt;
@end

@implementation TypelessConfig

+ (instancetype)sharedConfig {
    static TypelessConfig *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TypelessConfig alloc] init];
        [instance load];
    });
    return instance;
}

+ (NSString *)titleForMode:(TypelessVoiceMode)mode {
    switch (mode) {
        case TypelessVoiceModeDictate: return @"润色听写";
        case TypelessVoiceModeEdit: return @"选中改写";
        case TypelessVoiceModeTranslate: return @"实时翻译";
        case TypelessVoiceModeHelpWrite: return @"AI 帮写";
    }
    return @"润色听写";
}

+ (NSArray<NSString *> *)supportedTargetLanguages {
    return @[@"英语", @"简体中文", @"日语", @"韩语", @"法语", @"德语", @"西班牙语"];
}

+ (NSString *)titleForPolishStyle:(TypelessPolishStyle)style {
    switch (style) {
        case TypelessPolishStyleSmart: return @"智能润色";
        case TypelessPolishStyleConcise: return @"精简干练";
        case TypelessPolishStyleFormal: return @"正式书面";
        case TypelessPolishStyleLight: return @"轻修原意";
    }
    return @"智能润色";
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self applyDefaultValues];
    }
    return self;
}

- (void)applyDefaultValues {
    _voiceMode = TypelessVoiceModeDictate;
    _targetLanguage = @"英语";
    _polishStyle = TypelessPolishStyleSmart;
    _pipKeepAliveEnabled = NO;
    _launchInterface = TypelessLaunchInterfaceKeyboard;

    _asrLanguage = @"zh-CN";
    _asrBaseURL = kDefaultAsrBaseURL;
    _asrApiKey = @"";
    _asrModel = kDefaultAsrModel;
    _useAppleASR = YES;

    _llmBaseURL = kDefaultLlmBaseURL;
    _llmApiKey = @"";
    _llmModel = kDefaultLlmModel;
    _personalWords = @"";
    _smartDictationCleanup = YES;

    _customPromptDictate = kDefaultPromptDictate;
    _customPromptEdit = kDefaultPromptEdit;
    _customPromptTranslate = kDefaultPromptTranslate;
    _customPromptHelpWrite = kDefaultPromptHelpWrite;

    _lastRawTranscript = @"";
    _lastProcessedResult = @"";
    _recentHistory = @[];
    _lastUpdatedAt = 0;
}

#pragma mark - Dynamic AppGroup Discovery

- (NSArray<NSString *> *)mobileProvisionAppGroups {
    NSMutableArray<NSString *> *found = [NSMutableArray array];
    @try {
        NSBundle *mainBundle = [NSBundle mainBundle];
        NSString *bundlePath = mainBundle.bundlePath ?: @"";
        NSMutableArray<NSString *> *provPaths = [NSMutableArray array];
        [provPaths addObject:[bundlePath stringByAppendingPathComponent:@"embedded.mobileprovision"]];
        if ([bundlePath hasSuffix:@".appex"]) {
            NSString *hostPath = [[bundlePath stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
            [provPaths addObject:[hostPath stringByAppendingPathComponent:@"embedded.mobileprovision"]];
        }

        for (NSString *path in provPaths) {
            NSData *data = [NSData dataWithContentsOfFile:path];
            if (data.length == 0) continue;
            NSString *ascii = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
            if (!ascii) continue;
            NSRange startRange = [ascii rangeOfString:@"<plist"];
            NSRange endRange = [ascii rangeOfString:@"</plist>"];
            if (startRange.location != NSNotFound && endRange.location != NSNotFound && endRange.location > startRange.location) {
                NSRange xmlRange = NSMakeRange(startRange.location, NSMaxRange(endRange) - startRange.location);
                NSString *xml = [ascii substringWithRange:xmlRange];
                NSData *xmlData = [xml dataUsingEncoding:NSUTF8StringEncoding];
                if (xmlData) {
                    id plist = [NSPropertyListSerialization propertyListWithData:xmlData options:NSPropertyListImmutable format:nil error:nil];
                    if ([plist isKindOfClass:[NSDictionary class]]) {
                        NSDictionary *entitlements = plist[@"Entitlements"];
                        id groups = [entitlements isKindOfClass:[NSDictionary class]] ? entitlements[@"com.apple.security.application-groups"] : nil;
                        if ([groups isKindOfClass:[NSArray class]]) {
                            for (id g in (NSArray *)groups) {
                                if ([g isKindOfClass:[NSString class]] && [(NSString *)g length] > 0 && ![found containsObject:g]) {
                                    [found addObject:g];
                                }
                            }
                        }
                    }
                }
            }
        }
    } @catch (NSException *e) {}
    return found;
}

- (NSArray<NSString *> *)candidateAppGroupIdentifiers {
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    void (^addCand)(NSString *) = ^(NSString *cid) {
        if ([cid isKindOfClass:[NSString class]] && cid.length > 0 && ![candidates containsObject:cid]) {
            [candidates addObject:cid];
        }
    };

    for (NSString *g in [self mobileProvisionAppGroups]) {
        addCand(g);
    }

    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    if (bid.length > 0) {
        NSString *baseBid = bid;
        if ([[[NSBundle mainBundle] bundlePath] hasSuffix:@".appex"]) {
            NSRange lastDot = [bid rangeOfString:@"." options:NSBackwardsSearch];
            if (lastDot.location != NSNotFound && lastDot.location > 0) {
                baseBid = [bid substringToIndex:lastDot.location];
            }
        }
        addCand([@"group." stringByAppendingString:baseBid]);
        addCand([@"group." stringByAppendingString:bid]);
        addCand([@"group." stringByAppendingString:[baseBid stringByAppendingString:@".shared"]]);
    }

    addCand(kAppGroupPrimary);
    addCand(kAppGroupSecondary);
    return candidates;
}

- (void)probeAppGroupIfNeeded {
    if (self.didProbeAppGroups) return;
    self.didProbeAppGroups = YES;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *homePath = NSHomeDirectory();
    for (NSString *gid in [self candidateAppGroupIdentifiers]) {
        @try {
            NSURL *url = [fm containerURLForSecurityApplicationGroupIdentifier:gid];
            if (url.path.length > 0) {
                // Reject LintypeGboard's safe_containerURL local sandbox fallback (/Application Support/AppGroup_*)
                if ([url.path containsString:@"/AppGroup_"] || (homePath.length > 0 && [url.path hasPrefix:homePath])) {
                    continue;
                }
                BOOL isDir = NO;
                if ([fm fileExistsAtPath:url.path isDirectory:&isDir] && isDir) {
                    self.cachedDetectedGroupID = gid;
                    self.cachedGroupPath = url.path;
                    break;
                }
            }
        } @catch (NSException *e) {}
    }
}

- (nullable NSString *)detectedAppGroupIdentifier {
    [self probeAppGroupIfNeeded];
    return self.cachedDetectedGroupID;
}

- (nullable NSString *)sharedAppGroupPath {
    [self probeAppGroupIfNeeded];
    return self.cachedGroupPath;
}

- (BOOL)hasSharedAppGroup {
    return self.sharedAppGroupPath.length > 0;
}

- (NSString *)sharedConfigDirectory {
    NSString *groupPath = [self sharedAppGroupPath];
    NSString *baseDir = nil;
    if (groupPath.length > 0) {
        baseDir = [groupPath stringByAppendingPathComponent:@"Library/Application Support/Lintype"];
    } else {
        NSString *appSupport = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
        if (!appSupport) appSupport = NSTemporaryDirectory();
        baseDir = [appSupport stringByAppendingPathComponent:@"Lintype"];
    }
    [[NSFileManager defaultManager] createDirectoryAtPath:baseDir withIntermediateDirectories:YES attributes:nil error:nil];
    return baseDir;
}

- (NSString *)configFilePath {
    return [[self sharedConfigDirectory] stringByAppendingPathComponent:kConfigFileName];
}

- (NSString *)legacyConfigFilePath {
    return [[self sharedConfigDirectory] stringByAppendingPathComponent:kLegacyConfigFileName];
}

#pragma mark - Serialization & Multi-Store Sync

- (NSString *)normalizedURL:(NSString *)url fallback:(NSString *)fallback {
    NSString *clean = [url stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([clean hasSuffix:@"/"]) {
        clean = [clean substringToIndex:clean.length - 1];
    }
    return clean.length > 0 ? clean : fallback;
}

- (NSDictionary<NSString *, id> *)exportConfigDictionary {
    return @{
        @"version": @(3),
        @"updatedAt": @(self.lastUpdatedAt > 0 ? self.lastUpdatedAt : [[NSDate date] timeIntervalSince1970]),
        @"voiceMode": @(self.voiceMode),
        @"targetLanguage": self.targetLanguage ?: @"英语",
        @"polishStyle": @(self.polishStyle),
        @"pipKeepAliveEnabled": @(self.pipKeepAliveEnabled),
        @"launchInterface": @(self.launchInterface),
        @"asrLanguage": self.asrLanguage.length > 0 ? self.asrLanguage : @"zh-CN",
        @"asrBaseURL": [self normalizedURL:self.asrBaseURL fallback:kDefaultAsrBaseURL],
        @"asrApiKey": self.asrApiKey ?: @"",
        @"asrModel": self.asrModel.length > 0 ? self.asrModel : kDefaultAsrModel,
        @"useAppleASR": @(self.useAppleASR),
        @"llmBaseURL": [self normalizedURL:self.llmBaseURL fallback:kDefaultLlmBaseURL],
        @"llmApiKey": self.llmApiKey ?: @"",
        @"llmModel": self.llmModel.length > 0 ? self.llmModel : kDefaultLlmModel,
        @"personalWords": self.personalWords ?: @"",
        @"smartDictationCleanup": @(self.smartDictationCleanup),
        @"customPromptDictate": self.customPromptDictate ?: kDefaultPromptDictate,
        @"customPromptEdit": self.customPromptEdit ?: kDefaultPromptEdit,
        @"customPromptTranslate": self.customPromptTranslate ?: kDefaultPromptTranslate,
        @"customPromptHelpWrite": self.customPromptHelpWrite ?: kDefaultPromptHelpWrite
    };
}

- (BOOL)applyConfigDictionary:(NSDictionary<NSString *, id> *)dict persist:(BOOL)persist {
    if (![dict isKindOfClass:[NSDictionary class]] || dict.count == 0) return NO;

    NSTimeInterval ts = [dict[@"updatedAt"] doubleValue];
    if (ts > 0 && self.lastUpdatedAt > 0 && ts < self.lastUpdatedAt) {
        return NO;
    }
    if (ts > 0) self.lastUpdatedAt = ts;

    if (dict[@"voiceMode"]) self.voiceMode = (TypelessVoiceMode)[dict[@"voiceMode"] integerValue];
    if ([dict[@"targetLanguage"] isKindOfClass:[NSString class]] && [dict[@"targetLanguage"] length] > 0) {
        self.targetLanguage = dict[@"targetLanguage"];
    }
    if (dict[@"polishStyle"]) self.polishStyle = (TypelessPolishStyle)[dict[@"polishStyle"] integerValue];
    NSInteger cfgVersion = [dict[@"version"] integerValue];
    if (cfgVersion >= 3 && dict[@"pipKeepAliveEnabled"]) {
        self.pipKeepAliveEnabled = [dict[@"pipKeepAliveEnabled"] boolValue];
    } else if (cfgVersion < 3) {
        // v1.0.9+ defaults to pure audio keep-alive (PiP optional, default OFF)
        self.pipKeepAliveEnabled = NO;
    }
    if (dict[@"launchInterface"]) self.launchInterface = (TypelessLaunchInterface)[dict[@"launchInterface"] integerValue];

    // Migration support from v1.0.7 shared keys (`baseURL` / `apiKey`)
    NSString *legacyURL = [dict[@"baseURL"] isKindOfClass:[NSString class]] ? dict[@"baseURL"] : nil;
    NSString *legacyKey = [dict[@"apiKey"] isKindOfClass:[NSString class]] ? dict[@"apiKey"] : nil;

    NSString *asrURL = [dict[@"asrBaseURL"] isKindOfClass:[NSString class]] ? dict[@"asrBaseURL"] : legacyURL;
    NSString *asrKey = [dict[@"asrApiKey"] isKindOfClass:[NSString class]] ? dict[@"asrApiKey"] : legacyKey;
    NSString *llmURL = [dict[@"llmBaseURL"] isKindOfClass:[NSString class]] ? dict[@"llmBaseURL"] : legacyURL;
    NSString *llmKey = [dict[@"llmApiKey"] isKindOfClass:[NSString class]] ? dict[@"llmApiKey"] : legacyKey;

    if (asrURL.length > 0) self.asrBaseURL = [self normalizedURL:asrURL fallback:kDefaultAsrBaseURL];
    if (asrKey != nil) self.asrApiKey = [asrKey stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([dict[@"asrModel"] isKindOfClass:[NSString class]] && [dict[@"asrModel"] length] > 0) {
        self.asrModel = dict[@"asrModel"];
    }
    if (dict[@"useAppleASR"]) self.useAppleASR = [dict[@"useAppleASR"] boolValue];

    if (llmURL.length > 0) self.llmBaseURL = [self normalizedURL:llmURL fallback:kDefaultLlmBaseURL];
    if (llmKey != nil) self.llmApiKey = [llmKey stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([dict[@"llmModel"] isKindOfClass:[NSString class]] && [dict[@"llmModel"] length] > 0) {
        self.llmModel = dict[@"llmModel"];
    }
    if ([dict[@"asrLanguage"] isKindOfClass:[NSString class]] && [dict[@"asrLanguage"] length] > 0) {
        self.asrLanguage = dict[@"asrLanguage"];
    }
    if ([dict[@"personalWords"] isKindOfClass:[NSString class]]) {
        self.personalWords = dict[@"personalWords"];
    }
    if (dict[@"smartDictationCleanup"]) self.smartDictationCleanup = [dict[@"smartDictationCleanup"] boolValue];

    if ([dict[@"customPromptDictate"] isKindOfClass:[NSString class]] && [dict[@"customPromptDictate"] length] > 0) {
        self.customPromptDictate = dict[@"customPromptDictate"];
    }
    if ([dict[@"customPromptEdit"] isKindOfClass:[NSString class]] && [dict[@"customPromptEdit"] length] > 0) {
        self.customPromptEdit = dict[@"customPromptEdit"];
    }
    if ([dict[@"customPromptTranslate"] isKindOfClass:[NSString class]] && [dict[@"customPromptTranslate"] length] > 0) {
        self.customPromptTranslate = dict[@"customPromptTranslate"];
    }
    if ([dict[@"customPromptHelpWrite"] isKindOfClass:[NSString class]] && [dict[@"customPromptHelpWrite"] length] > 0) {
        self.customPromptHelpWrite = dict[@"customPromptHelpWrite"];
    }

    if (persist) {
        [self persistLocalMirrorOnly];
    }
    return YES;
}

- (nullable NSDictionary *)readKeychainConfig {
    @try {
        NSDictionary *query = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService: kKeychainService,
            (__bridge id)kSecAttrAccount: kKeychainAccount,
            (__bridge id)kSecReturnData: @YES,
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
        };
        CFTypeRef result = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
        if (status == errSecSuccess && result != NULL) {
            NSData *data = (__bridge_transfer NSData *)result;
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([obj isKindOfClass:[NSDictionary class]]) {
                return obj;
            }
        }
    } @catch (NSException *e) {}
    return nil;
}

- (void)writeKeychainConfig:(NSDictionary *)dict {
    @try {
        NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
        if (data.length == 0) return;

        NSDictionary *baseQuery = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService: kKeychainService,
            (__bridge id)kSecAttrAccount: kKeychainAccount
        };
        SecItemDelete((__bridge CFDictionaryRef)baseQuery);

        NSMutableDictionary *addQuery = [baseQuery mutableCopy];
        addQuery[(__bridge id)kSecValueData] = data;
        addQuery[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
        SecItemAdd((__bridge CFDictionaryRef)addQuery, NULL);
    } @catch (NSException *e) {}
}

- (nullable NSDictionary *)readDictFromFile:(NSString *)path {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length == 0) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

- (void)load {
    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    void (^collect)(NSDictionary *) = ^(NSDictionary *d) {
        if ([d isKindOfClass:[NSDictionary class]] && d.count > 0) {
            [candidates addObject:d];
        }
    };

    collect([self readDictFromFile:[self configFilePath]]);
    collect([self readDictFromFile:[self legacyConfigFilePath]]);

    NSString *gid = [self detectedAppGroupIdentifier];
    if (gid.length > 0) {
        NSUserDefaults *suiteDefs = [[NSUserDefaults alloc] initWithSuiteName:gid];
        id obj = [suiteDefs objectForKey:kConfigDictKey];
        if (![obj isKindOfClass:[NSDictionary class]]) {
            obj = [suiteDefs objectForKey:@"TypelessConfigDict"];
        }
        collect(obj);
    }

    collect([self readKeychainConfig]);

    NSUserDefaults *std = [NSUserDefaults standardUserDefaults];
    id stdObj = [std objectForKey:kConfigDictKey];
    if (![stdObj isKindOfClass:[NSDictionary class]]) {
        stdObj = [std objectForKey:@"TypelessConfigDict"];
    }
    collect(stdObj);

    NSDictionary *best = nil;
    NSTimeInterval bestTS = -1.0;
    for (NSDictionary *d in candidates) {
        NSTimeInterval ts = [d[@"updatedAt"] doubleValue];
        BOOL hasV2 = (d[@"version"] != nil);
        // Prefer v2 dicts or newest timestamp cleanly
        NSTimeInterval score = ts > 0 ? ts : (hasV2 ? 1.0 : 0.0);
        if (score >= bestTS) {
            bestTS = score;
            best = d;
        }
    }

    if (best) {
        // Allow loading even if bestTS is equal
        self.lastUpdatedAt = 0;
        [self applyConfigDictionary:best persist:NO];
    }

    NSArray *savedHistory = [std objectForKey:@"LintypeRecentHistoryV2"];
    if ([savedHistory isKindOfClass:[NSArray class]]) {
        self.recentHistory = savedHistory;
    }
}

- (void)persistLocalMirrorOnly {
    NSDictionary *dict = [self exportConfigDictionary];
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:nil];
    if (jsonData.length > 0) {
        [jsonData writeToFile:[self configFilePath] atomically:YES];
    }
    NSUserDefaults *std = [NSUserDefaults standardUserDefaults];
    [std setObject:dict forKey:kConfigDictKey];
    [std synchronize];
}

- (void)save {
    self.lastUpdatedAt = [[NSDate date] timeIntervalSince1970];
    self.asrBaseURL = [self normalizedURL:self.asrBaseURL fallback:kDefaultAsrBaseURL];
    self.llmBaseURL = [self normalizedURL:self.llmBaseURL fallback:kDefaultLlmBaseURL];
    if (self.asrModel.length == 0) self.asrModel = kDefaultAsrModel;
    if (self.llmModel.length == 0) self.llmModel = kDefaultLlmModel;

    NSDictionary *dict = [self exportConfigDictionary];

    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:nil];
    if (jsonData.length > 0) {
        [jsonData writeToFile:[self configFilePath] atomically:YES];
    }

    NSString *gid = [self detectedAppGroupIdentifier];
    if (gid.length > 0) {
        NSUserDefaults *suiteDefs = [[NSUserDefaults alloc] initWithSuiteName:gid];
        [suiteDefs setObject:dict forKey:kConfigDictKey];
        [suiteDefs synchronize];
    }

    [self writeKeychainConfig:dict];

    NSUserDefaults *std = [NSUserDefaults standardUserDefaults];
    [std setObject:dict forKey:kConfigDictKey];
    [std synchronize];

    CFNotificationCenterRef darwinCenter = CFNotificationCenterGetDarwinNotifyCenter();
    if (darwinCenter) {
        CFNotificationCenterPostNotification(darwinCenter, kConfigDidChangeDarwinName, NULL, NULL, true);
    }
}

- (void)resetToDefaults {
    [self applyDefaultValues];
    [self save];
}

#pragma mark - Helpers & History

- (NSString *)baseURL {
    return self.llmBaseURL.length > 0 ? self.llmBaseURL : self.asrBaseURL;
}

- (void)setBaseURL:(NSString *)baseURL {
    self.asrBaseURL = baseURL;
    self.llmBaseURL = baseURL;
}

- (NSString *)apiKey {
    return self.llmApiKey.length > 0 ? self.llmApiKey : self.asrApiKey;
}

- (void)setApiKey:(NSString *)apiKey {
    self.asrApiKey = apiKey;
    self.llmApiKey = apiKey;
}

- (NSString *)promptForMode:(TypelessVoiceMode)mode {
    switch (mode) {
        case TypelessVoiceModeDictate:
            return self.customPromptDictate.length > 0 ? self.customPromptDictate : kDefaultPromptDictate;
        case TypelessVoiceModeEdit:
            return self.customPromptEdit.length > 0 ? self.customPromptEdit : kDefaultPromptEdit;
        case TypelessVoiceModeTranslate:
            return self.customPromptTranslate.length > 0 ? self.customPromptTranslate : kDefaultPromptTranslate;
        case TypelessVoiceModeHelpWrite:
            return self.customPromptHelpWrite.length > 0 ? self.customPromptHelpWrite : kDefaultPromptHelpWrite;
    }
    return kDefaultPromptDictate;
}

- (NSArray<NSString *> *)parsedPersonalWordList {
    if (self.personalWords.length == 0) return @[];
    NSCharacterSet *sep = [NSCharacterSet characterSetWithCharactersInString:@",，;；\n\r、"];
    NSArray<NSString *> *parts = [self.personalWords componentsSeparatedByCharactersInSet:sep];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *raw in parts) {
        NSString *t = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length == 0 || [seen containsObject:t]) continue;
        [seen addObject:t];
        [out addObject:t];
        if (out.count >= 60) break;
    }
    return out;
}

- (NSString *)whisperHotwordPrompt {
    NSArray<NSString *> *words = [self parsedPersonalWordList];
    if (words.count == 0) return @"";
    NSUInteger count = MIN((NSUInteger)40, words.count);
    return [[words subarrayWithRange:NSMakeRange(0, count)] componentsJoinedByString:@", "];
}

- (nullable NSString *)effectiveWhisperLanguageCode {
    NSString *lang = [self.asrLanguage stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (lang.length == 0 || [lang caseInsensitiveCompare:@"auto"] == NSOrderedSame) {
        return nil;
    }
    if ([lang hasPrefix:@"zh"]) return @"zh";
    if ([lang hasPrefix:@"en"]) return @"en";
    if ([lang hasPrefix:@"ja"]) return @"ja";
    if ([lang hasPrefix:@"ko"]) return @"ko";
    return lang;
}

- (NSLocale *)resolvedAppleSpeechLocale {
    NSString *lang = [self.asrLanguage stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (lang.length > 0 && [lang caseInsensitiveCompare:@"auto"] != NSOrderedSame) {
        return [NSLocale localeWithLocaleIdentifier:lang];
    }
    NSString *preferred = [NSLocale preferredLanguages].firstObject;
    if (preferred.length > 0) {
        return [NSLocale localeWithLocaleIdentifier:preferred];
    }
    return [NSLocale localeWithLocaleIdentifier:@"zh-CN"];
}

- (NSString *)effectivePromptForMode:(TypelessVoiceMode)mode {
    NSString *base = [self promptForMode:mode];
    if (mode == TypelessVoiceModeDictate || mode == TypelessVoiceModeEdit || mode == TypelessVoiceModeHelpWrite) {
        switch (self.polishStyle) {
            case TypelessPolishStyleConcise:
                base = [base stringByAppendingString:@"\n补充风格要求：请尽量精简压缩冗长表达，直奔主题，去除一切多余寒暄和重复修饰，使文本简短干练。"];
                break;
            case TypelessPolishStyleFormal:
                base = [base stringByAppendingString:@"\n补充风格要求：请使用得体、礼貌、专业、偏正式的书面语措辞与完整标点，适合工作汇报、邮件或商务沟通。"];
                break;
            case TypelessPolishStyleLight:
                base = [base stringByAppendingString:@"\n补充风格要求：请最大程度保留说话人的原始用词与句式，仅修正明显的错别字、语气词卡顿与标点符号。"];
                break;
            case TypelessPolishStyleSmart:
            default:
                break;
        }
    }
    NSArray<NSString *> *words = [self parsedPersonalWordList];
    if (words.count > 0) {
        base = [NSString stringWithFormat:@"%@\n\n【个人词典/热词（若发音或语义相近，请优先采用以下专有写法）】\n%@",
                base, [words componentsJoinedByString:@"、"]];
    }
    return base;
}

- (NSString *)customPrompt {
    return [self promptForMode:self.voiceMode];
}

- (void)setCustomPrompt:(NSString *)customPrompt {
    NSString *val = customPrompt ?: @"";
    switch (self.voiceMode) {
        case TypelessVoiceModeDictate: self.customPromptDictate = val; break;
        case TypelessVoiceModeEdit: self.customPromptEdit = val; break;
        case TypelessVoiceModeTranslate: self.customPromptTranslate = val; break;
        case TypelessVoiceModeHelpWrite: self.customPromptHelpWrite = val; break;
    }
}

- (BOOL)isAIPolish {
    return self.smartDictationCleanup;
}

- (void)setIsAIPolish:(BOOL)isAIPolish {
    self.smartDictationCleanup = isAIPolish;
}

- (BOOL)hasValidAsrConfig {
    if (self.useAppleASR) return YES;
    return [self.asrApiKey stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length > 0 &&
           self.asrBaseURL.length > 0;
}

- (BOOL)hasValidLlmConfig {
    return [self.llmApiKey stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length > 0 &&
           self.llmBaseURL.length > 0;
}

- (BOOL)hasValidApiKey {
    return [self hasValidLlmConfig] || [self.asrApiKey stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length > 0;
}

- (BOOL)shouldUseWhisperAPI {
    if (self.useAppleASR) return NO;
    return [self.asrApiKey stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length > 0;
}

- (void)recordHistoryResult:(NSString *)result rawText:(nullable NSString *)rawText {
    if (result.length == 0) return;
    if (rawText) self.lastRawTranscript = rawText;
    self.lastProcessedResult = result;

    NSMutableArray<NSString *> *updated = [NSMutableArray array];
    [updated addObject:result];
    for (NSString *existing in self.recentHistory) {
        if ([existing isKindOfClass:[NSString class]] && existing.length > 0 && ![existing isEqualToString:result]) {
            [updated addObject:existing];
        }
        if (updated.count >= 5) break;
    }
    self.recentHistory = updated;
    NSUserDefaults *std = [NSUserDefaults standardUserDefaults];
    [std setObject:updated forKey:@"LintypeRecentHistoryV2"];
    [std synchronize];
}

@end
