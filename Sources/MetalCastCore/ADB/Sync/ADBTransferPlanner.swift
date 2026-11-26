import Darwin
import Foundation

public struct ADBConflictCheckEntry<Item: Sendable>: Sendable {
    public let item: Item
    public let originalName: String
    public let suggestedKeepBothName: String?
    public let keepBothError: String?

    public init(
        item: Item,
        originalName: String,
        suggestedKeepBothName: String?,
        keepBothError: String?
    ) {
        self.item = item
        self.originalName = originalName
        self.suggestedKeepBothName = suggestedKeepBothName
        self.keepBothError = keepBothError
    }
}

public enum ADBTransferPlanner {
    public static let maxRenameAttempt = 999

    /// Splits a filename into `(stem, ext)` where hidden `.name` files with no further dot
    /// are treated as having no extension (`.env` -> `(".env", "")` -> `".env (2)"`).
    public static func splitStemAndExtension(_ name: String) -> (stem: String, ext: String) {
        if name.hasPrefix(".") {
            let afterFirst = name.index(after: name.startIndex)
            if name[afterFirst...].firstIndex(of: ".") == nil {
                return (name, "")
            }
        }
        guard let lastDot = name.lastIndex(of: "."), lastDot > name.startIndex else {
            return (name, "")
        }
        return (String(name[..<lastDot]), String(name[lastDot...]))
    }

    public static func normalizeAndroidName(_ name: String) -> String {
        name.lowercased()
    }

