import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum CandidateSource: Equatable, Sendable {
    case personalDictionary
    case userLearned
    case exactPhrase
    case viterbiSentence
    case prefixOrInitial
    case singleChar
}

public struct PinyinCandidate: Identifiable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let consumedChars: Int
    public let displayPinyin: String
    public let isFullMatch: Bool
    public let source: CandidateSource

    public init(
        text: String,
        consumedChars: Int,
        displayPinyin: String = "",
        isFullMatch: Bool = true,
        source: CandidateSource
    ) {
        self.id = "\(text)_\(consumedChars)"
        self.text = text
        self.consumedChars = consumedChars
        self.displayPinyin = displayPinyin
        self.isFullMatch = isFullMatch
        self.source = source
    }
}

public final class LexiconDatabase: @unchecked Sendable {
    public static let shared = LexiconDatabase()

    private var bundleDB: OpaquePointer?
    private var userDB: OpaquePointer?
    private let queue = DispatchQueue(label: "com.flowtype.lexicon.sqlite", qos: .userInteractive)

    public init(bundleDBURL: URL? = nil, userDBURL: URL? = nil) {
        let resolvedBundleURL = bundleDBURL
            ?? Bundle(for: LexiconDatabase.self).url(forResource: "lexicon", withExtension: "sqlite")
            ?? Bundle.main.url(forResource: "lexicon", withExtension: "sqlite")

        if let url = resolvedBundleURL, FileManager.default.fileExists(atPath: url.path) {
            var db: OpaquePointer?
            if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK {
                self.bundleDB = db
            }
        }

        let resolvedUserURL = userDBURL ?? SharedStore.shared.sharedDatabaseURL
        var udb: OpaquePointer?
        if sqlite3_open_v2(
            resolvedUserURL.path,
            &udb,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX,
            nil
        ) == SQLITE_OK {
            self.userDB = udb
            createUserTablesIfNeeded()
        }
    }

    deinit {
        if let db = bundleDB { sqlite3_close(db) }
        if let udb = userDB { sqlite3_close(udb) }
    }

    private func createUserTablesIfNeeded() {
        guard let udb = userDB else { return }
        let sql = """
        CREATE TABLE IF NOT EXISTS user_phrases (
            pinyin TEXT NOT NULL,
            word TEXT NOT NULL,
            freq INTEGER NOT NULL DEFAULT 1,
            updated_at INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (pinyin, word)
        );
        CREATE INDEX IF NOT EXISTS idx_user_phrases_pinyin ON user_phrases(pinyin, freq DESC);
        CREATE TABLE IF NOT EXISTS user_en_words (
            word TEXT PRIMARY KEY,
            freq INTEGER NOT NULL DEFAULT 1
        );
        """
        sqlite3_exec(udb, sql, nil, nil, nil)
    }

    // MARK: - User Frequency Learning

    public func recordChineseSelection(pinyin: String, word: String) {
        let cleanPy = pinyin.lowercased().filter { $0 >= "a" && $0 <= "z" }
        guard !cleanPy.isEmpty, !word.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, let udb = self.userDB else { return }
            let now = Int64(Date().timeIntervalSince1970)
            let sql = """
            INSERT INTO user_phrases (pinyin, word, freq, updated_at)
            VALUES (?, ?, 1, ?)
            ON CONFLICT(pinyin, word) DO UPDATE SET
                freq = freq + 1,
                updated_at = excluded.updated_at;
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(udb, sql, -1, &stmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, cleanPy, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, word, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 3, now)
                sqlite3_step(stmt)
            }
        }
    }

    public func recordEnglishSelection(word: String) {
        let clean = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, let udb = self.userDB else { return }
            let sql = """
            INSERT INTO user_en_words (word, freq)
            VALUES (?, 1)
            ON CONFLICT(word) DO UPDATE SET freq = freq + 1;
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(udb, sql, -1, &stmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, clean, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
        }
    }

    // MARK: - Pinyin Query & Decoding

