import Foundation

public enum WordCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case name
    case tech
    case brand
    case phrase

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .name: return "人名"
        case .tech: return "术语"
        case .brand: return "品牌/代号"
        case .phrase: return "常用词"
        }
    }
}

public struct PersonalWord: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var term: String
    public var pinyinHint: String
    public var category: WordCategory
    public var autoLearned: Bool
    public var createdAt: Date
    public var usageCount: Int

    public init(
        id: UUID = UUID(),
        term: String,
        pinyinHint: String = "",
        category: WordCategory = .phrase,
        autoLearned: Bool = false,
        createdAt: Date = Date(),
        usageCount: Int = 1
    ) {
        self.id = id
        self.term = term
        self.pinyinHint = pinyinHint
        self.category = category
        self.autoLearned = autoLearned
        self.createdAt = createdAt
        self.usageCount = usageCount
    }
}

public struct HistoryRecord: Codable, Identifiable, Equatable {
    public var id: UUID
    public var timestamp: Date
    public var mode: VoiceActionMode
    public var rawTranscript: String
    public var finalOutput: String
    public var targetLanguage: String?
    public var durationSeconds: Double
    public var characterCount: Int

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        mode: VoiceActionMode,
        rawTranscript: String,
        finalOutput: String,
        targetLanguage: String? = nil,
        durationSeconds: Double = 0,
        characterCount: Int? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.mode = mode
        self.rawTranscript = rawTranscript
        self.finalOutput = finalOutput
        self.targetLanguage = targetLanguage
        self.durationSeconds = durationSeconds
        self.characterCount = characterCount ?? finalOutput.count
    }
}
