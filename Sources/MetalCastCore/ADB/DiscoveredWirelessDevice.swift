import Foundation

public struct DiscoveredWirelessDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let serviceType: String
    public let address: String

    public init(id: String, name: String, serviceType: String, address: String) {
        self.id = id
        self.name = name
        self.serviceType = serviceType
        self.address = address
    }

    public var ip: String {
        address.components(separatedBy: ":").first ?? address
    }

    public var port: Int {
        Int(address.components(separatedBy: ":").last ?? "5555") ?? 5555
    }

    public var isPairing: Bool {
        serviceType.contains("pairing")
    }

    public var displayName: String {
        var clean = name
        if clean.hasPrefix("adb-") {
            clean = String(clean.dropFirst(4))
        }
        return clean.isEmpty ? ip : clean
    }
}
