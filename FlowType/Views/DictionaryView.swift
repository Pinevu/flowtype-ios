import SwiftUI

struct DictionaryView: View {
    @EnvironmentObject var coordinator: HostVoiceCoordinator
    @State private var searchText = ""
    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var wordFilter: Int = 0 // 0=全部, 1=自学习, 2=手动添加

    @State private var showAddSheet = false
    @State private var showPasteImportSheet = false
    @State private var showOnlinePreviewSheet = false
    @State private var showFormatHelpSheet = false

    @State private var newTerm = ""
    @State private var newPinyinHint = ""
    @State private var newCategory: WordCategory = .phrase

    @State private var onlineURLDraft = ""
    @State private var pasteLexiconText = ""

    private var filteredWords: [PersonalWord] {
        let base: [PersonalWord]
        switch wordFilter {
        case 1: base = coordinator.dictionary.filter(\.autoLearned)
        case 2: base = coordinator.dictionary.filter { !$0.autoLearned }
        default: base = coordinator.dictionary
        }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.term.localizedCaseInsensitiveContains(q) ||
            $0.pinyinHint.localizedCaseInsensitiveContains(q)
        }
    }

    private var filteredOnlineEntries: [OnlineLexiconEntry] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return coordinator.onlineLexiconEntries }
        return coordinator.onlineLexiconEntries.filter {
            $0.term.localizedCaseInsensitiveContains(q) ||
            $0.pinyin.localizedCaseInsensitiveContains(q)
        }
    }

    private var autoLearnedCount: Int {
        coordinator.dictionary.filter(\.autoLearned).count
    }

    var body: some View {
        NavigationStack {
            List(selection: isSelecting ? $selectedIDs : .constant(Set<UUID>())) {
                onlineLexiconSection

                personalDictionarySection
            }
            .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
            .navigationTitle("个人词典")
            .searchable(text: $searchText, prompt: "搜索词条或拼音")
            .onAppear {
                if onlineURLDraft.isEmpty {
                    onlineURLDraft = coordinator.config.onlineLexiconURL
                }
            }
            .onChange(of: coordinator.config.onlineLexiconURL) { newVal in
                if !newVal.isEmpty && onlineURLDraft != newVal {
                    onlineURLDraft = newVal
                }
            }
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
                addWordSheet
            }
            .sheet(isPresented: $showPasteImportSheet) {
                pasteImportSheet
            }
            .sheet(isPresented: $showOnlinePreviewSheet) {
                onlinePreviewSheet
            }
            .sheet(isPresented: $showFormatHelpSheet) {
                formatHelpSheet
            }
        }
    }

    // MARK: - Sections

    private var onlineLexiconSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("在线自定义词库", systemImage: "icloud.and.arrow.down")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("格式说明") {
                        showFormatHelpSheet = true
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }

                TextField("粘贴词库直链（支持 JSON / Rime dict / TXT / GitHub 链接）", text: $onlineURLDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                HStack(spacing: 10) {
                    Button {
                        Task {
                            await coordinator.syncOnlineLexicon(urlString: onlineURLDraft)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            if coordinator.isSyncingOnlineLexicon {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Text(coordinator.isSyncingOnlineLexicon ? "同步中..." : "立即同步")
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(coordinator.isSyncingOnlineLexicon || onlineURLDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        showPasteImportSheet = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.clipboard")
                            Text("粘贴导入")
                        }
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.secondary.opacity(0.14))
                        .foregroundStyle(.primary)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    if coordinator.config.onlineLexiconWordCount > 0 || !coordinator.onlineLexiconEntries.isEmpty {
                        Button("清空", role: .destructive) {
                            coordinator.clearOnlineLexicon()
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                    }
                }

                Toggle("打开 App 时自动检查更新", isOn: Binding(
                    get: { coordinator.config.onlineLexiconAutoSync },
                    set: { newValue in
                        var updated = coordinator.config
                        updated.onlineLexiconAutoSync = newValue
                        coordinator.saveConfiguration(updated)
                    }
                ))
                .font(.caption)

                if !coordinator.config.onlineLexiconLastError.isEmpty {
                    Text(coordinator.config.onlineLexiconLastError)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    let count = max(coordinator.config.onlineLexiconWordCount, coordinator.onlineLexiconEntries.count)
                    if count > 0 {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("已启用 \(count) 个在线词条")
                                .font(.caption.weight(.medium))
                            if let syncDate = coordinator.config.onlineLexiconLastSyncAt {
                                Text("· \(syncDate.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("查看") {
                                showOnlinePreviewSheet = true
                            }
                            .font(.caption.weight(.medium))
                            .buttonStyle(.borderless)
                        }
                    } else {
                        Text("接入后将同步到系统键盘（九宫格与 26 键都会优先出词，无 App Group 侧载也可使用）。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("云端词库接入")
        }
    }

    private var personalDictionarySection: some View {
        Section {
            if coordinator.dictionary.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "character.book.closed")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("本地词典与自学习记录为空")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("平时打字频繁选词、组合新词或退格改错后都会自动学入词典；也可点击右上角 + 手动添加。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else {
                VStack(spacing: 8) {
                    Picker("筛选", selection: $wordFilter) {
                        Text("全部(\(coordinator.dictionary.count))").tag(0)
                        Text("自学习(\(autoLearnedCount))").tag(1)
                        Text("手动(\(coordinator.dictionary.count - autoLearnedCount))").tag(2)
                    }
                    .pickerStyle(.segmented)

                    if autoLearnedCount > 0 {
                        HStack {
                            Text("打字习惯会自动提升常用字词顺位")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("清除自学习记录", role: .destructive) {
                                coordinator.clearAutoLearnedWords()
                            }
                            .font(.caption2)
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .padding(.vertical, 2)

                if filteredWords.isEmpty {
                    Text("没有符合当前筛选或搜索条件的词条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
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
            }
        } header: {
            Text("个人词典与输入自学习")
        }
    }

    // MARK: - Sheets

    private var addWordSheet: some View {
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

    private var pasteImportSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("粘贴 JSON、Rime dict.yaml、TSV（词条\\t拼音）或每行一个词条：")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $pasteLexiconText)
                    .font(.footnote.monospaced())
                    .padding(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
            }
            .padding()
            .navigationTitle("粘贴导入在线词库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showPasteImportSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") {
                        let imported = coordinator.importOnlineLexiconText(pasteLexiconText)
                        if imported > 0 {
                            pasteLexiconText = ""
                            showPasteImportSheet = false
                        }
                    }
                    .disabled(pasteLexiconText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var onlinePreviewSheet: some View {
        NavigationStack {
            List {
                ForEach(Array(filteredOnlineEntries.prefix(300).enumerated()), id: \.offset) { _, entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.term)
                                .font(.body)
                            if !entry.pinyin.isEmpty {
                                Text(entry.pinyin)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text("权重 \(entry.weight)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .navigationTitle("在线词库 (\(coordinator.onlineLexiconEntries.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showOnlinePreviewSheet = false }
                }
            }
        }
    }

    private var formatHelpSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("支持的在线词库格式")
                        .font(.headline)

                    Group {
                        Text("1. Rime / 搜狗文本（Tab 或空格分隔，# 开头为注释）")
                            .font(.subheadline.weight(.semibold))
                        Text("林微音\tlinweiyin\t500\n全能签好用\tquannengqianhaoyong\nni hao\t你好")
                            .font(.caption.monospaced())
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    Group {
                        Text("2. 纯词条列表（自动推导汉字拼音）")
                            .font(.subheadline.weight(.semibold))
                        Text("林微音\nFlowType\n赛博朋克")
                            .font(.caption.monospaced())
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    Group {
                        Text("3. JSON 数组或键值对象")
                            .font(.subheadline.weight(.semibold))
                        Text("[{\"word\":\"林微音\",\"pinyin\":\"linweiyin\",\"weight\":500}]\n或 {\"林微音\":\"linweiyin\"}")
                            .font(.caption.monospaced())
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    Text("提示：直接粘贴 GitHub / Gitee 的文件链接会自动转为 Raw 直链下载；最多支持 20,000 条词条。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("格式说明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { showFormatHelpSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
