import Foundation

public enum ADBCommitMode: String, Sendable, Equatable, Codable {
    /// Preferred: `mv -nT -- <tmp> <dst>`
    case mvNoClobberNoTarget
    /// Fallback: `[ ! -e ] && [ ! -L ] && mv -n -- <tmp> <dst>`
    case mvNoClobberWithGuard
    /// Missing `mv -n`: upload disabled
    case unsupported
}

public struct ADBDeviceCapabilities: Sendable, Equatable, Codable {
    public let hasShellV2: Bool
    public let hasStatV2: Bool
    public let hasLsV2: Bool
    public let commitMode: ADBCommitMode

    public init(
        hasShellV2: Bool,
        hasStatV2: Bool,
        hasLsV2: Bool,
        commitMode: ADBCommitMode = .unsupported
    ) {
        self.hasShellV2 = hasShellV2
        self.hasStatV2 = hasStatV2
        self.hasLsV2 = hasLsV2
        self.commitMode = commitMode
    }

    public init(features: Set<String>, commitMode: ADBCommitMode = .unsupported) {
        self.hasShellV2 = features.contains("shell_v2")
        self.hasStatV2 = features.contains("stat_v2")
        self.hasLsV2 = features.contains("ls_v2")
        self.commitMode = commitMode
    }
}

public struct ADBFileSessionID: Hashable, Sendable, Codable {
    public let endpoint: ADBServerEndpoint
    public let serverGeneration: UInt64
    public let transportId: String
    public let serial: String

    public init(
        endpoint: ADBServerEndpoint,
        serverGeneration: UInt64,
        transportId: String,
        serial: String
    ) {
        self.endpoint = endpoint
        self.serverGeneration = serverGeneration
        self.transportId = transportId
        self.serial = serial
    }
}

public struct ADBFileSessionSnapshot: Sendable, Equatable {
    public let sessionId: ADBFileSessionID
    public let deviceName: String
    public let isWifi: Bool
    public let physicalRoot: String
    public let capabilities: ADBDeviceCapabilities
    public let initialComponents: [Data]

    public init(
        sessionId: ADBFileSessionID,
        deviceName: String,
        isWifi: Bool,
        physicalRoot: String,
        capabilities: ADBDeviceCapabilities,
        initialComponents: [Data]
    ) {
        self.sessionId = sessionId
        self.deviceName = deviceName
        self.isWifi = isWifi
        self.physicalRoot = physicalRoot
        self.capabilities = capabilities
        self.initialComponents = initialComponents
    }
}

public enum ADBRemoteEntryKind: String, Sendable, Equatable, Codable {
    case regular
    case directory
    case symlink
    case other

    public static func fromPOSIXMode(_ mode: UInt32) -> ADBRemoteEntryKind {
        let sIfmt: UInt32 = 0o170000
        let sIfreg: UInt32 = 0o100000
        let sIfdir: UInt32 = 0o040000
        let sIflnk: UInt32 = 0o120000

        switch mode & sIfmt {
        case sIfreg: return .regular
        case sIfdir: return .directory
        case sIflnk: return .symlink
        default: return .other
        }
    }
}

public struct ADBRemoteEntry: Identifiable, Hashable, Sendable {
    public let rawNameBytes: Data
    public let displayName: String
    public let isLosslessUTF8: Bool
    public let kind: ADBRemoteEntryKind
    /// Nil for directories or unreliable v1 metadata (`STAT` / `LIST`).
    public let size: UInt64?
    /// True only when populated from 64-bit `stat_v2` / `ls_v2`.
    public let isSizeReliable: Bool
    public let mtime: Date?
    public let dev: UInt64?
    public let ino: UInt64?
    public let posixMode: UInt32?
    public let entryErrno: Int32?
    public let isRestricted: Bool

    public var id: Data { rawNameBytes }

