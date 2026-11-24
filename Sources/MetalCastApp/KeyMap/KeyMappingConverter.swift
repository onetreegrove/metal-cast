import AppKit

public enum InputTrigger: Hashable, Sendable {
    case key(UInt16)          // macOS virtual keyCode
    case mouseButton(Int)     // 0: Left, 1: Right, 2: Middle / Center

    public var displayName: String {
        switch self {
        case .mouseButton(0): return "鼠标左键"
        case .mouseButton(1): return "鼠标右键"
        case .mouseButton(2): return "鼠标中键"
        case .mouseButton(let b): return "鼠标键\(b)"
        case .key(let code):
            switch code {
            case 50: return "~"
            case 49: return "Space"
            case 48: return "Tab"
            case 36: return "Enter"
            case 53: return "Esc"
            case 56, 60: return "Shift"
            case 59, 62: return "Ctrl"
            case 58, 61: return "Alt"
            case 55: return "Cmd"
            case 123: return "◀"
            case 124: return "▶"
            case 125: return "▼"
            case 126: return "▲"
            case 0: return "A"
            case 1: return "S"
            case 2: return "D"
            case 3: return "F"
            case 4: return "H"
            case 5: return "G"
            case 6: return "Z"
            case 7: return "X"
            case 8: return "C"
            case 9: return "V"
            case 11: return "B"
            case 12: return "Q"
            case 13: return "W"
            case 14: return "E"
            case 15: return "R"
            case 16: return "Y"
            case 17: return "T"
            case 31: return "O"
            case 32: return "U"
            case 34: return "I"
            case 35: return "P"
            case 37: return "L"
            case 38: return "J"
            case 40: return "K"
            case 45: return "N"
            case 46: return "M"
            case 18: return "1"
            case 19: return "2"
            case 20: return "3"
            case 21: return "4"
            case 23: return "5"
            case 22: return "6"
            case 26: return "7"
            case 28: return "8"
            case 25: return "9"
            case 29: return "0"
            default: return "Key(\(code))"
            }
        }
    }
}

public enum KeyMappingConverter {
    private static let keyNameToTriggerMap: [String: InputTrigger] = [
        // Mouse Buttons
        "LeftButton": .mouseButton(0),
        "RightButton": .mouseButton(1),
        "MidButton": .mouseButton(2),
        "MiddleButton": .mouseButton(2),

        // Letters
        "Key_A": .key(0),
        "Key_B": .key(11),
        "Key_C": .key(8),
        "Key_D": .key(2),
        "Key_E": .key(14),
        "Key_F": .key(3),
        "Key_G": .key(5),
        "Key_H": .key(4),
        "Key_I": .key(34),
        "Key_J": .key(38),
        "Key_K": .key(40),
        "Key_L": .key(37),
        "Key_M": .key(46),
        "Key_N": .key(45),
        "Key_O": .key(31),
        "Key_P": .key(35),
        "Key_Q": .key(12),
        "Key_R": .key(15),
        "Key_S": .key(1),
        "Key_T": .key(17),
        "Key_U": .key(32),
        "Key_V": .key(9),
        "Key_W": .key(13),
        "Key_X": .key(7),
        "Key_Y": .key(16),
        "Key_Z": .key(6),

        // Digits
        "Key_0": .key(29),
        "Key_1": .key(18),
        "Key_2": .key(19),
        "Key_3": .key(20),
        "Key_4": .key(21),
        "Key_5": .key(23),
        "Key_6": .key(22),
        "Key_7": .key(26),
        "Key_8": .key(28),
        "Key_9": .key(25),

        // Controls & Modifiers
        "Key_QuoteLeft": .key(50), // ` and ~
        "Key_Space": .key(49),
        "Key_Tab": .key(48),
        "Key_Return": .key(36),
        "Key_Enter": .key(36),
        "Key_Escape": .key(53),
        "Key_Shift": .key(56),
        "Key_Control": .key(59),
        "Key_Alt": .key(58),
        "Key_Option": .key(58),
        "Key_Meta": .key(55),
        "Key_Command": .key(55),
        "Key_CapsLock": .key(57),
        "Key_Backspace": .key(51),
        "Key_Delete": .key(51),

        // Navigation & Editing
        "Key_Left": .key(123),
        "Key_Right": .key(124),
        "Key_Down": .key(125),
        "Key_Up": .key(126),
        "Key_Home": .key(115),
        "Key_End": .key(119),
        "Key_PageUp": .key(116),
        "Key_PageDown": .key(121),
        "Key_ForwardDelete": .key(117),
        "Key_Insert": .key(114),

        // Punctuations & Symbols
        "Key_Equal": .key(24),
        "Key_Plus": .key(24),
        "Key_Minus": .key(27),
        "Key_Underscore": .key(27),
        "Key_BracketLeft": .key(33),
        "Key_BracketRight": .key(30),
        "Key_Semicolon": .key(41),
        "Key_Apostrophe": .key(39),
        "Key_Quote": .key(39),
        "Key_Comma": .key(43),
        "Key_Period": .key(47),
        "Key_Slash": .key(44),
        "Key_Backslash": .key(42),

        // Function Keys
        "Key_F1": .key(122),
        "Key_F2": .key(120),
        "Key_F3": .key(99),
        "Key_F4": .key(118),
        "Key_F5": .key(96),
        "Key_F6": .key(97),
        "Key_F7": .key(98),
        "Key_F8": .key(100),
        "Key_F9": .key(101),
        "Key_F10": .key(109),
        "Key_F11": .key(103),
        "Key_F12": .key(111)
    ]

    public static func parseTrigger(from rawName: String) -> InputTrigger? {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = keyNameToTriggerMap[trimmed] {
            return match
        }
        // Case-insensitive fallback
        for (k, v) in keyNameToTriggerMap {
            if k.caseInsensitiveCompare(trimmed) == .orderedSame {
                return v
            }
        }
        return nil
    }
}
