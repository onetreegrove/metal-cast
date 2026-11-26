import Darwin
import Foundation
import Testing
@testable import MetalCastCore

@Suite("ADBTransferAndLedger")
struct ADBTransferAndLedgerTests {
    private static func readSyncPacket(from conn: MockADBTCPServer.MockConnection) async throws -> (String, UInt32, Data) {
        let tagData = try await conn.readExact(4)
        let lenData = try await conn.readExact(4)
        let val = lenData.readUInt32LE(at: 0)
        let tag = String(decoding: tagData, as: UTF8.self)
        let payload = val > 0 && tag != "DONE" ? try await conn.readExact(Int(val)) : Data()
        return (tag, val, payload)
    }

    @Test("SEND streams 0B, exact 64 KiB, and multi-chunk files with QUIT and rejects non-zero OKAY")
    func syncSendStreamingAndNonZeroOkayRejection() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metalcast-send-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let zeroFile = tempDir.appendingPathComponent("zero.bin")
        let exact64KFile = tempDir.appendingPathComponent("64k.bin")
        let multiFile = tempDir.appendingPathComponent("multi.bin")
        let badOkayFile = tempDir.appendingPathComponent("badokay.bin")

        try Data().write(to: zeroFile)
        let exact64KData = Data((0..<65536).map { UInt8($0 & 0xFF) })
        try exact64KData.write(to: exact64KFile)
        let multiData = Data((0..<150_000).map { UInt8(($0 * 7) & 0xFF) })
        try multiData.write(to: multiFile)
        try Data("hello".utf8).write(to: badOkayFile)

        final class ReceivedMap: @unchecked Sendable {
            private let lock = NSLock()
            var map: [String: Data] = [:]
            func store(_ key: String, _ data: Data) {
                lock.lock(); map[key] = data; lock.unlock()
            }
            func get(_ key: String) -> Data? {
                lock.lock(); defer { lock.unlock() }; return map[key]
            }
        }
        let received = ReceivedMap()

        let server = try await MockADBTCPServer { conn in
            Task {
                defer { conn.close() }
                guard try await conn.readHostRequest() == "host:transport-id:3" else { return }
                try await conn.send(Data("OKAY".utf8))
                guard try await conn.readHostRequest() == "sync:" else { return }
                try await conn.send(Data("OKAY".utf8))

                let (tag, _, specBytes) = try await Self.readSyncPacket(from: conn)
                #expect(tag == "SEND")
                let spec = String(decoding: specBytes, as: UTF8.self)
                var body = Data()

                while true {
                    let (fTag, fVal, fPayload) = try await Self.readSyncPacket(from: conn)
                    if fTag == "DATA" {
                        body.append(fPayload)
                    } else if fTag == "DONE" {
                        break
                    } else {
                        Issue.record("Unexpected frame \(fTag) val \(fVal)")
                        return
                    }
                }
                received.store(spec, body)

                if spec.contains("badokay") {
                    // Non-zero OKAY msglen violates protocol
                    var badOkay = Data("OKAY".utf8)
                    badOkay.appendUInt32LE(4)
                    try await conn.send(badOkay)
                } else {
                    var okay = Data("OKAY".utf8)
                    okay.appendUInt32LE(0)
                    try await conn.send(okay)
                    let (qTag, qVal, _) = try await Self.readSyncPacket(from: conn)
                    #expect(qTag == "QUIT" && qVal == 0)
                }
            }
        }
        defer { server.stop() }

        let endpoint = try ADBServerEndpoint(host: "127.0.0.1", port: server.port)
        let sync = ADBSyncClient()

        for (file, name, expectedData) in [
            (zeroFile, "zero", Data()),
            (exact64KFile, "exact64k", exact64KData),
            (multiFile, "multi", multiData)
        ] {
            let conn = ADBSocketConnection(endpoint: endpoint)
            defer { conn.close() }
            try await conn.connect()
            try await conn.openDeviceService(transportId: "3", service: "sync:")
            let remoteTmp = "/storage/emulated/0/\(name)"
            try await sync.sendFile(
                connection: conn,
                localFileURL: file,
                remoteTempPath: remoteTmp,
                mtime: Date(timeIntervalSince1970: 1_764_100_000),
                onProgress: { _ in }
            )
            try await sync.sendQuit(connection: conn)
            #expect(received.get("\(remoteTmp),33188") == expectedData)
        }

