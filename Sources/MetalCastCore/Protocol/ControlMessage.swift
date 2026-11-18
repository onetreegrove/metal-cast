import Foundation

public enum ControlMessage: Sendable {
    case injectKeycode(action: KeyAction, keycode: UInt32, metaState: UInt32 = 0)
    case injectText(text: String)
    case injectTouch(action: TouchAction, pointerId: UInt64, position: Point, resolution: Size)
    case injectScroll(position: Point, resolution: Size, hScroll: Int16, vScroll: Int16)
    case backOrScreenOn(action: KeyAction)
    case expandNotificationPanel
    case expandSettingsPanel
    case collapsePanels
    case getClipboard
    case setClipboard(text: String, paste: Bool = false)
    case setScreenPower(on: Bool)
    case rotateDevice

    public enum KeyAction: UInt8, Sendable {
        case down = 0
        case up = 1
    }

    public enum TouchAction: UInt8, Sendable {
        case down = 0
        case up = 1
        case move = 2
    }

    public struct Point: Sendable {
        public let x: Int32
        public let y: Int32

        public init(x: Int32, y: Int32) {
            self.x = x
            self.y = y
        }
    }

    public struct Size: Sendable {
        public let width: UInt16
        public let height: UInt16

        public init(width: UInt16, height: UInt16) {
            self.width = width
            self.height = height
        }
    }

    public func serialize() -> Data {
        var data = Data()
        switch self {
        case .injectKeycode(let action, let keycode, let metaState):
            data.append(0) // TYPE_INJECT_KEYCODE
            data.append(action.rawValue)
            data.appendBigEndian(keycode)
            data.appendBigEndian(UInt32(0)) // repeat
            data.appendBigEndian(metaState)

        case .injectText(let text):
            data.append(1) // TYPE_INJECT_TEXT
            if let textData = text.data(using: .utf8) {
                data.appendBigEndian(UInt32(textData.count))
                data.append(textData)
            } else {
                data.appendBigEndian(UInt32(0))
            }

        case .injectTouch(let action, let pointerId, let position, let resolution):
            data.append(2) // TYPE_INJECT_TOUCH_EVENT (1 byte)
            data.append(action.rawValue) // (1 byte)
            data.appendBigEndian(pointerId) // (8 bytes)
            data.appendBigEndian(position.x) // (4 bytes)
            data.appendBigEndian(position.y) // (4 bytes)
            data.appendBigEndian(resolution.width) // (2 bytes)
            data.appendBigEndian(resolution.height) // (2 bytes)
            let isDownOrMove = (action == .down || action == .move)
            let pressure: UInt16 = isDownOrMove ? 0xFFFF : 0
            let buttons: UInt32 = isDownOrMove ? 1 : 0
            data.appendBigEndian(pressure) // (2 bytes)
            data.appendBigEndian(UInt32(1)) // action button (primary) (4 bytes)
            data.appendBigEndian(buttons) // buttons state (4 bytes)

        case .injectScroll(let position, let resolution, let hScroll, let vScroll):
            data.append(3) // TYPE_INJECT_SCROLL_EVENT (1 byte)
            data.appendBigEndian(position.x) // (4 bytes)
            data.appendBigEndian(position.y) // (4 bytes)
            data.appendBigEndian(resolution.width) // (2 bytes)
            data.appendBigEndian(resolution.height) // (2 bytes)
            data.appendBigEndian(hScroll) // Int16 (2 bytes)
            data.appendBigEndian(vScroll) // Int16 (2 bytes)
            data.appendBigEndian(UInt32(0)) // buttons (4 bytes)

        case .backOrScreenOn(let action):
            data.append(4) // TYPE_BACK_OR_SCREEN_ON
            data.append(action.rawValue)

        case .expandNotificationPanel:
            data.append(5) // TYPE_EXPAND_NOTIFICATION_PANEL

        case .expandSettingsPanel:
            data.append(6) // TYPE_EXPAND_SETTINGS_PANEL

        case .collapsePanels:
            data.append(7) // TYPE_COLLAPSE_PANELS

        case .getClipboard:
            data.append(8) // TYPE_GET_CLIPBOARD
            data.append(0) // copy key

        case .setClipboard(let text, let paste):
            data.append(9) // TYPE_SET_CLIPBOARD
            data.appendBigEndian(UInt64(0)) // sequence
            data.append(paste ? 1 : 0)
            if let textData = text.data(using: .utf8) {
                data.appendBigEndian(UInt32(textData.count))
                data.append(textData)
            } else {
                data.appendBigEndian(UInt32(0))
            }

        case .setScreenPower(let on):
            data.append(10) // TYPE_SET_SCREEN_POWER
            data.append(on ? 1 : 0)

        case .rotateDevice:
            data.append(11) // TYPE_ROTATE_DEVICE
        }

        return data
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { bytes in
            self.append(contentsOf: bytes)
        }
    }
}
