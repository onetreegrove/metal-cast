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

    @Test("Cancelling an active upload cleans up remote temp dir outside cancelled task and removes ledger")
    func cancelActiveUploadCleansUpRemoteStaging() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metalcast-cancel-up-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let localFile = tempDir.appendingPathComponent("large.bin")
        try Data(repeating: 0x42, count: 512_000).write(to: localFile)

        actor CleanupRecorder {
            var cleanedUp = false
            func markCleaned() { cleanedUp = true }
        }
        let recorder = CleanupRecorder()

        let server = try await MockADBTCPServer { conn in
            Task {
                defer { conn.close() }
                guard try await conn.readHostRequest() == "host:transport-id:3" else { return }
                try await conn.send(Data("OKAY".utf8))
                let service = try await conn.readHostRequest()
                try await conn.send(Data("OKAY".utf8))

                if service == "sync:" {
                    // Keep SEND open slightly so test can cancel while transferring
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                } else if service.contains("rmdir --") && service.contains(".metalcast-tmp-") {
                    await recorder.markCleaned()
                    var exit = Data([3]); exit.appendUInt32LE(1); exit.append(0)
                    try await conn.send(exit)
                } else {
                    var exit = Data([3]); exit.appendUInt32LE(1); exit.append(0)
                    try await conn.send(exit)
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

        let stream = await service.events
        let ids = try await service.enqueueUpload(
            sessionId: sessionId,
            targetComponents: [Data("Download".utf8)],
            items: [ADBUploadPlanItem(localURL: localFile, targetFileName: "large.bin", fileSize: 512_000)]
        )

        var sawTransferring = false
        for await event in stream {
            if case .taskUpdated(let snap) = event, snap.id == ids[0] {
                if snap.state == .transferring && !sawTransferring {
                    sawTransferring = true
                    await service.cancelTransfer(taskId: ids[0])
                } else if snap.state == .cancelled {
                    break
                }
            }
        }

        let wasCleaned = await recorder.cleanedUp
        let ledgerAfter = await service.ledgerStore.entries()
        #expect(sawTransferring)
        #expect(wasCleaned)
        #expect(ledgerAfter.isEmpty)
    }

    @Test("Commit conflict rename updates ledger finalTargetName before pendingConfirmation verify")
    func commitConflictRenameUpdatesLedger() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metalcast-commit-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let localFile = tempDir.appendingPathComponent("doc.txt")
        try Data("hello-world".utf8).write(to: localFile)

        actor CommitTracker {
            var attempt = 0
            var verifiedTargetNameFound = false
            func nextCommitAttempt() -> Int {
                attempt += 1
                return attempt
            }
            func markVerified() { verifiedTargetNameFound = true }
        }
        let tracker = CommitTracker()

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
                            if fTag == "DATA" { _ = try await conn.readExact(Int(fVal)) }
                            else if fTag == "DONE" { break }
                        }
                        var okay = Data("OKAY".utf8); okay.appendUInt32LE(0)
                        try await conn.send(okay)
                    } else if tag == "LIS2" {
                        // Return existing "doc.txt" so next candidate is "doc (2).txt"
                        var frame = Data("DNT2".utf8)
                        frame.appendUInt32LE(0)
                        frame.appendUInt32LE(1); frame.appendUInt32LE(0)
                        frame.appendUInt32LE(1); frame.appendUInt32LE(0)
                        frame.appendUInt32LE(0o100644)
                        frame.appendUInt32LE(1); frame.appendUInt32LE(1000); frame.appendUInt32LE(1000)
                        frame.appendUInt32LE(11); frame.appendUInt32LE(0)
                        for _ in 0..<3 { frame.appendUInt32LE(0); frame.appendUInt32LE(0) }
                        let nameBytes = Data("doc.txt".utf8)
                        frame.appendUInt32LE(UInt32(nameBytes.count))
                        frame.append(nameBytes)
                        frame.append(Data("DONE".utf8))
                        frame.append(Data(repeating: 0, count: 72))
                        try await conn.send(frame)
                    }
                } else if service.contains("mv -nT") && !service.contains(".metalcast-probe-") {
                    let n = await tracker.nextCommitAttempt()
                    if n == 1 {
                        // First attempt hits targetConflict (exit 22)
                        var exit = Data([3]); exit.appendUInt32LE(1); exit.append(22)
                        try await conn.send(exit)
                    } else {
                        // Second attempt for "doc (2).txt" drops before kIdExit
                        return
                    }
                } else if service.contains("'doc (2).txt'") && service.contains("rmdir --") {
                    // verifyPendingUpload for updated finalTargetName "doc (2).txt"
                    await tracker.markVerified()
                    var exit = Data([3]); exit.appendUInt32LE(1); exit.append(0)
                    try await conn.send(exit)
                } else {
                    var exit = Data([3]); exit.appendUInt32LE(1); exit.append(0)
                    try await conn.send(exit)
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

        let stream = await service.events
        let ids = try await service.enqueueUpload(
            sessionId: sessionId,
            targetComponents: [Data("Download".utf8)],
            items: [ADBUploadPlanItem(localURL: localFile, targetFileName: "doc.txt", conflictResolution: .keepBoth, fileSize: 11)]
        )

        for await event in stream {
            if case .taskUpdated(let snap) = event, snap.id == ids[0], snap.state == .pendingConfirmation {
                break
            }
        }

        let ledger = await service.ledgerStore.entries()
        #expect(ledger.count == 1)
        #expect(ledger[0].finalTargetName == "doc (2).txt")

        let verified = try await service.verifyPendingTask(taskId: ids[0])
        #expect(verified?.state == .completed)
        #expect(await tracker.verifiedTargetNameFound)
    }

    @Test("Delete connect failure before command reports notExecuted instead of pendingConfirmation")
    func deleteConnectFailureReportsNotExecuted() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metalcast-del-conn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        actor ServerControl {
            var serverRef: MockADBTCPServer?
            func setServer(_ s: MockADBTCPServer) { serverRef = s }
            func stopServer() { serverRef?.stop() }
        }
        let ctrl = ServerControl()

        let server = try await MockADBTCPServer { conn in
            Task {
                defer { conn.close() }
                guard try await conn.readHostRequest() == "host:transport-id:3" else { return }
                try await conn.send(Data("OKAY".utf8))
                let service = try await conn.readHostRequest()
                try await conn.send(Data("OKAY".utf8))
                if service == "sync:" {
                    _ = try await conn.readExact(4)
                    let len = Int((try await conn.readExact(4)).readUInt32LE(at: 0))
                    _ = try await conn.readExact(len)
                    try await conn.send(Self.makeStatV2(size: 10, dev: 1, ino: 500))
                    // Stop server right after stat finishes so delConn.connect() fails before sending delete command
                    await ctrl.stopServer()
                }
            }
        }
        await ctrl.setServer(server)

        let endpoint = try ADBServerEndpoint(host: "127.0.0.1", port: server.port)
        let service = ADBFileService(endpoint: endpoint, ledgerURL: tempDir.appendingPathComponent("ledger.json"))
        let sessionId = ADBFileSessionID(endpoint: endpoint, serverGeneration: 1, transportId: "3", serial: "dev3")
        await service.registerSessionForTesting(
            sessionId: sessionId,
            physicalRoot: "/storage/emulated/0",
            capabilities: ADBDeviceCapabilities(hasShellV2: true, hasStatV2: true, hasLsV2: true, commitMode: .mvNoClobberNoTarget)
        )

        let entry = ADBRemoteEntry(
            rawNameBytes: Data("target.txt".utf8),
            displayName: "target.txt",
            isLosslessUTF8: true,
            kind: .regular,
            size: 10,
            isSizeReliable: true,
            mtime: Date(timeIntervalSince1970: 1_764_100_000),
            dev: 1,
            ino: 500
        )

        let stream = await service.events
        let taskId = try await service.enqueueDelete(
            sessionId: sessionId,
            directoryComponents: [Data("Download".utf8)],
            items: [ADBDeleteTarget(remoteEntry: entry)]
        )

        var finalSnap: ADBFileTaskSnapshot?
        for await event in stream {
            if case .taskUpdated(let snap) = event, snap.id == taskId,
               snap.state == .completed || snap.state == .pendingConfirmation || snap.state == .failed {
                finalSnap = snap
                break
            }
        }

        #expect(finalSnap?.state == .completed)
        #expect(finalSnap?.deleteResults?.count == 1)
        #expect(finalSnap?.deleteResults?.first?.status == .notExecuted)
    }

    @Test("openSession waits for tracker initial snapshot and does not invalidate immediately")
    func openSessionNoGenerationRaceOnInitialConnect() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metalcast-session-race-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let server = try await MockADBTCPServer { conn in
            Task {
                defer { conn.close() }
                let req = try await conn.readHostRequest()
                if req == "host:track-devices-l" {
                    try await conn.send(Data("OKAY".utf8))
                    // Simulate slight startup delay before initial snapshot arrives
                    try await Task.sleep(nanoseconds: 80_000_000)
                    let snap = MockADBTCPServer.MockConnection.hostFrame(
                        "dev-99 device model:Pixel_9 transport_id:9\n"
                    )
                    try await conn.send(snap)
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } else if req == "host-transport-id:9:features" {
                    try await conn.send(Data("OKAY".utf8))
                    try await conn.send(MockADBTCPServer.MockConnection.hostFrame("shell_v2,stat_v2,ls_v2"))
                } else if req == "host:transport-id:9" {
                    try await conn.send(Data("OKAY".utf8))
                    let svc = try await conn.readHostRequest()
                    try await conn.send(Data("OKAY".utf8))
                    if svc.contains("pwd -P") && svc.contains("/sdcard") && !svc.contains("mkdir") {
                        let out = Data("/storage/emulated/0\n".utf8)
                        var f1 = Data([1]); f1.appendUInt32LE(UInt32(out.count)); f1.append(out)
                        var f3 = Data([3]); f3.appendUInt32LE(1); f3.append(0)
                        try await conn.send(f1 + f3)
                    } else {
                        var f3 = Data([3]); f3.appendUInt32LE(1); f3.append(0)
                        try await conn.send(f3)
                    }
                }
            }
        }
        defer { server.stop() }

        let endpoint = try ADBServerEndpoint(host: "127.0.0.1", port: server.port)
        let service = ADBFileService(endpoint: endpoint, ledgerURL: tempDir.appendingPathComponent("ledger.json"))
        let stream = await service.events

        let device = ADBDevice(serial: "dev-99", state: .device, model: "Pixel_9", transportId: "9")
        let snapshot = try await service.openSession(for: device)
        #expect(snapshot.sessionId.serverGeneration == 1)

        // Allow tracker loop time to settle; session must NOT be invalidated
        try await Task.sleep(nanoseconds: 150_000_000)
        let tracker = try await service.ensureTrackerStarted()
        let stillValid = await tracker.isSessionValid(snapshot.sessionId)
        #expect(stillValid)
        _ = stream
        await tracker.stop()
    }

    @Test("Cancelling active head upload during mkdir setup cancels cleanly without entering SEND")
    func cancelActiveHeadUploadDuringMkdirSetupNeverStartsTransfer() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metalcast-cancel-mkdir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let localFile = tempDir.appendingPathComponent("staged.bin")
        try Data(repeating: 0x55, count: 4096).write(to: localFile)

        actor SetupState {
            var mkdirEntered = false
            var syncEntered = false
            var cleanupEntered = false
            func markMkdir() { mkdirEntered = true }
            func markSync() { syncEntered = true }
            func markCleanup() { cleanupEntered = true }
        }
        let state = SetupState()

        let server = try await MockADBTCPServer { conn in
            Task {
                defer { conn.close() }
                guard try await conn.readHostRequest() == "host:transport-id:3" else { return }
                try await conn.send(Data("OKAY".utf8))
                let service = try await conn.readHostRequest()
                try await conn.send(Data("OKAY".utf8))

                if service == "sync:" {
                    await state.markSync()
                    return
                } else if service.contains("mkdir --") && service.contains(".metalcast-tmp-") {
                    await state.markMkdir()
                    // Hold mkdir open long enough for cancelTransfer to strike while task snapshot is still .queued.
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    var exit = Data([3]); exit.appendUInt32LE(1); exit.append(0)
                    try? await conn.send(exit)
                } else if service.contains("rmdir --") && service.contains(".metalcast-tmp-") {
                    await state.markCleanup()
                    var exit = Data([3]); exit.appendUInt32LE(1); exit.append(0)
                    try await conn.send(exit)
                } else {
                    var exit = Data([3]); exit.appendUInt32LE(1); exit.append(0)
                    try await conn.send(exit)
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

        let stream = await service.events
        let ids = try await service.enqueueUpload(
            sessionId: sessionId,
            targetComponents: [Data("Download".utf8)],
            items: [ADBUploadPlanItem(localURL: localFile, targetFileName: "staged.bin", fileSize: 4096)]
        )

        // Wait until mkdir is actually executing on the server while task snapshot state is still .queued
        for _ in 0..<100 {
            if await state.mkdirEntered { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await state.mkdirEntered)
        #expect(await service.taskSnapshot(id: ids[0])?.state == .queued)
        await service.cancelTransfer(taskId: ids[0])

        var observedStates: [ADBFileTaskState] = []
        var cancelledSnap: ADBFileTaskSnapshot?
        for await event in stream {
            if case .taskUpdated(let snap) = event, snap.id == ids[0] {
                observedStates.append(snap.state)
                if snap.state == .cancelled || snap.state == .failed {
                    cancelledSnap = snap
                    break
                }
            }
        }

        #expect(cancelledSnap?.state == .cancelled)
        #expect(!observedStates.contains(.transferring))
        #expect(await state.syncEntered == false)
        #expect(await state.cleanupEntered == true)
        #expect(await service.ledgerEntries().isEmpty)
    }

    @Test("verifyPendingLedgerEntry works across simulated app restart and retryLedgerCleanup rejects pendingConfirmation")
    func verifyPendingLedgerEntryWorksAfterRestartAndRetryCleanupRejectsPendingConfirmation() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metalcast-ledger-restart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let server = try await MockADBTCPServer { conn in
            Task {
                defer { conn.close() }
                guard try await conn.readHostRequest() == "host:transport-id:7" else { return }
                try await conn.send(Data("OKAY".utf8))
                let service = try await conn.readHostRequest()
                try await conn.send(Data("OKAY".utf8))
                if service.contains("'after-restart.bin'") && service.contains("rmdir --") {
                    var exit = Data([3]); exit.appendUInt32LE(1); exit.append(0)
                    try await conn.send(exit)
                }
            }
        }
        defer { server.stop() }

        let endpoint = try ADBServerEndpoint(host: "127.0.0.1", port: server.port)
        let ledgerURL = tempDir.appendingPathComponent("ledger.json")
        let entry = ADBLedgerEntry(
            taskId: UUID(),
            endpoint: endpoint,
            serial: "dev7",
            transportId: "7",
            serverGeneration: 1,
            targetParentPhysicalPath: "/storage/emulated/0/Download",
            tempDirName: ".metalcast-tmp-abc",
            tempPayloadName: "payload",
            finalTargetName: "after-restart.bin",
            state: .pendingConfirmation
        )
        let preStore = ADBLedgerStore(fileURL: ledgerURL)
        try await preStore.upsert(entry)

        // Fresh ADBFileService instance simulates app relaunch where in-memory `tasks` is empty.
        let restartedService = ADBFileService(endpoint: endpoint, ledgerURL: ledgerURL)
        let sessionId = ADBFileSessionID(endpoint: endpoint, serverGeneration: 2, transportId: "7", serial: "dev7")
        await restartedService.registerSessionForTesting(
            sessionId: sessionId,
            physicalRoot: "/storage/emulated/0",
            capabilities: ADBDeviceCapabilities(hasShellV2: true, hasStatV2: true, hasLsV2: true, commitMode: .mvNoClobberNoTarget)
        )

        await #expect(throws: ADBFileError.self) {
            try await restartedService.retryLedgerCleanup(entryId: entry.id)
        }

        let verified = try await restartedService.verifyPendingLedgerEntry(entryId: entry.id)
        #expect(verified?.committed == true)
        #expect(verified?.tempDirCleaned == true)
        #expect(verified?.finalTargetName == "after-restart.bin")
        #expect(verified?.taskSnapshot == nil)
        #expect(await restartedService.ledgerEntries().isEmpty)
    }

    @Test("openSession during tracker disconnect waits for next generation instead of binding stale generation")
    func reconnectAfterTrackerDisconnectBindsToNewGeneration() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metalcast-reconnect-gen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        actor TrackConnCounter {
            var count = 0
            func next() -> Int {
                count += 1
                return count
            }
        }
        let counter = TrackConnCounter()

        let server = try await MockADBTCPServer { conn in
            Task {
                defer { conn.close() }
                let req = try await conn.readHostRequest()
                if req == "host:track-devices-l" {
                    let n = await counter.next()
                    try await conn.send(Data("OKAY".utf8))
                    if n == 1 {
                        let snap = MockADBTCPServer.MockConnection.hostFrame(
                            "dev-99 device model:Pixel_9 transport_id:9\n"
                        )
                        try await conn.send(snap)
                        try await Task.sleep(nanoseconds: 80_000_000)
                        // Drop initial track stream to force reconnect & generation increment
                        return
                    } else {
                        // Simulate brief delay before second generation snapshot arrives
                        try await Task.sleep(nanoseconds: 120_000_000)
                        let snap = MockADBTCPServer.MockConnection.hostFrame(
                            "dev-99 device model:Pixel_9 transport_id:9\n"
                        )
                        try await conn.send(snap)
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                    }
                } else if req == "host:devices-l" {
                    try await conn.send(Data("OKAY".utf8))
                    try await conn.send(MockADBTCPServer.MockConnection.hostFrame(
                        "dev-99 device model:Pixel_9 transport_id:9\n"
                    ))
                } else if req == "host-transport-id:9:features" {
                    try await conn.send(Data("OKAY".utf8))
                    try await conn.send(MockADBTCPServer.MockConnection.hostFrame("shell_v2,stat_v2,ls_v2"))
                } else if req == "host:transport-id:9" {
                    try await conn.send(Data("OKAY".utf8))
                    let svc = try await conn.readHostRequest()
                    try await conn.send(Data("OKAY".utf8))
                    if svc.contains("pwd -P") && svc.contains("/sdcard") && !svc.contains("mkdir") {
                        let out = Data("/storage/emulated/0\n".utf8)
                        var f1 = Data([1]); f1.appendUInt32LE(UInt32(out.count)); f1.append(out)
                        var f3 = Data([3]); f3.appendUInt32LE(1); f3.append(0)
                        try await conn.send(f1 + f3)
                    } else {
                        var f3 = Data([3]); f3.appendUInt32LE(1); f3.append(0)
                        try await conn.send(f3)
                    }
                }
            }
        }
        defer { server.stop() }

        let endpoint = try ADBServerEndpoint(host: "127.0.0.1", port: server.port)
        let service = ADBFileService(endpoint: endpoint, ledgerURL: tempDir.appendingPathComponent("ledger.json"))
        let stream = await service.events

        let device = ADBDevice(serial: "dev-99", state: .device, model: "Pixel_9", transportId: "9")
        let snap1 = try await service.openSession(for: device)
        #expect(snap1.sessionId.serverGeneration == 1)

        // Wait until first session is invalidated by track stream EOF
        var sawInvalidation = false
        for await event in stream {
            if case .sessionInvalidated(let sid, _) = event, sid == snap1.sessionId {
                sawInvalidation = true
                break
            }
        }
        #expect(sawInvalidation)

        // Immediately reconnect during disconnect window — must wait for generation 2 and remain valid
        let snap2 = try await service.openSession(for: device)
        #expect(snap2.sessionId.serverGeneration >= 2)

        try await Task.sleep(nanoseconds: 150_000_000)
        let tracker = try await service.ensureTrackerStarted()
        #expect(await tracker.isSessionValid(snap2.sessionId))
        await tracker.stop()
    }

    @Test("publishExclusive uses originalBaseName on EEXIST retry instead of stacking (2) (2)")
    func publishExclusiveConflictRetryUsesOriginalBaseName() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metalcast-pub-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try Data("one".utf8).write(to: tempDir.appendingPathComponent("photo.jpg"))
        try Data("two".utf8).write(to: tempDir.appendingPathComponent("photo (2).jpg"))

        let (partURL, fd) = try ADBMacFilePublisher.createExclusivePartFile(in: tempDir)
        let payload = Data("three".utf8)
        payload.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                _ = Darwin.write(fd, base, payload.count)
            }
        }
        Darwin.close(fd)

        let published = try ADBMacFilePublisher.publishExclusive(
            partURL: partURL,
            targetDirectory: tempDir,
            preferredName: "photo (2).jpg",
            conflictResolution: .keepBoth,
            originalBaseName: "photo.jpg"
        )
        #expect(published?.lastPathComponent == "photo (3).jpg")
    }
}
