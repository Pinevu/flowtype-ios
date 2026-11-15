import Foundation

public enum OnlineLexiconError: LocalizedError, Sendable {
    case invalidURL
    case networkFailure(String)
    case htmlPageReturned
    case emptyOrUnsupportedFormat

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "请输入有效的 http:// 或 https:// 词库链接"
        case .networkFailure(let detail):
            return "下载失败：\(detail)"
        case .htmlPageReturned:
            return "链接返回了网页 HTML，请使用 Raw 纯文本或 JSON 直链"
        case .emptyOrUnsupportedFormat:
            return "未解析到有效词条（支持 JSON、Rime dict.yaml、TSV/TXT 词表）"
        }
    }
}

public enum OnlineLexiconService {
    public static let maxEntriesCount = 20_000

    /// Rewrites common GitHub/Gitee web blob URLs into raw content URLs for user convenience.
    public static func normalizeRawURLString(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if let comps = URLComponents(string: trimmed),
           let host = comps.host?.lowercased() {
            if host == "github.com" {
                let parts = comps.path.split(separator: "/").map(String.init)
                if parts.count >= 5 && parts[2] == "blob" {
                    let tail = ([parts[0], parts[1]] + Array(parts.dropFirst(3))).joined(separator: "/")
                    return "https://raw.githubusercontent.com/\(tail)"
                }
            } else if host == "gitee.com" {
                let parts = comps.path.split(separator: "/").map(String.init)
                if parts.count >= 5 && parts[2] == "blob" {
                    let tail = ([parts[0], parts[1], "raw"] + Array(parts.dropFirst(3))).joined(separator: "/")
                    return "https://gitee.com/\(tail)"
                }
            }
        }
        return trimmed
    }

    public static func fetchAndParse(
        urlString: String,
        pinyinFallback: (@Sendable (String) -> String)? = nil
    ) async throws -> [OnlineLexiconEntry] {
        let normalizedURLString = normalizeRawURLString(urlString)
        guard let url = URL(string: normalizedURLString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw OnlineLexiconError.invalidURL
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("FlowType-LexiconSync/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw OnlineLexiconError.networkFailure(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw OnlineLexiconError.networkFailure("HTTP \(http.statusCode)")
        }

        let decodedText = decodeText(from: data)
        let trimmedHead = decodedText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(256)
            .lowercased()
        if trimmedHead.hasPrefix("<!doctype html") || trimmedHead.hasPrefix("<html") {
            throw OnlineLexiconError.htmlPageReturned
        }

        let entries = parse(text: decodedText, pinyinFallback: pinyinFallback)
        if entries.isEmpty {
            throw OnlineLexiconError.emptyOrUnsupportedFormat
        }
        return entries
    }

    /// Parses JSON, Rime `.dict.yaml`, TSV/CSV (`词条\t拼音\t权重`), or plain term-per-line word lists.
    public static func parse(
        text: String,
        pinyinFallback: ((String) -> String)? = nil
    ) -> [OnlineLexiconEntry] {
        var clean = text
        if clean.hasPrefix("\u{FEFF}") {
            clean.removeFirst()
        }
        let trimmed = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var parsed: [OnlineLexiconEntry] = []
        if (trimmed.hasPrefix("[") || trimmed.hasPrefix("{")),
           let jsonData = trimmed.data(using: .utf8),
           let jsonEntries = parseJSON(jsonData) {
            parsed = jsonEntries
        } else {
            parsed = parseLineBasedText(trimmed)
        }

        var bestByKey: [String: OnlineLexiconEntry] = [:]
        var orderedKeys: [String] = []
        bestByKey.reserveCapacity(min(parsed.count, maxEntriesCount))
        orderedKeys.reserveCapacity(min(parsed.count, maxEntriesCount))

        for rawEntry in parsed {
            let term = rawEntry.term
                .replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, term.count <= 32 else { continue }

            var py = normalizePinyin(rawEntry.pinyin)
            if py.isEmpty {
                if isASCIIWord(term) {
                    py = normalizePinyin(term)
                } else if let derived = pinyinFallback?(term), !derived.isEmpty {
                    py = normalizePinyin(derived)
                }
            }
            let weight = max(1, min(1_000_000, rawEntry.weight))
            let key = "\(py)#\(term)"
            if let existing = bestByKey[key] {
                if weight > existing.weight {
                    bestByKey[key] = OnlineLexiconEntry(term: term, pinyin: py, weight: weight)
                }
            } else {
                guard orderedKeys.count < maxEntriesCount else { break }
                orderedKeys.append(key)
                bestByKey[key] = OnlineLexiconEntry(term: term, pinyin: py, weight: weight)
            }
        }

        return orderedKeys.compactMap { bestByKey[$0] }
    }

    // MARK: - JSON & Text Parsers

    private static func parseJSON(_ data: Data) -> [OnlineLexiconEntry]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }

