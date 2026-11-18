import Foundation

public enum DeviceMessage: Sendable {
    case clipboard(text: String)
    case ackClipboard(sequence: UInt64)
    case unknown(type: UInt8)

    public static func parse(from data: Data) -> (message: DeviceMessage?, bytesConsumed: Int) {
        guard !data.isEmpty else { return (nil, 0) }

        let type = data[0]
        switch type {
        case 0: // DEVICE_MSG_TYPE_CLIPBOARD
            guard data.count >= 5 else { return (nil, 0) }
            let length = data.subdata(in: 1..<5).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            let totalNeeded = 5 + Int(length)
            guard data.count >= totalNeeded else { return (nil, 0) }

            let textData = data.subdata(in: 5..<totalNeeded)
            let text = String(data: textData, encoding: .utf8) ?? ""
            return (.clipboard(text: text), totalNeeded)

        case 1: // DEVICE_MSG_TYPE_ACK_CLIPBOARD
            guard data.count >= 9 else { return (nil, 0) }
            let seq = data.subdata(in: 1..<9).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
            return (.ackClipboard(sequence: seq), 9)

        default:
            return (.unknown(type: type), 1)
        }
    }
}
