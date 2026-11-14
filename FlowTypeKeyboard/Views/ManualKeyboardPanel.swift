import SwiftUI

public struct ManualKeyboardPanel: View {
    @ObservedObject var model: KeyboardStateModel
    @Environment(\.colorScheme) private var colorScheme

    public var body: some View {
        VStack(spacing: 0) {
            candidateOrAccessoryBar
                .frame(height: 40)
                .padding(.horizontal, 6)

            Divider().opacity(0.25)

            if model.isCandidateDrawerExpanded && !model.pinyinCandidates.isEmpty {
                expandedCandidateDrawer
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                keyGrid
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 4)
                    .padding(.top, 6)
                    .padding(.bottom, 6)
            }
        }
    }

    // MARK: - 1. Candidate / Suggestion Bar

    @ViewBuilder
    private var candidateOrAccessoryBar: some View {
        if model.manualLanguage == .chinesePinyin && model.pinyinLayoutMode == .t9 && !model.t9ComposingDigits.isEmpty {
            t9CandidateBar
        } else if model.manualLanguage == .chinesePinyin && !model.composingPinyin.isEmpty {
            qwertyCandidateBar
        } else if model.manualLanguage == .english && !model.englishSuggestions.isEmpty {
            englishSuggestionBar
        } else {
            idleAccessoryBar
        }
    }

    private var t9CandidateBar: some View {
        HStack(spacing: 6) {
            // Raw digits / active filter preview button
            Button {
                model.commitT9AsRawDigits()
            } label: {
                Text(model.displayPinyin)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)

            // Syllable filter options (when multiple syllables match the digits)
            if model.t9SyllableOptions.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        Button {
                            model.selectT9SyllableFilter(nil)
                        } label: {
                            Text("全部")
                                .font(.system(size: 12, weight: model.selectedT9SyllableFilter == nil ? .bold : .regular))
                                .foregroundStyle(model.selectedT9SyllableFilter == nil ? Color.white : Color.primary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(model.selectedT9SyllableFilter == nil ? Color.blue : keyBackgroundColor)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        ForEach(model.t9SyllableOptions, id: \.self) { syll in
                            Button {
                                model.selectT9SyllableFilter(syll)
                            } label: {
                                Text(syll)
                                    .font(.system(size: 12, weight: model.selectedT9SyllableFilter == syll ? .bold : .regular))
                                    .foregroundStyle(model.selectedT9SyllableFilter == syll ? Color.white : Color.primary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(model.selectedT9SyllableFilter == syll ? Color.blue : keyBackgroundColor)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: 130)
                Divider().frame(height: 18)
            }

            // Candidates list
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(model.pinyinCandidates.prefix(20).enumerated()), id: \.element.id) { idx, cand in
                        Button {
                            model.selectPinyinCandidate(cand)
                        } label: {
                            Text(idx == 0 ? "\(cand.text)" : "\(idx + 1).\(cand.text)")
                                .font(.system(size: 16, weight: idx == 0 ? .semibold : .regular))
                                .foregroundStyle(idx == 0 ? Color.blue : Color.primary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(idx == 0 ? Color.blue.opacity(0.12) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button {
                model.triggerHaptic()
                model.isCandidateDrawerExpanded.toggle()
            } label: {
                Image(systemName: model.isCandidateDrawerExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
    }

    private var qwertyCandidateBar: some View {
        HStack(spacing: 6) {
            // Tap composing pinyin preview to insert raw ASCII letters
            Button {
                model.commitComposingAsRawLetters()
            } label: {
                Text(model.displayPinyin)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(model.pinyinCandidates.prefix(18).enumerated()), id: \.element.id) { idx, cand in
                        Button {
                            model.selectPinyinCandidate(cand)
                        } label: {
                            Text(idx == 0 ? "\(cand.text)" : "\(idx + 1).\(cand.text)")
                                .font(.system(size: 16, weight: idx == 0 ? .semibold : .regular))
                                .foregroundStyle(idx == 0 ? Color.blue : Color.primary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(idx == 0 ? Color.blue.opacity(0.12) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button {
                model.triggerHaptic()
                model.isCandidateDrawerExpanded.toggle()
            } label: {
                Image(systemName: model.isCandidateDrawerExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
    }

    private var englishSuggestionBar: some View {
        HStack(spacing: 6) {
            ForEach(model.englishSuggestions, id: \.self) { suggestion in
                Button {
                    model.applyEnglishSuggestion(suggestion)
                } label: {
                    Text(suggestion)
                        .font(.system(size: 15))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(keyBackgroundColor.opacity(0.55))
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var idleAccessoryBar: some View {
        HStack(spacing: 6) {
            let quickPunct = model.manualLanguage == .chinesePinyin
                ? ["，", "。", "？", "！", "、"]
                : [",", ".", "?", "!", "'"]
            ForEach(quickPunct, id: \.self) { p in
                Button {
                    model.handleKeyTap(p)
                } label: {
                    Text(p)
                        .font(.system(size: 16, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(keyBackgroundColor.opacity(0.45))
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            if model.manualLanguage == .chinesePinyin {
                Button {
                    model.togglePinyinLayoutMode()
                } label: {
                    Text(model.pinyinLayoutMode == .t9 ? "26键" : "九键")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 7)
                        .frame(height: 28)
                        .background(specialKeyBackgroundColor)
                        .foregroundStyle(.primary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Button {
                model.switchToPanel(.voice)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: model.isHostAlive ? "mic.fill" : "mic")
                    Text("语音")
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Color.blue.opacity(0.15))
                .foregroundStyle(.blue)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 2. Expanded Candidate Grid Drawer

    private var expandedCandidateDrawer: some View {
        VStack(spacing: 6) {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 8) {
                    ForEach(model.pinyinCandidates) { cand in
                        Button {
                            model.selectPinyinCandidate(cand)
                        } label: {
                            Text(cand.text)
                                .font(.system(size: 16))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(keyBackgroundColor)
                                .foregroundStyle(.primary)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }

            HStack(spacing: 8) {
                Button {
                    model.clearComposing()
                } label: {
                    Text("清空拼音")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(specialKeyBackgroundColor)
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    model.handleBackspaceTap()
                } label: {
                    Image(systemName: "delete.left")
                        .frame(width: 64, height: 36)
                        .background(specialKeyBackgroundColor)
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    model.isCandidateDrawerExpanded = false
                } label: {
                    Text("返回键盘")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 88, height: 36)
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    // MARK: - 3. Responsive Key Grid

    @ViewBuilder
    private var keyGrid: some View {
        if model.manualLanguage == .chinesePinyin && model.pinyinLayoutMode == .t9 && model.layoutPage == .letters {
            t9KeyGrid
        } else {
            qwertyKeyGrid
        }
    }

    private var t9KeyGrid: some View {
        GeometryReader { geo in
            let rowSpacing: CGFloat = 8
            let colSpacing: CGFloat = 6
            let totalHeight = geo.size.height
            let rowHeight = max(38, (totalHeight - rowSpacing * 3) / 4)

            // Side columns (Left & Right) each take ~18% width
            let sideWidth = max(52, geo.size.width * 0.18)
            // Center 3 columns take the remaining width
            let centerAvailableWidth = geo.size.width - (sideWidth * 2) - (colSpacing * 4)
            let centerKeyWidth = max(54, (centerAvailableWidth - colSpacing * 2) / 3)

            HStack(spacing: colSpacing) {
                // MARK: Left Column
                VStack(spacing: rowSpacing) {
                    // Row 1: 符号
                    Button {
                        model.triggerHaptic()
                        model.layoutPage = .symbols
                    } label: {
                        Text("符号")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: sideWidth, height: rowHeight)
                            .background(specialKeyBackgroundColor)
                            .foregroundStyle(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    // Row 2: 123
                    Button {
                        model.triggerHaptic()
                        model.layoutPage = .numbers
                    } label: {
                        Text("123")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: sideWidth, height: rowHeight)
                            .background(specialKeyBackgroundColor)
                            .foregroundStyle(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    // Row 3: 分词 / '
                    Button {
                        model.handleT9KeyTap("1")
                    } label: {
                        VStack(spacing: 1) {
                            Text("分词")
                                .font(.system(size: 14, weight: .medium))
                            Text("'")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: sideWidth, height: rowHeight)
                        .background(specialKeyBackgroundColor)
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    // Row 4: 切换到26键全拼
                    Button {
                        model.togglePinyinLayoutMode()
                    } label: {
                        Text("26键")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: sideWidth, height: rowHeight)
                            .background(specialKeyBackgroundColor)
                            .foregroundStyle(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                // MARK: Center 3x4 Grid
                VStack(spacing: rowSpacing) {
                    // Row 1 (1, 2, 3)
                    HStack(spacing: colSpacing) {
                        t9KeyButton(digit: "1", letters: "，。/'", width: centerKeyWidth, height: rowHeight)
                        t9KeyButton(digit: "2", letters: "ABC", width: centerKeyWidth, height: rowHeight)
                        t9KeyButton(digit: "3", letters: "DEF", width: centerKeyWidth, height: rowHeight)
                    }

                    // Row 2 (4, 5, 6)
                    HStack(spacing: colSpacing) {
                        t9KeyButton(digit: "4", letters: "GHI", width: centerKeyWidth, height: rowHeight)
                        t9KeyButton(digit: "5", letters: "JKL", width: centerKeyWidth, height: rowHeight)
                        t9KeyButton(digit: "6", letters: "MNO", width: centerKeyWidth, height: rowHeight)
                    }

                    // Row 3 (7, 8, 9)
                    HStack(spacing: colSpacing) {
                        t9KeyButton(digit: "7", letters: "PQRS", width: centerKeyWidth, height: rowHeight)
                        t9KeyButton(digit: "8", letters: "TUV", width: centerKeyWidth, height: rowHeight)
                        t9KeyButton(digit: "9", letters: "WXYZ", width: centerKeyWidth, height: rowHeight)
                    }

                    // Row 4 (拼/EN, 空格 Spacebar, 重输/清空)
                    HStack(spacing: colSpacing) {
                        // Language toggle
                        Button {
                            model.toggleManualLanguage()
                        } label: {
                            Text(model.manualLanguage.badgeTitle)
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: centerKeyWidth, height: rowHeight)
                                .background(specialKeyBackgroundColor)
                                .foregroundStyle(.primary)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        // Spacebar Key
                        SpacebarTrackpadKey(
                            title: model.t9ComposingDigits.isEmpty ? "空格" : "确认",
                            height: rowHeight,
                            keyColor: keyBackgroundColor,
                            onTap: { model.handleT9SpaceTap() },
                            onTrackpadDrag: { dx in model.handleSpaceTrackpadDrag(deltaX: dx) },
                            onTrackpadEnd: { model.resetSpaceTrackpad() }
                        )

                        // If composing: 重输; If idle: Quick Voice
                        if !model.t9ComposingDigits.isEmpty {
                            Button {
                                model.triggerHaptic()
                                model.clearT9Composing()
                            } label: {
                                Text("重输")
                                    .font(.system(size: 14, weight: .medium))
                                    .frame(width: centerKeyWidth, height: rowHeight)
                                    .background(specialKeyBackgroundColor)
                                    .foregroundStyle(.red)
                                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button {
                                model.switchToPanel(.voice)
                            } label: {
                                Image(systemName: model.isHostAlive ? "mic.fill" : "mic")
                                    .font(.system(size: 16, weight: .semibold))
                                    .frame(width: centerKeyWidth, height: rowHeight)
                                    .background(specialKeyBackgroundColor)
                                    .foregroundStyle(.blue)
                                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // MARK: Right Column
                VStack(spacing: rowSpacing) {
                    // Backspace button (spans 2 rows)
                    let backspaceHeight = rowHeight * 2 + rowSpacing
                    Image(systemName: "delete.left")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: sideWidth, height: backspaceHeight)
                        .background(specialKeyBackgroundColor)
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .onTapGesture {
                            model.handleBackspaceTap()
                        }
                        .onLongPressGesture(minimumDuration: 0.35, perform: {}, onPressingChanged: { pressing in
                            if pressing {
                                model.startContinuousBackspace()
                            } else {
                                model.stopContinuousBackspace()
                            }
                        })

                    // Return / Send button (spans 2 rows)
                    let returnHeight = rowHeight * 2 + rowSpacing
                    Button {
                        model.handleReturnTap()
                    } label: {
                        Text(effectiveReturnTitle)
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: sideWidth, height: returnHeight)
                            .background(effectiveReturnColor)
                            .foregroundStyle(effectiveReturnForeground)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func t9KeyButton(digit: String, letters: String, width: CGFloat, height: CGFloat) -> some View {
        Button {
            model.handleT9KeyTap(digit)
        } label: {
            VStack(spacing: 1) {
                Text(digit)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.primary)
                Text(letters)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: width, height: height)
            .background(keyBackgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var qwertyKeyGrid: some View {
        GeometryReader { geo in
            let rowSpacing: CGFloat = 8
            let colSpacing: CGFloat = 5
            let rowHeight = max(36, (geo.size.height - rowSpacing * 3) / 4)
            let standardKeyWidth = (geo.size.width - colSpacing * 9) / 10

            VStack(spacing: rowSpacing) {
                // Row 1 (10 keys)
                HStack(spacing: colSpacing) {
                    ForEach(row1Keys, id: \.self) { label in
                        CharacterKeyButton(
                            label: displayLabel(label),
                            width: standardKeyWidth,
                            height: rowHeight,
                            keyColor: keyBackgroundColor
                        ) {
                            model.handleKeyTap(label)
                        }
                    }
                }

                // Row 2 (9 keys in letters, 10 keys in numbers/symbols)
                HStack(spacing: colSpacing) {
                    if model.layoutPage == .letters {
                        Spacer(minLength: 0)
                    }
                    ForEach(row2Keys, id: \.self) { label in
                        let w = model.layoutPage == .letters
                            ? standardKeyWidth
                            : (geo.size.width - colSpacing * 9) / 10
                        CharacterKeyButton(
                            label: displayLabel(label),
                            width: w,
                            height: rowHeight,
                            keyColor: keyBackgroundColor
                        ) {
                            model.handleKeyTap(label)
                        }
                    }
                    if model.layoutPage == .letters {
                        Spacer(minLength: 0)
                    }
                }

                // Row 3 (Modifier + 7/5 keys + Backspace)
                HStack(spacing: colSpacing) {
                    row3LeftModifier(width: standardKeyWidth * 1.38, height: rowHeight)

                    let centerKeys = row3Keys
                    let centerAvail = geo.size.width - (standardKeyWidth * 1.38) * 2 - colSpacing * CGFloat(centerKeys.count + 1)
                    let centerKeyW = centerAvail / CGFloat(centerKeys.count)

                    ForEach(centerKeys, id: \.self) { label in
                        CharacterKeyButton(
                            label: displayLabel(label),
                            width: centerKeyW,
                            height: rowHeight,
                            keyColor: keyBackgroundColor
                        ) {
                            model.handleKeyTap(label)
                        }
                    }

                    backspaceKey(width: standardKeyWidth * 1.38, height: rowHeight)
                }

                // Row 4 (123/ABC + Voice + 中/EN + Spacebar Trackpad + Return)
                HStack(spacing: colSpacing) {
                    // 123 / ABC toggle
                    Button {
                        model.triggerHaptic()
                        model.layoutPage = (model.layoutPage == .letters) ? .numbers : .letters
                    } label: {
                        Text(model.layoutPage == .letters ? "123" : "ABC")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: standardKeyWidth * 1.45, height: rowHeight)
                            .background(specialKeyBackgroundColor)
                            .foregroundStyle(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    // Quick Nine-Key / Voice toggle
                    if model.manualLanguage == .chinesePinyin && model.layoutPage == .letters {
                        Button {
                            model.togglePinyinLayoutMode()
                        } label: {
                            Text("九键")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: standardKeyWidth * 1.15, height: rowHeight)
                                .background(specialKeyBackgroundColor)
                                .foregroundStyle(.primary)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            model.switchToPanel(.voice)
                        } label: {
                            Image(systemName: model.isHostAlive ? "mic.fill" : "mic")
                                .font(.system(size: 16, weight: .medium))
                                .frame(width: standardKeyWidth * 1.15, height: rowHeight)
                                .background(specialKeyBackgroundColor)
                                .foregroundStyle(.blue)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }

                    // Chinese / English toggle
                    Button {
                        model.toggleManualLanguage()
                    } label: {
                        Text(model.manualLanguage.badgeTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: standardKeyWidth * 1.25, height: rowHeight)
                            .background(specialKeyBackgroundColor)
                            .foregroundStyle(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    // Spacebar with Cursor Trackpad
                    SpacebarTrackpadKey(
                        title: spacebarTitle,
                        height: rowHeight,
                        keyColor: keyBackgroundColor,
                        onTap: { model.handleSpaceTap() },
                        onTrackpadDrag: { dx in model.handleSpaceTrackpadDrag(deltaX: dx) },
                        onTrackpadEnd: { model.resetSpaceTrackpad() }
                    )

                    // Return / Confirm Key
                    Button {
                        model.handleReturnTap()
                    } label: {
                        Text(effectiveReturnTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: standardKeyWidth * 1.85, height: rowHeight)
                            .background(effectiveReturnColor)
                            .foregroundStyle(effectiveReturnForeground)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Key Definitions

    private var row1Keys: [String] {
        switch model.layoutPage {
        case .letters: return ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"]
        case .numbers: return ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
        case .symbols: return ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="]
        }
    }

    private var row2Keys: [String] {
        switch model.layoutPage {
        case .letters:
            return ["a", "s", "d", "f", "g", "h", "j", "k", "l"]
        case .numbers:
            return model.manualLanguage == .chinesePinyin
                ? ["-", "/", "：", "；", "（", "）", "¥", "&", "@", "”"]
                : ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""]
        case .symbols:
            return model.manualLanguage == .chinesePinyin
                ? ["_", "\\", "|", "~", "《", "》", "€", "£", "、", "·"]
                : ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"]
        }
    }

    private var row3Keys: [String] {
        switch model.layoutPage {
        case .letters:
            return ["z", "x", "c", "v", "b", "n", "m"]
        case .numbers, .symbols:
            return model.manualLanguage == .chinesePinyin
                ? ["。", "，", "？", "！", "’"]
                : [".", ",", "?", "!", "'"]
        }
    }

    private func displayLabel(_ key: String) -> String {
        guard model.layoutPage == .letters else { return key }
        if model.manualLanguage == .chinesePinyin {
            return model.shiftState == .off ? key.lowercased() : key.uppercased()
        }
        return model.shiftState == .off ? key.lowercased() : key.uppercased()
    }

    @ViewBuilder
    private func row3LeftModifier(width: CGFloat, height: CGFloat) -> some View {
        switch model.layoutPage {
        case .letters:
            Button {
                model.handleShiftTap()
            } label: {
                Image(systemName: shiftIconName)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: width, height: height)
                    .background(model.shiftState == .off ? specialKeyBackgroundColor : keyBackgroundColor)
                    .foregroundStyle(model.shiftState == .capsLock ? .blue : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)

        case .numbers:
            Button {
                model.triggerHaptic()
                model.layoutPage = .symbols
            } label: {
                Text("#+=")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: width, height: height)
                    .background(specialKeyBackgroundColor)
                    .foregroundStyle(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)

        case .symbols:
            Button {
                model.triggerHaptic()
                model.layoutPage = .numbers
            } label: {
                Text("123")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: width, height: height)
                    .background(specialKeyBackgroundColor)
                    .foregroundStyle(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private func backspaceKey(width: CGFloat, height: CGFloat) -> some View {
        Image(systemName: "delete.left")
            .font(.system(size: 17, weight: .medium))
            .frame(width: width, height: height)
            .background(specialKeyBackgroundColor)
            .foregroundStyle(.primary)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onTapGesture {
                model.handleBackspaceTap()
            }
            .onLongPressGesture(minimumDuration: 0.35, perform: {}, onPressingChanged: { pressing in
                if pressing {
                    model.startContinuousBackspace()
                } else {
                    model.stopContinuousBackspace()
                }
            })
    }

    private var shiftIconName: String {
        switch model.shiftState {
        case .off: return "shift"
        case .shifted: return "shift.fill"
        case .capsLock: return "capslock.fill"
        }
    }

    private var spacebarTitle: String {
        if model.manualLanguage == .chinesePinyin {
            return model.composingPinyin.isEmpty ? "空格 · 拼音" : "选定首词"
        }
        return "space"
    }

    private var effectiveReturnTitle: String {
        if model.manualLanguage == .chinesePinyin && !model.composingPinyin.isEmpty {
            return "确认"
        }
        return model.returnKeyLabel
    }

    private var effectiveReturnColor: Color {
        if (model.manualLanguage == .chinesePinyin && !model.composingPinyin.isEmpty) || model.returnKeyLabel != "换行" {
            return .blue
        }
        return specialKeyBackgroundColor
    }

    private var effectiveReturnForeground: Color {
        if (model.manualLanguage == .chinesePinyin && !model.composingPinyin.isEmpty) || model.returnKeyLabel != "换行" {
            return .white
        }
        return .primary
    }

    private var keyBackgroundColor: Color {
        colorScheme == .dark ? Color(white: 0.29) : Color.white
    }

    private var specialKeyBackgroundColor: Color {
        colorScheme == .dark
            ? Color(white: 0.19)
            : Color(red: 0.68, green: 0.70, blue: 0.75)
    }
}

// MARK: - Character Key Button with Zero-Delay Touch + Keycap Popover

private struct CharacterKeyButton: View {
    let label: String
    let width: CGFloat
    let height: CGFloat
    let keyColor: Color
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(keyColor)
                .shadow(color: .black.opacity(0.22), radius: 0.5, x: 0, y: 1)

            Text(label)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.primary)
        }
        .frame(width: width, height: height)
        .overlay(alignment: .top) {
            if isPressed {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(keyColor)
                        .shadow(color: .black.opacity(0.28), radius: 4, y: 2)
                    Text(label)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.primary)
                }
                .frame(width: max(width + 10, 42), height: height + 10)
                .offset(y: -(height + 6))
                .allowsHitTesting(false)
            }
        }
        .zIndex(isPressed ? 100 : 0)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressed {
                        isPressed = true
                    }
                }
                .onEnded { _ in
                    isPressed = false
                    action()
                }
        )
    }
}

// MARK: - Spacebar with Tap + Long-Press Cursor Trackpad

private struct SpacebarTrackpadKey: View {
    let title: String
    let height: CGFloat
    let keyColor: Color
    let onTap: () -> Void
    let onTrackpadDrag: (CGFloat) -> Void
    let onTrackpadEnd: () -> Void

    @State private var isTrackpadActive = false
    @State private var lastDragX: CGFloat?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isTrackpadActive ? Color.blue.opacity(0.22) : keyColor)
                .shadow(color: .black.opacity(0.22), radius: 0.5, x: 0, y: 1)

            Text(isTrackpadActive ? "◀ 滑动移动光标 ▶" : title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isTrackpadActive ? .blue : .secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.25)
                .sequenced(before: DragGesture(minimumDistance: 0))
                .onChanged { value in
                    switch value {
                    case .second(true, let drag):
                        if !isTrackpadActive {
                            isTrackpadActive = true
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        }
                        if let drag {
                            if let prevX = lastDragX {
                                onTrackpadDrag(drag.location.x - prevX)
                            }
                            lastDragX = drag.location.x
                        }
                    default:
                        break
                    }
                }
                .onEnded { _ in
                    isTrackpadActive = false
                    lastDragX = nil
                    onTrackpadEnd()
                }
        )
    }
}
