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
    private let dbLock = NSRecursiveLock()
    private var bundleStmtCache: [String: OpaquePointer] = [:]

    // MARK: - In-Memory T9 Cache (0ms instant hits for repetitive typing and backspaces)
    private var t9Cache: [String: (syllableOptions: [String], candidates: [PinyinCandidate])] = [:]
    private var t9CacheKeys: [String] = []
    private let t9CacheCapacity = 192

    public func clearT9Cache() {
        dbLock.lock()
        defer { dbLock.unlock() }
        t9Cache.removeAll()
        t9CacheKeys.removeAll()
    }

    public init(bundleDBURL: URL? = nil, userDBURL: URL? = nil) {
        let resolvedBundleURL = bundleDBURL
            ?? Bundle(for: LexiconDatabase.self).url(forResource: "lexicon", withExtension: "sqlite")
            ?? Bundle.main.url(forResource: "lexicon", withExtension: "sqlite")

        if let url = resolvedBundleURL, FileManager.default.fileExists(atPath: url.path) {
            var db: OpaquePointer?
            if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK {
                sqlite3_exec(db, "PRAGMA temp_store=MEMORY; PRAGMA mmap_size=8388608; PRAGMA cache_size=-2000;", nil, nil, nil)
                self.bundleDB = db
            }
        }

        let resolvedUserURL = userDBURL ?? SharedStore.shared.sharedDatabaseURL
        var udb: OpaquePointer?
        if sqlite3_open_v2(
            resolvedUserURL.path,
            &udb,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK {
            sqlite3_exec(udb, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=1500;", nil, nil, nil)
            self.userDB = udb
            createUserTablesIfNeeded()
        }
    }

    deinit {
        dbLock.lock()
        defer { dbLock.unlock() }
        for stmt in bundleStmtCache.values {
            sqlite3_finalize(stmt)
        }
        bundleStmtCache.removeAll()
        t9Cache.removeAll()
        t9CacheKeys.removeAll()
        if let db = bundleDB { sqlite3_close(db) }
        if let udb = userDB { sqlite3_close(udb) }
    }

    private func createUserTablesIfNeeded() {
        guard let udb = userDB else { return }
        let sql = """
        CREATE TABLE IF NOT EXISTS user_phrases (
            pinyin TEXT NOT NULL,
            word TEXT NOT NULL,
            t9 TEXT NOT NULL DEFAULT '',
            t9_initials TEXT NOT NULL DEFAULT '',
            initials TEXT NOT NULL DEFAULT '',
            freq INTEGER NOT NULL DEFAULT 1,
            updated_at INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (pinyin, word)
        );
        CREATE INDEX IF NOT EXISTS idx_user_phrases_pinyin ON user_phrases(pinyin, freq DESC);
        CREATE INDEX IF NOT EXISTS idx_user_phrases_t9 ON user_phrases(t9, freq DESC, updated_at DESC);

        CREATE TABLE IF NOT EXISTS user_chars (
            hanzi TEXT NOT NULL,
            t9 TEXT NOT NULL,
            pinyin TEXT NOT NULL DEFAULT '',
            freq INTEGER NOT NULL DEFAULT 1,
            updated_at INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (hanzi, t9)
        );
        CREATE INDEX IF NOT EXISTS idx_user_chars_t9 ON user_chars(t9, freq DESC, updated_at DESC);
        CREATE INDEX IF NOT EXISTS idx_user_chars_pinyin ON user_chars(pinyin, freq DESC);

        CREATE TABLE IF NOT EXISTS user_associations (
            prev_word TEXT NOT NULL,
            next_word TEXT NOT NULL,
            freq INTEGER NOT NULL DEFAULT 1,
            updated_at INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (prev_word, next_word)
        );
        CREATE INDEX IF NOT EXISTS idx_user_assoc_prev ON user_associations(prev_word, freq DESC, updated_at DESC);

        CREATE TABLE IF NOT EXISTS user_en_words (
            word TEXT PRIMARY KEY,
            freq INTEGER NOT NULL DEFAULT 1
        );

        CREATE TABLE IF NOT EXISTS online_words (
            pinyin TEXT NOT NULL,
            word TEXT NOT NULL,
            t9 TEXT NOT NULL DEFAULT '',
            t9_initials TEXT NOT NULL DEFAULT '',
            initials TEXT NOT NULL DEFAULT '',
            weight INTEGER NOT NULL DEFAULT 100,
            PRIMARY KEY (pinyin, word)
        );
        CREATE INDEX IF NOT EXISTS idx_online_t9 ON online_words(t9, weight DESC);
        CREATE INDEX IF NOT EXISTS idx_online_t9_init ON online_words(t9_initials, weight DESC);
        CREATE INDEX IF NOT EXISTS idx_online_pinyin ON online_words(pinyin, weight DESC);
        CREATE INDEX IF NOT EXISTS idx_online_init ON online_words(initials, weight DESC);
        CREATE INDEX IF NOT EXISTS idx_online_word ON online_words(word);

        CREATE TABLE IF NOT EXISTS user_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """
        sqlite3_exec(udb, sql, nil, nil, nil)

        // Safe migration for older tables without t9 / initials columns
        sqlite3_exec(udb, "ALTER TABLE user_phrases ADD COLUMN t9 TEXT NOT NULL DEFAULT '';", nil, nil, nil)
        sqlite3_exec(udb, "ALTER TABLE user_phrases ADD COLUMN t9_initials TEXT NOT NULL DEFAULT '';", nil, nil, nil)
        sqlite3_exec(udb, "ALTER TABLE user_phrases ADD COLUMN initials TEXT NOT NULL DEFAULT '';", nil, nil, nil)
        sqlite3_exec(udb, "CREATE INDEX IF NOT EXISTS idx_user_phrases_t9 ON user_phrases(t9, freq DESC, updated_at DESC);", nil, nil, nil)
        sqlite3_exec(udb, "CREATE INDEX IF NOT EXISTS idx_user_phrases_t9_init ON user_phrases(t9_initials, freq DESC, updated_at DESC);", nil, nil, nil)
        sqlite3_exec(udb, "CREATE INDEX IF NOT EXISTS idx_user_phrases_init ON user_phrases(initials, freq DESC, updated_at DESC);", nil, nil, nil)
    }

    // MARK: - Online Lexicon Sync & Pinyin Derivation

    private static func deriveInitials(fromCleanPinyin cleanPy: String) -> (initials: String, t9Initials: String) {
        guard !cleanPy.isEmpty else { return ("", "") }
        let syls = PinyinSyllableParser.segment(rawInput: cleanPy).primarySyllables
        let initLetters = syls.compactMap { $0.text.first.map(String.init) }.joined()
        return (initLetters, Self.pinyinToT9Digits(initLetters))
    }

    /// Derives joined lowercase pinyin for a Chinese term using bundled character frequencies.
    public func derivePinyin(for term: String) -> String {
        dbLock.lock()
        defer { dbLock.unlock() }
        var out = ""
        for scalar in term.unicodeScalars {
            if (scalar.value >= 0x4E00 && scalar.value <= 0x9FFF) ||
               (scalar.value >= 0x3400 && scalar.value <= 0x4DBF) {
                let ch = String(scalar)
                if let py = fetchTopPinyinForChar(hanzi: ch) {
                    out += py
                }
            } else if (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122) {
                out += String(scalar).lowercased()
            }
        }
        return out
    }

    private func fetchTopPinyinForChar(hanzi: String) -> String? {
        let sql = "SELECT pinyin FROM chars WHERE hanzi = ? ORDER BY freq DESC LIMIT 1;"
        let rows: [String] = withCachedBundleStmt(sql) { stmt in
            sqlite3_bind_text(stmt, 1, hanzi, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW, let ptr = sqlite3_column_text(stmt, 0) {
                return [String(cString: ptr)]
            }
            return []
        }
        return rows.first
    }

    public func syncOnlineLexiconIfNeeded(store: SharedStore = .shared) {
        let storeRev = store.loadOnlineLexiconRevision()
        guard storeRev > 0 else { return }

        dbLock.lock()
        let currentRev = Int64(readUserMeta(key: "online_revision") ?? "-1") ?? -1
        dbLock.unlock()
        guard storeRev != currentRev else { return }

        guard let snapshot = store.loadOnlineLexiconSnapshot() else { return }
        replaceOnlineWords(snapshot.entries, revision: snapshot.revision > 0 ? snapshot.revision : storeRev)
    }

    public func replaceOnlineWords(_ entries: [OnlineLexiconEntry], revision: Int64) {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let udb = userDB else { return }

        sqlite3_exec(udb, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil)
        sqlite3_exec(udb, "DELETE FROM online_words;", nil, nil, nil)

        if !entries.isEmpty {
            let insertSQL = """
            INSERT INTO online_words (pinyin, word, t9, t9_initials, initials, weight)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(pinyin, word) DO UPDATE SET
                weight = MAX(online_words.weight, excluded.weight);
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(udb, insertSQL, -1, &stmt, nil) == SQLITE_OK, let prepared = stmt {
                defer { sqlite3_finalize(prepared) }
                for item in entries {
                    let cleanWord = item.term.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleanWord.isEmpty else { continue }
                    let rawPy = item.pinyin.lowercased().filter { $0 >= "a" && $0 <= "z" }
                    let resolvedPy = rawPy.isEmpty ? derivePinyin(for: cleanWord) : rawPy
                    let t9 = Self.pinyinToT9Digits(resolvedPy)
                    let (initials, t9Initials) = cleanWord.count >= 2
                        ? Self.deriveInitials(fromCleanPinyin: resolvedPy)
                        : (String(resolvedPy.prefix(1)), String(t9.prefix(1)))
                    let dbPinyin = resolvedPy.isEmpty ? cleanWord.lowercased() : resolvedPy

                    sqlite3_reset(prepared)
                    sqlite3_clear_bindings(prepared)
                    sqlite3_bind_text(prepared, 1, dbPinyin, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(prepared, 2, cleanWord, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(prepared, 3, t9, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(prepared, 4, t9Initials, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(prepared, 5, initials, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int64(prepared, 6, Int64(max(1, item.weight)))
                    sqlite3_step(prepared)
                }
            }
        }

        writeUserMeta(key: "online_revision", value: "\(revision)")
        sqlite3_exec(udb, "COMMIT;", nil, nil, nil)

        t9Cache.removeAll()
        t9CacheKeys.removeAll()
    }

    public func onlineWordsCount() -> Int {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let udb = userDB else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(udb, "SELECT COUNT(*) FROM online_words;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    private func readUserMeta(key: String) -> String? {
        guard let udb = userDB else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(udb, "SELECT value FROM user_meta WHERE key = ?;", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW, let ptr = sqlite3_column_text(stmt, 0) {
            return String(cString: ptr)
        }
        return nil
    }

    private func writeUserMeta(key: String, value: String) {
        guard let udb = userDB else { return }
        var stmt: OpaquePointer?
        let sql = "INSERT INTO user_meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;"
        if sqlite3_prepare_v2(udb, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    // MARK: - User Frequency Learning & Predictive Memory

    public func recordT9Selection(
        digits: String,
        word: String,
        pinyin: String,
        previousWord: String? = nil,
        boostWeight: Int = 1
    ) {
        let cleanDigits = digits.filter { $0 >= "2" && $0 <= "9" }
        let cleanPy = pinyin.lowercased().filter { ($0 >= "a" && $0 <= "z") || $0 == "'" }.replacingOccurrences(of: "'", with: "")
        guard !word.isEmpty else { return }
        let now = Int64(Date().timeIntervalSince1970)
        let weight = Int64(max(1, min(10, boostWeight)))
        let derivedDigits = !cleanPy.isEmpty ? Self.pinyinToT9Digits(cleanPy) : cleanDigits
        let effectiveDigits = derivedDigits.count >= cleanDigits.count ? derivedDigits : cleanDigits
        let (initials, t9Initials) = word.count >= 2
            ? Self.deriveInitials(fromCleanPinyin: cleanPy)
            : (String(cleanPy.prefix(1)), String(effectiveDigits.prefix(1)))

        dbLock.lock()
        defer { dbLock.unlock() }
        guard let udb = self.userDB else { return }

        // 1. Single character frequency learning (e.g. typing 64 and selecting 米 instead of 你)
        if word.count == 1, !effectiveDigits.isEmpty {
            let sql = """
            INSERT INTO user_chars (hanzi, t9, pinyin, freq, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(hanzi, t9) DO UPDATE SET
                freq = freq + excluded.freq,
                pinyin = CASE WHEN excluded.pinyin != '' THEN excluded.pinyin ELSE user_chars.pinyin END,
                updated_at = excluded.updated_at;
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(udb, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, word, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, effectiveDigits, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, cleanPy, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 4, weight)
                sqlite3_bind_int64(stmt, 5, now)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }

        // 2. Phrase frequency & novel phrase learning (keeps longest canonical T9 code & initials)
        if !cleanPy.isEmpty || !effectiveDigits.isEmpty {
            let resolvedPy = cleanPy.isEmpty ? "phrase" : cleanPy
            let sql = """
            INSERT INTO user_phrases (pinyin, word, t9, t9_initials, initials, freq, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(pinyin, word) DO UPDATE SET
                t9 = CASE WHEN length(excluded.t9) >= length(user_phrases.t9) AND excluded.t9 != '' THEN excluded.t9 ELSE user_phrases.t9 END,
                t9_initials = CASE WHEN excluded.t9_initials != '' THEN excluded.t9_initials ELSE user_phrases.t9_initials END,
                initials = CASE WHEN excluded.initials != '' THEN excluded.initials ELSE user_phrases.initials END,
                freq = freq + excluded.freq,
                updated_at = excluded.updated_at;
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(udb, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, resolvedPy, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, word, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, effectiveDigits, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, t9Initials, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 5, initials, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 6, weight)
                sqlite3_bind_int64(stmt, 7, now)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }

        // 3. Predictive Next-Word Association
        if let prev = previousWord?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prev.isEmpty, prev != word, prev.count <= 10, word.count <= 10 {
            let sql = """
            INSERT INTO user_associations (prev_word, next_word, freq, updated_at)
            VALUES (?, ?, 1, ?)
            ON CONFLICT(prev_word, next_word) DO UPDATE SET
                freq = freq + 1,
                updated_at = excluded.updated_at;
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(udb, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, prev, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, word, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 3, now)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }

        // Clear cache synchronously so the very next query reflects learned words/frequencies immediately
        self.t9Cache.removeAll()
        self.t9CacheKeys.removeAll()
    }

    public func fetchUserPhraseFrequency(pinyin: String, word: String) -> Int {
        let cleanPy = pinyin.lowercased().filter { $0 >= "a" && $0 <= "z" }
        guard !word.isEmpty else { return 0 }
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let udb = userDB else { return 0 }
        let sql = "SELECT freq FROM user_phrases WHERE pinyin = ? AND word = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(udb, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, cleanPy.isEmpty ? "phrase" : cleanPy, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, word, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    public func fetchUserPhrasesByT9Prefix(prefix: String, limit: Int = 8) -> [(word: String, freq: Int, pinyin: String)] {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let udb = userDB, prefix.count >= 2 else { return [] }
        let sql = "SELECT word, freq, pinyin FROM user_phrases WHERE t9 >= ? AND t9 < ? ORDER BY freq DESC, updated_at DESC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(udb, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, prefix, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, nextPrefixBound(prefix), -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, Int32(limit))
        var rows: [(word: String, freq: Int, pinyin: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let wStr = sqlite3_column_text(stmt, 0), let pyStr = sqlite3_column_text(stmt, 2) {
                rows.append((String(cString: wStr), Int(sqlite3_column_int64(stmt, 1)), String(cString: pyStr)))
            }
        }
        return rows
    }

    public func fetchUserPhrasesByT9Initials(t9: String, limit: Int = 8) -> [(word: String, freq: Int, pinyin: String)] {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let udb = userDB, t9.count >= 2 else { return [] }
        let sql = "SELECT word, freq, pinyin FROM user_phrases WHERE t9_initials = ? ORDER BY freq DESC, updated_at DESC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(udb, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, t9, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var rows: [(word: String, freq: Int, pinyin: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let wStr = sqlite3_column_text(stmt, 0), let pyStr = sqlite3_column_text(stmt, 2) {
                rows.append((String(cString: wStr), Int(sqlite3_column_int64(stmt, 1)), String(cString: pyStr)))
            }
        }
        return rows
    }

    public func fetchUserPhrasesByT9(t9: String, limit: Int = 10) -> [(word: String, freq: Int, pinyin: String)] {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let udb = userDB, !t9.isEmpty else { return [] }
        let sql = "SELECT word, freq, pinyin FROM user_phrases WHERE t9 = ? ORDER BY freq DESC, updated_at DESC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(udb, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, t9, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var rows: [(word: String, freq: Int, pinyin: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let wStr = sqlite3_column_text(stmt, 0), let pyStr = sqlite3_column_text(stmt, 2) {
                rows.append((String(cString: wStr), Int(sqlite3_column_int64(stmt, 1)), String(cString: pyStr)))
            }
        }
        return rows
    }

    public func fetchUserCharsByT9(t9: String, limit: Int = 10) -> [(hanzi: String, freq: Int, pinyin: String)] {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let udb = userDB, !t9.isEmpty else { return [] }
        let sql = "SELECT hanzi, freq, pinyin FROM user_chars WHERE t9 = ? ORDER BY freq DESC, updated_at DESC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(udb, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, t9, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var rows: [(hanzi: String, freq: Int, pinyin: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let hStr = sqlite3_column_text(stmt, 0), let pyStr = sqlite3_column_text(stmt, 2) {
                rows.append((String(cString: hStr), Int(sqlite3_column_int64(stmt, 1)), String(cString: pyStr)))
            }
        }
        return rows
    }

    public func fetchUserChars(pinyin: String, limit: Int = 10) -> [(String, Int)] {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let udb = userDB, !pinyin.isEmpty else { return [] }
        let sql = "SELECT hanzi, freq FROM user_chars WHERE pinyin = ? ORDER BY freq DESC, updated_at DESC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(udb, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, pinyin, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var rows: [(String, Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let hStr = sqlite3_column_text(stmt, 0) {
                rows.append((String(cString: hStr), Int(sqlite3_column_int64(stmt, 1))))
            }
        }
        return rows
    }

    public func fetchUserAssociations(prevWord: String, limit: Int = 8) -> [String] {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let udb = userDB, !prevWord.isEmpty else { return [] }
        let sql = "SELECT next_word FROM user_associations WHERE prev_word = ? ORDER BY freq DESC, updated_at DESC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(udb, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, prevWord, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var list: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let wStr = sqlite3_column_text(stmt, 0) {
                list.append(String(cString: wStr))
            }
        }
        return list
    }

    // MARK: - User Frequency Learning

    public func recordChineseSelection(
        pinyin: String,
        word: String,
        previousWord: String? = nil,
        boostWeight: Int = 1
    ) {
        let cleanPy = pinyin.lowercased().filter { $0 >= "a" && $0 <= "z" }
        guard !cleanPy.isEmpty, !word.isEmpty else { return }
        let t9Digits = Self.pinyinToT9Digits(cleanPy)
        recordT9Selection(
            digits: t9Digits,
            word: word,
            pinyin: cleanPy,
            previousWord: previousWord,
            boostWeight: boostWeight
        )
    }

    public func recordEnglishSelection(word: String) {
        let clean = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let udb = self.userDB else { return }
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

    // MARK: - User & Online Phrase Queries

    private func fetchUserPhrasesByPrefix(prefix: String, limit: Int) -> [(String, Int, String)] {
        guard let udb = userDB, prefix.count >= 2 else { return [] }
        let sql = "SELECT word, freq, pinyin FROM user_phrases WHERE pinyin >= ? AND pinyin < ? ORDER BY freq DESC, updated_at DESC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(udb, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, prefix, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, nextPrefixBound(prefix), -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, Int32(limit))
        var rows: [(String, Int, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let w = sqlite3_column_text(stmt, 0), let py = sqlite3_column_text(stmt, 2) {
                rows.append((String(cString: w), Int(sqlite3_column_int64(stmt, 1)), String(cString: py)))
            }
        }
        return rows
    }

    private func fetchUserPhrasesByInitials(initials: String, limit: Int) -> [(String, Int, String)] {
        guard let udb = userDB, initials.count >= 2 else { return [] }
        let sql = "SELECT word, freq, pinyin FROM user_phrases WHERE initials = ? ORDER BY freq DESC, updated_at DESC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(udb, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, initials, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var rows: [(String, Int, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let w = sqlite3_column_text(stmt, 0), let py = sqlite3_column_text(stmt, 2) {
                rows.append((String(cString: w), Int(sqlite3_column_int64(stmt, 1)), String(cString: py)))
            }
        }
        return rows
    }

    private func fetchOnlineWords(pinyin: String, limit: Int) -> [(word: String, weight: Int, pinyin: String)] {
        guard let udb = userDB, !pinyin.isEmpty else { return [] }
        let sql = "SELECT word, weight, pinyin FROM online_words WHERE pinyin = ? ORDER BY weight DESC LIMIT ?;"
        return fetchOnlineRows(udb: udb, sql: sql, key: pinyin, limit: limit)
    }

    private func fetchOnlineWordsByPrefix(prefix: String, limit: Int) -> [(word: String, weight: Int, pinyin: String)] {
        guard let udb = userDB, prefix.count >= 2 else { return [] }
        let sql = "SELECT word, weight, pinyin FROM online_words WHERE pinyin >= ? AND pinyin < ? ORDER BY weight DESC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(udb, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, prefix, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, nextPrefixBound(prefix), -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, Int32(limit))
        var rows: [(word: String, weight: Int, pinyin: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let w = sqlite3_column_text(stmt, 0), let py = sqlite3_column_text(stmt, 2) {
                rows.append((String(cString: w), Int(sqlite3_column_int64(stmt, 1)), String(cString: py)))
            }
        }
        return rows
    }

    private func fetchOnlineWordsByInitials(initials: String, limit: Int) -> [(word: String, weight: Int, pinyin: String)] {
        guard let udb = userDB, initials.count >= 2 else { return [] }
        let sql = "SELECT word, weight, pinyin FROM online_words WHERE initials = ? ORDER BY weight DESC LIMIT ?;"
        return fetchOnlineRows(udb: udb, sql: sql, key: initials, limit: limit)
    }

    private func fetchOnlineWordsByT9(t9: String, limit: Int) -> [(word: String, weight: Int, pinyin: String)] {
        guard let udb = userDB, !t9.isEmpty else { return [] }
        let sql = "SELECT word, weight, pinyin FROM online_words WHERE t9 = ? ORDER BY weight DESC LIMIT ?;"
        return fetchOnlineRows(udb: udb, sql: sql, key: t9, limit: limit)
    }

    private func fetchOnlineWordsByT9Prefix(prefix: String, limit: Int) -> [(word: String, weight: Int, pinyin: String)] {
        guard let udb = userDB, prefix.count >= 2 else { return [] }
        let sql = "SELECT word, weight, pinyin FROM online_words WHERE t9 >= ? AND t9 < ? ORDER BY weight DESC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(udb, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, prefix, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, nextPrefixBound(prefix), -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, Int32(limit))
        var rows: [(word: String, weight: Int, pinyin: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let w = sqlite3_column_text(stmt, 0), let py = sqlite3_column_text(stmt, 2) {
                rows.append((String(cString: w), Int(sqlite3_column_int64(stmt, 1)), String(cString: py)))
            }
        }
        return rows
    }

    private func fetchOnlineWordsByT9Initials(t9: String, limit: Int) -> [(word: String, weight: Int, pinyin: String)] {
        guard let udb = userDB, t9.count >= 2 else { return [] }
        let sql = "SELECT word, weight, pinyin FROM online_words WHERE t9_initials = ? ORDER BY weight DESC LIMIT ?;"
        return fetchOnlineRows(udb: udb, sql: sql, key: t9, limit: limit)
    }

    private func fetchOnlineRows(udb: OpaquePointer, sql: String, key: String, limit: Int) -> [(word: String, weight: Int, pinyin: String)] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(udb, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var rows: [(word: String, weight: Int, pinyin: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let w = sqlite3_column_text(stmt, 0), let py = sqlite3_column_text(stmt, 2) {
                rows.append((String(cString: w), Int(sqlite3_column_int64(stmt, 1)), String(cString: py)))
            }
        }
        return rows
    }

    // MARK: - Pinyin Query & Decoding

    public func queryPinyinCandidates(
        rawInput: String,
        fuzzy: Bool = false,
        personalWords: [PersonalWord] = [],
        limit: Int = 40,
        isCancelled: (() -> Bool)? = nil
    ) -> (segmentation: PinyinSegmentationResult, candidates: [PinyinCandidate]) {
        let seg = PinyinSyllableParser.segment(rawInput: rawInput)
        let clean = seg.cleanInput
        guard !clean.isEmpty else {
            return (seg, [])
        }

        dbLock.lock()
        defer { dbLock.unlock() }
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

        // 1. Personal dictionary exact/prefix matches sorted by usageCount
        let sortedPersonal = personalWords
            .filter { !$0.pinyinHint.isEmpty }
            .sorted { $0.usageCount > $1.usageCount }
        for entry in sortedPersonal {
            let hint = entry.pinyinHint.lowercased().filter { $0 >= "a" && $0 <= "z" }
            if hint == clean || (hint.hasPrefix(clean) && clean.count >= 2) {
                appendCandidate(PinyinCandidate(
                    text: entry.term,
                    consumedChars: clean.count,
                    displayPinyin: seg.displayPinyin,
                    isFullMatch: true,
                    source: .personalDictionary
                ))
            }
        }

        // 1b. Online custom lexicon exact/initials (top) & multi-syllable prefix matches
        var onlinePrefixPool: [PinyinCandidate] = []
        for item in fetchOnlineWords(pinyin: clean, limit: 8) {
            appendCandidate(PinyinCandidate(
                text: item.word,
                consumedChars: clean.count,
                displayPinyin: item.pinyin.isEmpty ? seg.displayPinyin : item.pinyin,
                isFullMatch: true,
                source: .personalDictionary
            ))
        }
        if clean.count >= 2 {
            for item in fetchOnlineWordsByInitials(initials: clean, limit: 4) {
                appendCandidate(PinyinCandidate(
                    text: item.word,
                    consumedChars: clean.count,
                    displayPinyin: item.pinyin.isEmpty ? seg.displayPinyin : item.pinyin,
                    isFullMatch: true,
                    source: .personalDictionary
                ))
            }
            for item in fetchOnlineWordsByPrefix(prefix: clean, limit: 6) {
                onlinePrefixPool.append(PinyinCandidate(
                    text: item.word,
                    consumedChars: clean.count,
                    displayPinyin: item.pinyin.isEmpty ? seg.displayPinyin : item.pinyin,
                    isFullMatch: false,
                    source: .personalDictionary
                ))
            }
        }

        // 2. User learned exact phrases & initials
        for (word, _) in fetchUserPhrases(pinyin: clean, limit: 8) {
            appendCandidate(PinyinCandidate(
                text: word,
                consumedChars: clean.count,
                displayPinyin: seg.displayPinyin,
                isFullMatch: true,
                source: .userLearned
            ))
        }
        if clean.count >= 2 {
            for (word, _, py) in fetchUserPhrasesByInitials(initials: clean, limit: 4) {
                appendCandidate(PinyinCandidate(
                    text: word,
                    consumedChars: clean.count,
                    displayPinyin: py.isEmpty ? seg.displayPinyin : py,
                    isFullMatch: true,
                    source: .userLearned
                ))
            }
            for (word, _, py) in fetchUserPhrasesByPrefix(prefix: clean, limit: 4) {
                onlinePrefixPool.append(PinyinCandidate(
                    text: word,
                    consumedChars: clean.count,
                    displayPinyin: py.isEmpty ? seg.displayPinyin : py,
                    isFullMatch: false,
                    source: .userLearned
                ))
            }
        }
        // Promote learned/online prefix phrases ahead of bundle when 2+ syllables started (>= 4 letters)
        if clean.count >= 4 {
            for cand in onlinePrefixPool {
                appendCandidate(cand)
            }
        }

        if isCancelled?() == true { return (seg, results) }

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

        if isCancelled?() == true { return (seg, results) }

        // 4. Viterbi / Beam-Search sentence decoding across syllable lattice
        if seg.primarySyllables.count >= 2 {
            let decodedSentences = decodeViterbiSentences(
                cleanInput: clean,
                seg: seg,
                fuzzy: fuzzy,
                topK: 4,
                isCancelled: isCancelled
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
                    for item in fetchOnlineWordsByInitials(initials: initialKey, limit: 4) {
                        appendCandidate(PinyinCandidate(
                            text: item.word,
                            consumedChars: clean.count,
                            displayPinyin: item.pinyin.isEmpty ? seg.displayPinyin : item.pinyin,
                            isFullMatch: true,
                            source: .personalDictionary
                        ))
                    }
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

                // User learned single chars first (checks both user_chars and user_phrases)
                for (hanzi, _) in fetchUserChars(pinyin: firstSyllable.text, limit: 6) {
                    appendCandidate(PinyinCandidate(
                        text: hanzi,
                        consumedChars: consumed,
                        displayPinyin: firstSyllable.text,
                        isFullMatch: isFull,
                        source: .userLearned
                    ))
                }
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

            // 8. Automatic Pinyin typo & transposition correction (e.g. "zhogn"->"zhong", "laing"->"liang")
            let hasPartial = seg.primarySyllables.contains(where: \.isPartial)
            let hasStrongPhraseHit = results.contains { $0.source == .personalDictionary || $0.source == .userLearned || $0.source == .exactPhrase }
            if (hasPartial || (clean.count >= 3 && !hasStrongPhraseHit)) && results.count < limit {
                for repair in PinyinSyllableParser.correctedInputs(for: clean, maxResults: 3) {
                    let repairedSeg = PinyinSyllableParser.segment(rawInput: repair.corrected)
                    for (word, _) in fetchUserPhrases(pinyin: repair.corrected, limit: 4) {
                        appendCandidate(PinyinCandidate(
                            text: word,
                            consumedChars: clean.count,
                            displayPinyin: repair.display,
                            isFullMatch: true,
                            source: .userLearned
                        ))
                    }
                    for (word, _) in fetchBundlePhrases(pinyin: repair.corrected, limit: 6) {
                        appendCandidate(PinyinCandidate(
                            text: word,
                            consumedChars: clean.count,
                            displayPinyin: repair.display,
                            isFullMatch: true,
                            source: .exactPhrase
                        ))
                    }
                    if repairedSeg.primarySyllables.count >= 2 {
                        for sentence in decodeViterbiSentences(cleanInput: repair.corrected, seg: repairedSeg, fuzzy: fuzzy, topK: 2) {
                            appendCandidate(PinyinCandidate(
                                text: sentence,
                                consumedChars: clean.count,
                                displayPinyin: repair.display,
                                isFullMatch: true,
                                source: .viterbiSentence
                            ))
                        }
                    } else if repairedSeg.primarySyllables.count == 1 {
                        for (hanzi, _) in fetchBundleChars(pinyin: repair.corrected, limit: 6) {
                            appendCandidate(PinyinCandidate(
                                text: hanzi,
                                consumedChars: clean.count,
                                displayPinyin: repair.display,
                                isFullMatch: true,
                                source: .singleChar
                            ))
                        }
                    }
                }
            }

            return (seg, results)
    }

    // MARK: - T9 (九宫格) Pinyin Decoding

    public static func letterToT9Digit(_ ch: Character) -> Character? {
        switch ch.lowercased().first ?? " " {
        case "a", "b", "c": return "2"
        case "d", "e", "f": return "3"
        case "g", "h", "i": return "4"
        case "j", "k", "l": return "5"
        case "m", "n", "o": return "6"
        case "p", "q", "r", "s": return "7"
        case "t", "u", "v": return "8"
        case "w", "x", "y", "z": return "9"
        default: return nil
        }
    }

    public static func pinyinToT9Digits(_ pinyin: String) -> String {
        var digits = ""
        for ch in pinyin.lowercased() {
            if let d = letterToT9Digit(ch) {
                digits.append(d)
            }
        }
        return digits
    }

    private static let t9ToSyllablesMap: [String: [String]] = {
        var map: [String: [String]] = [:]
        for s in PinyinSyllableParser.validSyllables {
            let d = pinyinToT9Digits(s)
            map[d, default: []].append(s)
        }
        for (k, v) in map {
            map[k] = v.sorted()
        }
        return map
    }()

    private static let t9SyllableStartSet: Set<String> = {
        var prefixes = Set<String>()
        for d in t9ToSyllablesMap.keys {
            for len in 1...d.count {
                prefixes.insert(String(d.prefix(len)))
            }
        }
        return prefixes
    }()

    public static func syllablesForT9Digits(_ digits: String) -> [String] {
        let firstSeg = digits
            .split(separator: "'", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        let clean = firstSeg.filter { $0 >= "2" && $0 <= "9" }
        guard !clean.isEmpty else { return [] }

        var result: [String] = []
        var seen = Set<String>()
        func addAll(_ items: [String]) {
            for s in items where seen.insert(s).inserted {
                result.append(s)
            }
        }

        // 1. Exact full-segment syllable matches
        if let exact = t9ToSyllablesMap[clean] {
            addAll(exact)
        }

        // 2. Valid starting syllable prefixes (e.g. "64426" -> "mi", "ni")
        if clean.count >= 2 {
            let maxPrefix = min(6, clean.count - 1)
            for len in stride(from: maxPrefix, through: 2, by: -1) {
                let prefixSub = String(clean.prefix(len))
                let remainder = String(clean.dropFirst(len))
                if let matches = t9ToSyllablesMap[prefixSub],
                   t9SyllableStartSet.contains(String(remainder.prefix(min(6, remainder.count)))) {
                    addAll(matches)
                }
            }
        }

        // 3. Fallback single-vowel syllables ("a", "o", "e") only if no multi-letter syllable found
        if result.isEmpty, clean.count >= 2 {
            let firstDigit = String(clean.prefix(1))
            let remainder = String(clean.dropFirst(1))
            if let matches = t9ToSyllablesMap[firstDigit],
               t9SyllableStartSet.contains(String(remainder.prefix(min(6, remainder.count)))) {
                addAll(matches)
            }
        }

        return result
    }

    private func rankT9SyllablesByFrequency(_ syllables: [String]) -> [String] {
        guard syllables.count > 1, let db = bundleDB else { return syllables }
        let placeholders = Array(repeating: "?", count: syllables.count).joined(separator: ",")
        let sql = "SELECT pinyin, MAX(freq) as mf FROM chars WHERE pinyin IN (\(placeholders)) GROUP BY pinyin;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return syllables }
        defer { sqlite3_finalize(stmt) }
        for (idx, s) in syllables.enumerated() {
            sqlite3_bind_text(stmt, Int32(idx + 1), s, -1, SQLITE_TRANSIENT)
        }
        var freqs: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let p = sqlite3_column_text(stmt, 0) {
                freqs[String(cString: p)] = Int(sqlite3_column_int64(stmt, 1))
            }
        }
        return syllables.enumerated().sorted { lhs, rhs in
            let fl = freqs[lhs.element] ?? 0
            let fr = freqs[rhs.element] ?? 0
            if fl != fr { return fl > fr }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    public func queryT9Candidates(
        digits: String,
        pinyinFilter: String? = nil,
        personalWords: [PersonalWord] = [],
        limit: Int = 40,
        includeSentenceDecoding: Bool = true,
        isCancelled: (() -> Bool)? = nil
    ) -> (syllableOptions: [String], candidates: [PinyinCandidate]) {
        let cleanDigits = digits.filter { ($0 >= "2" && $0 <= "9") || $0 == "'" }
        guard !cleanDigits.isEmpty else { return ([], []) }

        var pureChars: [Character] = []
        var obligatorySplits = Set<Int>()
        for ch in cleanDigits {
            if ch == "'" {
                if !pureChars.isEmpty {
                    obligatorySplits.insert(pureChars.count)
                }
            } else {
                pureChars.append(ch)
            }
        }
        let pureDigits = String(pureChars)
        guard !pureDigits.isEmpty else { return ([], []) }

        let cacheKey = "\(pureDigits)|\(pinyinFilter ?? "")|\(personalWords.count)|\(includeSentenceDecoding ? 1 : 0)"

        dbLock.lock()
        defer { dbLock.unlock() }
        if let cached = t9Cache[cacheKey] {
            return cached
        }

            var results: [PinyinCandidate] = []
            var seenTexts = Set<String>()

            func finishResult(_ sylls: [String], _ cands: [PinyinCandidate]) -> ([String], [PinyinCandidate]) {
                let pair = (sylls, cands)
                if t9Cache.count >= t9CacheCapacity, let oldest = t9CacheKeys.first {
                    t9CacheKeys.removeFirst()
                    t9Cache.removeValue(forKey: oldest)
                }
                t9Cache[cacheKey] = pair
                t9CacheKeys.append(cacheKey)
                return pair
            }

            func appendCandidate(_ cand: PinyinCandidate) {
                guard results.count < limit else { return }
                let key = "\(cand.text)#\(cand.consumedChars)"
                if !seenTexts.contains(key) {
                    seenTexts.insert(key)
                    results.append(cand)
                }
            }

            // Parse locked syllable prefix if user chose syllables via 选拼音 (e.g. "ni" or "ni'hao")
            var lockedSpans: [(start: Int, end: Int, syllable: String)] = []
            var lockedDigitCount = 0
            var lockedPinyinNoSep = ""
            if let filter = pinyinFilter?.lowercased(), !filter.isEmpty {
                let parts = filter.split(separator: "'").map { $0.filter { $0 >= "a" && $0 <= "z" } }.filter { !$0.isEmpty }
                var offset = 0
                var validLock = !parts.isEmpty
                for part in parts {
                    let partDigits = Self.pinyinToT9Digits(part)
                    let end = offset + partDigits.count
                    if end <= pureDigits.count,
                       String(pureDigits.dropFirst(offset).prefix(partDigits.count)) == partDigits {
                        lockedSpans.append((offset, end, part))
                        offset = end
                        lockedPinyinNoSep += part
                    } else {
                        validLock = false
                        break
                    }
                }
                if validLock {
                    lockedDigitCount = offset
                } else {
                    lockedSpans.removeAll()
                    lockedPinyinNoSep = ""
                }
            }

            let unpinnedDigits = String(pureDigits.dropFirst(lockedDigitCount))
            let syllableSlice: String
            if let nextSplit = obligatorySplits.filter({ $0 > lockedDigitCount }).min() {
                syllableSlice = String(pureDigits.dropFirst(lockedDigitCount).prefix(nextSplit - lockedDigitCount))
            } else {
                syllableSlice = unpinnedDigits
            }
            let rawSyllables: [String]
            if unpinnedDigits.isEmpty && lockedSpans.count == 1 {
                rawSyllables = Self.syllablesForT9Digits(pureDigits)
            } else {
                rawSyllables = Self.syllablesForT9Digits(syllableSlice)
            }
            let syllableOptions = rankT9SyllablesByFrequency(rawSyllables)

                // When filter covers the whole input with one or more exact syllables
            if !lockedSpans.isEmpty && unpinnedDigits.isEmpty {
                let filterPy = lockedSpans.map(\.syllable).joined(separator: "'")
                let filterClean = lockedPinyinNoSep

                for entry in personalWords where !entry.pinyinHint.isEmpty {
                    let hintClean = entry.pinyinHint.lowercased().filter { $0 >= "a" && $0 <= "z" }
                    if hintClean == filterClean {
                        appendCandidate(PinyinCandidate(
                            text: entry.term,
                            consumedChars: pureDigits.count,
                            displayPinyin: filterPy,
                            isFullMatch: true,
                            source: .personalDictionary
                        ))
                    }
                }
                for item in fetchOnlineWords(pinyin: filterClean, limit: 8) {
                    appendCandidate(PinyinCandidate(
                        text: item.word,
                        consumedChars: pureDigits.count,
                        displayPinyin: filterPy,
                        isFullMatch: true,
                        source: .personalDictionary
                    ))
                }
                for (word, _) in fetchUserPhrases(pinyin: filterClean, limit: 8) {
                    appendCandidate(PinyinCandidate(
                        text: word,
                        consumedChars: pureDigits.count,
                        displayPinyin: filterPy,
                        isFullMatch: true,
                        source: .userLearned
                    ))
                }
                for (hanzi, _) in fetchUserChars(pinyin: filterClean, limit: 12) {
                    appendCandidate(PinyinCandidate(
                        text: hanzi,
                        consumedChars: pureDigits.count,
                        displayPinyin: filterPy,
                        isFullMatch: true,
                        source: .userLearned
                    ))
                }
                for (word, _) in fetchBundlePhrases(pinyin: filterClean, limit: 14) {
                    appendCandidate(PinyinCandidate(
                        text: word,
                        consumedChars: pureDigits.count,
                        displayPinyin: filterPy,
                        isFullMatch: true,
                        source: .exactPhrase
                    ))
                }
                if lockedSpans.count == 1 {
                    for (hanzi, _) in fetchBundleChars(pinyin: filterClean, limit: 24) {
                        appendCandidate(PinyinCandidate(
                            text: hanzi,
                            consumedChars: pureDigits.count,
                            displayPinyin: filterPy,
                            isFullMatch: true,
                            source: .singleChar
                        ))
                    }
                } else if includeSentenceDecoding {
                    let decoded = decodeT9ViterbiSentences(
                        pureDigits: pureDigits,
                        obligatorySplits: obligatorySplits,
                        lockedSpans: lockedSpans,
                        topK: 4,
                        isCancelled: isCancelled
                    )
                    for item in decoded {
                        appendCandidate(PinyinCandidate(
                            text: item.text,
                            consumedChars: pureDigits.count,
                            displayPinyin: item.pinyin,
                            isFullMatch: true,
                            source: .viterbiSentence
                        ))
                    }
                }
                return finishResult(syllableOptions, results)
            }

            // 0. User Learned Phrases & Characters matching full T9 digits (TOP PRIORITY: Boosted to #1)
            let userPhrases = fetchUserPhrasesByT9(t9: pureDigits, limit: 10)
            for item in userPhrases {
                if !lockedPinyinNoSep.isEmpty && !item.pinyin.hasPrefix(lockedPinyinNoSep) {
                    continue
                }
                appendCandidate(PinyinCandidate(
                    text: item.word,
                    consumedChars: pureDigits.count,
                    displayPinyin: item.pinyin,
                    isFullMatch: true,
                    source: .userLearned
                ))
            }

            if pureDigits.count <= 6 && lockedSpans.count <= 1 && obligatorySplits.isEmpty {
                let userChars = fetchUserCharsByT9(t9: pureDigits, limit: 12)
                for item in userChars {
                    if !lockedPinyinNoSep.isEmpty && item.pinyin != lockedPinyinNoSep {
                        continue
                    }
                    appendCandidate(PinyinCandidate(
                        text: item.hanzi,
                        consumedChars: pureDigits.count,
                        displayPinyin: item.pinyin,
                        isFullMatch: true,
                        source: .userLearned
                    ))
                }
            }

            // 1. Exact Personal Dictionary & Online Lexicon matches matching full T9 digits
            let sortedPersonal = personalWords
                .filter { !$0.pinyinHint.isEmpty }
                .sorted { $0.usageCount > $1.usageCount }
            var customExactInitials: [PinyinCandidate] = []
            var personalPrefixPool: [PinyinCandidate] = []
            for entry in sortedPersonal {
                let hintDigits = Self.pinyinToT9Digits(entry.pinyinHint)
                let hintClean = entry.pinyinHint.lowercased().filter { $0 >= "a" && $0 <= "z" }
                let matchesFilter = lockedPinyinNoSep.isEmpty || hintClean.hasPrefix(lockedPinyinNoSep)
                guard matchesFilter else { continue }
                if hintDigits == pureDigits {
                    appendCandidate(PinyinCandidate(
                        text: entry.term,
                        consumedChars: pureDigits.count,
                        displayPinyin: entry.pinyinHint,
                        isFullMatch: true,
                        source: .personalDictionary
                    ))
                } else if pureDigits.count >= 2 && hintDigits.hasPrefix(pureDigits) {
                    personalPrefixPool.append(PinyinCandidate(
                        text: entry.term,
                        consumedChars: pureDigits.count,
                        displayPinyin: entry.pinyinHint,
                        isFullMatch: false,
                        source: .personalDictionary
                    ))
                }
            }

            for item in fetchOnlineWordsByT9(t9: pureDigits, limit: 10) {
                if !lockedPinyinNoSep.isEmpty && !item.pinyin.hasPrefix(lockedPinyinNoSep) { continue }
                appendCandidate(PinyinCandidate(
                    text: item.word,
                    consumedChars: pureDigits.count,
                    displayPinyin: item.pinyin,
                    isFullMatch: true,
                    source: .personalDictionary
                ))
            }

            if pureDigits.count >= 2 {
                for item in fetchOnlineWordsByT9Initials(t9: pureDigits, limit: 6) {
                    if !lockedPinyinNoSep.isEmpty && !item.pinyin.hasPrefix(lockedPinyinNoSep) { continue }
                    customExactInitials.append(PinyinCandidate(
                        text: item.word,
                        consumedChars: pureDigits.count,
                        displayPinyin: item.pinyin,
                        isFullMatch: true,
                        source: .personalDictionary
                    ))
                }
                for item in fetchUserPhrasesByT9Initials(t9: pureDigits, limit: 6) {
                    if !lockedPinyinNoSep.isEmpty && !item.pinyin.hasPrefix(lockedPinyinNoSep) { continue }
                    customExactInitials.append(PinyinCandidate(
                        text: item.word,
                        consumedChars: pureDigits.count,
                        displayPinyin: item.pinyin,
                        isFullMatch: true,
                        source: .userLearned
                    ))
                }
                for item in fetchOnlineWordsByT9Prefix(prefix: pureDigits, limit: 8) {
                    if !lockedPinyinNoSep.isEmpty && !item.pinyin.hasPrefix(lockedPinyinNoSep) { continue }
                    personalPrefixPool.append(PinyinCandidate(
                        text: item.word,
                        consumedChars: pureDigits.count,
                        displayPinyin: item.pinyin,
                        isFullMatch: false,
                        source: .personalDictionary
                    ))
                }
                for item in fetchUserPhrasesByT9Prefix(prefix: pureDigits, limit: 8) {
                    if !lockedPinyinNoSep.isEmpty && !item.pinyin.hasPrefix(lockedPinyinNoSep) { continue }
                    personalPrefixPool.append(PinyinCandidate(
                        text: item.word,
                        consumedChars: pureDigits.count,
                        displayPinyin: item.pinyin,
                        isFullMatch: false,
                        source: .userLearned
                    ))
                }
            }

            // Custom exact initials (e.g. "lwy" / "599") and 4+ digit prefix matches rank ahead of bundle dictionary.
            // Short 1-syllable inputs keep bundle exact chars ("今" at "546") ahead of long prefix expansions.
            if pureDigits.count >= 3 {
                for cand in customExactInitials {
                    appendCandidate(cand)
                }
            }
            if pureDigits.count >= 4 {
                for cand in personalPrefixPool {
                    appendCandidate(cand)
                }
            }

            // 2 & 3. Exact phrases & single characters from bundled dictionary matching full T9 digits
            let exactPhrases = fetchBundlePhrasesByT9(t9: pureDigits, limit: 20).filter {
                lockedPinyinNoSep.isEmpty || $0.pinyin.hasPrefix(lockedPinyinNoSep)
            }
            let exactChars: [(hanzi: String, freq: Int, pinyin: String)]
            if pureDigits.count <= 6 && lockedSpans.count <= 1 && obligatorySplits.isEmpty {
                exactChars = fetchBundleCharsByT9(t9: pureDigits, limit: 24).filter {
                    lockedPinyinNoSep.isEmpty || $0.pinyin == lockedPinyinNoSep
                }
            } else {
                exactChars = []
            }

            if exactChars.isEmpty {
                for item in exactPhrases {
                    appendCandidate(PinyinCandidate(
                        text: item.word,
                        consumedChars: pureDigits.count,
                        displayPinyin: item.pinyin,
                        isFullMatch: true,
                        source: .exactPhrase
                    ))
                }
            } else {
                // High-frequency exact phrases (>= 5000) rank ahead of chars, while common single chars ("中" 243k) beat obscure 5-digit words ("印尼" 1k).
                for item in exactPhrases where item.freq >= 5000 {
                    appendCandidate(PinyinCandidate(
                        text: item.word,
                        consumedChars: pureDigits.count,
                        displayPinyin: item.pinyin,
                        isFullMatch: true,
                        source: .exactPhrase
                    ))
                }
                for item in exactChars {
                    appendCandidate(PinyinCandidate(
                        text: item.hanzi,
                        consumedChars: pureDigits.count,
                        displayPinyin: item.pinyin,
                        isFullMatch: true,
                        source: .singleChar
                    ))
                }
                for item in exactPhrases where item.freq < 5000 {
                    appendCandidate(PinyinCandidate(
                        text: item.word,
                        consumedChars: pureDigits.count,
                        displayPinyin: item.pinyin,
                        isFullMatch: true,
                        source: .exactPhrase
                    ))
                }
            }

            if pureDigits.count < 3 {
                for cand in customExactInitials {
                    appendCandidate(cand)
                }
            }
            if pureDigits.count < 4 {
                for cand in personalPrefixPool {
                    appendCandidate(cand)
                }
            }

            // 4. Merge non-exact prefix & initials phrases by frequency score so high-freq prefix words (e.g. "966" -> "我们" 260k)
            // rank far ahead of obscure initials ("笑眯眯" 227) and synthetic Viterbi splits.
            var rankedExpansion: [(word: String, score: Double, pinyin: String, isInitial: Bool)] = []
            if pureDigits.count >= 3 && lockedSpans.isEmpty {
                for item in fetchBundlePhrasesByT9Prefix(prefix: pureDigits, limit: 16) {
                    rankedExpansion.append((item.word, Double(item.freq), item.pinyin, false))
                }
            }
            if pureDigits.count >= 2 && pureDigits.count <= 6 {
                let initialFirst = lockedPinyinNoSep.first.map(String.init)
                for item in fetchBundlePhrasesByT9Initials(t9: pureDigits, limit: 12) {
                    if let firstChar = initialFirst, !item.pinyin.hasPrefix(firstChar) { continue }
                    rankedExpansion.append((item.word, Double(item.freq) * 1.5, item.pinyin, true))
                }
            }
            rankedExpansion.sort { $0.score > $1.score }

            for item in rankedExpansion where item.score >= 3000 {
                appendCandidate(PinyinCandidate(
                    text: item.word,
                    consumedChars: pureDigits.count,
                    displayPinyin: item.pinyin,
                    isFullMatch: item.isInitial,
                    source: .prefixOrInitial
                ))
            }

            // 5. Multi-syllable T9 Viterbi sentence decoding (4+ digits or explicit apostrophe split)
            if includeSentenceDecoding && (pureDigits.count >= 4 || !obligatorySplits.isEmpty) {
                let decoded = decodeT9ViterbiSentences(
                    pureDigits: pureDigits,
                    obligatorySplits: obligatorySplits,
                    lockedSpans: lockedSpans,
                    topK: 4,
                    isCancelled: isCancelled
                )
                for item in decoded {
                    appendCandidate(PinyinCandidate(
                        text: item.text,
                        consumedChars: pureDigits.count,
                        displayPinyin: item.pinyin,
                        isFullMatch: true,
                        source: .viterbiSentence
                    ))
                }
            }

            for item in rankedExpansion where item.score < 3000 {
                appendCandidate(PinyinCandidate(
                    text: item.word,
                    consumedChars: pureDigits.count,
                    displayPinyin: item.pinyin,
                    isFullMatch: item.isInitial,
                    source: .prefixOrInitial
                ))
            }

            // 6. Index-0 partial prefix phrases & single chars (allows step-by-step selection on long input)
            if pureDigits.count >= 3 && results.count < limit {
                if !lockedSpans.isEmpty {
                    let lockedText = lockedPinyinNoSep
                    let lockedCount = lockedDigitCount
                    if lockedSpans.count >= 2 {
                        for (word, _) in fetchBundlePhrases(pinyin: lockedText, limit: 4) {
                            appendCandidate(PinyinCandidate(
                                text: word,
                                consumedChars: lockedCount,
                                displayPinyin: lockedText,
                                isFullMatch: false,
                                source: .exactPhrase
                            ))
                        }
                    } else if let firstSyl = lockedSpans.first?.syllable {
                        for (hanzi, _) in fetchBundleChars(pinyin: firstSyl, limit: 6) {
                            appendCandidate(PinyinCandidate(
                                text: hanzi,
                                consumedChars: lockedCount,
                                displayPinyin: firstSyl,
                                isFullMatch: false,
                                source: .singleChar
                            ))
                        }
                    }
                } else {
                    let maxPhrasePrefix = min(pureDigits.count - 1, 9)
                    if maxPhrasePrefix >= 4 {
                        for subLen in stride(from: maxPhrasePrefix, through: 4, by: -1) {
                            let prefixT9 = String(pureDigits.prefix(subLen))
                            let hits = fetchBundlePhrasesByT9(t9: prefixT9, limit: 3)
                            for item in hits {
                                appendCandidate(PinyinCandidate(
                                    text: item.word,
                                    consumedChars: subLen,
                                    displayPinyin: item.pinyin,
                                    isFullMatch: false,
                                    source: .exactPhrase
                                ))
                            }
                            if results.count >= limit { break }
                        }
                    }

                    let firstBoundary = obligatorySplits.min() ?? pureDigits.count
                    let maxCharPrefix = min(6, min(firstBoundary, pureDigits.count - 1))
                    if maxCharPrefix >= 1 {
                        for subLen in stride(from: maxCharPrefix, through: 1, by: -1) {
                            let prefixT9 = String(pureDigits.prefix(subLen))
                            guard Self.t9ToSyllablesMap[prefixT9] != nil else { continue }
                            for item in fetchBundleCharsByT9(t9: prefixT9, limit: 6) {
                                appendCandidate(PinyinCandidate(
                                    text: item.hanzi,
                                    consumedChars: subLen,
                                    displayPinyin: item.pinyin,
                                    isFullMatch: false,
                                    source: .singleChar
                                ))
                            }
                        }
                    }
                }
            }

        return finishResult(syllableOptions, results)
    }

    private func decodeT9ViterbiSentences(
        pureDigits: String,
        obligatorySplits: Set<Int>,
        lockedSpans: [(start: Int, end: Int, syllable: String)],
        topK: Int,
        isCancelled: (() -> Bool)? = nil
    ) -> [(text: String, pinyin: String)] {
        let chars = Array(pureDigits)
        let n = chars.count
        guard n >= 2 else { return [] }

        struct T9Span: Hashable {
            let start: Int
            let end: Int
            let digits: String
            let lockedSyllable: String?
        }

        struct T9Edge {
            let start: Int
            let end: Int
            let text: String
            let pinyin: String
            let score: Double
        }

        struct T9Path {
            let text: String
            let pinyin: String
            let score: Double
        }

        let logCorpusMass = 7.0
        var spansByStart = Array(repeating: [T9Span](), count: n)
        let lockedEnd = lockedSpans.last?.end ?? 0

        for lock in lockedSpans {
            let sub = String(chars[lock.start..<lock.end])
            spansByStart[lock.start].append(T9Span(start: lock.start, end: lock.end, digits: sub, lockedSyllable: lock.syllable))
        }

        if lockedEnd < n {
            for i in lockedEnd..<n {
                for len in 1...min(6, n - i) {
                    let end = i + len
                    let crossesSplit = obligatorySplits.contains { $0 > i && $0 < end }
                    if crossesSplit { continue }
                    let sub = String(chars[i..<end])
                    if Self.t9ToSyllablesMap[sub] != nil {
                        spansByStart[i].append(T9Span(start: i, end: end, digits: sub, lockedSyllable: nil))
                    }
                }
            }
        }

        var transitions = Array(repeating: [T9Edge](), count: n)
        var bestEdgeIndex: [[String: Int]] = Array(repeating: [:], count: n)

        func addEdge(start: Int, end: Int, text: String, pinyin: String, score: Double) {
            let key = "\(end)#\(text)"
            if let existing = bestEdgeIndex[start][key] {
                if score > transitions[start][existing].score {
                    transitions[start][existing] = T9Edge(start: start, end: end, text: text, pinyin: pinyin, score: score)
                }
            } else {
                bestEdgeIndex[start][key] = transitions[start].count
                transitions[start].append(T9Edge(start: start, end: end, text: text, pinyin: pinyin, score: score))
            }
        }

        // Single-syllable T9 char edges
        for start in 0..<n {
            if isCancelled?() == true { return [] }
            for span in spansByStart[start] {
                if let fixedSyl = span.lockedSyllable {
                    var rank = 0
                    for (hanzi, freq) in fetchBundleChars(pinyin: fixedSyl, limit: 3) {
                        let s = log10(Double(max(freq, 1)) + 1.0) - logCorpusMass + 0.1 - Double(rank) * 0.25
                        addEdge(start: span.start, end: span.end, text: hanzi, pinyin: fixedSyl, score: s)
                        rank += 1
                    }
                } else {
                    let isIsolatedBySplit = obligatorySplits.contains(span.start) || obligatorySplits.contains(span.end)
                    let unsplitSingleDigitPenalty = (span.digits.count == 1 && !isIsolatedBySplit) ? 2.2 : 0.0
                    var rank = 0
                    for item in fetchBundleCharsByT9(t9: span.digits, limit: 4) {
                        let s = log10(Double(max(item.freq, 1)) + 1.0) - logCorpusMass - Double(rank) * 0.25 - unsplitSingleDigitPenalty
                        addEdge(start: span.start, end: span.end, text: item.hanzi, pinyin: item.pinyin, score: s)
                        rank += 1
                        if rank >= 3 { break }
                    }
                }
            }
        }

        // Multi-syllable T9 phrase edges (2..4 syllables)
        var pathLockedPrefix = ""
        var phraseLookupCount = 0
        func collectMulti(start: Int, currentOffset: Int, depth: Int, expectedSyllables: Int) {
            if phraseLookupCount >= 48 { return }
            if isCancelled?() == true { return }
            if depth >= 2 {
                let subDigits = String(chars[start..<currentOffset])
                phraseLookupCount += 1
                for item in fetchUserPhrasesByT9(t9: subDigits, limit: 2) where item.word.count == expectedSyllables {
                    if !pathLockedPrefix.isEmpty && !item.pinyin.hasPrefix(pathLockedPrefix) { continue }
                    let s = log10(Double(item.freq * 5000 + 1000)) - logCorpusMass + 0.9 + Double(min(depth - 2, 2)) * 0.22
                    addEdge(start: start, end: currentOffset, text: item.word, pinyin: item.pinyin, score: s)
                }
                for item in fetchOnlineWordsByT9(t9: subDigits, limit: 2) where item.word.count == expectedSyllables {
                    if !pathLockedPrefix.isEmpty && !item.pinyin.hasPrefix(pathLockedPrefix) { continue }
                    let s = log10(Double(item.weight * 3000 + 1000)) - logCorpusMass + 0.85 + Double(min(depth - 2, 2)) * 0.22
                    addEdge(start: start, end: currentOffset, text: item.word, pinyin: item.pinyin, score: s)
                }
                var rank = 0
                for item in fetchBundlePhrasesByT9(t9: subDigits, limit: 5) {
                    if !pathLockedPrefix.isEmpty && !item.pinyin.hasPrefix(pathLockedPrefix) {
                        continue
                    }
                    let wordCharCount = item.word.count
                    if wordCharCount == expectedSyllables {
                        let s = log10(Double(max(item.freq, 1)) + 1.0) - logCorpusMass + 0.65 + Double(min(depth - 2, 2)) * 0.22 - Double(rank) * 0.25
                        addEdge(start: start, end: currentOffset, text: item.word, pinyin: item.pinyin, score: s)
                        rank += 1
                        if rank >= 3 { break }
                    }
                }
            }
            guard depth < 4, currentOffset < n else { return }
            for nextSpan in spansByStart[currentOffset] {
                let prevPrefix = pathLockedPrefix
                if let fixedSyl = nextSpan.lockedSyllable {
                    pathLockedPrefix += fixedSyl
                }
                collectMulti(start: start, currentOffset: nextSpan.end, depth: depth + 1, expectedSyllables: expectedSyllables + 1)
                pathLockedPrefix = prevPrefix
            }
        }

        for i in 0..<n where !spansByStart[i].isEmpty {
            if isCancelled?() == true { return [] }
            pathLockedPrefix = ""
            collectMulti(start: i, currentOffset: i, depth: 0, expectedSyllables: 0)
        }

        func prune(_ list: [T9Path], maxKeep: Int) -> [T9Path] {
            let sorted = list.sorted { $0.score > $1.score }
            var seen = Set<String>()
            var out: [T9Path] = []
            for p in sorted where seen.insert(p.text).inserted {
                out.append(p)
                if out.count >= maxKeep { break }
            }
            return out
        }

        var beams = Array(repeating: [T9Path](), count: n + 1)
        beams[0] = [T9Path(text: "", pinyin: "", score: 0)]

        for i in 0..<n {
            guard !beams[i].isEmpty, !transitions[i].isEmpty else { continue }
            if beams[i].count > 8 {
                beams[i] = prune(beams[i], maxKeep: 8)
            }
            for path in beams[i] {
                for edge in transitions[i] {
                    let joinedPy = path.pinyin.isEmpty ? edge.pinyin : "\(path.pinyin) \(edge.pinyin)"
                    beams[edge.end].append(T9Path(text: path.text + edge.text, pinyin: joinedPy, score: path.score + edge.score))
                }
            }
            for j in (i + 1)...n where beams[j].count > 20 {
                beams[j] = prune(beams[j], maxKeep: 8)
            }
        }

        let finished = beams[n].sorted { $0.score > $1.score }
        var seen = Set<String>()
        var output: [(text: String, pinyin: String)] = []
        for p in finished where seen.insert(p.text).inserted {
            output.append((p.text, p.pinyin))
            if output.count >= topK { break }
        }
        return output
    }

    // MARK: - English Prefix Completions

    public func queryEnglishCompletions(
        prefix: String,
        personalWords: [PersonalWord] = [],
        limit: Int = 8
    ) -> [String] {
        let lower = prefix.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return [] }

        dbLock.lock()
        defer { dbLock.unlock() }
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

            // 2. Online & User learned English words
            if let udb = userDB {
                let onlineEnSQL = "SELECT word FROM online_words WHERE word >= ? AND word < ? COLLATE NOCASE ORDER BY weight DESC LIMIT ?;"
                var oStmt: OpaquePointer?
                if sqlite3_prepare_v2(udb, onlineEnSQL, -1, &oStmt, nil) == SQLITE_OK {
                    defer { sqlite3_finalize(oStmt) }
                    sqlite3_bind_text(oStmt, 1, lower, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(oStmt, 2, nextPrefixBound(lower), -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int(oStmt, 3, Int32(limit))
                    while sqlite3_step(oStmt) == SQLITE_ROW {
                        if let cStr = sqlite3_column_text(oStmt, 0) {
                            let w = String(cString: cStr)
                            if w.range(of: "^[A-Za-z]", options: .regularExpression) != nil {
                                add(w)
                            }
                        }
                    }
                }

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

    // MARK: - Viterbi / Beam Search Decoding

    private struct ViterbiPath {
        let text: String
        let score: Double
    }

    private func decodeViterbiSentences(
        cleanInput: String,
        seg: PinyinSegmentationResult,
        fuzzy: Bool,
        topK: Int,
        isCancelled: (() -> Bool)? = nil
    ) -> [String] {
        let chars = Array(cleanInput)
        let n = chars.count
        guard n > 1 else { return [] }

        // Collect all valid syllable spans and multi-syllable spans up to 5 syllables
        let fullEdges = seg.latticeEdges.filter { !$0.isPartial }
        if fullEdges.isEmpty {
            return []
        }

        let primaryEdges = Set(seg.primarySyllables)
        // Negative log10 corpus normalization keeps every single-char cost < 0 so valid longer syllables beat bogus splits
        let logCorpusMass = 7.0

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
        var bestEdgeIndex: [[String: Int]] = Array(repeating: [:], count: n)

        func addTransition(start: Int, end: Int, text: String, score: Double) {
            let key = "\(end)#\(text)"
            if let existingIdx = bestEdgeIndex[start][key] {
                if score > transitions[start][existingIdx].score {
                    transitions[start][existingIdx] = LatticeNodeEdge(start: start, end: end, text: text, score: score)
                }
            } else {
                bestEdgeIndex[start][key] = transitions[start].count
                transitions[start].append(LatticeNodeEdge(start: start, end: end, text: text, score: score))
            }
        }

        // Single-syllable character edges
        for edge in fullEdges {
            if isCancelled?() == true { return [] }
            let variants = fuzzy ? PinyinSyllableParser.fuzzyVariants(for: edge.text) : [edge.text]
            let primBonus = primaryEdges.contains(edge) ? 0.25 : 0.0
            let singleVowelPenalty = (edge.text.count == 1 && ["a", "o", "e", "m", "n"].contains(edge.text)) ? 2.0 : 0.0
            var charPool: [(word: String, score: Double)] = []
            for v in variants {
                let fuzzyPenalty = (v == edge.text) ? 0.0 : 0.45
                for (hanzi, freq) in fetchBundleChars(pinyin: v, limit: 3) {
                    let base = log10(Double(max(freq, 1)) + 1.0) - logCorpusMass + primBonus - fuzzyPenalty - singleVowelPenalty
                    charPool.append((hanzi, base))
                }
            }
            charPool.sort { $0.score > $1.score }
            var seenChars = Set<String>()
            var rank = 0
            for item in charPool where seenChars.insert(item.word).inserted {
                let s = item.score - Double(rank) * 0.25
                addTransition(start: edge.startOffset, end: edge.endOffset, text: item.word, score: s)
                rank += 1
                if rank >= 3 { break }
            }
        }

        // Multi-syllable phrase edges (2..5 syllables chained along valid spans)
        var pathSyllables: [SyllableSpan] = []
        func collectMultiEdges(start: Int, currentOffset: Int, depth: Int) {
            if isCancelled?() == true { return }
            if depth >= 2 {
                let sub = String(chars[start..<currentOffset])
                let sylString = pathSyllables.map(\.text).joined(separator: " ")
                let primMatches = pathSyllables.reduce(0) { $0 + (primaryEdges.contains($1) ? 1 : 0) }
                let primBonus = 0.25 * Double(primMatches)

                let userHits = fetchUserPhrases(pinyin: sub, limit: 2)
                for (w, f) in userHits where w.count == depth {
                    let s = log10(Double(f * 5000 + 1000)) - logCorpusMass + 0.9 + Double(min(depth - 2, 3)) * 0.2 + primBonus
                    addTransition(start: start, end: currentOffset, text: w, score: s)
                }

                for item in fetchOnlineWords(pinyin: sub, limit: 2) where item.word.count == depth {
                    let s = log10(Double(item.weight * 3000 + 1000)) - logCorpusMass + 0.85 + Double(min(depth - 2, 3)) * 0.2 + primBonus
                    addTransition(start: start, end: currentOffset, text: item.word, score: s)
                }

                let bundleHits = fetchBundlePhrasesWithSyllables(pinyin: sub, limit: 6)
                var phraseRank = 0
                for item in bundleHits {
                    if !item.syllables.isEmpty && item.syllables != sylString {
                        continue
                    }
                    let s = log10(Double(max(item.freq, 1)) + 1.0) - logCorpusMass + 0.6 + Double(min(depth - 2, 3)) * 0.2 - Double(phraseRank) * 0.25 + primBonus
                    addTransition(start: start, end: currentOffset, text: item.word, score: s)
                    phraseRank += 1
                    if phraseRank >= 3 { break }
                }
            }
            guard depth < 5, currentOffset < n else { return }
            for nextSpan in singleStarts[currentOffset] {
                pathSyllables.append(nextSpan)
                collectMultiEdges(start: start, currentOffset: nextSpan.endOffset, depth: depth + 1)
                pathSyllables.removeLast()
            }
        }

        for i in 0..<n where !singleStarts[i].isEmpty {
            if isCancelled?() == true { return [] }
            collectMultiEdges(start: i, currentOffset: i, depth: 0)
        }

        // Beam search DP across 0...n
        func pruneBeams(_ list: [ViterbiPath], maxKeep: Int) -> [ViterbiPath] {
            let sorted = list.sorted { $0.score > $1.score }
            var seenTexts = Set<String>()
            var deduped: [ViterbiPath] = []
            for p in sorted where seenTexts.insert(p.text).inserted {
                deduped.append(p)
                if deduped.count >= maxKeep { break }
            }
            return deduped
        }

        var beams = Array(repeating: [ViterbiPath](), count: n + 1)
        beams[0] = [ViterbiPath(text: "", score: 0)]

        for i in 0..<n {
            guard !beams[i].isEmpty, !transitions[i].isEmpty else { continue }
            if beams[i].count > 10 {
                beams[i] = pruneBeams(beams[i], maxKeep: 10)
            }
            for path in beams[i] {
                for edge in transitions[i] {
                    let candidate = ViterbiPath(text: path.text + edge.text, score: path.score + edge.score)
                    beams[edge.end].append(candidate)
                }
            }
            for j in (i + 1)...n where beams[j].count > 24 {
                beams[j] = pruneBeams(beams[j], maxKeep: 10)
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

    private func withCachedBundleStmt<T>(_ sql: String, body: (OpaquePointer) -> [T]) -> [T] {
        guard let db = bundleDB else { return [] }
        let stmt: OpaquePointer
        if let cached = bundleStmtCache[sql] {
            stmt = cached
        } else {
            var newStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &newStmt, nil) == SQLITE_OK, let prepared = newStmt else {
                return []
            }
            bundleStmtCache[sql] = prepared
            stmt = prepared
        }
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
        return body(stmt)
    }

    private func fetchBundleChars(pinyin: String, limit: Int) -> [(String, Int)] {
        let sql = "SELECT hanzi, freq FROM chars WHERE pinyin = ? ORDER BY freq DESC LIMIT ?;"
        return withCachedBundleStmt(sql) { stmt in
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
    }

    private func fetchBundlePhrases(pinyin: String, limit: Int) -> [(String, Int)] {
        fetchBundlePhrasesWithSyllables(pinyin: pinyin, limit: limit).map { ($0.word, $0.freq) }
    }

    private func fetchBundlePhrasesWithSyllables(pinyin: String, limit: Int) -> [(word: String, freq: Int, syllables: String)] {
        let sql = "SELECT word, freq, syllables FROM phrases WHERE pinyin = ? ORDER BY freq DESC LIMIT ?;"
        return withCachedBundleStmt(sql) { stmt in
            sqlite3_bind_text(stmt, 1, pinyin, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            var rows: [(String, Int, String)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cStr = sqlite3_column_text(stmt, 0) {
                    let word = String(cString: cStr)
                    let freq = Int(sqlite3_column_int64(stmt, 1))
                    let syls = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                    rows.append((word, freq, syls))
                }
            }
            return rows
        }
    }

    private func fetchBundlePhrasesByPrefix(prefix: String, limit: Int) -> [(String, Int)] {
        let sql = "SELECT word, freq FROM phrases WHERE pinyin >= ? AND pinyin < ? ORDER BY freq DESC LIMIT ?;"
        return withCachedBundleStmt(sql) { stmt in
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
    }

    private func fetchPhrasesByInitials(initials: String, pinyinPrefix: String?, limit: Int) -> [(String, Int)] {
        let sql = "SELECT word, freq, pinyin FROM phrases WHERE initials = ? ORDER BY freq DESC LIMIT 40;"
        return withCachedBundleStmt(sql) { stmt in
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

    private func fetchBundlePhrasesByT9(t9: String, limit: Int) -> [(word: String, freq: Int, pinyin: String)] {
        let sql = "SELECT word, freq, pinyin FROM phrases WHERE t9 = ? ORDER BY freq DESC LIMIT ?;"
        return fetchBundleWordRows(sql: sql, key: t9, limit: limit)
    }

    private func fetchBundleCharsByT9(t9: String, limit: Int) -> [(hanzi: String, freq: Int, pinyin: String)] {
        let sql = "SELECT hanzi, freq, pinyin FROM chars WHERE t9 = ? ORDER BY freq DESC LIMIT ?;"
        return fetchBundleWordRows(sql: sql, key: t9, limit: limit)
            .map { (hanzi: $0.word, freq: $0.freq, pinyin: $0.pinyin) }
    }

    private func fetchBundlePhrasesByT9Initials(t9: String, limit: Int) -> [(word: String, freq: Int, pinyin: String)] {
        let sql = "SELECT word, freq, pinyin FROM phrases WHERE t9_initials = ? ORDER BY freq DESC LIMIT ?;"
        return fetchBundleWordRows(sql: sql, key: t9, limit: limit)
    }

    private func fetchBundleWordRows(sql: String, key: String, limit: Int) -> [(word: String, freq: Int, pinyin: String)] {
        withCachedBundleStmt(sql) { stmt in
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            var rows: [(word: String, freq: Int, pinyin: String)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let wStr = sqlite3_column_text(stmt, 0), let pyStr = sqlite3_column_text(stmt, 2) {
                    rows.append((String(cString: wStr), Int(sqlite3_column_int64(stmt, 1)), String(cString: pyStr)))
                }
            }
            return rows
        }
    }

    private func fetchBundlePhrasesByT9Prefix(prefix: String, limit: Int) -> [(word: String, freq: Int, pinyin: String)] {
        let sql = "SELECT word, freq, pinyin FROM phrases WHERE t9 >= ? AND t9 < ? ORDER BY freq DESC LIMIT ?;"
        return withCachedBundleStmt(sql) { stmt in
            sqlite3_bind_text(stmt, 1, prefix, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, nextPrefixBound(prefix), -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 3, Int32(limit))
            var rows: [(word: String, freq: Int, pinyin: String)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let wStr = sqlite3_column_text(stmt, 0), let pyStr = sqlite3_column_text(stmt, 2) {
                    rows.append((String(cString: wStr), Int(sqlite3_column_int64(stmt, 1)), String(cString: pyStr)))
                }
            }
            return rows
        }
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