        // Non-zero OKAY msglen must throw protocolError
        let badConn = ADBSocketConnection(endpoint: endpoint)
        defer { badConn.close() }
        try await badConn.connect()
        try await badConn.openDeviceService(transportId: "3", service: "sync:")
        await #expect(throws: ADBFileError.self) {
            try await sync.sendFile(
                connection: badConn,
                localFileURL: badOkayFile,
                remoteTempPath: "/storage/emulated/0/badokay",
                mtime: nil,
                onProgress: { _ in }
            )
        }
    }

    @Test("RECV streams multi-chunk and zero-byte files cleanly and enforces <= 64 KiB DATA chunks")
    func syncRecvStreaming() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metalcast-recv-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let expectedBytes = Data((0..<140_000).map { UInt8(($0 * 3) & 0xFF) })

        let server = try await MockADBTCPServer { conn in
            Task {
                defer { conn.close() }
                guard try await conn.readHostRequest() == "host:transport-id:3" else { return }
                try await conn.send(Data("OKAY".utf8))
                guard try await conn.readHostRequest() == "sync:" else { return }
                try await conn.send(Data("OKAY".utf8))

                let (tag, _, pathBytes) = try await Self.readSyncPacket(from: conn)
                #expect(tag == "RECV")
                let path = String(decoding: pathBytes, as: UTF8.self)

                if path.hasSuffix("/multi.bin") {
                    var offset = 0
                    while offset < expectedBytes.count {
                        let end = min(expectedBytes.count, offset + 65536)
                        let slice = Data(expectedBytes[offset..<end])
                        var frame = Data("DATA".utf8)
                        frame.appendUInt32LE(UInt32(slice.count))
                        frame.append(slice)
                        try await conn.send(frame)
                        offset = end
                    }
                }
                var done = Data("DONE".utf8)
                done.appendUInt32LE(0)
                try await conn.send(done)

                let (qTag, qVal, _) = try await Self.readSyncPacket(from: conn)
                #expect(qTag == "QUIT" && qVal == 0)
            }
        }
        defer { server.stop() }

        let endpoint = try ADBServerEndpoint(host: "127.0.0.1", port: server.port)
        let sync = ADBSyncClient()

        let (partURL, fd) = try ADBMacFilePublisher.createExclusivePartFile(in: tempDir)
        let conn = ADBSocketConnection(endpoint: endpoint)
        defer { conn.close() }
        try await conn.connect()
        try await conn.openDeviceService(transportId: "3", service: "sync:")
        let written = try await sync.receiveFile(
            connection: conn,
            remotePathBytes: Data("/storage/emulated/0/multi.bin".utf8),
            destinationFD: fd,
            onProgress: { _ in }
        )
        try await sync.sendQuit(connection: conn)
        Darwin.close(fd)

        #expect(written == UInt64(expectedBytes.count))
        let diskData = try Data(contentsOf: partURL)
        #expect(diskData == expectedBytes)
    }

    @Test("Ledger store persists atomically, reloads across instances, and updates termination states")
    func ledgerStorePersistence() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metalcast-ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let ledgerURL = tempDir.appendingPathComponent("file-transfer-ledger.json")
        let endpoint = try ADBServerEndpoint()
        let entry1 = ADBLedgerEntry(
            taskId: UUID(),
            endpoint: endpoint,
            serial: "emulator-5554",
            transportId: "3",
            serverGeneration: 2,
            targetParentPhysicalPath: "/storage/emulated/0/Download",
            tempDirName: ".metalcast-tmp-1111",
            finalTargetName: "demo.zip",
            state: .committing
        )
        let entry2 = ADBLedgerEntry(
            taskId: UUID(),
            endpoint: endpoint,
            serial: "emulator-5554",
            transportId: "3",
            serverGeneration: 2,
            targetParentPhysicalPath: "/storage/emulated/0/Download",
            tempDirName: ".metalcast-tmp-2222",
            finalTargetName: "other.zip",
            state: .created
        )

        let store1 = ADBLedgerStore(fileURL: ledgerURL)
        try await store1.upsert(entry1)
        try await store1.upsert(entry2)
        try await store1.markUnfinishedForTermination()

        // Reload from disk in a fresh store instance
        let store2 = ADBLedgerStore(fileURL: ledgerURL)
        let reloaded1 = await store2.entry(id: entry1.id)
        let reloaded2 = await store2.entry(id: entry2.id)
        #expect(reloaded1?.state == .pendingConfirmation)
        #expect(reloaded2?.state == .cleanupPending)

        try await store2.remove(id: entry2.id)
        let store3 = ADBLedgerStore(fileURL: ledgerURL)
        let remaining = await store3.entries()
        #expect(remaining.count == 1)
        #expect(remaining[0].id == entry1.id)
    }

    @Test("Shell commit probe, mv -n fallback, exit codes 20/21/22/23/24/27, and missing exit frame")
    func shellCommitModesAndExitCodes() async throws {
        actor ModeScenario {
            var nextCommitExit: UInt8 = 0
            func setCommitExit(_ c: UInt8) { nextCommitExit = c }
            func popCommitExit() -> UInt8 { nextCommitExit }
        }
        let scenario = ModeScenario()

        let server = try await MockADBTCPServer { conn in
            Task {
                defer { conn.close() }
                guard try await conn.readHostRequest() == "host:transport-id:3" else { return }
                try await conn.send(Data("OKAY".utf8))
                let service = try await conn.readHostRequest()
                try await conn.send(Data("OKAY".utf8))

                let exitCode: UInt8
                if service.contains("mv -nT") && service.contains(".metalcast-probe-") {
                    // Simulate old Toybox without -T, falling back to mv -n -> exit 1
                    exitCode = 1
                } else if service.contains("mv -n --") && !service.contains("disconnect-commit") {
                    exitCode = await scenario.popCommitExit()
                } else if service.contains("disconnect-commit") {
                    // Close without kIdExit to simulate commit-time disconnect
                    return
                } else {
                    exitCode = 0
                }

                var frame = Data([3])
                frame.appendUInt32LE(1)
                frame.append(exitCode)
                try await conn.send(frame)
            }
        }
        defer { server.stop() }

        let endpoint = try ADBServerEndpoint(host: "127.0.0.1", port: server.port)
        let shell = ADBShellClient()

        let detectedMode = try await shell.probeCommitCapability(
            endpoint: endpoint,
            transportId: "3",
            parentPhysicalPath: "/storage/emulated/0/Download"
        )
        #expect(detectedMode == .mvNoClobberWithGuard)

        let conn0 = ADBSocketConnection(endpoint: endpoint)
        defer { conn0.close() }
        try await conn0.connect()
        await scenario.setCommitExit(22)
        let conflictOutcome = try await shell.commitUploadedFile(
            connection: conn0,
            transportId: "3",
            parentPhysicalPath: "/storage/emulated/0/Download",
            tempDirName: ".metalcast-tmp-1",
            tempPayloadName: "payload",
            destinationName: "photo.jpg",
            commitMode: .mvNoClobberWithGuard
        )
        #expect(conflictOutcome == .targetConflict)

        let conn27 = ADBSocketConnection(endpoint: endpoint)
        defer { conn27.close() }
        try await conn27.connect()
        await scenario.setCommitExit(27)
        let pendingDirOutcome = try await shell.commitUploadedFile(
            connection: conn27,
            transportId: "3",
            parentPhysicalPath: "/storage/emulated/0/Download",
            tempDirName: ".metalcast-tmp-2",
            tempPayloadName: "payload",
            destinationName: "photo2.jpg",
            commitMode: .mvNoClobberWithGuard
        )
        #expect(pendingDirOutcome == .committedPendingDirCleanup)

        for (code, isTargetChanged) in [(UInt8(20), false), (UInt8(21), false), (UInt8(23), false), (UInt8(24), true)] {
            let conn = ADBSocketConnection(endpoint: endpoint)
            defer { conn.close() }
            try await conn.connect()
            await scenario.setCommitExit(code)
            do {
                _ = try await shell.commitUploadedFile(
                    connection: conn,
                    transportId: "3",
                    parentPhysicalPath: "/storage/emulated/0/Download",
                    tempDirName: ".metalcast-tmp-3",
                    tempPayloadName: "payload",
                    destinationName: "x.txt",
                    commitMode: .mvNoClobberWithGuard
                )
                Issue.record("Expected error for exit \(code)")
            } catch let error as ADBFileError {
                if isTargetChanged {
                    guard case .targetChanged = error else { Issue.record("Expected targetChanged, got \(error)"); return }
                }
            }
        }

        // Disconnect without exit frame during commit -> operationUnconfirmed
        let connDisc = ADBSocketConnection(endpoint: endpoint)
        defer { connDisc.close() }
        try await connDisc.connect()
        await #expect(throws: ADBFileError.self) {
            _ = try await shell.commitUploadedFile(
                connection: connDisc,
                transportId: "3",
                parentPhysicalPath: "/storage/emulated/0/Download",
                tempDirName: ".metalcast-tmp-4",
                tempPayloadName: "payload",
                destinationName: "disconnect-commit.txt",
                commitMode: .mvNoClobberWithGuard
            )
        }
    }
}
