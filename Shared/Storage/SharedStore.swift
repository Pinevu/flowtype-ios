import Foundation
import Security

private enum KeychainSyncBridge {
    private static let serviceName = "com.flowtype.voice.shared.ipc"

    static func candidateAccessGroups(from provisioning: ProvisioningInfo) -> [String] {
        var candidates: [String] = []
        var seen = Set<String>()

        func add(_ val: String) {
            guard !val.isEmpty, !val.contains("*"), seen.insert(val).inserted else { return }
            candidates.append(val)
        }

        for raw in provisioning.keychainAccessGroups {
            if raw.hasSuffix(".*") {
                let prefix = String(raw.dropLast(1))
                add(prefix + "com.flowtype.voice.shared")
            } else if !raw.contains("*") {
                add(raw)
            }
        }

        if !provisioning.teamID.isEmpty {
            add("\(provisioning.teamID).com.flowtype.voice.shared")
        }

        return candidates
    }

    static func probeWorkingGroup(provisioning: ProvisioningInfo) -> String? {
        for group in candidateAccessGroups(from: provisioning) {
            let probeData = Data("ok".utf8)
            if write(data: probeData, key: "__flowtype_probe__", accessGroup: group),
               read(key: "__flowtype_probe__", accessGroup: group) == probeData {
                return group
            }
        }
        return nil
    }

    static func read(key: String, accessGroup: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    @discardableResult
    static func write(data: Data, key: String, accessGroup: String) -> Bool {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            return addStatus == errSecSuccess
        }
        return false
    }