    public func queryPinyinCandidates(
        rawInput: String,
        fuzzy: Bool = false,
        personalWords: [PersonalWord] = [],
        limit: Int = 40
    ) -> (segmentation: PinyinSegmentationResult, candidates: [PinyinCandidate]) {
        let seg = PinyinSyllableParser.segment(rawInput: rawInput)
        let clean = seg.cleanInput
        guard !clean.isEmpty else {
            return (seg, [])
        }

        return queue.sync {
            var results: [PinyinCandidate] = []
            var seenTexts = Set<String>()

            func appendCandidate(_ cand: PinyinCandidate) {
                guard results.count < limit else { return }
                let key = "\(cand.text)#\(cand.consumedChars)"
                if !seenTexts.contains(key) {
                    seenTexts.insert(key)
                    results.append(cand)
                }
            }

            // 1. Personal dictionary exact/prefix matches using pinyinHint
            for entry in personalWords where !entry.pinyinHint.isEmpty {
                let hint = entry.pinyinHint.lowercased().filter { $0 >= "a" && $0 <= "z" }
                if hint == clean {
                    appendCandidate(PinyinCandidate(
                        text: entry.term,
                        consumedChars: clean.count,
                        displayPinyin: seg.displayPinyin,
                        isFullMatch: true,
                        source: .personalDictionary
                    ))
                } else if hint.hasPrefix(clean) && clean.count >= 2 {
                    appendCandidate(PinyinCandidate(
                        text: entry.term,
                        consumedChars: clean.count,
                        displayPinyin: seg.displayPinyin,
                        isFullMatch: true,
                        source: .personalDictionary
                    ))
                }
            }

            // 2. User learned exact phrases
            for (word, _) in fetchUserPhrases(pinyin: clean, limit: 8) {
                appendCandidate(PinyinCandidate(
                    text: word,
                    consumedChars: clean.count,
                    displayPinyin: seg.displayPinyin,
                    isFullMatch: true,
                    source: .userLearned
                ))
            }

            // 3. Exact phrase matches in bundled dictionary
            let exactVariants = fuzzy ? expandedJoinedVariants(syllables: seg.primarySyllables, maxCount: 6) : [clean]
            for variant in exactVariants {
                for (word, _) in fetchBundlePhrases(pinyin: variant, limit: 12) {
                    appendCandidate(PinyinCandidate(
                        text: word,
                        consumedChars: clean.count,
                        displayPinyin: seg.displayPinyin,
                        isFullMatch: true,
                        source: .exactPhrase
                    ))
                }
            }

            // 4. Viterbi / Beam-Search sentence decoding across syllable lattice (handles multi-word phrases!)
            if seg.primarySyllables.count >= 2 {
                let decodedSentences = decodeViterbiSentences(
                    cleanInput: clean,
                    seg: seg,
                    fuzzy: fuzzy,
                    topK: 4
                )
                for sentence in decodedSentences {
                    appendCandidate(PinyinCandidate(
                        text: sentence,
                        consumedChars: clean.count,
                        displayPinyin: seg.displayPinyin,
                        isFullMatch: true,
                        source: .viterbiSentence
                    ))
                }
            }

            // 5. Prefix & Initials (简拼) matching when user hasn't finished typing all syllables
            if clean.count >= 2 && clean.count <= 8 {
                let initialKey: String
                if seg.primarySyllables.allSatisfy({ $0.text.count == 1 || $0.isPartial }) {
                    initialKey = clean
                } else {
                    initialKey = seg.primarySyllables.compactMap { $0.text.first.map(String.init) }.joined()
                }
                if initialKey.count >= 2 {
                    let prefixMatches = fetchPhrasesByInitials(
                        initials: initialKey,
                        pinyinPrefix: seg.primarySyllables.count >= 2 ? seg.primarySyllables.first?.text : nil,
                        limit: 10
                    )
                    for (word, _) in prefixMatches {
                        appendCandidate(PinyinCandidate(
                            text: word,
                            consumedChars: clean.count,
                            displayPinyin: seg.displayPinyin,
                            isFullMatch: true,
                            source: .prefixOrInitial
                        ))
                    }
                }
            }

            // 6. Partial prefix phrases starting at index 0 (allows step-by-step word selection)
            if seg.primarySyllables.count >= 2 {
                let maxPrefixSyllables = min(4, seg.primarySyllables.count - 1)
                for endSyllableIdx in stride(from: maxPrefixSyllables, through: 2, by: -1) {
                    let endOffset = seg.primarySyllables[endSyllableIdx - 1].endOffset
                    let subPy = String(clean.prefix(endOffset))
                    for (word, _) in fetchUserPhrases(pinyin: subPy, limit: 3) {
                        appendCandidate(PinyinCandidate(
                            text: word,
                            consumedChars: endOffset,
                            displayPinyin: seg.primarySyllables[0..<endSyllableIdx].map(\.text).joined(separator: "'"),
                            isFullMatch: false,
                            source: .userLearned
                        ))
                    }
                    for (word, _) in fetchBundlePhrases(pinyin: subPy, limit: 4) {
                        appendCandidate(PinyinCandidate(
                            text: word,
                            consumedChars: endOffset,
                            displayPinyin: seg.primarySyllables[0..<endSyllableIdx].map(\.text).joined(separator: "'"),
                            isFullMatch: false,
                            source: .exactPhrase
                        ))
                    }
                }
            }

            // 7. Single character candidates for the leading syllable (or full cleanInput if single syllable)
            if let firstSyllable = seg.primarySyllables.first {
                let consumed = firstSyllable.endOffset
                let isFull = consumed == clean.count
                let charVariants = fuzzy ? PinyinSyllableParser.fuzzyVariants(for: firstSyllable.text) : [firstSyllable.text]

                // User learned single chars first
                for (word, _) in fetchUserPhrases(pinyin: firstSyllable.text, limit: 4) where word.count == 1 {
                    appendCandidate(PinyinCandidate(
                        text: word,
                        consumedChars: consumed,
                        displayPinyin: firstSyllable.text,
                        isFullMatch: isFull,
                        source: .userLearned
                    ))
                }

                // Bundle single chars
                var charPool: [(String, Int)] = []
                for variant in charVariants {
                    charPool.append(contentsOf: fetchBundleChars(pinyin: variant, limit: 25))
                }
                charPool.sort { $0.1 > $1.1 }
                for (hanzi, _) in charPool {
                    appendCandidate(PinyinCandidate(
                        text: hanzi,
                        consumedChars: consumed,
                        displayPinyin: firstSyllable.text,
                        isFullMatch: isFull,
                        source: .singleChar
                    ))
                }

                // If user typed a partial consonant like "zh" or "sh", show prefix phrase hits
                if firstSyllable.isPartial || (seg.primarySyllables.count == 1 && charPool.isEmpty) {
                    for (word, _) in fetchBundlePhrasesByPrefix(prefix: clean, limit: 10) {
                        appendCandidate(PinyinCandidate(
                            text: word,
                            consumedChars: clean.count,
                            displayPinyin: seg.displayPinyin,
                            isFullMatch: true,
                            source: .prefixOrInitial
                        ))
                    }
                }
            }

            return (seg, results)
        }
    }

