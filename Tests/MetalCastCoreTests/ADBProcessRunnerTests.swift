import Foundation
import Testing
@testable import MetalCastCore

@Suite("ADBProcessRunner")
struct ADBProcessRunnerTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metalcast-adb-runner-tests-\(UUID().uuidString)")
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

    @Test("run prepends -L endpoint and sanitizes child environment")
    func runPrependsAndSanitizes() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let mockAdb = try makeMockExecutable(in: dir, scriptBody: """
        echo "ARGS:$*"
        echo "SOCK:${ADB_SERVER_SOCKET:-UNSET}"
        echo "ADDR:${ANDROID_ADB_SERVER_ADDRESS:-UNSET}"
        echo "PORT:${ANDROID_ADB_SERVER_PORT:-UNSET}"
        echo "EXTRA:${CUSTOM_VAR:-UNSET}"
        """)

        let runner = ADBProcessRunner(
            customAdbPath: mockAdb.path,
            environmentProvider: {
                [
                    "PATH": "/usr/bin:/bin",
                    "ADB_SERVER_SOCKET": "tcp:127.0.0.1:5044",
                    "ANDROID_ADB_SERVER_ADDRESS": "127.0.0.1",
                    "ANDROID_ADB_SERVER_PORT": "5044",
                    "CUSTOM_VAR": "preserved"
                ]
            }
        )

        let result = try await runner.run(args: ["devices", "-l"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("ARGS:-L tcp:127.0.0.1:5044 devices -l"))
        #expect(result.stdout.contains("SOCK:UNSET"))
        #expect(result.stdout.contains("ADDR:UNSET"))
        #expect(result.stdout.contains("PORT:UNSET"))
        #expect(result.stdout.contains("EXTRA:preserved"))
    }

    @Test("spawn also prepends -L endpoint and sanitizes child environment")
    func spawnPrependsAndSanitizes() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let outputFile = dir.appendingPathComponent("spawn-env.txt")
        let mockAdb = try makeMockExecutable(in: dir, scriptBody: """
        {
          echo "ARGS:$*"
          echo "SOCK:${ADB_SERVER_SOCKET:-UNSET}"
          echo "PORT:${ANDROID_ADB_SERVER_PORT:-UNSET}"
        } > "\(outputFile.path)"
        """)

        let endpoint = try ADBServerEndpoint(host: "localhost", port: 5066)
        let runner = ADBProcessRunner(
            customAdbPath: mockAdb.path,
            explicitEndpoint: endpoint,
            environmentProvider: {
                [
                    "ADB_SERVER_SOCKET": "tcp:127.0.0.1:9999",
                    "ANDROID_ADB_SERVER_PORT": "9999"
                ]
            }
        )

        let process = try runner.spawn(args: ["shell", "echo", "hi"])
        process.waitUntilExit()

        let recorded = try String(contentsOf: outputFile, encoding: .utf8)
        #expect(recorded.contains("ARGS:-L tcp:localhost:5066 shell echo hi"))
        #expect(recorded.contains("SOCK:UNSET"))
        #expect(recorded.contains("PORT:UNSET"))
    }

    @Test("Concurrent cancellation terminates child processes promptly")
    func concurrentCancellation() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let markerFile = dir.appendingPathComponent("started.txt")
        let mockAdb = try makeMockExecutable(in: dir, scriptBody: """
        echo "started" > "\(markerFile.path)"
        sleep 30
        """)

        let runner = ADBProcessRunner(
            customAdbPath: mockAdb.path,
            explicitEndpoint: try ADBServerEndpoint(),
            environmentProvider: { ["PATH": "/usr/bin:/bin"] }
        )

        let tasks = (0..<4).map { _ in
            Task {
                try await runner.run(args: ["wait-for-device"])
            }
        }

        try await Task.sleep(nanoseconds: 150_000_000)
        for task in tasks {
            task.cancel()
        }

        let start = Date()
        for task in tasks {
            await #expect(throws: CancellationError.self) {
                _ = try await task.value
            }
        }
        #expect(Date().timeIntervalSince(start) < 2.0)
    }

    @Test("run timeout terminates child process and reports adbServerStartFailed")
    func runTimeout() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let mockAdb = try makeMockExecutable(in: dir, scriptBody: "sleep 10")
        let runner = ADBProcessRunner(
            customAdbPath: mockAdb.path,
            explicitEndpoint: try ADBServerEndpoint(),
            environmentProvider: { ["PATH": "/usr/bin:/bin"] }
        )

        await #expect(throws: ADBFileError.self) {
            _ = try await runner.run(args: ["start-server"], timeout: 0.25)
        }
    }
}
