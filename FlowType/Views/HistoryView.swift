import SwiftUI
import UIKit

struct HistoryView: View {
    @EnvironmentObject var coordinator: HostVoiceCoordinator
    @State private var searchText = ""
    @State private var copiedId: UUID?

    private var filteredRecords: [HistoryRecord] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return coordinator.history }
        return coordinator.history.filter {
            $0.finalOutput.localizedCaseInsensitiveContains(q) ||
            $0.rawTranscript.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if filteredRecords.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "waveform.and.magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text(searchText.isEmpty ? "暂无语音输入历史" : "没有匹配的历史记录")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(filteredRecords) { record in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Label(record.mode.title, systemImage: record.mode.systemImage)
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.blue.opacity(0.12))
                                        .foregroundStyle(.blue)
                                        .clipShape(Capsule())

                                    if let lang = record.targetLanguage {
                                        Text(lang)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Text(record.timestamp, style: .relative)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                Text(record.finalOutput)
                                    .font(.body)
                                    .textSelection(.enabled)

                                if record.rawTranscript != record.finalOutput && !record.rawTranscript.isEmpty {
                                    Text("识别原文：\(record.rawTranscript)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                HStack {
                                    Text(String(format: "%.1fs · %d 字", record.durationSeconds, record.characterCount))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                    Spacer()
                                    Button {
                                        UIPasteboard.general.string = record.finalOutput
                                        copiedId = record.id
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                            if copiedId == record.id { copiedId = nil }
                                        }
                                    } label: {
                                        Label(copiedId == record.id ? "已复制" : "复制", systemImage: copiedId == record.id ? "checkmark" : "doc.on.doc")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .onDelete { offsets in
                            let ids = Set(offsets.map { filteredRecords[$0].id })
                            coordinator.deleteHistory(ids: ids)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("听写历史")
            .searchable(text: $searchText, prompt: "搜索听写内容或原文")
            .toolbar {
                if !coordinator.history.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("清空", role: .destructive) {
                            coordinator.clearAllHistory()
                        }
                    }
                }
            }
        }
    }
}
