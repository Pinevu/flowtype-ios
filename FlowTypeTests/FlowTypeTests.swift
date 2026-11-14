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
}
