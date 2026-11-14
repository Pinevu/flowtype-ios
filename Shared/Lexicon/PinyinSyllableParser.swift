import Foundation

public struct SyllableSpan: Equatable, Hashable {
    public let text: String
    public let startOffset: Int // character index in cleaned lowercase input (without apostrophes)
    public let endOffset: Int
    public let isPartial: Bool

    public init(text: String, startOffset: Int, endOffset: Int, isPartial: Bool = false) {
        self.text = text
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.isPartial = isPartial
    }
}

public struct PinyinSegmentationResult {
    public let cleanInput: String
    public let displayPinyin: String
    public let primarySyllables: [SyllableSpan]
    public let latticeEdges: [SyllableSpan]
}

public enum PinyinSyllableParser {
    // Complete Mandarin Pinyin syllable set (without tones; ü represented as v for l/n).
    public static let validSyllables: Set<String> = [
        "a", "ai", "an", "ang", "ao",
        "ba", "bai", "ban", "bang", "bao", "bei", "ben", "beng", "bi", "bian", "biao", "bie", "bin", "bing", "bo", "bu",
        "ca", "cai", "can", "cang", "cao", "ce", "cen", "ceng", "cha", "chai", "chan", "chang", "chao", "che", "chen", "cheng", "chi", "chong", "chou", "chu", "chua", "chuai", "chuan", "chuang", "chui", "chun", "chuo", "ci", "cong", "cou", "cu", "cuan", "cui", "cun", "cuo",
        "da", "dai", "dan", "dang", "dao", "de", "dei", "den", "deng", "di", "dia", "dian", "diao", "die", "ding", "diu", "dong", "dou", "du", "duan", "dui", "dun", "duo",
        "e", "ei", "en", "eng", "er",
        "fa", "fan", "fang", "fei", "fen", "feng", "fiao", "fo", "fou", "fu",
        "ga", "gai", "gan", "gang", "gao", "ge", "gei", "gen", "geng", "gong", "gou", "gu", "gua", "guai", "guan", "guang", "gui", "gun", "guo",
        "ha", "hai", "han", "hang", "hao", "he", "hei", "hen", "heng", "hong", "hou", "hu", "hua", "huai", "huan", "huang", "hui", "hun", "huo",
        "ji", "jia", "jian", "jiang", "jiao", "jie", "jin", "jing", "jiong", "jiu", "ju", "juan", "jue", "jun",
        "ka", "kai", "kan", "kang", "kao", "ke", "kei", "ken", "keng", "kong", "kou", "ku", "kua", "kuai", "kuan", "kuang", "kui", "kun", "kuo",
        "la", "lai", "lan", "lang", "lao", "le", "lei", "leng", "li", "lia", "lian", "liang", "liao", "lie", "lin", "ling", "liu", "lo", "long", "lou", "lu", "luan", "lue", "lun", "luo", "lv", "lve",
        "ma", "mai", "man", "mang", "mao", "me", "mei", "men", "meng", "mi", "mian", "miao", "mie", "min", "ming", "miu", "mo", "mou", "mu",
        "na", "nai", "nan", "nang", "nao", "ne", "nei", "nen", "neng", "ni", "nian", "niang", "niao", "nie", "nin", "ning", "niu", "nong", "nou", "nu", "nuan", "nue", "nuo", "nv", "nve",
        "o", "ou",
        "pa", "pai", "pan", "pang", "pao", "pei", "pen", "peng", "pi", "pian", "piao", "pie", "pin", "ping", "po", "pou", "pu",
        "qi", "qia", "qian", "qiang", "qiao", "qie", "qin", "qing", "qiong", "qiu", "qu", "quan", "que", "qun",
        "ran", "rang", "rao", "re", "ren", "reng", "ri", "rong", "rou", "ru", "rua", "ruan", "rui", "run", "ruo",
        "sa", "sai", "san", "sang", "sao", "se", "sen", "seng", "sha", "shai", "shan", "shang", "shao", "she", "shei", "shen", "sheng", "shi", "shou", "shu", "shua", "shuai", "shuan", "shuang", "shui", "shun", "shuo", "si", "song", "sou", "su", "suan", "sui", "sun", "suo",
        "ta", "tai", "tan", "tang", "tao", "te", "tei", "teng", "ti", "tian", "tiao", "tie", "ting", "tong", "tou", "tu", "tuan", "tui", "tun", "tuo",
        "wa", "wai", "wan", "wang", "wei", "wen", "weng", "wo", "wu",
        "xi", "xia", "xian", "xiang", "xiao", "xie", "xin", "xing", "xiong", "xiu", "xu", "xuan", "xue", "xun",
        "ya", "yan", "yang", "yao", "ye", "yi", "yin", "ying", "yo", "yong", "you", "yu", "yuan", "yue", "yun",
        "za", "zai", "zan", "zang", "zao", "ze", "zei", "zen", "zeng", "zha", "zhai", "zhan", "zhang", "zhao", "zhe", "zhei", "zhen", "zheng", "zhi", "zhong", "zhou", "zhu", "zhua", "zhuai", "zhuan", "zhuang", "zhui", "zhun", "zhuo", "zi", "zong", "zou", "zu", "zuan", "zui", "zun", "zuo"
    ]

    public static let validInitialPrefixes: Set<String> = {
        var prefixes = Set<String>()
        for s in validSyllables {
            for len in 1...s.count {
                prefixes.insert(String(s.prefix(len)))
            }
        }
        return prefixes
    }()

