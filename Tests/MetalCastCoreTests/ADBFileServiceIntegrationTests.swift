import Foundation
import Testing
@testable import MetalCastCore

@Suite("ADBFileServiceIntegration")
struct ADBFileServiceIntegrationTests {
    private static func makeStatV2(size: UInt64, dev: UInt64 = 1, ino: UInt64 = 100, mtime: Int64 = 1_764_100_000) -> Data {
        var d = Data("LST2".utf8)
        d.appendUInt32LE(0) // errno
        d.appendUInt32LE(UInt32(dev & 0xFFFFFFFF)); d.appendUInt32LE(UInt32(dev >> 32))
        d.appendUInt32LE(UInt32(ino & 0xFFFFFFFF)); d.appendUInt32LE(UInt32(ino >> 32))
        d.appendUInt32LE(0o100644)
        d.appendUInt32LE(1)
        d.appendUInt32LE(1000)
        d.appendUInt32LE(1000)
        d.appendUInt32LE(UInt32(size & 0xFFFFFFFF)); d.appendUInt32LE(UInt32(size >> 32))
        for _ in 0..<3 {
            let v = UInt64(bitPattern: mtime)
            d.appendUInt32LE(UInt32(v & 0xFFFFFFFF)); d.appendUInt32LE(UInt32(v >> 32))
        }
        return d
    }

    private static func makeStatV1(mode: UInt32 = 0o100644, size: UInt32 = 1234, mtime: UInt32 = 1_764_100_000) -> Data {
        var d = Data("STAT".utf8)
        d.appendUInt32LE(mode)
        d.appendUInt32LE(size)
        d.appendUInt32LE(mtime)
        return d
    }

    @Test("v1 metadata download ignores >4GiB size wrap and succeeds without mismatch error")
    func v1DownloadDoesNotTriggerSizeMismatch() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metalcast-v1-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let payload = Data("actual-stream-payload-12345".utf8)

        let server = try await MockADBTCPServer { conn in
            Task {
                defer { conn.close() }
                guard try await conn.readHostRequest() == "host:transport-id:11" else { return }
                try await conn.send(Data("OKAY".utf8))
                guard try await conn.readHostRequest() == "sync:" else { return }
                try await conn.send(Data("OKAY".utf8))

                let tag = String(decoding: try await conn.readExact(4), as: UTF8.self)
                let len = Int((try await conn.readExact(4)).readUInt32LE(at: 0))
                _ = len > 0 ? try await conn.readExact(len) : Data()

                if tag == "STAT" {
                    // Wrapped 32-bit size differs from actual payload count; v1 must ignore length mismatch
                    try await conn.send(Self.makeStatV1(mode: 0o100644, size: 99999, mtime: 1_764_100_000))
                } else if tag == "RECV" {
                    var frame = Data("DATA".utf8)
                    frame.appendUInt32LE(UInt32(payload.count))
                    frame.append(payload)
                    frame.append(Data("DONE".utf8))
                    frame.appendUInt32LE(0)
                    try await conn.send(frame)
                }
            }
        }
        defer { server.stop() }

        let endpoint = try ADBServerEndpoint(host: "127.0.0.1", port: server.port)
        let ledgerURL = tempDir.appendingPathComponent("ledger.json")
        let service = ADBFileService(endpoint: endpoint, ledgerURL: ledgerURL)
        let sessionId = ADBFileSessionID(endpoint: endpoint, serverGeneration: 1, transportId: "11", serial: "pixel4")

        await service.registerSessionForTesting(
            sessionId: sessionId,
            physicalRoot: "/storage/emulated/0",
            capabilities: ADBDeviceCapabilities(hasShellV2: true, hasStatV2: false, hasLsV2: false, commitMode: .mvNoClobberWithGuard)
        )

        let entry = ADBRemoteEntry(
            rawNameBytes: Data("4gb-video.mp4".utf8),
            displayName: "4gb-video.mp4",
            isLosslessUTF8: true,
            kind: .regular,
            size: nil,
            isSizeReliable: false,
            mtime: Date(timeIntervalSince1970: 1_764_100_000),
            posixMode: 0o100644
        )

