import Foundation

/// Shared native keycaps, swipe-up / long-press character maps, and PiP sizing constants.
public enum KeyboardKeyGestureMap {
    /// Flattest widescreen aspect ratio (2.4 : 1) supported cleanly by iOS PiP without vertical black letterboxing.
    public static let pipOptimalRenderWidth: Int = 240
    public static let pipOptimalRenderHeight: Int = 100

    public static func t9SwipeUp(digit: String) -> String? {
        switch digit {
        case "1", "2", "3", "4", "5", "6", "7", "8", "9":
            return digit
        default:
            return nil
        }
    }

    public static func t9LongPressOptions(digit: String) -> [String] {
        switch digit {
        case "1": return ["1", "，", "。", "？", "！", "、", "：", "；"]
        case "2": return ["2", "a", "b", "c", "A", "B", "C"]
        case "3": return ["3", "d", "e", "f", "D", "E", "F"]
        case "4": return ["4", "g", "h", "i", "G", "H", "I"]
        case "5": return ["5", "j", "k", "l", "J", "K", "L"]
        case "6": return ["6", "m", "n", "o", "M", "N", "O"]
        case "7": return ["7", "p", "q", "r", "s", "P", "Q", "R", "S"]
        case "8": return ["8", "t", "u", "v", "T", "U", "V"]
        case "9": return ["9", "w", "x", "y", "z", "W", "X", "Y", "Z"]
        default: return []
        }
    }

    public static func qwertySwipeUp(key: String, isChinese: Bool) -> String? {
        switch key.lowercased() {
        case "q": return "1"
        case "w": return "2"
        case "e": return "3"
        case "r": return "4"
        case "t": return "5"
        case "y": return "6"
        case "u": return "7"
        case "i": return "8"
        case "o": return "9"
        case "p": return "0"
        case "a": return "@"
        case "s": return "#"
        case "d": return "$"
        case "f": return "%"
        case "g": return "&"
        case "h": return "*"
        case "j": return "-"
        case "k": return "("
        case "l": return ")"
        case "z": return "_"
        case "x": return "\""
        case "c": return "/"
        case "v": return "'"
        case "b": return isChinese ? "；" : ";"
        case "n": return isChinese ? "！" : "!"
        case "m": return isChinese ? "？" : "?"
        default: return nil
        }
    }

    public static func qwertyLongPressOptions(key: String, isChinese: Bool, isShifted: Bool) -> [String] {
        let lower = key.lowercased()
        let upSym = qwertySwipeUp(key: lower, isChinese: isChinese)

        if lower == "." { return [".", "。", "…", "?", "!"] }
        if lower == "。" { return ["。", "，", "、", "：", "；", "？", "！"] }
        if lower == "," { return [",", "，", ";", ":"] }
        if lower == "，" { return ["，", "、", "。", "：", "；"] }

        guard lower.count == 1, let ch = lower.first, ch >= "a" && ch <= "z" else {
            return []
        }
        let upper = lower.uppercased()

        if isChinese {
            if let upSym {
                return [upSym, lower, upper]
            }
            return [lower, upper]
        }

        let enAccents: [String: [String]] = [
            "a": ["a", "à", "á", "â", "ä", "æ", "ã", "å", "@"],
            "e": ["e", "è", "é", "ê", "ë", "ē", "3"],
            "i": ["i", "ì", "í", "î", "ï", "ī", "8"],
            "o": ["o", "ò", "ó", "ô", "ö", "œ", "ø", "9"],
            "u": ["u", "ù", "ú", "û", "ü", "ū", "7"],
            "y": ["y", "ý", "ÿ", "6"],
            "s": ["s", "ß", "ś", "š", "#"],
            "c": ["c", "ç", "ć", "č", "/"],
            "n": ["n", "ñ", "ń", "!"],
            "z": ["z", "ž", "ź", "_"],
            "l": ["l", "ł", ")"]
        ]

        if let accents = enAccents[lower] {
            if isShifted {
                return accents.map { item in
                    item == "ß" ? "SS" : item.uppercased()
                }
            }
            return accents
        }

        let primary = isShifted ? upper : lower
        let secondary = isShifted ? lower : upper
        if let upSym {
            return [primary, upSym, secondary]
        }
        return [primary, secondary]
    }

    public static func isAudioSessionConflictError(message: String?) -> Bool {
        guard let msg = message, !msg.isEmpty else { return false }
        let markers = ["560557684", "561017449", "561015905", "cannotInterruptOthers", "麦克风被其他后台音频", "系统限制当前后台"]
        return markers.contains { msg.contains($0) }
    }
}
