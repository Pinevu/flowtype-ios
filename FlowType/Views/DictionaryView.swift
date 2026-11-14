import SwiftUI

struct DictionaryView: View {
    @EnvironmentObject var coordinator: HostVoiceCoordinator
    @State private var searchText = ""
    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var showAddSheet = false

    @State private var newTerm = ""
    @State private var newPinyinHint = ""
    @State private var newCategory: WordCategory = .phrase

    private var filteredWords: [PersonalWord] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return coordinator.dictionary }
        return coordinator.dictionary.filter {
            $0.term.localizedCaseInsensitiveContains(q) ||
            $0.pinyinHint.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if filteredWords.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "character.book.closed")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text(searchText.isEmpty ? "个人词典为空" : "没有找到匹配词条")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("添加人名、产品代号或专有术语后，语音识别、AI 润色和拼音手打都会优先命中；通过手打键盘修正语音结果也会自动学入词典。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: isSelecting ? $selectedIDs : .constant(Set<UUID>())) {
                        ForEach(filteredWords) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(item.term)
                                            .font(.body.weight(.medium))
                                        if item.autoLearned {
                                            Text("自学习")
                                                .font(.caption2.weight(.semibold))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.purple.opacity(0.15))
                                                .foregroundStyle(.purple)
                                                .clipShape(Capsule())
                                        }
                                    }
                                    HStack(spacing: 8) {
                                        Text(item.category.title)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        if !item.pinyinHint.isEmpty {
                                            Text("拼音：\(item.pinyinHint)")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Text("使用 \(item.usageCount) 次")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                Spacer()
                            }
                            .tag(item.id)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    coordinator.deleteWords(ids: [item.id])
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
                }
            }
            .navigationTitle("个人词典")
            .searchable(text: $searchText, prompt: "搜索词条或拼音")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !filteredWords.isEmpty {
                        Button(isSelecting ? "完成" : "多选") {
                            isSelecting.toggle()
                            if !isSelecting { selectedIDs.removeAll() }
                        }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if isSelecting && !selectedIDs.isEmpty {
                        Button("删除(\(selectedIDs.count))", role: .destructive) {
                            coordinator.deleteWords(ids: selectedIDs)
                            selectedIDs.removeAll()
                            isSelecting = false
                        }
                    } else {
                        Button {
                            showAddSheet = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                NavigationStack {
                    Form {
                        Section("词条信息") {
                            TextField("词条内容（如：张伟、Lintype）", text: $newTerm)
                            TextField("可选拼音提示（如：zhangwei）", text: $newPinyinHint)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Picker("分类", selection: $newCategory) {
                                ForEach(WordCategory.allCases) { cat in
                                    Text(cat.title).tag(cat)
                                }
                            }
                        }
                    }
                    .navigationTitle("添加词条")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { showAddSheet = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                coordinator.addWord(term: newTerm, pinyinHint: newPinyinHint, category: newCategory)
                                newTerm = ""
                                newPinyinHint = ""
                                showAddSheet = false
                            }
                            .disabled(newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .presentationDetents([.medium])
            }
        }
    }
}
