import Foundation

public struct ADBDevice: Identifiable, Sendable, Equatable, Hashable {
    public let serial: String
    public let state: DeviceState
    public let model: String?
    public let product: String?
    public let transportId: String?

    public var selectionKey: String {
        transportId.map { "tid:\($0)" } ?? "serial:\(serial)"
    }

    public var id: String { selectionKey }

    public var isWifi: Bool {
        serial.contains(":") || serial.contains(".")
    }

    public enum DeviceState: String, Sendable {
        case device
        case offline
        case unauthorized
        case recovery
        case bootloader
        case unknown

        public var isAvailable: Bool {
            self == .device
        }
    }

    public init(
        serial: String,
        state: DeviceState,
        model: String? = nil,
        product: String? = nil,
        transportId: String? = nil
    ) {
        self.serial = serial
        self.state = state
        self.model = model
        self.product = product
        self.transportId = transportId
    }

    public static func parse(deviceLine: String) -> ADBDevice? {
        let trimmed = deviceLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.starts(with: "*"),
              !trimmed.lowercased().starts(with: "list of devices") else {
            return nil
        }

        let components = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard components.count >= 2 else { return nil }

        let serial = components[0]
        let state = DeviceState(rawValue: components[1]) ?? .unknown

        var model: String? = nil
        var product: String? = nil
        var transportId: String? = nil

        for item in components.dropFirst(2) {
            if item.starts(with: "model:") {
                model = String(item.dropFirst(6))
            } else if item.starts(with: "product:") {
                product = String(item.dropFirst(8))
            } else if item.starts(with: "transport_id:") {
                transportId = String(item.dropFirst(13))
            }
        }

        return ADBDevice(
            serial: serial,
            state: state,
            model: model,
            product: product,
            transportId: transportId
        )
    }
}