    public static func normalizeMacAPFSName(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Generates the next available `名称 (2).扩展名` candidate (`2...999`),
    /// strictly enforcing `<= 255` UTF-8 bytes without silent truncation.
    public static func nextAvailableRenameCandidate(
        originalName: String,
        occupiedNormalizedNames: Set<String>,
        normalize: (String) -> String,
        validateCandidate: ((String) throws -> Void)? = nil
    ) throws -> String {
        let (stem, ext) = splitStemAndExtension(originalName)
        for index in 2...maxRenameAttempt {
            let candidate = "\(stem) (\(index))\(ext)"
            let utf8Count = candidate.utf8.count
            guard utf8Count <= ADBPathUtils.maxFileNameUTF8Bytes else {
                throw ADBFileError.invalidFileName("自动重命名「\(candidate)」超过 255 UTF-8 字节上限")
            }
            if let validateCandidate {
                try validateCandidate(candidate)
            }
            let normalized = normalize(candidate)
            if !occupiedNormalizedNames.contains(normalized) {
                return candidate
            }
        }
        throw ADBFileError.invalidFileName("同名文件过多，已达到自动重命名上限 (999)")
    }

    /// Verifies via `lstat` that `url` is an existing local regular file (not directory or symlink)
    /// and extracts its byte size and modification time.
    public static func verifyLocalRegularFile(_ url: URL) throws -> (fileSize: UInt64, mtime: Date?) {
        var st = stat()
        guard Darwin.lstat(url.path, &st) == 0 else {
            let err = errno
            throw ADBFileError.invalidFileName("无法读取本地文件 \(url.lastPathComponent): \(String(cString: strerror(err)))")
        }
        let mode = UInt32(st.st_mode) & UInt32(S_IFMT)
        guard mode == UInt32(S_IFREG) else {
            throw ADBFileError.invalidFileName("仅支持上传普通文件，已忽略: \(url.lastPathComponent)")
        }
        let sec = TimeInterval(st.st_mtimespec.tv_sec)
        let nsec = TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000.0
        return (UInt64(max(0, st.st_size)), Date(timeIntervalSince1970: sec + nsec))
    }

    /// Computes upload conflict analysis against `existingRemoteNames` and intra-batch duplicates.
    public static func analyzeUploadConflicts(
        localURLs: [URL],
        existingRemoteNames: [String],
        parentPhysicalPath: String
    ) -> (
        nonConflicts: [ADBUploadPlanItem],
        conflicts: [ADBConflictCheckEntry<ADBUploadPlanItem>],
        rejected: [(url: URL, reason: String)]
    ) {
        var occupied = Set(existingRemoteNames.map(normalizeAndroidName))
        var nonConflicts: [ADBUploadPlanItem] = []
        var conflicts: [ADBConflictCheckEntry<ADBUploadPlanItem>] = []
        var rejected: [(URL, String)] = []

        for url in localURLs {
            do {
                let (fileSize, mtime) = try verifyLocalRegularFile(url)
                let fileName = url.lastPathComponent
                try ADBPathUtils.validateUploadFileName(fileName)

                let finalTargetBytes = Data("\(parentPhysicalPath)/\(fileName)".utf8).count
                guard finalTargetBytes <= ADBPathUtils.syncMaxPathBytes else {
                    throw ADBFileError.pathTooLong(finalTargetBytes)
                }

                let norm = normalizeAndroidName(fileName)
                if occupied.contains(norm) {
                    let placeholder = ADBUploadPlanItem(
                        localURL: url,
                        targetFileName: fileName,
                        conflictResolution: .keepBoth,
                        fileSize: fileSize,
                        mtime: mtime
                    )
                    do {
                        let candidate = try nextAvailableRenameCandidate(
                            originalName: fileName,
                            occupiedNormalizedNames: occupied,
                            normalize: normalizeAndroidName,
                            validateCandidate: { try ADBPathUtils.validateUploadFileName($0) }
                        )
                        let candBytes = Data("\(parentPhysicalPath)/\(candidate)".utf8).count
                        guard candBytes <= ADBPathUtils.syncMaxPathBytes else {
                            throw ADBFileError.pathTooLong(candBytes)
                        }
                        occupied.insert(normalizeAndroidName(candidate))
                        conflicts.append(
                            ADBConflictCheckEntry(
                                item: placeholder,
                                originalName: fileName,
                                suggestedKeepBothName: candidate,
                                keepBothError: nil
                            )
                        )
                    } catch {
                        conflicts.append(
                            ADBConflictCheckEntry(
                                item: placeholder,
                                originalName: fileName,
                                suggestedKeepBothName: nil,
                                keepBothError: error.localizedDescription
                            )
                        )
                    }
                } else {
                    occupied.insert(norm)
                    nonConflicts.append(
                        ADBUploadPlanItem(
                            localURL: url,
                            targetFileName: fileName,
                            conflictResolution: .keepBoth,
                            fileSize: fileSize,
                            mtime: mtime
                        )
                    )
                }
            } catch {
                rejected.append((url, error.localizedDescription))
            }
        }

        return (nonConflicts, conflicts, rejected)
    }

    /// Computes download conflict analysis against `localDirectory` contents using APFS NFC+case normalization.
    public static func analyzeDownloadConflicts(
        entries: [ADBRemoteEntry],
        localDirectory: URL
    ) throws -> (
        nonConflicts: [ADBDownloadPlanItem],
        conflicts: [ADBConflictCheckEntry<ADBDownloadPlanItem>]
    ) {
        let existingNames = try FileManager.default.contentsOfDirectory(atPath: localDirectory.path)
        var occupied = Set(existingNames.map(normalizeMacAPFSName))
        var nonConflicts: [ADBDownloadPlanItem] = []
        var conflicts: [ADBConflictCheckEntry<ADBDownloadPlanItem>] = []

        for entry in entries {
            guard entry.kind == .regular, !entry.isRestricted, entry.isLosslessUTF8 else { continue }
            let name = entry.displayName
            let norm = normalizeMacAPFSName(name)
            let plan = ADBDownloadPlanItem(remoteEntry: entry, targetFileName: name, conflictResolution: .keepBoth)

            if occupied.contains(norm) {
                do {
                    let candidate = try nextAvailableRenameCandidate(
                        originalName: name,
                        occupiedNormalizedNames: occupied,
                        normalize: normalizeMacAPFSName
                    )
                    occupied.insert(normalizeMacAPFSName(candidate))
                    conflicts.append(
                        ADBConflictCheckEntry(
                            item: plan,
                            originalName: name,
                            suggestedKeepBothName: candidate,
                            keepBothError: nil
                        )
                    )
                } catch {
                    conflicts.append(
                        ADBConflictCheckEntry(
                            item: plan,
                            originalName: name,
                            suggestedKeepBothName: nil,
                            keepBothError: error.localizedDescription
                        )
                    )
                }
            } else {
                occupied.insert(norm)
                nonConflicts.append(plan)
            }
        }

        return (nonConflicts, conflicts)
    }

    /// Re-verifies remote object identity immediately before download, delete, or post-download check (Plan §3.4).
    public static func verifyRemoteEntryIdentity(
        connection: ADBSocketConnection,
        syncClient: ADBSyncClient,
        remotePathBytes: Data,
        expected: ADBRemoteEntry,
        useV2: Bool
    ) async throws -> ADBStatResult {
        let current = try await syncClient.stat(
            connection: connection,
            pathBytes: remotePathBytes,
            useV2: useV2,
            followSymlinks: false
        )

        if let errnoVal = current.entryErrno {
            if errnoVal == ENOENT {
                throw ADBFileError.targetChanged("目标已不存在，请刷新目录")
            }
            if errnoVal == EACCES || errnoVal == EPERM {
                throw ADBFileError.permissionDenied("无权限访问目标文件")
            }
            throw ADBFileError.targetChanged("目标状态异常 (errno \(errnoVal))，请刷新目录")
        }

        if !useV2 && current.isAllZeroV1 {
            throw ADBFileError.targetChanged("目标状态不可确认（v1 全零响应），请刷新目录")
        }

        guard current.kind == expected.kind else {
            throw ADBFileError.targetChanged("目标类型发生变化，请刷新目录")
        }

        if useV2 {
            if let expDev = expected.dev, let curDev = current.dev, expDev != curDev {
                throw ADBFileError.targetChanged("目标设备号发生变化，请刷新目录")
            }
            if let expIno = expected.ino, let curIno = current.ino, expIno != curIno {
                throw ADBFileError.targetChanged("目标 inode 发生变化，请刷新目录")
            }
            if expected.kind == .regular {
                if let expSize = expected.size, let curSize = current.size, expSize != curSize {
                    throw ADBFileError.targetChanged("目标文件大小发生变化，请刷新目录")
                }
                if let expMtime = expected.mtime, let curMtime = current.mtime,
                   abs(expMtime.timeIntervalSince1970 - curMtime.timeIntervalSince1970) > 1.0 {
                    throw ADBFileError.targetChanged("目标修改时间发生变化，请刷新目录")
                }
            }
        } else {
            if let expMode = expected.posixMode, let curMode = current.posixMode, expMode != curMode {
                throw ADBFileError.targetChanged("目标权限模式发生变化，请刷新目录")
            }
            if let expMtime = expected.mtime, let curMtime = current.mtime,
               abs(expMtime.timeIntervalSince1970 - curMtime.timeIntervalSince1970) > 1.0 {
                throw ADBFileError.targetChanged("目标修改时间发生变化，请刷新目录")
            }
        }

        return current
    }
}

/// Manages exclusive `.part` temp files, `futimens` timestamp preservation, and `renamex_np(RENAME_EXCL)` publishing on Mac.
public enum ADBMacFilePublisher {
    public static func createExclusivePartFile(in directory: URL) throws -> (partURL: URL, fd: Int32) {
        let partName = ".MetalCast-\(UUID().uuidString.lowercased()).part"
        let partURL = directory.appendingPathComponent(partName)
        let fd = Darwin.open(partURL.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard fd >= 0 else {
            let err = errno
            let msg = String(cString: strerror(err))
            if err == EACCES || err == EPERM {
                throw ADBFileError.permissionDenied("无法在 Mac 目标目录创建临时文件: \(msg)")
            }
            if err == ENOSPC {
                throw ADBFileError.diskFull(msg)
            }
            throw ADBFileError.protocolError(stage: "RECV", detail: "创建本地临时文件失败: \(msg)")
        }
        return (partURL, fd)
    }

    public static func applyModificationTime(fd: Int32, mtime: Date?) {
        guard let mtime else { return }
        let ti = mtime.timeIntervalSince1970
        let sec = Int(floor(ti))
        let nsec = Int((ti - Double(sec)) * 1_000_000_000.0)
        let clampedNsec = max(0, min(999_999_999, nsec))
        let ts = timespec(tv_sec: sec, tv_nsec: clampedNsec)
        let pair = [ts, ts]
        pair.withUnsafeBufferPointer { ptr in
            _ = Darwin.futimens(fd, ptr.baseAddress)
        }
    }

    public static func publishExclusive(
        partURL: URL,
        targetDirectory: URL,
        preferredName: String,
        conflictResolution: ADBTransferConflictResolution
    ) throws -> URL? {
        var candidateName = preferredName

        while true {
            let destinationURL = targetDirectory.appendingPathComponent(candidateName)
            let rc = Darwin.renamex_np(partURL.path, destinationURL.path, UInt32(RENAME_EXCL))
            if rc == 0 {
                return destinationURL
            }

            let err = errno
            if err == EEXIST {
                switch conflictResolution {
                case .skip:
                    try? FileManager.default.removeItem(at: partURL)
                    return nil
                case .keepBoth:
                    let existing = (try? FileManager.default.contentsOfDirectory(atPath: targetDirectory.path)) ?? []
                    var occupied = Set(existing.map(ADBTransferPlanner.normalizeMacAPFSName))
                    occupied.insert(ADBTransferPlanner.normalizeMacAPFSName(candidateName))
                    candidateName = try ADBTransferPlanner.nextAvailableRenameCandidate(
                        originalName: preferredName,
                        occupiedNormalizedNames: occupied,
                        normalize: ADBTransferPlanner.normalizeMacAPFSName
                    )
                    continue
                }
            }

            let msg = String(cString: strerror(err))
            if err == ENOSPC {
                throw ADBFileError.diskFull(msg)
            }
            if err == EACCES || err == EPERM {
                throw ADBFileError.permissionDenied("无权写入目标目录: \(msg)")
            }
            throw ADBFileError.protocolError(stage: "publish", detail: "原子发布失败: \(msg)")
        }
    }
}