    public init(
        rawNameBytes: Data,
        displayName: String,
        isLosslessUTF8: Bool,
        kind: ADBRemoteEntryKind,
        size: UInt64?,
        isSizeReliable: Bool,
        mtime: Date?,
        dev: UInt64? = nil,
        ino: UInt64? = nil,
        posixMode: UInt32? = nil,
        entryErrno: Int32? = nil,
        isRestricted: Bool = false
    ) {
        self.rawNameBytes = rawNameBytes
        self.displayName = displayName
        self.isLosslessUTF8 = isLosslessUTF8
        self.kind = kind
        self.size = size
        self.isSizeReliable = isSizeReliable
        self.mtime = mtime
        self.dev = dev
        self.ino = ino
        self.posixMode = posixMode
        self.entryErrno = entryErrno
        self.isRestricted = isRestricted
    }
}

public struct ADBStatResult: Sendable, Equatable {
    public let kind: ADBRemoteEntryKind
    public let size: UInt64?
    public let isSizeReliable: Bool
    public let mtime: Date?
    public let dev: UInt64?
    public let ino: UInt64?
    public let posixMode: UInt32?
    public let entryErrno: Int32?
    /// True when legacy 16B `STAT` returned all-zero `(mode=0, size=0, mtime=0)`,
    /// which cannot distinguish ENOENT from EACCES and requires Shell verification.
    public let isAllZeroV1: Bool

    public init(
        kind: ADBRemoteEntryKind,
        size: UInt64?,
        isSizeReliable: Bool,
        mtime: Date?,
        dev: UInt64? = nil,
        ino: UInt64? = nil,
        posixMode: UInt32? = nil,
        entryErrno: Int32? = nil,
        isAllZeroV1: Bool = false
    ) {
        self.kind = kind
        self.size = size
        self.isSizeReliable = isSizeReliable
        self.mtime = mtime
        self.dev = dev
        self.ino = ino
        self.posixMode = posixMode
        self.entryErrno = entryErrno
        self.isAllZeroV1 = isAllZeroV1
    }
}

public struct ADBDirectoryBatch: Sendable, Equatable {
    public let sessionId: ADBFileSessionID
    public let requestId: UUID
    public let entries: [ADBRemoteEntry]
    public let isFinal: Bool

    public init(
        sessionId: ADBFileSessionID,
        requestId: UUID,
        entries: [ADBRemoteEntry],
        isFinal: Bool
    ) {
        self.sessionId = sessionId
        self.requestId = requestId
        self.entries = entries
        self.isFinal = isFinal
    }
}

public enum ADBEmptyDirectoryProbeResult: Int32, Sendable, Equatable {
    case accessibleEmpty = 0
    case notFound = 10
    case notDirectoryOrSymlink = 11
    case pathChanged = 12
    case permissionDenied = 13
}

public enum ADBTransferConflictResolution: String, Sendable, Codable, Equatable {
    case skip
    case keepBoth
}

public enum ADBFileTaskState: String, Sendable, Codable, Equatable {
    case queued
    case transferring
    case committing
    case completed
    case skipped
    case cancelled
    case failed
    case pendingConfirmation
}

public enum ADBFileTaskKind: String, Sendable, Codable, Equatable {
    case upload
    case download
    case delete
}

public struct ADBUploadPlanItem: Sendable, Equatable {
    public let localURL: URL
    public let targetFileName: String
    public let conflictResolution: ADBTransferConflictResolution
    public let fileSize: UInt64
    public let mtime: Date?

    public init(
        localURL: URL,
        targetFileName: String,
        conflictResolution: ADBTransferConflictResolution = .keepBoth,
        fileSize: UInt64,
        mtime: Date? = nil
    ) {
        self.localURL = localURL
        self.targetFileName = targetFileName
        self.conflictResolution = conflictResolution
        self.fileSize = fileSize
        self.mtime = mtime
    }
}

public struct ADBDownloadPlanItem: Sendable, Equatable {
    public let remoteEntry: ADBRemoteEntry
    public let targetFileName: String
    public let conflictResolution: ADBTransferConflictResolution

    public init(
        remoteEntry: ADBRemoteEntry,
        targetFileName: String,
        conflictResolution: ADBTransferConflictResolution = .keepBoth
    ) {
        self.remoteEntry = remoteEntry
        self.targetFileName = targetFileName
        self.conflictResolution = conflictResolution
    }
}

