import Foundation
import Testing
@testable import MetalCastCore

@Suite("ADBShellClient")
struct ADBShellClientTests {
    private static func shellFrame(id: UInt8, payload: Data) -> Data {
        var d = Data([id])
        d.appendUInt32LE(UInt32(payload.count))
        d.append(payload)
        return d
    }

    private static func readShellFrame(from conn: MockADBTCPServer.MockConnection) async throws -> (id: UInt8, payload: Data) {
        let header = try await conn.readExact(5)
        let id = header[header.startIndex]
        let len = Int(header.readUInt32LE(at: 1))
        let payload = len > 0 ? try await conn.readExact(len) : Data()
        return (id, payload)
    }

    @Test("Shell v2 inline command parses stdout/stderr/exit and rejects missing exit frame")
    func inlineExecutionAndMissingExitFrame() async throws {
        let server = try await MockADBTCPServer { conn in
            Task {
                defer { conn.close() }
                guard try await conn.readHostRequest() == "host:transport-id:3" else { return }
                try await conn.send(Data("OKAY".utf8))
                let service = try await conn.readHostRequest()
                try await conn.send(Data("OKAY".utf8))

                if service.contains("missing-exit") {
                    try await conn.send(Self.shellFrame(id: 1, payload: Data("partial\n".utf8)))
                    // Close without id=3 exit frame
                } else {
                    var resp = Self.shellFrame(id: 1, payload: Data("/storage/emulated/0\n".utf8))
                    resp.append(Self.shellFrame(id: 2, payload: Data("warn\n".utf8)))
                    resp.append(Self.shellFrame(id: 3, payload: Data([0])))
                    try await conn.sendFragmentedOneByte(Data(resp.prefix(7)), delayNanoseconds: 200_000)
                    try await conn.send(Data(resp.dropFirst(7)))
                }
            }
        }
        defer { server.stop() }

        let endpoint = try ADBServerEndpoint(host: "127.0.0.1", port: server.port)
        let shell = ADBShellClient()

        let conn1 = ADBSocketConnection(endpoint: endpoint)
        defer { conn1.close() }
        try await conn1.connect()
        let root = try await shell.resolveSharedStorageRoot(connection: conn1, transportId: "3")
        #expect(root == "/storage/emulated/0")

        let conn2 = ADBSocketConnection(endpoint: endpoint)
        defer { conn2.close() }
        try await conn2.connect()
        do {
            _ = try await shell.execute(connection: conn2, transportId: "3", command: "echo missing-exit")
            Issue.record("Expected operationUnconfirmed when kIdExit is missing")
        } catch let error as ADBFileError {
            guard case .operationUnconfirmed = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }

    @Test("Commands >= 3800 bytes automatically switch to shell,v2,raw:sh stdin feeding")
    func longCommandUsesShStdinFallback() async throws {
        final class Capture: @unchecked Sendable {
            private let lock = NSLock()
            var openedService: String?
            var stdinData = Data()
            var closedStdin = false
            func setService(_ s: String) {
                lock.lock(); openedService = s; lock.unlock()
            }
            func appendStdin(_ d: Data) {
                lock.lock(); stdinData.append(d); lock.unlock()
            }
            func markClosed() {
                lock.lock(); closedStdin = true; lock.unlock()
            }
        }
        let capture = Capture()

        let server = try await MockADBTCPServer { conn in
            Task {
                defer { conn.close() }
                guard try await conn.readHostRequest() == "host:transport-id:3" else { return }
                try await conn.send(Data("OKAY".utf8))
                let service = try await conn.readHostRequest()
                capture.setService(service)
                try await conn.send(Data("OKAY".utf8))

                while true {
                    let (id, payload) = try await Self.readShellFrame(from: conn)
                    if id == 0 {
                        capture.appendStdin(payload)
                    } else if id == 4 {
                        capture.markClosed()
                        break
                    }
                }
                var resp = Self.shellFrame(id: 1, payload: Data("ok\n".utf8))
                resp.append(Self.shellFrame(id: 3, payload: Data([0])))
                try await conn.send(resp)
            }
        }
        defer { server.stop() }

        let endpoint = try ADBServerEndpoint(host: "127.0.0.1", port: server.port)
        let conn = ADBSocketConnection(endpoint: endpoint)
        defer { conn.close() }
        try await conn.connect()

        let longCmd = "echo '" + String(repeating: "a", count: 4000) + "'"
        let shell = ADBShellClient()
        let result = try await shell.execute(connection: conn, transportId: "3", command: longCmd)

        #expect(result.usedStdinFallback == true)
        #expect(result.exitCode == 0)
        #expect(capture.openedService == "shell,v2,raw:sh")
        #expect(capture.closedStdin == true)
        #expect(String(data: capture.stdinData, encoding: .utf8) == longCmd + "\n")
    }

    @Test("Empty directory probe maps exit codes 0, 10, 11, 12, 13 and uses trailing-newline sentinel")
    func emptyDirectoryProbeCodes() async throws {
        let codes: [UInt8] = [0, 10, 11, 12, 13]
        actor CodeQueue {
            var remaining: [UInt8]
            init(_ items: [UInt8]) { remaining = items }
            func pop() -> UInt8 { remaining.removeFirst() }
        }
        let queue = CodeQueue(codes)

        let server = try await MockADBTCPServer { conn in
            Task {
                defer { conn.close() }
                guard try await conn.readHostRequest() == "host:transport-id:3" else { return }
                try await conn.send(Data("OKAY".utf8))
                let service = try await conn.readHostRequest()
                #expect(service.contains("p=$(pwd -P && echo x)"))
                try await conn.send(Data("OKAY".utf8))

                let code = await queue.pop()
                try await conn.send(Self.shellFrame(id: 3, payload: Data([code])))
            }
        }
        defer { server.stop() }

        let endpoint = try ADBServerEndpoint(host: "127.0.0.1", port: server.port)
        let shell = ADBShellClient()

        var results: [ADBEmptyDirectoryProbeResult] = []
        for _ in codes {
            let conn = ADBSocketConnection(endpoint: endpoint)
            defer { conn.close() }
            try await conn.connect()
            let res = try await shell.probeEmptyDirectory(
                connection: conn,
                transportId: "3",
                physicalRoot: "/storage/emulated/0",
                components: [Data("Empty\nDir".utf8)]
            )
            results.append(res)
        }

        #expect(results == [.accessibleEmpty, .notFound, .notDirectoryOrSymlink, .pathChanged, .permissionDenied])
    }
}
