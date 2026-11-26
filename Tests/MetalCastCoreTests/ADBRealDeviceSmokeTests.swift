import Foundation
import Testing
@testable import MetalCastCore

@Suite("ADBRealDeviceSmoke")
struct ADBRealDeviceSmokeTests {
    @Test(
        "Real Android device end-to-end browse, restricted block, upload, conflict keepBoth, download, and delete",
        .enabled(if: ProcessInfo.processInfo.environment["METALCAST_REAL_DEVICE_TEST"] == "1")
    )
    func endToEndRealDeviceSmoke() async throws {
        let endpoint = try ADBServerEndpoint.resolve()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metalcast-realdev-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let ledgerURL = tempDir.appendingPathComponent("ledger.json")
        let service = ADBFileService(endpoint: endpoint, ledgerURL: ledgerURL)

        let tracker = try await service.ensureTrackerStarted()
        let (_, devices) = try await tracker.refreshOnce()
        let candidate = devices.first { $0.state == .device && $0.transportId != nil }
        let device = try #require(candidate, "No authorized Android device with transport_id attached")

        let session = try await service.openSession(for: device)
        #expect(session.capabilities.hasShellV2)
        #expect(session.physicalRoot.hasPrefix("/"))
        print("📱 [RealDevice] model=\(session.deviceName) root=\(session.physicalRoot) shellV2=\(session.capabilities.hasShellV2) statV2=\(session.capabilities.hasStatV2) lsV2=\(session.capabilities.hasLsV2) commitMode=\(session.capabilities.commitMode)")

        // 1. Verify Android directory lists data/obb as restricted, and direct navigation throws restrictedPath
        var androidEntries: [ADBRemoteEntry] = []
        for try await batch in await service.listDirectory(sessionId: session.sessionId, relativeComponents: [Data("Android".utf8)]) {
            androidEntries.append(contentsOf: batch.entries)
        }
        let dataEntry = androidEntries.first { $0.displayName.lowercased() == "data" }
        #expect(dataEntry?.isRestricted == true)

        await #expect(throws: ADBFileError.self) {
            for try await _ in await service.listDirectory(
                sessionId: session.sessionId,
                relativeComponents: [Data("Android".utf8), Data("data".utf8)]
            ) {}
        }

        // 2. Upload a 200 KiB test file (multi-chunk > 64 KiB) to Download
        let uniqueTag = UUID().uuidString.prefix(8)
        let testFileName = "mc_verify_\(uniqueTag).bin"
        let keepBothName = "mc_verify_\(uniqueTag) (2).bin"
        let localSource = tempDir.appendingPathComponent(testFileName)
        let payload = Data((0..<200_000).map { UInt8(($0 * 13 + 7) & 0xFF) })
        try payload.write(to: localSource)

        let stream = await service.events

        let up1 = try await service.enqueueUpload(
            sessionId: session.sessionId,
            targetComponents: [Data("Download".utf8)],
            items: [ADBUploadPlanItem(localURL: localSource, targetFileName: testFileName, fileSize: UInt64(payload.count), mtime: Date())]
        )

        var up1Done = false
        for await event in stream {
            if case .taskUpdated(let snap) = event, snap.id == up1[0],
               snap.state == .completed || snap.state == .failed {
                #expect(snap.state == .completed, "Upload 1 failed: \(snap.detail)")
                up1Done = true
                break
            }
        }
        #expect(up1Done)

        // 3. Upload same filename again with keepBoth -> should become "mc_verify_<tag> (2).bin"
        let up2 = try await service.enqueueUpload(
            sessionId: session.sessionId,
            targetComponents: [Data("Download".utf8)],
            items: [ADBUploadPlanItem(localURL: localSource, targetFileName: keepBothName, fileSize: UInt64(payload.count), mtime: Date())]
        )

        var up2Done = false
        for await event in stream {
            if case .taskUpdated(let snap) = event, snap.id == up2[0],
               snap.state == .completed || snap.state == .failed {
                #expect(snap.state == .completed, "Upload 2 failed: \(snap.detail)")
                up2Done = true
                break
            }
        }
        #expect(up2Done)

        // 4. List Download and find both uploaded entries
        var downloadEntries: [ADBRemoteEntry] = []
        for try await batch in await service.listDirectory(sessionId: session.sessionId, relativeComponents: [Data("Download".utf8)]) {
            downloadEntries.append(contentsOf: batch.entries)
        }
        let uploaded1 = try #require(downloadEntries.first { $0.displayName == testFileName })
        let uploaded2 = try #require(downloadEntries.first { $0.displayName == keepBothName })
        #expect(uploaded1.size == UInt64(payload.count))
        #expect(uploaded2.size == UInt64(payload.count))

        // 5. Download uploaded1 back to a fresh local folder and verify exact bytes
        let dlDir = tempDir.appendingPathComponent("downloaded")
        try FileManager.default.createDirectory(at: dlDir, withIntermediateDirectories: true)
        let dlIds = try await service.enqueueDownload(
            sessionId: session.sessionId,
            sourceComponents: [Data("Download".utf8)],
            items: [ADBDownloadPlanItem(remoteEntry: uploaded1, targetFileName: testFileName)],
            localDirectory: dlDir
        )

        var dlDone = false
        for await event in stream {
            if case .taskUpdated(let snap) = event, snap.id == dlIds[0],
               snap.state == .completed || snap.state == .failed {
                #expect(snap.state == .completed, "Download failed: \(snap.detail)")
                dlDone = true
                break
            }
        }
        #expect(dlDone)
        let downloadedBytes = try Data(contentsOf: dlDir.appendingPathComponent(testFileName))
        #expect(downloadedBytes == payload)

        // 6. Delete both test files cleanly and verify ledger is empty
        let delId = try await service.enqueueDelete(
            sessionId: session.sessionId,
            directoryComponents: [Data("Download".utf8)],
            items: [ADBDeleteTarget(remoteEntry: uploaded1), ADBDeleteTarget(remoteEntry: uploaded2)]
        )

        var delResults: [ADBDeleteItemResult] = []
        for await event in stream {
            if case .taskUpdated(let snap) = event, snap.id == delId,
               snap.state == .completed || snap.state == .failed {
                #expect(snap.state == .completed)
                delResults = snap.deleteResults ?? []
                break
            }
        }
        #expect(delResults.count == 2)
        #expect(delResults.allSatisfy { $0.status == .deleted })

        let leftoverLedger = await service.ledgerEntries()
        #expect(leftoverLedger.isEmpty)
    }
}
