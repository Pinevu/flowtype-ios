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
}
