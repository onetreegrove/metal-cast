import Foundation
import Testing
@testable import MetalCastCore

@Suite("ADBManager")
struct ADBManagerTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metalcast-adb-manager-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeMockExecutable(in dir: URL, scriptBody: String) throws -> URL {
        let url = dir.appendingPathComponent("mock-adb-\(UUID().uuidString).sh")
        let fullScript = "#!/bin/sh\n\(scriptBody)\n"
        try fullScript.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test("connectWifi times out cleanly and disconnects zombie offline transport")
    func connectWifiTimeoutCleansUpOfflineTransport() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let logFile = dir.appendingPathComponent("adb-calls.log")
        let mockAdb = try makeMockExecutable(in: dir, scriptBody: """
        echo "$*" >> "\(logFile.path)"
        # Strip leading -L <endpoint>
        shift 2
        case "$1" in
          devices)
            echo "List of devices attached"
            ;;
          connect)
            sleep 30
            ;;
          disconnect)
            echo "disconnected $2"
            ;;
        esac
        """)

        let runner = ADBProcessRunner(
            customAdbPath: mockAdb.path,
            explicitEndpoint: try ADBServerEndpoint(),
            environmentProvider: { ["PATH": "/usr/bin:/bin"] }
        )
        let manager = ADBManager(runner: runner)

        let start = Date()
        await #expect(throws: ADBError.self) {
            _ = try await manager.connectWifi(ip: "10.128.0.151", port: 5555, timeout: 0.3)
        }
        #expect(Date().timeIntervalSince(start) < 2.0)

        let calls = try String(contentsOf: logFile, encoding: .utf8)
        #expect(calls.contains("connect 10.128.0.151:5555"))
        #expect(calls.contains("disconnect 10.128.0.151:5555"))
    }

    @Test("connectWifi clears stale offline transport before reconnecting and rejects offline status")
    func connectWifiRejectsStaleOfflineDevice() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let logFile = dir.appendingPathComponent("adb-calls.log")
        let mockAdb = try makeMockExecutable(in: dir, scriptBody: """
        echo "$*" >> "\(logFile.path)"
        shift 2
        case "$1" in
          devices)
            echo "List of devices attached"
            echo "192.168.1.50:5555\toffline\ttransport_id:5"
            ;;
          disconnect)
            echo "disconnected $2"
            ;;
          connect)
            echo "connected to 192.168.1.50:5555"
            ;;
        esac
        """)

        let runner = ADBProcessRunner(
            customAdbPath: mockAdb.path,
            explicitEndpoint: try ADBServerEndpoint(),
            environmentProvider: { ["PATH": "/usr/bin:/bin"] }
        )
        let manager = ADBManager(runner: runner)

        let ok = try await manager.connectWifi(ip: "192.168.1.50", port: 5555, timeout: 1.0)
        #expect(!ok)

        let calls = try String(contentsOf: logFile, encoding: .utf8)
        #expect(calls.contains("disconnect 192.168.1.50:5555"))
    }

    @Test("connectWifi succeeds when device state reaches device")
    func connectWifiSucceedsWhenDeviceOnline() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let stateFile = dir.appendingPathComponent("connected.flag")
        let mockAdb = try makeMockExecutable(in: dir, scriptBody: """
        shift 2
        case "$1" in
          devices)
            echo "List of devices attached"
            if [ -f "\(stateFile.path)" ]; then
              echo "192.168.1.50:5555\tdevice\tmodel:Pixel\ttransport_id:9"
            fi
            ;;
          connect)
            touch "\(stateFile.path)"
            echo "connected to 192.168.1.50:5555"
            ;;
        esac
        """)

        let runner = ADBProcessRunner(
            customAdbPath: mockAdb.path,
            explicitEndpoint: try ADBServerEndpoint(),
            environmentProvider: { ["PATH": "/usr/bin:/bin"] }
        )
        let manager = ADBManager(runner: runner)

        let ok = try await manager.connectWifi(ip: "192.168.1.50", port: 5555, timeout: 1.0)
        #expect(ok)
    }
}