    @discardableResult
    static func delete(key: String, accessGroup: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

public final class SharedStore: @unchecked Sendable {
    public static let shared = SharedStore(containerURL: nil)

    public let baseDirectory: URL
    public let isUsingAppGroup: Bool
    public let isUsingKeychainSync: Bool
    public let activeKeychainAccessGroup: String?

    public var hasSharedChannel: Bool {
        isUsingAppGroup || isUsingKeychainSync
    }

    private let lock = NSLock()
    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return enc
    }()

    private let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()

    public init(containerURL: URL? = nil) {
        if let customURL = containerURL {
            self.baseDirectory = customURL
            self.isUsingAppGroup = true
            self.isUsingKeychainSync = false
            self.activeKeychainAccessGroup = nil
        } else if let groupURL = AppConfig.activeContainerURL {
            self.baseDirectory = groupURL.appendingPathComponent("FlowTypeShared", isDirectory: true)
            self.isUsingAppGroup = true
            self.isUsingKeychainSync = false
            self.activeKeychainAccessGroup = nil
        } else {
            let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.baseDirectory = fallback.appendingPathComponent("FlowTypeShared", isDirectory: true)
            self.isUsingAppGroup = false

            if let kcGroup = KeychainSyncBridge.probeWorkingGroup(provisioning: AppConfig.provisioningInfo) {
                self.isUsingKeychainSync = true
                self.activeKeychainAccessGroup = kcGroup
            } else {
                self.isUsingKeychainSync = false
                self.activeKeychainAccessGroup = nil
            }
        }

        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    private func fileURL(_ name: String) -> URL {
        baseDirectory.appendingPathComponent(name, isDirectory: false)
    }

    // MARK: - Generic Atomic JSON Helpers

    public func readJSON<T: Decodable>(_ filename: String, as type: T.Type) -> T? {
        lock.lock()
        defer { lock.unlock() }
        if isUsingKeychainSync, let kcGroup = activeKeychainAccessGroup,
           let kcData = KeychainSyncBridge.read(key: filename, accessGroup: kcGroup),
           let decoded = try? decoder.decode(T.self, from: kcData) {
            return decoded
        }
        let url = fileURL(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    public func writeJSON<T: Encodable>(_ value: T, to filename: String) {
        lock.lock()
        defer { lock.unlock() }
        let url = fileURL(filename)
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: [.atomic])
        if isUsingKeychainSync, let kcGroup = activeKeychainAccessGroup {
            _ = KeychainSyncBridge.write(data: data, key: filename, accessGroup: kcGroup)
        }
    }

    // MARK: - AI Configuration

    public func loadConfig() -> AIConfiguration {
        readJSON("config.json", as: AIConfiguration.self) ?? AIConfiguration()
    }

    public func saveConfig(_ config: AIConfiguration) {
        writeJSON(config, to: "config.json")
    }

    // MARK: - Custom Keyboard Background

    public var customBackgroundImageURL: URL {
        fileURL("custom_keyboard_bg.jpg")
    }

    public func saveCustomBackgroundImage(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        let key = "custom_keyboard_bg.jpg"
        let url = customBackgroundImageURL
        try? data.write(to: url, options: [.atomic])
        if isUsingKeychainSync, let kcGroup = activeKeychainAccessGroup {
            _ = KeychainSyncBridge.write(data: data, key: key, accessGroup: kcGroup)
        }
    }

    public func loadCustomBackgroundImageData() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let key = "custom_keyboard_bg.jpg"
        if isUsingKeychainSync, let kcGroup = activeKeychainAccessGroup,
           let kcData = KeychainSyncBridge.read(key: key, accessGroup: kcGroup),
           !kcData.isEmpty {
            return kcData
        }
        let url = customBackgroundImageURL
        return try? Data(contentsOf: url)
    }

    public func removeCustomBackgroundImage() {
        lock.lock()
        defer { lock.unlock() }
        let key = "custom_keyboard_bg.jpg"
        try? FileManager.default.removeItem(at: customBackgroundImageURL)
        if isUsingKeychainSync, let kcGroup = activeKeychainAccessGroup {
            _ = KeychainSyncBridge.delete(key: key, accessGroup: kcGroup)
        }
    }

    // MARK: - Personal Dictionary

    public func loadDictionary() -> [PersonalWord] {
        readJSON("personal_dictionary.json", as: [PersonalWord].self) ?? []
    }

    public func saveDictionary(_ words: [PersonalWord]) {
        writeJSON(words, to: "personal_dictionary.json")
    }

    @discardableResult
    public func addOrLearnWord(
        term: String,
        pinyinHint: String = "",
        category: WordCategory = .phrase,
        autoLearned: Bool = false
    ) -> PersonalWord? {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var list = loadDictionary()
        if let idx = list.firstIndex(where: { $0.term.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            list[idx].usageCount += 1
            if !pinyinHint.isEmpty && list[idx].pinyinHint.isEmpty {
                list[idx].pinyinHint = pinyinHint.lowercased()
            }
            saveDictionary(list)
            return list[idx]
        }

        let entry = PersonalWord(
            term: trimmed,
            pinyinHint: pinyinHint.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
            category: category,
            autoLearned: autoLearned
        )
        list.insert(entry, at: 0)
        if isUsingKeychainSync && list.count > 160 {
            let manual = list.filter { !$0.autoLearned }
            var auto = list.filter { $0.autoLearned }
                .sorted { ($0.usageCount, $0.createdAt) > ($1.usageCount, $1.createdAt) }
            let autoBudget = max(40, 160 - manual.count)
            if auto.count > autoBudget {
                auto = Array(auto.prefix(autoBudget))
            }
            list = manual + auto
        }
        saveDictionary(list)
        return entry
    }

    public func deleteDictionaryWords(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let filtered = loadDictionary().filter { !ids.contains($0.id) }
        saveDictionary(filtered)
    }

    // MARK: - Online Custom Lexicon Storage (App Group + Compressed Chunked Keychain)

    private struct OnlineLexiconMeta: Codable, Sendable {
        var revision: Int64
        var updatedAt: Date
        var sourceURL: String
        var entryCount: Int
        var chunkCount: Int
    }

    private static let onlineMetaFilename = "online_lexicon_meta.json"
    private static let onlinePayloadFilename = "online_lexicon.tsv.lzfse"
    private static let onlineMetaKCKey = "online_lexicon_meta"
    private static let onlineChunkKCKeyPrefix = "online_lexicon_chunk_"
    private static let onlineChunkSizeBytes = 24 * 1024
    private static let onlineMaxChunks = 32

    public func loadOnlineLexiconRevision() -> Int64 {
        readOnlineMeta()?.revision ?? 0
    }

    public func saveOnlineLexiconSnapshot(_ snapshot: OnlineLexiconSnapshot) {
        lock.lock()
        defer { lock.unlock() }

        let oldRev = readOnlineMetaUnlocked()?.revision ?? 0
        let tsRev = Int64(Date().timeIntervalSince1970 * 1000)
        let rev = max(snapshot.revision, max(oldRev + 1, tsRev))

        var lines: [String] = []
        lines.reserveCapacity(snapshot.entries.count)
        for item in snapshot.entries {
            let cleanTerm = item.term
                .replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanTerm.isEmpty else { continue }
            let cleanPy = item.pinyin.lowercased().filter { $0 >= "a" && $0 <= "z" }
            lines.append("\(cleanTerm)\t\(cleanPy)\t\(item.weight)")
        }

        let rawData = Data(lines.joined(separator: "\n").utf8)
        let compressed = (try? (rawData as NSData).compressed(using: .lzfse) as Data) ?? rawData

        var chunksWritten = 0
        if isUsingKeychainSync, let kcGroup = activeKeychainAccessGroup {
            if !lines.isEmpty && !compressed.isEmpty {
                let chunkSize = Self.onlineChunkSizeBytes
                var offset = 0
                while offset < compressed.count && chunksWritten < Self.onlineMaxChunks {
                    let end = min(compressed.count, offset + chunkSize)
                    let slice = compressed.subdata(in: offset..<end)
                    _ = KeychainSyncBridge.write(
                        data: slice,
                        key: "\(Self.onlineChunkKCKeyPrefix)\(chunksWritten)",
                        accessGroup: kcGroup
                    )
                    chunksWritten += 1
                    offset = end
                }
            }
            for idx in chunksWritten..<Self.onlineMaxChunks {
                _ = KeychainSyncBridge.delete(
                    key: "\(Self.onlineChunkKCKeyPrefix)\(idx)",
                    accessGroup: kcGroup
                )
            }
        }

        let meta = OnlineLexiconMeta(
            revision: rev,
            updatedAt: snapshot.updatedAt,
            sourceURL: snapshot.sourceURL,
            entryCount: lines.count,
            chunkCount: chunksWritten
        )

        if let metaData = try? encoder.encode(meta) {
            try? compressed.write(to: fileURL(Self.onlinePayloadFilename), options: .atomic)
            try? metaData.write(to: fileURL(Self.onlineMetaFilename), options: .atomic)
            if isUsingKeychainSync, let kcGroup = activeKeychainAccessGroup {
                _ = KeychainSyncBridge.write(data: metaData, key: Self.onlineMetaKCKey, accessGroup: kcGroup)
            }
        }
    }

    public func clearOnlineLexiconSnapshot() {
        let rev = max(Int64(Date().timeIntervalSince1970 * 1000), loadOnlineLexiconRevision() + 1)
        saveOnlineLexiconSnapshot(
            OnlineLexiconSnapshot(revision: rev, updatedAt: Date(), sourceURL: "", entries: [])
        )
    }

    public func loadOnlineLexiconSnapshot() -> OnlineLexiconSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let meta = readOnlineMetaUnlocked() else { return nil }
        if meta.entryCount == 0 {
            return OnlineLexiconSnapshot(
                revision: meta.revision,
                updatedAt: meta.updatedAt,
                sourceURL: meta.sourceURL,
                entries: []
            )
        }

        var compressedData: Data?
        let fileMeta = readFileOnlineMetaUnlocked()
        if let fileMeta, fileMeta.revision >= meta.revision,
           let filePayload = try? Data(contentsOf: fileURL(Self.onlinePayloadFilename)) {
            compressedData = filePayload
        } else if isUsingKeychainSync, let kcGroup = activeKeychainAccessGroup, meta.chunkCount > 0 {
            var assembled = Data()
            var valid = true
            for idx in 0..<meta.chunkCount {
                if let chunk = KeychainSyncBridge.read(key: "\(Self.onlineChunkKCKeyPrefix)\(idx)", accessGroup: kcGroup) {
                    assembled.append(chunk)
                } else {
                    valid = false
                    break
                }
            }
            if valid && !assembled.isEmpty {
                compressedData = assembled
            }
        }

        if compressedData == nil {
            compressedData = try? Data(contentsOf: fileURL(Self.onlinePayloadFilename))
        }
        guard let compressed = compressedData else { return nil }

        let rawData = (try? (compressed as NSData).decompressed(using: .lzfse) as Data) ?? compressed
        guard let text = String(data: rawData, encoding: .utf8) else { return nil }

        var entries: [OnlineLexiconEntry] = []
        entries.reserveCapacity(meta.entryCount)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard !parts.isEmpty else { continue }
            let term = String(parts[0])
            let py = parts.count > 1 ? String(parts[1]) : ""
            let weight = parts.count > 2 ? (Int(parts[2]) ?? 100) : 100
            entries.append(OnlineLexiconEntry(term: term, pinyin: py, weight: weight))
        }

        return OnlineLexiconSnapshot(
            revision: meta.revision,
            updatedAt: meta.updatedAt,
            sourceURL: meta.sourceURL,
            entries: entries
        )
    }

    private func readOnlineMeta() -> OnlineLexiconMeta? {
        lock.lock()
        defer { lock.unlock() }
        return readOnlineMetaUnlocked()
    }

    private func readFileOnlineMetaUnlocked() -> OnlineLexiconMeta? {
        guard let data = try? Data(contentsOf: fileURL(Self.onlineMetaFilename)) else { return nil }
        return try? decoder.decode(OnlineLexiconMeta.self, from: data)
    }

    private func readOnlineMetaUnlocked() -> OnlineLexiconMeta? {
        let fileMeta = readFileOnlineMetaUnlocked()
        if isUsingKeychainSync, let kcGroup = activeKeychainAccessGroup,
           let kcData = KeychainSyncBridge.read(key: Self.onlineMetaKCKey, accessGroup: kcGroup),
           let kcMeta = try? decoder.decode(OnlineLexiconMeta.self, from: kcData) {
            if let fm = fileMeta {
                return fm.revision >= kcMeta.revision ? fm : kcMeta
            }
            return kcMeta
        }
        return fileMeta
    }

    // MARK: - History & Insights

    public func loadHistory() -> [HistoryRecord] {
        readJSON("history.json", as: [HistoryRecord].self) ?? []
    }

    public func appendHistory(_ record: HistoryRecord, maxCount: Int = 500) {
        var list = loadHistory()
        list.insert(record, at: 0)
        if list.count > maxCount {
            list = Array(list.prefix(maxCount))
        }
        let storeLimit = isUsingKeychainSync ? min(list.count, 80) : list.count
        writeJSON(Array(list.prefix(storeLimit)), to: "history.json")
    }

    public func deleteHistory(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let filtered = loadHistory().filter { !ids.contains($0.id) }
        writeJSON(filtered, to: "history.json")
    }

    public func clearHistory() {
        writeJSON([HistoryRecord](), to: "history.json")
    }

    public func dailyCharacterCounts(days: Int = 49, calendar: Calendar = .current) -> [(date: Date, count: Int)] {
        let records = loadHistory()
        let today = calendar.startOfDay(for: Date())
        var buckets: [Date: Int] = [:]
        for r in records {
            let day = calendar.startOfDay(for: r.timestamp)
            buckets[day, default: 0] += r.characterCount
        }
        var result: [(Date, Int)] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            if let d = calendar.date(byAdding: .day, value: -offset, to: today) {
                result.append((d, buckets[d] ?? 0))
            }
        }
        return result
    }

    // MARK: - IPC Payloads

    public func saveCommand(_ command: VoiceCommandPayload) {
        writeJSON(command, to: "ipc_command.json")
    }

    public func loadCommand() -> VoiceCommandPayload? {
        readJSON("ipc_command.json", as: VoiceCommandPayload.self)
    }

    public func saveStatus(_ status: HostRuntimeStatus) {
        writeJSON(status, to: "ipc_status.json")
    }

    public func loadStatus() -> HostRuntimeStatus {
        readJSON("ipc_status.json", as: HostRuntimeStatus.self) ?? HostRuntimeStatus()
    }

    public func markResultConsumed(requestId: UUID) {
        writeJSON(ConsumedResultAck(requestId: requestId, consumedAt: Date()), to: "ipc_consumed.json")
    }

    public func loadConsumedAck() -> ConsumedResultAck? {
        readJSON("ipc_consumed.json", as: ConsumedResultAck.self)
    }

    public var sharedDatabaseURL: URL {
        baseDirectory.appendingPathComponent("user_lexicon.sqlite", isDirectory: false)
    }
}