        if let arr = obj as? [Any] {
            return parseJSONArray(arr)
        }
        if let dict = obj as? [String: Any] {
            for containerKey in ["words", "entries", "lexicon", "items", "data"] {
                if let arr = dict[containerKey] as? [Any] {
                    return parseJSONArray(arr)
                }
            }
            var entries: [OnlineLexiconEntry] = []
            entries.reserveCapacity(dict.count)
            for (k, v) in dict {
                if let strVal = v as? String {
                    let kAscii = looksLikePinyinCode(k)
                    let vAscii = looksLikePinyinCode(strVal)
                    if kAscii && !vAscii {
                        entries.append(OnlineLexiconEntry(term: strVal, pinyin: k, weight: 200))
                    } else {
                        entries.append(OnlineLexiconEntry(term: k, pinyin: strVal, weight: 200))
                    }
                } else if let sub = v as? [String: Any] {
                    let term = stringValue(in: sub, keys: ["term", "word", "text", "hanzi"]) ?? k
                    let py = stringValue(in: sub, keys: ["pinyin", "py", "pinyinHint", "code", "reading"]) ?? ""
                    let weight = intValue(in: sub, keys: ["weight", "freq", "frequency", "priority"]) ?? 200
                    entries.append(OnlineLexiconEntry(term: term, pinyin: py, weight: weight))
                }
            }
            return entries
        }
        return nil
    }

    private static func parseJSONArray(_ array: [Any]) -> [OnlineLexiconEntry] {
        var entries: [OnlineLexiconEntry] = []
        entries.reserveCapacity(array.count)
        for element in array {
            if let str = element as? String {
                entries.append(OnlineLexiconEntry(term: str, pinyin: "", weight: 200))
            } else if let dict = element as? [String: Any],
                      let term = stringValue(in: dict, keys: ["term", "word", "text", "hanzi", "value"]) {
                let py = stringValue(in: dict, keys: ["pinyin", "py", "pinyinHint", "code", "reading"]) ?? ""
                let weight = intValue(in: dict, keys: ["weight", "freq", "frequency", "priority"]) ?? 200
                entries.append(OnlineLexiconEntry(term: term, pinyin: py, weight: weight))
            }
        }
        return entries
    }

    private static func parseLineBasedText(_ text: String) -> [OnlineLexiconEntry] {
        let lines = text.components(separatedBy: .newlines)
        var inYAMLHeader = false
        var sawNonEmptyLine = false
        var results: [OnlineLexiconEntry] = []
        results.reserveCapacity(min(lines.count, maxEntriesCount))

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if !sawNonEmptyLine && line == "---" {
                inYAMLHeader = true
                sawNonEmptyLine = true
                continue
            }
            sawNonEmptyLine = true
            if inYAMLHeader {
                if line == "..." || line == "---" {
                    inYAMLHeader = false
                }
                continue
            }
            if line.hasPrefix("#") || line.hasPrefix("//") || line.hasPrefix("--") {
                continue
            }

            let columns = splitLineColumns(line)
            guard !columns.isEmpty else { continue }

            var cols = columns
            var weight = 200
            if cols.count >= 2, let trailingWeight = Int(cols[cols.count - 1]) {
                weight = max(1, trailingWeight)
                cols.removeLast()
            }

            if cols.count == 1 {
                results.append(OnlineLexiconEntry(term: cols[0], pinyin: "", weight: weight))
            } else {
                let c0 = cols[0]
                let c1 = cols[1]
                // Auto-detect `"pinyin\tword"` (Rime / custom code tables) vs `"word\tpinyin"` (standard)
                if looksLikePinyinCode(c0) && !looksLikePinyinCode(c1) {
                    let tailTerm = cols.count > 2 ? cols.dropFirst().joined(separator: " ") : c1
                    results.append(OnlineLexiconEntry(term: tailTerm, pinyin: c0, weight: weight))
                } else {
                    let pyCol = cols.dropFirst().joined(separator: "")
                    results.append(OnlineLexiconEntry(term: c0, pinyin: pyCol, weight: weight))
                }
            }
        }
        return results
    }

    private static func splitLineColumns(_ line: String) -> [String] {
        if line.contains("\t") {
            return line
                .split(separator: "\t", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        if line.contains(",") && !line.contains(" ") {
            return line
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        // Handle space-separated lines carefully: `"你好 ni hao"` or `"ni hao 你好"` or `"林微音 linweiyin 500"`
        let tokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard tokens.count > 1 else { return tokens }

        var mutable = tokens
        var trailingWeight: String?
        if mutable.count >= 2, Int(mutable.last ?? "") != nil {
            trailingWeight = mutable.removeLast()
        }
        let nonAsciiIndices = mutable.indices.filter { !looksLikePinyinCode(mutable[$0]) }
        if nonAsciiIndices.count == 1, let idx = nonAsciiIndices.first {
            let term = mutable[idx]
            let restPy = mutable.enumerated()
                .filter { $0.offset != idx }
                .map(\.element)
                .joined()
            var out = idx == 0 ? [term, restPy] : [restPy, term]
            if let trailingWeight { out.append(trailingWeight) }
            return out
        }
        if let trailingWeight { mutable.append(trailingWeight) }
        return mutable
    }

    private static func stringValue(in dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let s = dict[key] as? String {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func intValue(in dict: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let n = dict[key] as? Int { return n }
            if let n = dict[key] as? Double { return Int(n) }
            if let s = dict[key] as? String, let n = Int(s) { return n }
        }
        return nil
    }

    private static func normalizePinyin(_ raw: String) -> String {
        raw.lowercased().filter { $0 >= "a" && $0 <= "z" }
    }

    private static func isASCIIWord(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy {
            ($0.value >= 65 && $0.value <= 90) ||
            ($0.value >= 97 && $0.value <= 122) ||
            $0.value == 39 || $0.value == 45
        }
    }

    private static func looksLikePinyinCode(_ s: String) -> Bool {
        var hasLetter = false
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if (v >= 65 && v <= 90) || (v >= 97 && v <= 122) {
                hasLetter = true
            } else if v == 39 || v == 32 || (v >= 49 && v <= 53) {
                continue
            } else {
                return false
            }
        }
        return hasLetter
    }

    private static func decodeText(from data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .utf16) { return s }
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        )
        if let s = String(data: data, encoding: gb18030) { return s }
        return String(decoding: data, as: UTF8.self)
    }
}