        let stream = await service.events
        let ids = try await service.enqueueDownload(
            sessionId: sessionId,
            sourceComponents: [Data("Download".utf8)],
            items: [ADBDownloadPlanItem(remoteEntry: entry, targetFileName: "4gb-video.mp4")],
            localDirectory: tempDir
        )

        var completedSnap: ADBFileTaskSnapshot?
        for await event in stream {
            if case .taskUpdated(let snap) = event, snap.id == ids[0],
               snap.state == .completed || snap.state == .failed {
                completedSnap = snap
                break
            }
        }

        #expect(completedSnap?.state == .completed)
        #expect(completedSnap?.bytesTransferred == UInt64(payload.count))
        let disk = try Data(contentsOf: tempDir.appendingPathComponent("4gb-video.mp4"))
        #expect(disk == payload)
    }

    @Test("Upload commit disconnect enters pendingConfirmation and verifyPendingTask resolves it")
    func uploadPendingConfirmationAndVerifyFlow() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metalcast-pending-up-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let localFile = tempDir.appendingPathComponent("artifact.bin")
        let fileData = Data("release-binary".utf8)
        try fileData.write(to: localFile)

        let server = try await MockADBTCPServer { conn in
            Task {
                defer { conn.close() }
                guard try await conn.readHostRequest() == "host:transport-id:3" else { return }
                try await conn.send(Data("OKAY".utf8))
                let service = try await conn.readHostRequest()
                try await conn.send(Data("OKAY".utf8))

                if service == "sync:" {
                    let tag = String(decoding: try await conn.readExact(4), as: UTF8.self)
                    let len = Int((try await conn.readExact(4)).readUInt32LE(at: 0))
                    _ = try await conn.readExact(len)
                    if tag == "SEND" {
                        while true {
                            let fTag = String(decoding: try await conn.readExact(4), as: UTF8.self)
                            let fVal = (try await conn.readExact(4)).readUInt32LE(at: 0)
                            if fTag == "DATA" {
                                _ = try await conn.readExact(Int(fVal))
                            } else if fTag == "DONE" {
                                break
                            }
                        }
                        var okay = Data("OKAY".utf8)
                        okay.appendUInt32LE(0)
                        try await conn.send(okay)
                    }
                } else if service.contains("mv -nT") && !service.contains(".metalcast-probe-") {
                    // Disconnect during commit without sending kIdExit
                    return
                } else {
                    // mkdir, probe, or verifyPendingUpload -> exit 0
                    var exit = Data([3])
                    exit.appendUInt32LE(1)
                    exit.append(0)
                    try await conn.send(exit)
                }
            }
        }
        defer { server.stop() }

        let endpoint = try ADBServerEndpoint(host: "127.0.0.1", port: server.port)
        let ledgerURL = tempDir.appendingPathComponent("ledger.json")
        let service = ADBFileService(endpoint: endpoint, ledgerURL: ledgerURL)
        let sessionId = ADBFileSessionID(endpoint: endpoint, serverGeneration: 1, transportId: "3", serial: "dev3")

        await service.registerSessionForTesting(
            sessionId: sessionId,
            physicalRoot: "/storage/emulated/0",
            capabilities: ADBDeviceCapabilities(hasShellV2: true, hasStatV2: true, hasLsV2: true, commitMode: .mvNoClobberNoTarget)
        )

        let stream = await service.events
        let taskIds = try await service.enqueueUpload(
            sessionId: sessionId,
            targetComponents: [Data("Download".utf8)],
            items: [ADBUploadPlanItem(localURL: localFile, targetFileName: "artifact.bin", fileSize: UInt64(fileData.count))]
        )

        var pendingSnap: ADBFileTaskSnapshot?
        for await event in stream {
            if case .taskUpdated(let snap) = event, snap.id == taskIds[0], snap.state == .pendingConfirmation {
                pendingSnap = snap
                break
            }
        }

        #expect(pendingSnap?.state == .pendingConfirmation)
        let ledgerEntries = await service.ledgerStore.entries()
        #expect(ledgerEntries.count == 1)
        #expect(ledgerEntries[0].state == .pendingConfirmation)

        let verified = try await service.verifyPendingTask(taskId: taskIds[0])
        #expect(verified?.state == .completed)
        let remainingLedger = await service.ledgerStore.entries()
        #expect(remainingLedger.isEmpty)
    }

    @Test("Global 2-slot transfer cap across 3 devices leaves independent browsing unblocked")
    func globalTwoSlotCapAndIndependentBrowse() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metalcast-slots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        actor ConcurrencyTracker {
            var activeTransfers = 0
            var maxObservedTransfers = 0
            func enterTransfer() {
                activeTransfers += 1
                maxObservedTransfers = max(maxObservedTransfers, activeTransfers)
            }
            func exitTransfer() {
                activeTransfers -= 1
            }
        }
        let tracker = ConcurrencyTracker()

        let server = try await MockADBTCPServer { conn in
            Task {
                defer { conn.close() }
                _ = try await conn.readHostRequest() // host:transport-id:<x>
                try await conn.send(Data("OKAY".utf8))
                let service = try await conn.readHostRequest()
                try await conn.send(Data("OKAY".utf8))

                if service == "sync:" {
                    let tag = String(decoding: try await conn.readExact(4), as: UTF8.self)
                    let len = Int((try await conn.readExact(4)).readUInt32LE(at: 0))
                    _ = try await conn.readExact(len)
                    if tag == "RECV" {
                        await tracker.enterTransfer()
                        try await Task.sleep(nanoseconds: 220_000_000)
                        var resp = Data("DATA".utf8)
                        resp.appendUInt32LE(2)
                        resp.append(Data("ok".utf8))
                        resp.append(Data("DONE".utf8))
                        resp.appendUInt32LE(0)
                        try await conn.send(resp)
                        await tracker.exitTransfer()
                    } else if tag == "STAT" || tag == "LST2" {
                        try await conn.send(Self.makeStatV2(size: 2))
                    } else if tag == "LIS2" {
                        var done = Data("DONE".utf8)
                        done.append(Data(repeating: 0, count: 72))
                        try await conn.send(done)
                    }
                } else {
                    var exit = Data([3])
                    exit.appendUInt32LE(1)
                    exit.append(0)
                    try await conn.send(exit)
                }
            }
        }
        defer { server.stop() }

        let endpoint = try ADBServerEndpoint(host: "127.0.0.1", port: server.port)
        let service = ADBFileService(endpoint: endpoint, ledgerURL: tempDir.appendingPathComponent("ledger.json"))
        let caps = ADBDeviceCapabilities(hasShellV2: true, hasStatV2: true, hasLsV2: true, commitMode: .mvNoClobberNoTarget)

        var sessions: [ADBFileSessionID] = []
        for idx in 1...3 {
            let sid = ADBFileSessionID(endpoint: endpoint, serverGeneration: 1, transportId: "\(idx)", serial: "dev-\(idx)")
            await service.registerSessionForTesting(sessionId: sid, physicalRoot: "/storage/emulated/0", capabilities: caps)
            sessions.append(sid)
        }

        let stream = await service.events
        var allTaskIds: Set<UUID> = []
        for (idx, sid) in sessions.enumerated() {
            let entry = ADBRemoteEntry(
                rawNameBytes: Data("file\(idx).bin".utf8),
                displayName: "file\(idx).bin",
                isLosslessUTF8: true,
                kind: .regular,
                size: 2,
                isSizeReliable: true,
                mtime: Date(timeIntervalSince1970: 1_764_100_000),
                dev: 1,
                ino: 100
            )
            let ids = try await service.enqueueDownload(
                sessionId: sid,
                sourceComponents: [Data("Download".utf8)],
                items: [ADBDownloadPlanItem(remoteEntry: entry, targetFileName: "file\(idx).bin")],
                localDirectory: tempDir
            )
            allTaskIds.insert(ids[0])
        }

        // Independent directory browse while 2 transfer slots are busy must complete immediately
        let browseStream = await service.listDirectory(sessionId: sessions[2], relativeComponents: [Data("Download".utf8)])
        for try await _ in browseStream {}

        var completedCount = 0
        for await event in stream {
            if case .taskUpdated(let snap) = event, allTaskIds.contains(snap.id), snap.state == .completed {
                completedCount += 1
                if completedCount == 3 { break }
            }
        }

        let maxConcurrent = await tracker.maxObservedTransfers
        #expect(maxConcurrent <= 2)
        #expect(completedCount == 3)
    }

    @Test("Batch delete reports per-item deleted, targetChanged, notFound, and disconnect pendingConfirmation")
    func batchDeleteMixedResultsAndDisconnect() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metalcast-del-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let server = try await MockADBTCPServer { conn in
            Task {
                defer { conn.close() }
                guard try await conn.readHostRequest() == "host:transport-id:3" else { return }
                try await conn.send(Data("OKAY".utf8))
                let service = try await conn.readHostRequest()
                try await conn.send(Data("OKAY".utf8))

                if service == "sync:" {
                    let tag = String(decoding: try await conn.readExact(4), as: UTF8.self)
                    let len = Int((try await conn.readExact(4)).readUInt32LE(at: 0))
                    let path = String(decoding: try await conn.readExact(len), as: UTF8.self)
                    if tag == "LST2" {
                        if path.hasSuffix("/changed.txt") {
                            try await conn.send(Self.makeStatV2(size: 999, dev: 1, ino: 200))
                        } else if path.hasSuffix("/ok.txt") {
                            try await conn.send(Self.makeStatV2(size: 10, dev: 1, ino: 100))
                        } else if path.hasSuffix("/gone.txt") {
                            try await conn.send(Self.makeStatV2(size: 10, dev: 1, ino: 101))
                        } else if path.hasSuffix("/drop.txt") {
                            try await conn.send(Self.makeStatV2(size: 10, dev: 1, ino: 102))
                        }
                    }
                } else if service.contains("'ok.txt'") {
                    var exit = Data([3]); exit.appendUInt32LE(1); exit.append(0)
                    try await conn.send(exit)
                } else if service.contains("'gone.txt'") {
                    var exit = Data([3]); exit.appendUInt32LE(1); exit.append(30)
                    try await conn.send(exit)
                } else if service.contains("'drop.txt'") {
                    // Disconnect without kIdExit
                    return
                }
            }
        }
        defer { server.stop() }

        let endpoint = try ADBServerEndpoint(host: "127.0.0.1", port: server.port)
        let service = ADBFileService(endpoint: endpoint, ledgerURL: tempDir.appendingPathComponent("ledger.json"))
        let sessionId = ADBFileSessionID(endpoint: endpoint, serverGeneration: 1, transportId: "3", serial: "dev3")
        await service.registerSessionForTesting(
            sessionId: sessionId,
            physicalRoot: "/storage/emulated/0",
            capabilities: ADBDeviceCapabilities(hasShellV2: true, hasStatV2: true, hasLsV2: true, commitMode: .mvNoClobberNoTarget)
        )

        func makeEntry(_ name: String, ino: UInt64) -> ADBRemoteEntry {
            ADBRemoteEntry(
                rawNameBytes: Data(name.utf8),
                displayName: name,
                isLosslessUTF8: true,
                kind: .regular,
                size: 10,
                isSizeReliable: true,
                mtime: Date(timeIntervalSince1970: 1_764_100_000),
                dev: 1,
                ino: ino
            )
        }

        let targets = [
            ADBDeleteTarget(remoteEntry: makeEntry("ok.txt", ino: 100)),
            ADBDeleteTarget(remoteEntry: makeEntry("changed.txt", ino: 199)),
            ADBDeleteTarget(remoteEntry: makeEntry("gone.txt", ino: 101)),
            ADBDeleteTarget(remoteEntry: makeEntry("drop.txt", ino: 102)),
            ADBDeleteTarget(remoteEntry: makeEntry("after_drop.txt", ino: 103))
        ]

        let stream = await service.events
        let taskId = try await service.enqueueDelete(
            sessionId: sessionId,
            directoryComponents: [Data("Download".utf8)],
            items: targets
        )

        var finalSnap: ADBFileTaskSnapshot?
        for await event in stream {
            if case .taskUpdated(let snap) = event, snap.id == taskId,
               snap.state == .completed || snap.state == .pendingConfirmation || snap.state == .failed {
                finalSnap = snap
                break
            }
        }

        let results = finalSnap?.deleteResults ?? []
        #expect(finalSnap?.state == .pendingConfirmation)
        #expect(results.count == 5)
        #expect(results[0].status == .deleted)
        #expect(results[1].status == .targetChanged)
        #expect(results[2].status == .notFound)
        #expect(results[3].status == .pendingConfirmation)
        #expect(results[4].status == .notExecuted)
    }
}
