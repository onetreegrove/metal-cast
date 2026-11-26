import Foundation

/// Unified loopback TCP endpoint shared by CLI `adb` processes and Swift `NWConnection` sockets.
public struct ADBServerEndpoint: Hashable, Sendable, Codable {
    public let host: String
    public let port: UInt16

    public static let defaultHost = "127.0.0.1"
    public static let defaultPort: UInt16 = 5037
    public static let sanitizedEnvironmentKeys: [String] = [
        "ADB_SERVER_SOCKET",
        "ANDROID_ADB_SERVER_PORT",
        "ANDROID_ADB_SERVER_ADDRESS"
    ]

    public var cliAddressArgument: String {
        if host.contains(":") && !host.hasPrefix("[") {
            return "tcp:[\(host)]:\(port)"
        }
        return "tcp:\(host):\(port)"
    }

    public init(host: String = defaultHost, port: UInt16 = defaultPort) throws {
        let normalizedHost = try Self.validateLoopbackHost(host)
        guard port >= 1 else {
            throw ADBFileError.incompatibleEndpoint("无效端口号: \(port)")
        }
        self.host = normalizedHost
        self.port = port
    }

    /// Resolves the active local ADB Server endpoint according to priority:
    /// 1. Explicit custom endpoint
    /// 2. `ADB_SERVER_SOCKET` (`tcp:<loopback>:<port>` only)
    /// 3. `ANDROID_ADB_SERVER_ADDRESS` + `ANDROID_ADB_SERVER_PORT`
    /// 4. Default `127.0.0.1:5037`
    public static func resolve(
        explicit: ADBServerEndpoint? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ADBServerEndpoint {
        if let explicit {
            return try ADBServerEndpoint(host: explicit.host, port: explicit.port)
        }

        let socketEnv = environment["ADB_SERVER_SOCKET"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let addressEnv = environment["ANDROID_ADB_SERVER_ADDRESS"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let portEnv = environment["ANDROID_ADB_SERVER_PORT"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        let hasSocket = socketEnv.map { !$0.isEmpty } ?? false
        let hasAddress = addressEnv.map { !$0.isEmpty } ?? false
        let hasPort = portEnv.map { !$0.isEmpty } ?? false

        var parsedAddressHost: String?
        if hasAddress, let rawAddress = addressEnv {
            parsedAddressHost = try validateLoopbackHost(rawAddress)
        }

        var parsedEnvPort: UInt16?
        if hasPort, let rawPort = portEnv {
            parsedEnvPort = try validatePortString(rawPort, source: "ANDROID_ADB_SERVER_PORT")
        }

        if hasSocket, let rawSocket = socketEnv {
            let socketEndpoint = try parseServerSocket(rawSocket)
            if let envHost = parsedAddressHost, !hostsEquivalentForConflictCheck(envHost, socketEndpoint.host) {
                throw ADBFileError.incompatibleEndpoint(
                    "ADB_SERVER_SOCKET (\(rawSocket)) 与 ANDROID_ADB_SERVER_ADDRESS (\(envHost)) 冲突"
                )
            }
            if let envPort = parsedEnvPort, envPort != socketEndpoint.port {
                throw ADBFileError.incompatibleEndpoint(
                    "ADB_SERVER_SOCKET (\(rawSocket)) 与 ANDROID_ADB_SERVER_PORT (\(envPort)) 冲突"
                )
            }
            return socketEndpoint
        }

        let finalHost = parsedAddressHost ?? defaultHost
        let finalPort = parsedEnvPort ?? defaultPort
        return try ADBServerEndpoint(host: finalHost, port: finalPort)
    }

    /// Returns a copy of `environment` with ADB endpoint override variables removed so `-L` never conflicts.
    public static func sanitizedEnvironment(
        from environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var copy = environment
        for key in sanitizedEnvironmentKeys {
            copy.removeValue(forKey: key)
        }
        return copy
    }

    /// Prepends `["-L", cliAddressArgument]` to the given CLI arguments.
    public func cliArguments(prependedTo args: [String]) -> [String] {
        ["-L", cliAddressArgument] + args
    }

    private static func parseServerSocket(_ raw: String) throws -> ADBServerEndpoint {
        guard raw.lowercased().hasPrefix("tcp:") else {
            throw ADBFileError.incompatibleEndpoint(
                "ADB_SERVER_SOCKET=\(raw) 不受支持，首版仅允许 tcp:<loopback>:<port>"
            )
        }

        let remainder = String(raw.dropFirst(4))
        guard !remainder.isEmpty else {
            throw ADBFileError.incompatibleEndpoint("ADB_SERVER_SOCKET=\(raw) 缺少主机与端口")
        }

        let rawHost: String
        let rawPort: String

        if remainder.hasPrefix("[") {
            guard let closeBracket = remainder.firstIndex(of: "]") else {
                throw ADBFileError.incompatibleEndpoint("ADB_SERVER_SOCKET=\(raw) 方括号格式非法")
            }
            let afterBracket = remainder.index(after: closeBracket)
            guard afterBracket < remainder.endIndex, remainder[afterBracket] == ":" else {
                throw ADBFileError.incompatibleEndpoint("ADB_SERVER_SOCKET=\(raw) 缺少端口")
            }
            rawHost = String(remainder[remainder.index(after: remainder.startIndex)..<closeBracket])
            rawPort = String(remainder[remainder.index(after: afterBracket)...])
        } else {
            guard let lastColon = remainder.lastIndex(of: ":") else {
                throw ADBFileError.incompatibleEndpoint("ADB_SERVER_SOCKET=\(raw) 缺少端口")
            }
            rawHost = String(remainder[..<lastColon])
            rawPort = String(remainder[remainder.index(after: lastColon)...])
        }

        let validHost = try validateLoopbackHost(rawHost)
        let validPort = try validatePortString(rawPort, source: "ADB_SERVER_SOCKET")
        return try ADBServerEndpoint(host: validHost, port: validPort)
    }

    private static func validateLoopbackHost(_ raw: String) throws -> String {
        let stripped: String
        if raw.hasPrefix("[") && raw.hasSuffix("]") && raw.count >= 2 {
            stripped = String(raw.dropFirst().dropLast())
        } else {
            stripped = raw
        }

        switch stripped.lowercased() {
        case "127.0.0.1":
            return "127.0.0.1"
        case "localhost":
            return "localhost"
        case "::1":
            return "::1"
        default:
            throw ADBFileError.incompatibleEndpoint("仅允许本地回环地址（127.0.0.1 / localhost / ::1），当前为: \(raw)")
        }
    }

    private static func validatePortString(_ raw: String, source: String) throws -> UInt16 {
        guard !raw.isEmpty, raw.allSatisfy({ $0.isNumber }), let port = UInt16(raw), port >= 1 else {
            throw ADBFileError.incompatibleEndpoint("\(source) 端口非法: \(raw)")
        }
        return port
    }

    private static func hostsEquivalentForConflictCheck(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }
}
