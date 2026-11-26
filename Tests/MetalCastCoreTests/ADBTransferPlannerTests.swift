import Darwin
import Foundation
import Testing
@testable import MetalCastCore

@Suite("ADBTransferPlanner")
struct ADBTransferPlannerTests {
    @Test("Auto-rename handles .env, multi-dot archive.tar.gz, and rejects >255 UTF-8 bytes")
    func autoRenameRules() throws {
        let dotEnv = try ADBTransferPlanner.nextAvailableRenameCandidate(
            originalName: ".env",
            occupiedNormalizedNames: [".env"],
            normalize: ADBTransferPlanner.normalizeAndroidName
        )
        #expect(dotEnv == ".env (2)")

        let tarGz = try ADBTransferPlanner.nextAvailableRenameCandidate(
            originalName: "archive.tar.gz",
            occupiedNormalizedNames: ["archive.tar.gz", "archive.tar (2).gz"],
            normalize: ADBTransferPlanner.normalizeAndroidName
        )
        #expect(tarGz == "archive.tar (3).gz")

        let longName = String(repeating: "a", count: 251) + ".txt" // 255 bytes
        #expect(throws: ADBFileError.self) {
            _ = try ADBTransferPlanner.nextAvailableRenameCandidate(
                originalName: longName,
                occupiedNormalizedNames: [longName],
                normalize: ADBTransferPlanner.normalizeAndroidName
            )
        }
    }

    @Test("Upload conflict check catches case-insensitive collisions and intra-batch duplicates")
    func uploadConflictAndIntraBatch() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metalcast-upload-plan-\(UUID().uuidString)")
        let dirA = tempDir.appendingPathComponent("a")
        let dirB = tempDir.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file1 = dirA.appendingPathComponent("Report.pdf")
        let file2 = dirB.appendingPathComponent("report.pdf")
        let file3 = dirA.appendingPathComponent("notes?.txt")
        let file4 = dirA.appendingPathComponent("photo.jpg")

        try Data("one".utf8).write(to: file1)
        try Data("two".utf8).write(to: file2)
        try Data("bad".utf8).write(to: file3)
        try Data("pic".utf8).write(to: file4)

        let analysis = ADBTransferPlanner.analyzeUploadConflicts(
            localURLs: [file1, file2, file3, file4],
            existingRemoteNames: ["PHOTO.JPG"],
            parentPhysicalPath: "/storage/emulated/0/Download"
        )

        #expect(analysis.rejected.count == 1)
        #expect(analysis.rejected[0].url == file3)
        #expect(analysis.nonConflicts.map(\.targetFileName) == ["Report.pdf"])
        #expect(analysis.conflicts.count == 2)
        #expect(analysis.conflicts[0].suggestedKeepBothName == "report (2).pdf")
        #expect(analysis.conflicts[1].suggestedKeepBothName == "photo (2).jpg")
    }

    @Test("Download conflict check detects APFS case and NFC/NFD equivalence")
    func downloadAPFSConflictNFCAndNFD() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metalcast-apfs-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create file with NFC precomposed "Café.txt"
        let nfcName = "Caf\u{00E9}.txt"
        try Data("local".utf8).write(to: tempDir.appendingPathComponent(nfcName))

        // Remote entry has lowercase + NFD decomposed "cafe\u{0301}.txt"
        let nfdName = "cafe\u{0301}.txt"
        let entry = ADBRemoteEntry(
            rawNameBytes: Data(nfdName.utf8),
            displayName: nfdName,
            isLosslessUTF8: true,
            kind: .regular,
            size: 5,
            isSizeReliable: true,
            mtime: Date()
        )

        let result = try ADBTransferPlanner.analyzeDownloadConflicts(entries: [entry], localDirectory: tempDir)
        #expect(result.nonConflicts.isEmpty)
        #expect(result.conflicts.count == 1)
        #expect(result.conflicts[0].suggestedKeepBothName == "cafe\u{0301} (2).txt")
    }

    @Test("Mac exclusive publisher sets mtime and handles renamex_np RENAME_EXCL conflicts")
    func macExclusivePublishAndMtime() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metalcast-mac-pub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let existing = tempDir.appendingPathComponent("demo.txt")
        try Data("old".utf8).write(to: existing)

        let (partURL, fd) = try ADBMacFilePublisher.createExclusivePartFile(in: tempDir)
        let bytes = Array("new-content".utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        let targetDate = Date(timeIntervalSince1970: 1_700_000_000)
        ADBMacFilePublisher.applyModificationTime(fd: fd, mtime: targetDate)
        Darwin.close(fd)

        let published = try ADBMacFilePublisher.publishExclusive(
            partURL: partURL,
            targetDirectory: tempDir,
            preferredName: "demo.txt",
            conflictResolution: .keepBoth
        )

        #expect(published?.lastPathComponent == "demo (2).txt")
        #expect(!FileManager.default.fileExists(atPath: partURL.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: published!.path)
        let modDate = attrs[.modificationDate] as? Date
        #expect(abs((modDate?.timeIntervalSince1970 ?? 0) - 1_700_000_000) < 1.0)
    }
}
