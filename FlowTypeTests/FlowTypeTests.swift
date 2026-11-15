import Foundation
import XCTest

final class FlowTypeTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowTypeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testPinyinSyllableSegmentation() {
        let nihao = PinyinSyllableParser.segment(rawInput: "nihao")
        XCTAssertEqual(nihao.primarySyllables.map(\.text), ["ni", "hao"])
        XCTAssertEqual(nihao.displayPinyin, "ni'hao")

        let xianApostrophe = PinyinSyllableParser.segment(rawInput: "xi'an")
        XCTAssertEqual(xianApostrophe.primarySyllables.map(\.text), ["xi", "an"])

        let xianJoined = PinyinSyllableParser.segment(rawInput: "xian")
        XCTAssertEqual(xianJoined.primarySyllables.map(\.text), ["xian"])

        let partial = PinyinSyllableParser.segment(rawInput: "nih")
        XCTAssertEqual(partial.primarySyllables.map(\.text), ["ni", "h"])
        XCTAssertTrue(partial.primarySyllables.last?.isPartial == true)
    }

    func testLexiconDatabaseQueriesAndViterbiSentence() throws {
        XCTAssertNotNil(
            Bundle(for: LexiconDatabase.self).url(forResource: "lexicon", withExtension: "sqlite"),
            "lexicon.sqlite should be bundled into FlowTypeTests resources"
        )
        let userDBURL = tempDir.appendingPathComponent("user_test.sqlite")
        let db = LexiconDatabase(userDBURL: userDBURL)

        let (_, nihaoCands) = db.queryPinyinCandidates(rawInput: "nihao")
        XCTAssertEqual(nihaoCands.first?.text, "你好")

        let (_, srfCands) = db.queryPinyinCandidates(rawInput: "shurufa")
        XCTAssertTrue(srfCands.contains(where: { $0.text == "输入法" }))

        let (_, sentenceCands) = db.queryPinyinCandidates(rawInput: "woxiangchifan")
        XCTAssertTrue(sentenceCands.contains(where: { $0.text == "我想吃饭" }))

        let (_, longSentenceCands) = db.queryPinyinCandidates(rawInput: "womenyiqiquchifan")
        XCTAssertEqual(longSentenceCands.first?.text, "我们一起去吃饭")

        let (_, initialCands) = db.queryPinyinCandidates(rawInput: "nh")
        XCTAssertTrue(initialCands.contains(where: { $0.text == "你好" }))

        let customWord = PersonalWord(term: "李星河", pinyinHint: "lixinghe", category: .name)
        let (_, personalCands) = db.queryPinyinCandidates(rawInput: "lixinghe", personalWords: [customWord])
        XCTAssertEqual(personalCands.first?.text, "李星河")
        XCTAssertEqual(personalCands.first?.source, .personalDictionary)

        let enCompletions = db.queryEnglishCompletions(prefix: "hel")
        XCTAssertTrue(enCompletions.contains(where: { $0.hasPrefix("hel") }))
    }

    func testSharedStoreDictionaryAndHistory() {
        let store = SharedStore(containerURL: tempDir)

        let w1 = store.addOrLearnWord(term: "FlowType", pinyinHint: "", category: .brand, autoLearned: false)
        let w2 = store.addOrLearnWord(term: "张小龙", pinyinHint: "zhangxiaolong", category: .name, autoLearned: true)
        XCTAssertNotNil(w1)
        XCTAssertNotNil(w2)
        XCTAssertEqual(store.loadDictionary().count, 2)

        if let id1 = w1?.id {
            store.deleteDictionaryWords(ids: [id1])
        }
        XCTAssertEqual(store.loadDictionary().map(\.term), ["张小龙"])

        store.appendHistory(HistoryRecord(mode: .dictate, rawTranscript: "嗯那个测试", finalOutput: "测试", durationSeconds: 2.0))
        XCTAssertEqual(store.loadHistory().count, 1)
        XCTAssertEqual(store.dailyCharacterCounts(days: 7).last?.count, 2)
    }

    func testAudioWAVEncoderHeader() {
        let wav = AudioWAVEncoder.encodePCM16Mono(samples: [0, 1000, -1000, 500], sampleRate: 16000)
        XCTAssertEqual(wav.count, 44 + 8)
        XCTAssertEqual(String(data: wav.subdata(in: 0..<4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav.subdata(in: 8..<12), encoding: .ascii), "WAVE")
    }

    func testPromptComposerIncludesPersonalDictionary() {
        let cfg = AIConfiguration()
        let words = [PersonalWord(term: "Soundcore", category: .brand)]
        let sysPrompt = PromptComposer.systemPrompt(
            mode: .translate,
            config: cfg,
            personalWords: words,
            targetLanguage: "日本語"
        )
        XCTAssertTrue(sysPrompt.contains("日本語"))
        XCTAssertTrue(sysPrompt.contains("Soundcore"))
    }

    func testProvisioningAppGroupExtraction() throws {
        let mockXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Name</key><string>MockProfile</string>
            <key>TeamIdentifier</key>
            <array><string>TEAM123456</string></array>
            <key>Entitlements</key>
            <dict>
                <key>application-identifier</key>
                <string>TEAM123456.com.demo.flowtype</string>
                <key>com.apple.security.application-groups</key>
                <array>
                    <string>group.com.example.two</string>
                    <string>group.com.example.one</string>
                </array>
                <key>keychain-access-groups</key>
                <array>
                    <string>TEAM123456.*</string>
                </array>
            </dict>
        </dict>
        </plist>
        """
        var blob = Data([0x30, 0x82, 0x01, 0x00, 0x06, 0x09]) // simulated CMS ASN.1 header bytes
        blob.append(Data(mockXML.utf8))
        blob.append(Data([0x31, 0x00, 0xAB, 0xCD]))

        let provURL = tempDir.appendingPathComponent("embedded.mobileprovision")
        try blob.write(to: provURL)

        let extracted = AppConfig.extractProvisionAppGroups(from: provURL)
        XCTAssertEqual(extracted, ["group.com.example.two", "group.com.example.one"])

        let info = AppConfig.extractProvisioningInfo(from: blob)
        XCTAssertEqual(info?.teamID, "TEAM123456")
        XCTAssertEqual(info?.keychainAccessGroups, ["TEAM123456.*"])

        let candidates = AppConfig.candidateAppGroupIDs(
            infoPlistGroupID: "group.com.flowtype.voice",
            hostBundleID: "com.demo.flowtype",
            provisioning: info ?? ProvisioningInfo()
        )
        XCTAssertEqual(Array(candidates.prefix(3)), ["group.com.flowtype.voice", "group.com.example.one", "group.com.example.two"])
        XCTAssertTrue(candidates.contains("group.com.demo.flowtype"))
    }

    func testT9PinyinDecodingAndCandidates() {
        let db = LexiconDatabase(bundleDBURL: Bundle(for: LexiconDatabase.self).url(forResource: "lexicon", withExtension: "sqlite"))

        // 1. T9 mapping
        XCTAssertEqual(LexiconDatabase.pinyinToT9Digits("nihao"), "64426")
        XCTAssertEqual(LexiconDatabase.pinyinToT9Digits("women"), "96636")

        // 2. Syllables for single and multi-syllable T9 digits
        let sylls64 = LexiconDatabase.syllablesForT9Digits("64")
        XCTAssertTrue(sylls64.contains("ni"))
        XCTAssertTrue(sylls64.contains("mi"))

        let (sylls64426, cands64426) = db.queryT9Candidates(digits: "64426")
        XCTAssertTrue(sylls64426.contains("ni"))
        XCTAssertEqual(cands64426.first?.text, "你好")

        // 3. Exact chars rank above initials & filtered syllable locks remaining digits
        let (rankedSylls64, cands64) = db.queryT9Candidates(digits: "64")
        XCTAssertEqual(rankedSylls64.first, "ni")
        XCTAssertEqual(cands64.first?.text, "你")
        XCTAssertTrue(cands64.contains(where: { $0.text == "米" }))
        XCTAssertTrue(cands64.contains(where: { $0.text == "你好" }))

        let (nextSyllsAfterNi, candsNiFilter) = db.queryT9Candidates(digits: "64426", pinyinFilter: "ni")
        XCTAssertTrue(candsNiFilter.contains(where: { $0.text == "你好" }))
        XCTAssertFalse(candsNiFilter.contains(where: { $0.text == "密告" }))
        XCTAssertTrue(nextSyllsAfterNi.contains("hao"))

        // 4. Filtered by exact syllable
        let (_, candsFiltered) = db.queryT9Candidates(digits: "64", pinyinFilter: "ni")
        XCTAssertTrue(candsFiltered.contains(where: { $0.text == "你" }))

        // 5. Uncached multi-syllable T9 falls back to Viterbi / prefix without returning empty
        let (_, cands96426) = db.queryT9Candidates(digits: "96426")
        XCTAssertFalse(cands96426.isEmpty)
        XCTAssertTrue(cands96426.contains(where: { $0.text.hasPrefix("我") }))

        // 6. Fast phase (no sentence lattice) already yields exact matches instantly
        let (_, fast64426) = db.queryT9Candidates(digits: "64426", includeSentenceDecoding: false)
        XCTAssertEqual(fast64426.first?.text, "你好")
        let (_, fast64) = db.queryT9Candidates(digits: "64", includeSentenceDecoding: false)
        XCTAssertEqual(fast64.first?.text, "你")

        // Repeated sequential T9 queries reuse cached SQLite statements accurately without stale bindings (e.g. "96" -> "wo")
        let (_, cands96) = db.queryT9Candidates(digits: "96")
        XCTAssertEqual(cands96.first?.text, "我")
        XCTAssertEqual(cands96.first?.displayPinyin, "wo")
        XCTAssertTrue(cands96.allSatisfy { $0.displayPinyin.rangeOfCharacter(from: .decimalDigits) == nil })

        // Verify Sendable & compact JSON round-trip across Task.detached
        let status = HostRuntimeStatus(state: .standbyPiP, mode: .dictate, isPiPActive: true, heartbeatAt: Date())
        let cfg = AIConfiguration(asrLanguage: "yue", backgroundOpacity: 0.85)
        let exp = expectation(description: "sendable-detached")
        Task.detached {
            let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("flowtype-test-\(UUID().uuidString)", isDirectory: true)
            let store = SharedStore(containerURL: tmpDir)
            store.saveConfig(cfg)
            store.saveStatus(status)
            let loadedCfg = store.loadConfig()
            let loadedStatus = store.loadStatus()
            try? FileManager.default.removeItem(at: tmpDir)
            DispatchQueue.main.async {
                XCTAssertEqual(loadedCfg.asrLanguage, "yue")
                XCTAssertEqual(loadedCfg.backgroundOpacity, 0.85, accuracy: 0.001)
                XCTAssertEqual(loadedStatus.state, .standbyPiP)
                XCTAssertTrue(loadedStatus.isPiPActive)
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 3.0)
        let (_, cands96636) = db.queryT9Candidates(digits: "96636")
        XCTAssertEqual(cands96636.first?.text, "我们")

        // 7. Cancelled long input returns promptly without crashing
        let (_, cancelled) = db.queryT9Candidates(digits: "9694264244326", isCancelled: { true })
        XCTAssertLessThanOrEqual(cancelled.count, 40)
    }

    func testT9UserLearningAndFrequencyBoost() throws {
        let userDBURL = tempDir.appendingPathComponent("user_t9_learning.sqlite")
        let db = LexiconDatabase(
            bundleDBURL: Bundle(for: LexiconDatabase.self).url(forResource: "lexicon", withExtension: "sqlite"),
            userDBURL: userDBURL
        )

        // Baseline: 64 queries "你" as #1
        let (_, baselineCands) = db.queryT9Candidates(digits: "64")
        XCTAssertEqual(baselineCands.first?.text, "你")

        // User repeatedly selects "米" for 64
        let exp = expectation(description: "record learning")
        db.recordT9Selection(digits: "64", word: "米", pinyin: "mi")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        // After learning: "米" must be boosted to candidate #1!
        let (_, learnedCands) = db.queryT9Candidates(digits: "64")
        XCTAssertEqual(learnedCands.first?.text, "米")
        XCTAssertEqual(learnedCands.first?.source, .userLearned)
    }

    func testT9CustomPhraseLearningAndAssociations() throws {
        let userDBURL = tempDir.appendingPathComponent("user_custom_phrase.sqlite")
        let db = LexiconDatabase(
            bundleDBURL: Bundle(for: LexiconDatabase.self).url(forResource: "lexicon", withExtension: "sqlite"),
            userDBURL: userDBURL
        )

        // User enters a custom phrase not in standard lexicon: "全能签好用" for T9
        let novelPhrase = "全能签好用"
        let novelT9 = "76663674269664"
        let exp1 = expectation(description: "record novel phrase")
        db.recordT9Selection(digits: novelT9, word: novelPhrase, pinyin: "quannengqianhaoyong")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            exp1.fulfill()
        }
        wait(for: [exp1], timeout: 2.0)

        let (_, novelCands) = db.queryT9Candidates(digits: novelT9)
        XCTAssertEqual(novelCands.first?.text, novelPhrase)
        XCTAssertEqual(novelCands.first?.source, .userLearned)

        // Test next-word association learning: "你好" -> "世界"
        let exp2 = expectation(description: "record association")
        db.recordT9Selection(digits: "74543", word: "世界", pinyin: "shijie", previousWord: "你好")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 2.0)

        let associations = db.fetchUserAssociations(prevWord: "你好")
        XCTAssertTrue(associations.contains("世界"))
    }

    func testBackgroundCropLayoutAndOpacityConfigRoundTrip() throws {
        // 1. Zero opacity & crop fields persist across encode/decode
        let config = AIConfiguration(
            backgroundStyle: .customImage,
            backgroundOpacity: 0.0,
            customBackgroundHex: "#223344",
            customBackgroundScale: 2.5,
            customBackgroundOffsetX: 0.15,
            customBackgroundOffsetY: -0.10,
            customBackgroundRevision: 7
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AIConfiguration.self, from: data)
        XCTAssertEqual(decoded.backgroundStyle, .customImage)
        XCTAssertEqual(decoded.backgroundOpacity, 0.0, accuracy: 0.0001)
        XCTAssertEqual(decoded.customBackgroundScale, 2.5, accuracy: 0.0001)
        XCTAssertEqual(decoded.customBackgroundOffsetX, 0.15, accuracy: 0.0001)
        XCTAssertEqual(decoded.customBackgroundOffsetY, -0.10, accuracy: 0.0001)
        XCTAssertEqual(decoded.customBackgroundRevision, 7)

        // 2. Legacy JSON defaults stay backward-compatible
        let legacyDecoded = try JSONDecoder().decode(AIConfiguration.self, from: Data("{}".utf8))
        XCTAssertEqual(legacyDecoded.backgroundOpacity, 1.0, accuracy: 0.0001)
        XCTAssertEqual(legacyDecoded.customBackgroundScale, 1.0, accuracy: 0.0001)
        XCTAssertEqual(legacyDecoded.customBackgroundOffsetX, 0.0, accuracy: 0.0001)
        XCTAssertEqual(legacyDecoded.customBackgroundOffsetY, 0.0, accuracy: 0.0001)

        // 3. Scale-invariant crop layout maintains proportionality & clamps overflow
        let large = AIConfiguration.computeBackgroundCropLayout(
            imageWidth: 1080,
            imageHeight: 1440,
            containerWidth: 390,
            containerHeight: 302,
            scale: 2.0,
            normalizedOffsetX: 0.12,
            normalizedOffsetY: -0.08
        )
        let smallW = 276.0
        let smallH = 276.0 * (302.0 / 390.0)
        let small = AIConfiguration.computeBackgroundCropLayout(
            imageWidth: 1080,
            imageHeight: 1440,
            containerWidth: smallW,
            containerHeight: smallH,
            scale: 2.0,
            normalizedOffsetX: 0.12,
            normalizedOffsetY: -0.08
        )
        XCTAssertEqual(small.drawWidth / smallW, large.drawWidth / 390.0, accuracy: 0.001)
        XCTAssertEqual(small.offsetX / smallW, large.offsetX / 390.0, accuracy: 0.001)

        let overflow = AIConfiguration.computeBackgroundCropLayout(
            imageWidth: 1000,
            imageHeight: 1000,
            containerWidth: 390,
            containerHeight: 302,
            scale: 1.0,
            normalizedOffsetX: 9.0,
            normalizedOffsetY: -9.0
        )
        XCTAssertLessThanOrEqual(abs(overflow.offsetX), overflow.maxPanX + 0.0001)
        XCTAssertLessThanOrEqual(abs(overflow.offsetY), overflow.maxPanY + 0.0001)

        // 4. SharedStore image round-trip
        let store = SharedStore(containerURL: tempDir)
        let mockJPEG = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02])
        store.saveCustomBackgroundImage(mockJPEG)
        XCTAssertEqual(store.loadCustomBackgroundImageData(), mockJPEG)
        store.removeCustomBackgroundImage()
        XCTAssertNil(store.loadCustomBackgroundImageData())
    }

    func testConcurrentLexiconReadsAndWritesDoNotCrash() throws {
        let userDBURL = tempDir.appendingPathComponent("concurrent_stress.sqlite")
        let db = LexiconDatabase(
            bundleDBURL: Bundle(for: LexiconDatabase.self).url(forResource: "lexicon", withExtension: "sqlite"),
            userDBURL: userDBURL
        )

        let group = DispatchGroup()
        let writeQueue = DispatchQueue(label: "test.stress.write", attributes: .concurrent)
        let readQueue = DispatchQueue(label: "test.stress.read", attributes: .concurrent)

        for i in 0..<80 {
            group.enter()
            writeQueue.async {
                if i.isMultiple(of: 2) {
                    db.recordT9Selection(digits: "64", word: "米", pinyin: "mi", previousWord: "吃")
                } else {
                    db.recordChineseSelection(pinyin: "zhongwen", word: "中文", previousWord: "输入")
                }
                group.leave()
            }

            group.enter()
            readQueue.async {
                _ = db.queryT9Candidates(digits: "64426")
                _ = db.queryPinyinCandidates(rawInput: "nihao", fuzzy: true)
                _ = db.fetchUserAssociations(prevWord: "吃")
                _ = db.fetchUserCharsByT9(t9: "64")
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 10.0), .success)
    }

    func testPinyinAutoCorrectionAndBoostLearning() throws {
        let userDBURL = tempDir.appendingPathComponent("autocorrect_learning.sqlite")
        let db = LexiconDatabase(
            bundleDBURL: Bundle(for: LexiconDatabase.self).url(forResource: "lexicon", withExtension: "sqlite"),
            userDBURL: userDBURL
        )

        // 1. Typo "zhognwen" -> auto-corrected to "zhongwen" ("中文")
        let repairs = PinyinSyllableParser.correctedInputs(for: "zhognwen")
        XCTAssertTrue(repairs.contains(where: { $0.corrected == "zhongwen" }))
        let (_, correctedCands) = db.queryPinyinCandidates(rawInput: "zhognwen", fuzzy: true)
        XCTAssertTrue(correctedCands.contains(where: { $0.text == "中文" }))

        // 2. QWERTY single-character learning & correction boost (weight 3 beats weight 1)
        let exp = expectation(description: "boost learning")
        db.recordChineseSelection(pinyin: "mi", word: "迷", boostWeight: 1)
        db.recordChineseSelection(pinyin: "mi", word: "米", boostWeight: 3)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        let (_, candsMi) = db.queryPinyinCandidates(rawInput: "mi")
        XCTAssertEqual(candsMi.first?.text, "米")
        XCTAssertEqual(candsMi.first?.source, .userLearned)
    }

    func testPiPFreeKeepAliveConfigurationDefaults() throws {
        let defaults = AIConfiguration()
        XCTAssertFalse(defaults.autoKeepAlivePiP)
        XCTAssertTrue(defaults.enableAudioBackgroundKeepAlive)
        XCTAssertTrue(defaults.enablePinyinFuzzy)

        let decodedEmpty = try JSONDecoder().decode(AIConfiguration.self, from: Data("{}".utf8))
        XCTAssertFalse(decodedEmpty.autoKeepAlivePiP)
        XCTAssertTrue(decodedEmpty.enableAudioBackgroundKeepAlive)

        let decodedWithPiP = try JSONDecoder().decode(
            AIConfiguration.self,
            from: Data(#"{"autoKeepAlivePiP":true,"enableAudioBackgroundKeepAlive":false}"#.utf8)
        )
        XCTAssertTrue(decodedWithPiP.autoKeepAlivePiP)
        XCTAssertFalse(decodedWithPiP.enableAudioBackgroundKeepAlive)
    }

    func testT9966RankingEliminatesSyntheticViterbiAndRanksRealWords() throws {
        let userDBURL = tempDir.appendingPathComponent("t9_966_test.sqlite")
        let db = LexiconDatabase(
            bundleDBURL: Bundle(for: LexiconDatabase.self).url(forResource: "lexicon", withExtension: "sqlite"),
            userDBURL: userDBURL
        )

        let (_, cands966) = db.queryT9Candidates(digits: "966", includeSentenceDecoding: true)
        XCTAssertEqual(cands966.first?.text, "我们")
        XCTAssertFalse(cands966.contains(where: { $0.text == "我哦" || $0.text == "我嗯" || $0.text == "握哦" }))
        XCTAssertTrue(cands966.contains(where: { $0.text == "我" }))

        let (_, candsSplit966) = db.queryT9Candidates(digits: "96'6", includeSentenceDecoding: true)
        XCTAssertFalse(candsSplit966.isEmpty)

        let (_, cands94664) = db.queryT9Candidates(digits: "94664", includeSentenceDecoding: true)
        XCTAssertEqual(cands94664.first?.text, "中")
    }

    func testImmediateCrossSessionSelfLearningAndPrefixRetention() throws {
        let userDBURL = tempDir.appendingPathComponent("cross_session_learning.sqlite")
        let bundleURL = Bundle(for: LexiconDatabase.self).url(forResource: "lexicon", withExtension: "sqlite")

        var db1: LexiconDatabase? = LexiconDatabase(bundleDBURL: bundleURL, userDBURL: userDBURL)
        // Immediate synchronous visibility on the very next query (no sleep)
        db1?.recordT9Selection(digits: "64", word: "米", pinyin: "mi")
        XCTAssertEqual(db1?.queryT9Candidates(digits: "64").candidates.first?.text, "米")

        // Prefix digit selection still stores canonical full pinyin digits & initials
        db1?.recordT9Selection(digits: "546", word: "林微音", pinyin: "linweiyin")
        XCTAssertEqual(db1?.fetchUserPhraseFrequency(pinyin: "linweiyin", word: "林微音"), 1)
        db1 = nil

        // Reopen DB (simulates iOS keyboard extension restart)
        let db2 = LexiconDatabase(bundleDBURL: bundleURL, userDBURL: userDBURL)
        db2.recordT9Selection(digits: "546934946", word: "林微音", pinyin: "linweiyin")
        XCTAssertEqual(db2.fetchUserPhraseFrequency(pinyin: "linweiyin", word: "林微音"), 2)

        XCTAssertEqual(db2.queryT9Candidates(digits: "546934946").candidates.first?.text, "林微音")
        XCTAssertEqual(db2.queryT9Candidates(digits: "5469").candidates.first?.text, "林微音")
        XCTAssertTrue(db2.queryT9Candidates(digits: "546").candidates.contains(where: { $0.text == "林微音" }))
        XCTAssertEqual(db2.queryT9Candidates(digits: "599").candidates.first?.text, "林微音")
        XCTAssertEqual(db2.queryPinyinCandidates(rawInput: "lwy").candidates.first?.text, "林微音")
        XCTAssertEqual(db2.queryPinyinCandidates(rawInput: "linwei").candidates.first?.text, "林微音")
    }

    func testOnlineLexiconParsingChunkedSyncAndPriority() throws {
        let userDBURL = tempDir.appendingPathComponent("online_lexicon.sqlite")
        let db = LexiconDatabase(
            bundleDBURL: Bundle(for: LexiconDatabase.self).url(forResource: "lexicon", withExtension: "sqlite"),
            userDBURL: userDBURL
        )

        XCTAssertEqual(
            OnlineLexiconService.normalizeRawURLString("https://github.com/user/repo/blob/main/dict.txt"),
            "https://raw.githubusercontent.com/user/repo/main/dict.txt"
        )

        let rimeSample = """
        ---
        name: custom_test
        version: "1.0"
        ...
        # comment line
        星辰大海\txingchendahai\t800
        ni hao\t你好
        全能签
        FlowTypePro
        """
        let parsedText = OnlineLexiconService.parse(text: rimeSample) { term in
            db.derivePinyin(for: term)
        }
        XCTAssertTrue(parsedText.contains(where: { $0.term == "星辰大海" && $0.pinyin == "xingchendahai" && $0.weight == 800 }))
        XCTAssertTrue(parsedText.contains(where: { $0.term == "全能签" && $0.pinyin == "quannengqian" }))
        XCTAssertTrue(parsedText.contains(where: { $0.term == "FlowTypePro" }))

        let jsonSample = #"[{"word":"光年之外","pinyin":"guangnianzhiwai","weight":500}]"#
        let parsedJSON = OnlineLexiconService.parse(text: jsonSample)
        XCTAssertEqual(parsedJSON.first?.term, "光年之外")

        let store = SharedStore(containerURL: tempDir)
        var bulk = parsedText + parsedJSON
        for idx in 0..<1200 {
            bulk.append(OnlineLexiconEntry(term: "测试词条\(idx)", pinyin: "ceshicitiao", weight: 50))
        }
        let snapshot = OnlineLexiconSnapshot(
            revision: 42,
            updatedAt: Date(),
            sourceURL: "https://example.com/dict.txt",
            entries: bulk
        )
        store.saveOnlineLexiconSnapshot(snapshot)
        XCTAssertGreaterThanOrEqual(store.loadOnlineLexiconRevision(), 42)
        XCTAssertEqual(store.loadOnlineLexiconSnapshot()?.entries.count, bulk.count)

        db.syncOnlineLexiconIfNeeded(store: store)
        XCTAssertGreaterThanOrEqual(db.onlineWordsCount(), 1200)
        XCTAssertEqual(db.queryT9Candidates(digits: "9464243632424").candidates.first?.text, "星辰大海")
        XCTAssertEqual(db.queryPinyinCandidates(rawInput: "xingchendahai").candidates.first?.text, "星辰大海")
        XCTAssertEqual(db.queryPinyinCandidates(rawInput: "xcdh").candidates.first?.text, "星辰大海")
        XCTAssertTrue(db.queryEnglishCompletions(prefix: "Flow").contains("FlowTypePro"))

        store.clearOnlineLexiconSnapshot()
        db.syncOnlineLexiconIfNeeded(store: store)
        XCTAssertEqual(db.onlineWordsCount(), 0)
    }

    func testKeyboardKeyGestureMapT9SwipeUpAndLongPress() {
        for digit in 1...9 {
            XCTAssertEqual(KeyboardKeyGestureMap.t9SwipeUp(digit: "\(digit)"), "\(digit)")
        }
        XCTAssertNil(KeyboardKeyGestureMap.t9SwipeUp(digit: "0"))

        XCTAssertEqual(
            KeyboardKeyGestureMap.t9LongPressOptions(digit: "1"),
            ["1", "，", "。", "？", "！", "、", "：", "；"]
        )
        XCTAssertEqual(
            KeyboardKeyGestureMap.t9LongPressOptions(digit: "2"),
            ["2", "a", "b", "c", "A", "B", "C"]
        )
        XCTAssertEqual(
            KeyboardKeyGestureMap.t9LongPressOptions(digit: "9"),
            ["9", "w", "x", "y", "z", "W", "X", "Y", "Z"]
        )
    }

    func testKeyboardKeyGestureMapQwertySwipeUpAndAccents() {
        XCTAssertEqual(KeyboardKeyGestureMap.qwertySwipeUp(key: "q", isChinese: true), "1")
        XCTAssertEqual(KeyboardKeyGestureMap.qwertySwipeUp(key: "P", isChinese: false), "0")
        XCTAssertEqual(KeyboardKeyGestureMap.qwertySwipeUp(key: "b", isChinese: true), "；")
        XCTAssertEqual(KeyboardKeyGestureMap.qwertySwipeUp(key: "b", isChinese: false), ";")
        XCTAssertEqual(KeyboardKeyGestureMap.qwertySwipeUp(key: "n", isChinese: true), "！")
        XCTAssertEqual(KeyboardKeyGestureMap.qwertySwipeUp(key: "n", isChinese: false), "!")
        XCTAssertEqual(KeyboardKeyGestureMap.qwertySwipeUp(key: "m", isChinese: true), "？")
        XCTAssertEqual(KeyboardKeyGestureMap.qwertySwipeUp(key: "m", isChinese: false), "?")

        XCTAssertEqual(
            KeyboardKeyGestureMap.qwertyLongPressOptions(key: "e", isChinese: true, isShifted: false),
            ["3", "e", "E"]
        )
        let enLower = KeyboardKeyGestureMap.qwertyLongPressOptions(key: "e", isChinese: false, isShifted: false)
        XCTAssertEqual(enLower.first, "e")
        XCTAssertTrue(enLower.contains("é"))
        XCTAssertEqual(enLower.last, "3")

        let enUpperS = KeyboardKeyGestureMap.qwertyLongPressOptions(key: "s", isChinese: false, isShifted: true)
        XCTAssertTrue(enUpperS.contains("SS"))
        XCTAssertTrue(enUpperS.contains("S"))

        XCTAssertEqual(
            KeyboardKeyGestureMap.qwertyLongPressOptions(key: "。", isChinese: true, isShifted: false),
            ["。", "，", "、", "：", "；", "？", "！"]
        )
    }

    func testMinimalPiPDimensionsAndAudioConflictDetection() {
        let w = KeyboardKeyGestureMap.pipOptimalRenderWidth
        let h = KeyboardKeyGestureMap.pipOptimalRenderHeight
        XCTAssertEqual(w, 240)
        XCTAssertEqual(h, 100)
        XCTAssertEqual(Double(w) / Double(h), 2.4, accuracy: 0.01)

        XCTAssertTrue(KeyboardKeyGestureMap.isAudioSessionConflictError(message: "未能完成操作。（OSStatus 错误 560557684。）"))
        XCTAssertTrue(KeyboardKeyGestureMap.isAudioSessionConflictError(message: "AVAudioSessionErrorCode.cannotInterruptOthers"))
        XCTAssertTrue(KeyboardKeyGestureMap.isAudioSessionConflictError(message: "错误 561017449"))
        XCTAssertFalse(KeyboardKeyGestureMap.isAudioSessionConflictError(message: nil))
        XCTAssertFalse(KeyboardKeyGestureMap.isAudioSessionConflictError(message: "网络连接正常"))
    }

    func testAIServiceURLNormalizationAndModelDefaults() {
        XCTAssertEqual(
            AIServiceClient.normalizedBase("stt.example.com/v1/"),
            "https://stt.example.com/v1"
        )
        XCTAssertEqual(
            AIServiceClient.normalizedBase("https://stt.example.com/v1/"),
            "https://stt.example.com/v1"
        )
        XCTAssertEqual(
            AIServiceClient.normalizedBase("127.0.0.1:8080/v1"),
            "http://127.0.0.1:8080/v1"
        )
        XCTAssertEqual(
            AIServiceClient.buildOpenAIURL(base: "stt.example.com/v1", suffix: "audio/transcriptions")?.absoluteString,
            "https://stt.example.com/v1/audio/transcriptions"
        )
        XCTAssertTrue(AIServiceClient.modelPrefersNoPrompt("grok-stt"))
        XCTAssertTrue(AIServiceClient.modelPrefersNoPrompt("SenseVoiceSmall"))
        XCTAssertFalse(AIServiceClient.modelPrefersNoPrompt("whisper-1"))
    }

    func testOpenAITranscriptResponseParserFormatsAndErrors() throws {
        XCTAssertEqual(
            try AIServiceClient.parseOpenAITranscriptResponse(data: Data(#"{"text":" 你好世界 "}"#.utf8)),
            "你好世界"
        )
        XCTAssertEqual(
            try AIServiceClient.parseOpenAITranscriptResponse(data: Data(#"{"transcript":"语音识别成功"}"#.utf8)),
            "语音识别成功"
        )
        XCTAssertEqual(
            try AIServiceClient.parseOpenAITranscriptResponse(data: Data(#"{"data":{"text":"嵌套结果"}}"#.utf8)),
            "嵌套结果"
        )
        XCTAssertEqual(
            try AIServiceClient.parseOpenAITranscriptResponse(data: Data(#"{"choices":[{"message":{"content":"对话格式"}}]}"#.utf8)),
            "对话格式"
        )
        XCTAssertEqual(
            try AIServiceClient.parseOpenAITranscriptResponse(data: Data(#""纯文本JSON""#.utf8)),
            "纯文本JSON"
        )
        XCTAssertThrowsError(
            try AIServiceClient.parseOpenAITranscriptResponse(
                data: Data(#"{"error":{"code":"bad_key","message":"invalid token"}}"#.utf8)
            )
        )
        XCTAssertThrowsError(
            try AIServiceClient.parseOpenAITranscriptResponse(
                data: Data("<!DOCTYPE html><html><body>404</body></html>".utf8)
            )
        )
    }

    func testOpenAIWhisperCompatibilityRetriesAndGrokSTT() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockSTTURLProtocol.self]
        let mockSession = URLSession(configuration: sessionConfig)
        let client = AIServiceClient(session: mockSession)
        let dummyWAV = Data(repeating: 0x5A, count: 128)
        let hotwords = [PersonalWord(term: "FlowType"), PersonalWord(term: "热词测试")]

        defer { MockSTTURLProtocol.setHandler(nil) }

        // Case 1: Custom model sends prompt, server rejects with 400 unsupported_parameter -> auto retry without prompt
        var customBodies: [String] = []
        MockSTTURLProtocol.setHandler { request, body in
            XCTAssertEqual(request.url?.absoluteString, "https://stt.example.com/v1/audio/transcriptions")
            customBodies.append(body)
            if body.contains("name=\"prompt\"") {
                return (400, Data(#"{"error":{"code":"unsupported_parameter","message":"prompt 暂不支持"}}"#.utf8))
            }
            XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nzh"))
            return (200, Data(#"{"text":"自动重试成功"}"#.utf8))
        }
        let cfgCustom = AIConfiguration(
            asrProvider: .openAIWhisperCompatible,
            asrBaseURL: "stt.example.com/v1",
            asrAPIKey: "test_key_123",
            asrModel: "whisper-custom",
            asrLanguage: "zh"
        )
        let customOut = try await client.transcribeAudio(wavData: dummyWAV, config: cfgCustom, personalWords: hotwords)
        XCTAssertEqual(customOut, "自动重试成功")
        XCTAssertEqual(customBodies.count, 2)

        // Case 2: grok-stt skips prompt proactively on first attempt and succeeds cleanly
        var grokCalls = 0
        MockSTTURLProtocol.setHandler { request, body in
            grokCalls += 1
            XCTAssertEqual(request.url?.absoluteString, "https://stt.example.com/v1/audio/transcriptions")
            XCTAssertTrue(body.contains("name=\"model\"\r\n\r\ngrok-stt"))
            XCTAssertFalse(body.contains("name=\"prompt\""))
            return (200, Data(#"{"text":"直连成功"}"#.utf8))
        }
        let cfgGrok = AIConfiguration(
            asrProvider: .openAIWhisperCompatible,
            asrBaseURL: "stt.example.com/v1",
            asrAPIKey: "test_key_123",
            asrModel: "grok-stt",
            asrLanguage: "zh"
        )
        let grokOut = try await client.transcribeAudio(wavData: dummyWAV, config: cfgGrok, personalWords: hotwords)
        XCTAssertEqual(grokOut, "直连成功")
        XCTAssertEqual(grokCalls, 1)

        // Case 3: Endpoint rejecting language also falls back to model + file only
        var langFallbackCalls = 0
        MockSTTURLProtocol.setHandler { _, body in
            langFallbackCalls += 1
            if body.contains("name=\"language\"") {
                return (422, Data(#"{"error":{"message":"language unsupported"}}"#.utf8))
            }
            return (200, Data(#"{"data":{"text":"极简参数成功"}}"#.utf8))
        }
        let langOut = try await client.transcribeAudio(wavData: dummyWAV, config: cfgGrok, personalWords: hotwords)
        XCTAssertEqual(langOut, "极简参数成功")
        XCTAssertEqual(langFallbackCalls, 2)

        // Case 4: Bare domain without /v1 gets 404 on /audio/transcriptions and falls back to /v1/audio/transcriptions
        var pathsVisited: [String] = []
        MockSTTURLProtocol.setHandler { request, _ in
            let path = request.url?.path ?? ""
            pathsVisited.append(path)
            if path == "/audio/transcriptions" {
                return (404, Data(#"{"error":"not found"}"#.utf8))
            }
            return (200, Data(#"{"transcript":"自动补全v1成功"}"#.utf8))
        }
        let cfgBare = AIConfiguration(
            asrProvider: .openAIWhisperCompatible,
            asrBaseURL: "stt.example.com",
            asrAPIKey: "test_key_123",
            asrModel: "grok-stt",
            asrLanguage: "auto"
        )
        let bareOut = try await client.transcribeAudio(wavData: dummyWAV, config: cfgBare, personalWords: hotwords)
        XCTAssertEqual(bareOut, "自动补全v1成功")
        XCTAssertEqual(pathsVisited, ["/audio/transcriptions", "/v1/audio/transcriptions"])
    }
}

private final class MockSTTURLProtocol: URLProtocol {
    typealias Handler = (URLRequest, String) throws -> (Int, Data)
    private static let lock = NSLock()
    private static var handler: Handler?

    static func setHandler(_ newHandler: Handler?) {
        lock.lock()
        handler = newHandler
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let currentHandler = Self.handler
        Self.lock.unlock()

        guard let currentHandler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        var bodyData = request.httpBody ?? Data()
        if bodyData.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let readCount = stream.read(&buffer, maxLength: buffer.count)
                if readCount > 0 {
                    bodyData.append(buffer, count: readCount)
                } else {
                    break
                }
            }
            stream.close()
        }
        let bodyString = String(decoding: bodyData, as: UTF8.self)

        do {
            let (statusCode, responseData) = try currentHandler(request, bodyString)
            let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseData)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