    /// Segments raw user Pinyin input (which may contain `'`) into a syllable lattice
    /// and a primary display segmentation.
    public static func segment(rawInput: String) -> PinyinSegmentationResult {
        let lower = rawInput.lowercased()
        let groups = lower.split(separator: "'", omittingEmptySubsequences: false)
        var cleanChars = ""
        var forcedBoundaries = Set<Int>([0])
        for group in groups {
            let filtered = group.filter { $0 >= "a" && $0 <= "z" }
            cleanChars.append(contentsOf: filtered)
            forcedBoundaries.insert(cleanChars.count)
        }

        let chars = Array(cleanChars)
        let n = chars.count
        guard n > 0 else {
            return PinyinSegmentationResult(cleanInput: "", displayPinyin: "", primarySyllables: [], latticeEdges: [])
        }

        // Build all valid syllable spans respecting explicit apostrophe boundaries
        var edges: [SyllableSpan] = []
        for i in 0..<n {
            let maxLen = min(6, n - i)
            var foundFull = false
            for len in stride(from: maxLen, through: 1, by: -1) {
                let end = i + len
                // Do not cross an explicit apostrophe inside a single syllable
                var crossesBoundary = false
                if len > 1 {
                    for mid in (i + 1)..<end where forcedBoundaries.contains(mid) {
                        crossesBoundary = true
                        break
                    }
                }
                if crossesBoundary { continue }

                let sub = String(chars[i..<end])
                if validSyllables.contains(sub) {
                    edges.append(SyllableSpan(text: sub, startOffset: i, endOffset: end, isPartial: false))
                    foundFull = true
                }
            }
            // If at the end (or before apostrophe), also allow partial syllable prefixes (e.g., "zh", "nih" -> "ni"+"h")
            if !foundFull || (n - i <= 5) {
                let sub = String(chars[i..<n])
                if sub.count <= 5 && !validSyllables.contains(sub) && validInitialPrefixes.contains(sub) {
                    var crossesBoundary = false
                    for mid in (i + 1)..<n where forcedBoundaries.contains(mid) {
                        crossesBoundary = true
                        break
                    }
                    if !crossesBoundary {
                        edges.append(SyllableSpan(text: sub, startOffset: i, endOffset: n, isPartial: true))
                    }
                }
            }
        }

        // Dynamic programming for primary display split (prefer fewest syllables, avoid single-letter fragments unless needed)
        var dpCost = Array(repeating: Double.infinity, count: n + 1)
        var dpPrev: [SyllableSpan?] = Array(repeating: nil, count: n + 1)
        dpCost[0] = 0

        var edgesByStart = Array(repeating: [SyllableSpan](), count: n)
        for edge in edges {
            edgesByStart[edge.startOffset].append(edge)
        }

        for i in 0..<n {
            guard dpCost[i].isFinite else { continue }
            var advanced = false
            for edge in edgesByStart[i] {
                let penalty: Double = edge.isPartial ? 4.5 : (edge.text.count == 1 ? 2.5 : 1.0)
                // Prefer longer valid syllables (e.g., "chang" over "ch"+"ang")
                let lengthBonus = Double(edge.text.count) * 0.15
                let nextCost = dpCost[i] + penalty - lengthBonus
                if nextCost < dpCost[edge.endOffset] {
                    dpCost[edge.endOffset] = nextCost
                    dpPrev[edge.endOffset] = edge
                }
                advanced = true
            }
            if !advanced {
                let single = SyllableSpan(text: String(chars[i]), startOffset: i, endOffset: i + 1, isPartial: true)
                let nextCost = dpCost[i] + 10.0
                if nextCost < dpCost[i + 1] {
                    dpCost[i + 1] = nextCost
                    dpPrev[i + 1] = single
                }
            }
        }

        var primary: [SyllableSpan] = []
        var cursor = n
        while cursor > 0 {
            if let span = dpPrev[cursor] {
                primary.append(span)
                cursor = span.startOffset
            } else {
                let single = SyllableSpan(text: String(chars[cursor - 1]), startOffset: cursor - 1, endOffset: cursor, isPartial: true)
                primary.append(single)
                cursor -= 1
            }
        }
        primary.reverse()

        let display = primary.map(\.text).joined(separator: "'")
        return PinyinSegmentationResult(
            cleanInput: cleanChars,
            displayPinyin: display,
            primarySyllables: primary,
            latticeEdges: edges
        )
    }

    public static func fuzzyVariants(for syllable: String) -> [String] {
        var set = Set<String>([syllable])

        func togglePrefix(_ a: String, _ b: String) {
            let snapshot = Array(set)
            for s in snapshot {
                if s.hasPrefix(a) {
                    set.insert(b + s.dropFirst(a.count))
                } else if s.hasPrefix(b) {
                    set.insert(a + s.dropFirst(b.count))
                }
            }
        }

        togglePrefix("zh", "z")
        togglePrefix("ch", "c")
        togglePrefix("sh", "s")
        togglePrefix("n", "l")
        togglePrefix("r", "l")
        togglePrefix("f", "h")

        func toggleSuffix(_ a: String, _ b: String) {
            let snapshot = Array(set)
            for s in snapshot {
                if s.hasSuffix(a) {
                    set.insert(String(s.dropLast(a.count)) + b)
                } else if s.hasSuffix(b) {
                    set.insert(String(s.dropLast(b.count)) + a)
                }
            }
        }

        toggleSuffix("ang", "an")
        toggleSuffix("eng", "en")
        toggleSuffix("ing", "in")
        toggleSuffix("iang", "ian")
        toggleSuffix("uang", "uan")

        return Array(set).filter { validSyllables.contains($0) }
    }
}
