import Foundation
import Testing
@testable import MetalCastCore

@Suite("ADBDeviceTracker")
struct ADBDeviceTrackerTests {
    @Test("Tracks two online devices and invalidates session on transportId switch and server reconnect")
    func dualDevicesSwitchAndGenerationInvalidation() async throws {
        actor ServerPhase {
            var connectionIndex = 0
            func nextConnection() -> Int {
                connectionIndex += 1
                return connectionIndex
            }
        }
        let phase = ServerPhase()

        let server = try await MockADBTCPServer { conn in
            Task {
                defer { conn.close() }
                let idx = await phase.nextConnection()
                let req = try await conn.readHostRequest()
                guard req == "host:track-devices-l" else { return }

                try await conn.send(Data("OKAY".utf8))
                if idx == 1 {
                    let frame1 = MockADBTCPServer.MockConnection.hostFrame(
                        "usb-001 device model:Pixel_8 transport_id:3\n192.168.1.8:5555 device model:Xiaomi_14 transport_id:7\n"
                    )
                    try await conn.send(frame1)
                    try await Task.sleep(nanoseconds: 150_000_000)

                    let frame2 = MockADBTCPServer.MockConnection.hostFrame(
                        "usb-001 device model:Pixel_8 transport_id:9\n192.168.1.8:5555 device model:Xiaomi_14 transport_id:7\n"
                    )
                    try await conn.send(frame2)
                    try await Task.sleep(nanoseconds: 150_000_000)
                } else {
                    let frame3 = MockADBTCPServer.MockConnection.hostFrame(
                        "usb-001 device model:Pixel_8 transport_id:9\n"
                    )
                    try await conn.send(frame3)
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
        defer { server.stop() }

        let endpoint = try ADBServerEndpoint(host: "127.0.0.1", port: server.port)
        let tracker = ADBDeviceTracker(
            endpoint: endpoint,
            reconnectDelayNanoseconds: 50_000_000
        )
        let stream = await tracker.events()
        await tracker.start()

        var sawDualDevices = false
        var oldSession: ADBFileSessionID?
        var invalidatedOnSwitch = false
        var sawGen2AfterReconnect = false

        let consumeTask = Task {
            for await event in stream {
                switch event {
                case .snapshot(let gen, let devices, let fallback):
                    #expect(!fallback)
                    if gen == 1 && devices.count == 2 && devices.contains(where: { $0.transportId == "3" }) {
                        sawDualDevices = true
                        let session = ADBFileSessionID(
                            endpoint: endpoint,
                            serverGeneration: gen,
                            transportId: "3",
                            serial: "usb-001"
                        )
                        oldSession = session
                        let valid = await tracker.isSessionValid(session)
                        #expect(valid)
                    } else if gen == 1, let session = oldSession, devices.contains(where: { $0.transportId == "9" }) {
                        let valid = await tracker.isSessionValid(session)
                        #expect(!valid)
                        invalidatedOnSwitch = true
                    } else if gen >= 2 {
                        if let session = oldSession {
                            let validOldGen = await tracker.isSessionValid(session)
                            #expect(!validOldGen)
                        }
                        sawGen2AfterReconnect = true
                        return
                    }
                case .disconnected:
                    break
                }
            }
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await consumeTask.value
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                throw NSError(domain: "Timeout", code: 1)
            }
            try await group.next()
            group.cancelAll()
        }

        await tracker.stop()
        #expect(sawDualDevices)
        #expect(invalidatedOnSwitch)
        #expect(sawGen2AfterReconnect)
    }

    @Test("Falls back from host:track-devices-l FAIL to host:track-devices + host:devices-l")
    func fallbackTrackDevices() async throws {
        let server = try await MockADBTCPServer { conn in
            Task {
                defer { conn.close() }
                let req = try await conn.readHostRequest()
                if req == "host:track-devices-l" {
                    try await conn.send(MockADBTCPServer.MockConnection.hostFail("unknown host service"))
                } else if req == "host:track-devices" {
                    try await conn.send(Data("OKAY".utf8))
                    try await conn.send(MockADBTCPServer.MockConnection.hostFrame("emulator-5554\tdevice\n"))
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } else if req == "host:devices-l" {
                    try await conn.send(Data("OKAY".utf8))
                    try await conn.send(MockADBTCPServer.MockConnection.hostFrame(
                        "emulator-5554          device product:sdk_gphone model:Pixel_7 transport_id:12\n"
                    ))
                }
            }
        }
        defer { server.stop() }

        let endpoint = try ADBServerEndpoint(host: "127.0.0.1", port: server.port)
        let tracker = ADBDeviceTracker(endpoint: endpoint, reconnectDelayNanoseconds: 50_000_000)
        let stream = await tracker.events()
        await tracker.start()

        var captured: (UInt64, [ADBDevice], Bool)?
        let waitTask = Task {
            for await event in stream {
                if case .snapshot(let gen, let devices, let usedFallback) = event {
                    captured = (gen, devices, usedFallback)
                    return
                }
            }
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await waitTask.value }
            group.addTask {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                throw NSError(domain: "Timeout", code: 2)
            }
            try await group.next()
            group.cancelAll()
        }

        await tracker.stop()
        #expect(captured?.0 == 1)
        #expect(captured?.2 == true)
        #expect(captured?.1.count == 1)
        #expect(captured?.1.first?.serial == "emulator-5554")
        #expect(captured?.1.first?.transportId == "12")
        #expect(captured?.1.first?.model == "Pixel_7")
    }
}