    // MARK: - English Prefix Completions

    public func queryEnglishCompletions(
        prefix: String,
        personalWords: [PersonalWord] = [],
        limit: Int = 8
    ) -> [String] {
        let lower = prefix.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return [] }

        return queue.sync {
            var results: [String] = []
            var seen = Set<String>()

            func add(_ w: String) {
                guard results.count < limit else { return }
                if seen.insert(w.lowercased()).inserted {
                    results.append(w)
                }
            }

            // 1. Personal dictionary ASCII terms
            for entry in personalWords where entry.term.range(of: "^[A-Za-z]", options: .regularExpression) != nil {
                if entry.term.lowercased().hasPrefix(lower) {
                    add(entry.term)
                }
            }

            // 2. User learned English words
            if let udb = userDB {
                let sql = "SELECT word FROM user_en_words WHERE word >= ? AND word < ? ORDER BY freq DESC LIMIT ?;"
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(udb, sql, -1, &stmt, nil) == SQLITE_OK {
                    defer { sqlite3_finalize(stmt) }
                    sqlite3_bind_text(stmt, 1, lower, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 2, nextPrefixBound(lower), -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int(stmt, 3, Int32(limit))
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        if let cStr = sqlite3_column_text(stmt, 0) {
                            add(String(cString: cStr))
                        }
                    }
                }
            }

            // 3. Bundled English frequency dictionary
            if let db = bundleDB {
                let sql = "SELECT word, freq FROM en_words WHERE word >= ? AND word < ? LIMIT 60;"
                var stmt: OpaquePointer?
                var pool: [(String, Int)] = []
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    defer { sqlite3_finalize(stmt) }
                    sqlite3_bind_text(stmt, 1, lower, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 2, nextPrefixBound(lower), -1, SQLITE_TRANSIENT)
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        if let cStr = sqlite3_column_text(stmt, 0) {
                            let w = String(cString: cStr)
                            let f = Int(sqlite3_column_int64(stmt, 1))
                            pool.append((w, f))
                        }
                    }
                }
                pool.sort { $0.1 > $1.1 }
                for (w, _) in pool {
                    add(w)
                }
            }

            return results
        }
    }

    // MARK: - Viterbi / Beam Search Decoding

    private struct ViterbiPath {
        let text: String
        let score: Double
    }

    private func decodeViterbiSentences(
        cleanInput: String,
        seg: PinyinSegmentationResult,
        fuzzy: Bool,
        topK: Int
    ) -> [String] {
        let chars = Array(cleanInput)
        let n = chars.count
        guard n > 1 else { return [] }

        // Collect all valid syllable spans and multi-syllable spans up to 6 syllables
        let fullEdges = seg.latticeEdges.filter { !$0.isPartial }
        if fullEdges.isEmpty {
            return []
        }

        // Group single-syllable transitions by start index
        var singleStarts = Array(repeating: [SyllableSpan](), count: n)
        for edge in fullEdges {
            singleStarts[edge.startOffset].append(edge)
        }

        struct LatticeNodeEdge {
            let start: Int
            let end: Int
            let text: String
            let score: Double
        }

        var transitions = Array(repeating: [LatticeNodeEdge](), count: n)

        // Single-syllable character edges
        for edge in fullEdges {
            let variants = fuzzy ? PinyinSyllableParser.fuzzyVariants(for: edge.text) : [edge.text]
            var topChars: [(String, Int)] = []
            for v in variants {
                topChars.append(contentsOf: fetchBundleChars(pinyin: v, limit: 3))
            }
            topChars.sort { $0.1 > $1.1 }
            for (rank, item) in topChars.prefix(2).enumerated() {
                let s = log10(Double(max(item.1, 1)) + 1.0) - Double(rank) * 0.6
                transitions[edge.startOffset].append(LatticeNodeEdge(start: edge.startOffset, end: edge.endOffset, text: item.0, score: s))
            }
        }

        // Multi-syllable phrase edges (2..5 syllables chained along valid spans)
        func collectMultiEdges(start: Int, currentOffset: Int, depth: Int) {
            if depth >= 2 {
                let sub = String(chars[start..<currentOffset])
                let userHits = fetchUserPhrases(pinyin: sub, limit: 2)
                for (w, f) in userHits {
                    let s = log10(Double(f * 5000 + 1000)) + Double(depth) * 3.8
                    transitions[start].append(LatticeNodeEdge(start: start, end: currentOffset, text: w, score: s))
                }
                let bundleHits = fetchBundlePhrases(pinyin: sub, limit: 3)
                for (rank, item) in bundleHits.enumerated() {
                    let s = log10(Double(max(item.1, 1)) + 1.0) + Double(depth) * 3.6 - Double(rank) * 0.4
                    transitions[start].append(LatticeNodeEdge(start: start, end: currentOffset, text: item.0, score: s))
                }
            }
            guard depth < 5, currentOffset < n else { return }
            for nextSpan in singleStarts[currentOffset] {
                collectMultiEdges(start: start, currentOffset: nextSpan.endOffset, depth: depth + 1)
            }
        }

        for i in 0..<n where !singleStarts[i].isEmpty {
            collectMultiEdges(start: i, currentOffset: i, depth: 0)
        }

        // Beam search DP across 0...n
        var beams = Array(repeating: [ViterbiPath](), count: n + 1)
        beams[0] = [ViterbiPath(text: "", score: 0)]

        for i in 0..<n {
            guard !beams[i].isEmpty, !transitions[i].isEmpty else { continue }
            for path in beams[i] {
                for edge in transitions[i] {
                    let candidate = ViterbiPath(text: path.text + edge.text, score: path.score + edge.score)
                    beams[edge.end].append(candidate)
                }
            }
            // Prune beams at reachable nodes later or immediately for next positions
            for j in (i + 1)...n where beams[j].count > 12 {
                beams[j].sort { $0.score > $1.score }
                var seenBeamTexts = Set<String>()
                var deduped: [ViterbiPath] = []
                for p in beams[j] where seenBeamTexts.insert(p.text).inserted {
                    deduped.append(p)
                    if deduped.count >= 6 { break }
                }
                beams[j] = deduped
            }
        }

        let finished = beams[n].sorted { $0.score > $1.score }
        var seen = Set<String>()
        var output: [String] = []
        for p in finished {
            if seen.insert(p.text).inserted {
                output.append(p.text)
                if output.count >= topK { break }
            }
        }
        return output
    }

    // MARK: - Raw SQLite Queries

    private func fetchBundleChars(pinyin: String, limit: Int) -> [(String, Int)] {
        guard let db = bundleDB else { return [] }
        let sql = "SELECT hanzi, freq FROM chars WHERE pinyin = ? ORDER BY freq DESC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, pinyin, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var rows: [(String, Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                rows.append((String(cString: cStr), Int(sqlite3_column_int64(stmt, 1))))
            }
        }
        return rows
    }

    private func fetchBundlePhrases(pinyin: String, limit: Int) -> [(String, Int)] {
        guard let db = bundleDB else { return [] }
        let sql = "SELECT word, freq FROM phrases WHERE pinyin = ? ORDER BY freq DESC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, pinyin, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var rows: [(String, Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                rows.append((String(cString: cStr), Int(sqlite3_column_int64(stmt, 1))))
            }
        }
        return rows
    }

    private func fetchBundlePhrasesByPrefix(prefix: String, limit: Int) -> [(String, Int)] {
        guard let db = bundleDB else { return [] }
        let sql = "SELECT word, freq FROM phrases WHERE pinyin >= ? AND pinyin < ? ORDER BY freq DESC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, prefix, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, nextPrefixBound(prefix), -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, Int32(limit))
        var rows: [(String, Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                rows.append((String(cString: cStr), Int(sqlite3_column_int64(stmt, 1))))
            }
        }
        return rows
    }

    private func fetchPhrasesByInitials(initials: String, pinyinPrefix: String?, limit: Int) -> [(String, Int)] {
        guard let db = bundleDB else { return [] }
        let sql = "SELECT word, freq, pinyin FROM phrases WHERE initials = ? ORDER BY freq DESC LIMIT 40;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, initials, -1, SQLITE_TRANSIENT)

        var rows: [(String, Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let wPtr = sqlite3_column_text(stmt, 0),
               let pyPtr = sqlite3_column_text(stmt, 2) {
                let word = String(cString: wPtr)
                let freq = Int(sqlite3_column_int64(stmt, 1))
                let py = String(cString: pyPtr)
                if let pinyinPrefix, !py.hasPrefix(pinyinPrefix) {
                    continue
                }
                rows.append((word, freq))
                if rows.count >= limit { break }
            }
        }
        return rows
    }

    private func fetchUserPhrases(pinyin: String, limit: Int) -> [(String, Int)] {
        guard let udb = userDB else { return [] }
        let sql = "SELECT word, freq FROM user_phrases WHERE pinyin = ? ORDER BY freq DESC, updated_at DESC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(udb, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, pinyin, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var rows: [(String, Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                rows.append((String(cString: cStr), Int(sqlite3_column_int64(stmt, 1))))
            }
        }
        return rows
    }

    private func expandedJoinedVariants(syllables: [SyllableSpan], maxCount: Int) -> [String] {
        guard !syllables.isEmpty, syllables.count <= 4 else {
            return [syllables.map(\.text).joined()]
        }
        var current = [""]
        for s in syllables {
            let variants = Array(PinyinSyllableParser.fuzzyVariants(for: s.text).prefix(3))
            var next: [String] = []
            for base in current {
                for v in variants {
                    next.append(base + v)
                    if next.count >= maxCount { break }
                }
                if next.count >= maxCount { break }
            }
            current = next
        }
        return current
    }

    private func nextPrefixBound(_ s: String) -> String {
        guard !s.isEmpty, let last = s.unicodeScalars.last else { return s + "\u{FFFF}" }
        let nextScalar = UnicodeScalar(last.value + 1) ?? UnicodeScalar(0x7E)!
        return String(s.dropLast()) + String(nextScalar)
    }
}
