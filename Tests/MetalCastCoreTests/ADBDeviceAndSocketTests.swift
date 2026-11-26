import Foundation
import Testing
@testable import MetalCastCore

@Suite("ADBDeviceAndSocket")
struct ADBDeviceAndSocketTests {
    @Test("selectionKey distinguishes duplicate serials by transportId")
    func selectionKeyDistinguishesDuplicateSerial() {
        let oldOffline = ADBDevice(serial: "8e45f92a", state: .offline, model: "Xiaomi", transportId: "2")
        let newOnline = ADBDevice(serial: "8e45f92a", state: .device, model: "Xiaomi", transportId: "5")
        let noTid = ADBDevice(serial: "8e45f92a", state: .unauthorized, model: nil, transportId: nil)

        #expect(oldOffline.selectionKey == "tid:2")
        #expect(newOnline.selectionKey == "tid:5")
        #expect(noTid.selectionKey == "serial:8e45f92a")
        #expect(oldOffline.id != newOnline.id)
    }

    @Test("Handles 1-byte fragmentation and coalesced multi-frames")
    func oneByteFragmentationAndCoalescing() async throws {
        let server = try await MockADBTCPServer { conn in
            Task {
                defer { conn.close() }
                let req = try await conn.readHostRequest()
                if req == "host-transport-id:3:features" {
                    let response = Data("OKAY".utf8) + MockADBTCPServer.MockConnection.hostFrame("shell_v2,stat_v2,ls_v2")
                    try await conn.sendFragmentedOneByte(response, delayNanoseconds: 400_000)
                } else if req == "host:devices-l" {
                    let payload = "8e45f92a device model:Xiaomi_14_Pro transport_id:3\n192.168.1.50:5555 device model:Galaxy transport_id:7\n"
                    let response = Data("OKAY".utf8) + MockADBTCPServer.MockConnection.hostFrame(payload)
                    try await conn.send(response)
                }
            }
        }
        defer { server.stop() }

        let endpoint = try ADBServerEndpoint(host: "127.0.0.1", port: server.port)

        let conn1 = ADBSocketConnection(endpoint: endpoint)
        defer { conn1.close() }
        try await conn1.connect()
        let features = try await conn1.queryFeatures(transportId: "3")
        #expect(features == ["shell_v2", "stat_v2", "ls_v2"])

        let conn2 = ADBSocketConnection(endpoint: endpoint)
        defer { conn2.close() }
        try await conn2.connect()
        let devices = try await conn2.listDevicesLong()
        #expect(devices.count == 2)
        #expect(devices[0].selectionKey == "tid:3")
        #expect(devices[1].selectionKey == "tid:7")
    }

    @Test("Parses fragmented Host FAIL hex length and preserves stage")
    func hostFailHexLength() async throws {
        let server = try await MockADBTCPServer { conn in
            Task {
                defer { conn.close() }
                _ = try await conn.readHostRequest()
                try await conn.sendFragmentedOneByte(
                    MockADBTCPServer.MockConnection.hostFail("device unauthorized"),
                    delayNanoseconds: 300_000
                )
            }
        }
        defer { server.stop() }

        let endpoint = try ADBServerEndpoint(host: "127.0.0.1", port: server.port)
        let conn = ADBSocketConnection(endpoint: endpoint)
        defer { conn.close() }
        try await conn.connect()

        do {
            try await conn.selectTransport(transportId: "9")
            Issue.record("Expected protocolError")
        } catch let error as ADBFileError {
            #expect(error == .protocolError(stage: "transport-id", detail: "device unauthorized"))
        }
    }

    @Test("Handshake timeout and idempotent cancellation")
    func timeoutAndCancellation() async throws {
        let server = try await MockADBTCPServer { conn in
            Task {
                _ = try? await conn.readHostRequest()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                conn.close()
            }
        }
        defer { server.stop() }

        let endpoint = try ADBServerEndpoint(host: "127.0.0.1", port: server.port)

        let connTimeout = ADBSocketConnection(endpoint: endpoint)
        defer { connTimeout.close() }
        try await connTimeout.connect()
        do {
            try await connTimeout.selectTransport(transportId: "3", timeout: 0.2)
            Issue.record("Expected timeout error")
        } catch let error as ADBFileError {
            if case .protocolError(let stage, _) = error {
                #expect(stage == "transport-id")
            } else {
                Issue.record("Unexpected error: \(error)")
            }
        }

        let connCancel = ADBSocketConnection(endpoint: endpoint)
        defer { connCancel.close() }
        try await connCancel.connect()
        let task = Task {
            try await connCancel.selectTransport(transportId: "3", timeout: 10.0)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test("Concurrent ECONNREFUSED coalesces into a single start-server call")
    func concurrentECONNREFUSEDCoalesces() async throws {
        let probeServer = try await MockADBTCPServer { _ in }
        let freePort = probeServer.port
        probeServer.stop()
        try await Task.sleep(nanoseconds: 80_000_000)

        let endpoint = try ADBServerEndpoint(host: "127.0.0.1", port: freePort)

        actor Counter {
            var count = 0
            var activeServer: MockADBTCPServer?
            func incrementAndStartServer(port: UInt16) async throws {
                count += 1
                try await Task.sleep(nanoseconds: 120_000_000)
                activeServer = try await MockADBTCPServer(port: port) { conn in
                    Task {
                        defer { conn.close() }
                        let req = try await conn.readHostRequest()
                        if req == "host:devices-l" {
                            let response = Data("OKAY".utf8) + MockADBTCPServer.MockConnection.hostFrame("abc device transport_id:1\n")
                            try await conn.send(response)
                        }
                    }
                }
            }
            func cleanup() {
                activeServer?.stop()
            }
        }

        let counter = Counter()
        let starter = ADBServerStarter { ep in
            try await counter.incrementAndStartServer(port: ep.port)
        }

        let results = try await withThrowingTaskGroup(of: (Int, Bool).self) { group in
            for _ in 0..<5 {
                group.addTask {
                    let (conn, didStart) = try await ADBSocketConnection.connectWithAutoStart(
                        endpoint: endpoint,
                        starter: starter,
                        timeout: 2.0
                    )
                    defer { conn.close() }
                    let devices = try await conn.listDevicesLong()
                    return (devices.count, didStart)
                }
            }

            var out: [(Int, Bool)] = []
            for try await item in group {
                out.append(item)
            }
            return out
        }

        await counter.cleanup()

        let startCount = await counter.count
        #expect(startCount == 1)
        #expect(results.count == 5)
        #expect(results.allSatisfy { $0.0 == 1 && $0.1 == true })
    }
}