public struct ADBDeleteTarget: Sendable, Equatable {
    public let remoteEntry: ADBRemoteEntry

    public init(remoteEntry: ADBRemoteEntry) {
        self.remoteEntry = remoteEntry
    }
}

public enum ADBDeleteItemStatus: String, Sendable, Equatable {
    case deleted
    case notFound
    case notRegularFile
    case pathChanged
    case permissionDenied
    case targetChanged
    case pendingConfirmation
    case notExecuted
}

public struct ADBDeleteItemResult: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let fileName: String
    public let rawNameBytes: Data
    public let status: ADBDeleteItemStatus
    public let message: String

    public init(
        id: UUID = UUID(),
        fileName: String,
        rawNameBytes: Data,
        status: ADBDeleteItemStatus,
        message: String
    ) {
        self.id = id
        self.fileName = fileName
        self.rawNameBytes = rawNameBytes
        self.status = status
        self.message = message
    }
}

public struct ADBFileTaskSnapshot: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let sessionId: ADBFileSessionID
    public let kind: ADBFileTaskKind
    public let displayName: String
    public let totalBytes: UInt64?
    public let isSizeReliable: Bool
    public let bytesTransferred: UInt64
    public let bytesPerSecond: Double
    public let state: ADBFileTaskState
    public let detail: String
    public let localOutputURL: URL?
    public let ledgerEntryId: UUID?
    public let deleteResults: [ADBDeleteItemResult]?

    public init(
        id: UUID,
        sessionId: ADBFileSessionID,
        kind: ADBFileTaskKind,
        displayName: String,
        totalBytes: UInt64?,
        isSizeReliable: Bool,
        bytesTransferred: UInt64,
        bytesPerSecond: Double,
        state: ADBFileTaskState,
        detail: String,
        localOutputURL: URL? = nil,
        ledgerEntryId: UUID? = nil,
        deleteResults: [ADBDeleteItemResult]? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.kind = kind
        self.displayName = displayName
        self.totalBytes = totalBytes
        self.isSizeReliable = isSizeReliable
        self.bytesTransferred = bytesTransferred
        self.bytesPerSecond = bytesPerSecond
        self.state = state
        self.detail = detail
        self.localOutputURL = localOutputURL
        self.ledgerEntryId = ledgerEntryId
        self.deleteResults = deleteResults
    }
}

public enum ADBFileTaskEvent: Sendable, Equatable {
    case taskUpdated(ADBFileTaskSnapshot)
    case activeTransferSlotCountChanged(Int)
    case ledgerUpdated([ADBLedgerEntry])
    case sessionInvalidated(ADBFileSessionID, reason: String)
}

public enum ADBLedgerEntryState: String, Sendable, Codable, Equatable {
    case planned
    case created
    case committing
    case pendingConfirmation
    case cleanupPending
}

public struct ADBLedgerEntry: Identifiable, Sendable, Codable, Equatable {
    public let id: UUID
    public let taskId: UUID
    public let endpoint: ADBServerEndpoint
    public let serial: String
    public let transportId: String
    public let serverGeneration: UInt64
    public let targetParentPhysicalPath: String
    public let tempDirName: String
    public let tempPayloadName: String
    public let finalTargetName: String
    public var state: ADBLedgerEntryState
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        taskId: UUID,
        endpoint: ADBServerEndpoint,
        serial: String,
        transportId: String,
        serverGeneration: UInt64,
        targetParentPhysicalPath: String,
        tempDirName: String,
        tempPayloadName: String = "payload",
        finalTargetName: String,
        state: ADBLedgerEntryState,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.taskId = taskId
        self.endpoint = endpoint
        self.serial = serial
        self.transportId = transportId
        self.serverGeneration = serverGeneration
        self.targetParentPhysicalPath = targetParentPhysicalPath
        self.tempDirName = tempDirName
        self.tempPayloadName = tempPayloadName
        self.finalTargetName = finalTargetName
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ADBLedgerFile: Sendable, Codable, Equatable {
    public let schemaVersion: Int
    public var entries: [ADBLedgerEntry]

    public init(schemaVersion: Int = 1, entries: [ADBLedgerEntry] = []) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }
}
