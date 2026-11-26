import Foundation

/// Implements ADB `sync:` v1/v2 binary framing for attribute queries (`STAT`/`STA2`/`LST2`),
/// directory listing (`LIST`/`LIS2`), and `QUIT` termination.
public struct ADBSyncClient: Sendable {
    public static let maxSyncPathBytes = ADBPathUtils.syncMaxPathBytes
    public static let maxEntryNameBytes = 4096
    public static let maxDataChunkBytes = 64 * 1024
    public static let maxFailMessageBytes = 64 * 1024
    public static let statTimeout: TimeInterval = 5.0
    public static let listIdleTimeout: TimeInterval = 15.0
    public static let listTotalTimeout: TimeInterval = 60.0
    public static let transferIdleTimeout: TimeInterval = 30.0

    public init() {}

    // MARK: - Stat (`STAT` / `STA2` / `LST2`)

    public func stat(
        connection: ADBSocketConnection,
        pathBytes: Data,
        useV2: Bool,
        followSymlinks: Bool = false,
        timeout: TimeInterval = statTimeout
    ) async throws -> ADBStatResult {
        try validatePathLength(pathBytes)

        let commandTag: String
        if useV2 {
            commandTag = followSymlinks ? "STA2" : "LST2"
        } else {
            commandTag = "STAT"
        }

        try await sendSyncPathRequest(
            connection: connection,
            tag: commandTag,
            pathBytes: pathBytes,
            timeout: timeout,
            stage: commandTag
        )

        let respTagData = try await connection.readExact(4, timeout: timeout, stage: commandTag)
        guard let respTag = String(data: respTagData, encoding: .ascii) else {
            throw ADBFileError.protocolError(stage: commandTag, detail: "非法 Sync 响应标签")
        }

        if respTag == "FAIL" {
            let message = try await readSyncFailMessage(connection: connection, timeout: timeout, stage: commandTag)
            throw ADBFileError.protocolError(stage: commandTag, detail: message)
        }

        guard respTag == commandTag else {
            throw ADBFileError.protocolError(stage: commandTag, detail: "意外 Sync 响应标签: \(respTag)")
        }

        if useV2 {
            // Remaining 68 bytes of 72B STA2/LST2 response (4B tag already consumed)
            let body = try await connection.readExact(68, timeout: timeout, stage: commandTag)
            let errRaw = body.readUInt32LE(at: 0)
            if errRaw != 0 {
                return ADBStatResult(
                    kind: .other,
                    size: nil,
                    isSizeReliable: false,
                    mtime: nil,
                    entryErrno: Int32(bitPattern: errRaw)
                )
            }
            let dev = body.readUInt64LE(at: 4)
            let ino = body.readUInt64LE(at: 12)
            let mode = body.readUInt32LE(at: 20)
            let size64 = body.readUInt64LE(at: 36)
            let mtime64 = body.readInt64LE(at: 52)
            let kind = ADBRemoteEntryKind.fromPOSIXMode(mode)

            return ADBStatResult(
                kind: kind,
                size: kind == .directory ? nil : size64,
                isSizeReliable: true,
                mtime: Date(timeIntervalSince1970: TimeInterval(mtime64)),
                dev: dev,
                ino: ino,
                posixMode: mode,
                entryErrno: nil,
                isAllZeroV1: false
            )
        } else {
            // Remaining 12 bytes of 16B STAT response (4B tag already consumed)
            let body = try await connection.readExact(12, timeout: timeout, stage: commandTag)
            let mode = body.readUInt32LE(at: 0)
            let size32 = body.readUInt32LE(at: 4)
            let mtime32 = body.readUInt32LE(at: 8)
            let isAllZero = (mode == 0 && size32 == 0 && mtime32 == 0)
            let kind = ADBRemoteEntryKind.fromPOSIXMode(mode)
            let mtime: Date? = mtime32 > 0 ? Date(timeIntervalSince1970: TimeInterval(mtime32)) : nil

            return ADBStatResult(
                kind: kind,
                size: nil,
                isSizeReliable: false,
                mtime: mtime,
                dev: nil,
                ino: nil,
                posixMode: mode,
                entryErrno: nil,
                isAllZeroV1: isAllZero
            )
        }
    }

    // MARK: - List (`LIST` / `LIS2`)

    public func listDirectory(
        connection: ADBSocketConnection,
        pathBytes: Data,
        directoryComponents: [Data],
        useV2: Bool,
        batchEntryThreshold: Int = 200,
        batchInterval: TimeInterval = 0.05,
        idleTimeout: TimeInterval = listIdleTimeout,
        totalTimeout: TimeInterval = listTotalTimeout,
        onBatch: @Sendable ([ADBRemoteEntry]) async -> Void
    ) async throws {
        try validatePathLength(pathBytes)

        let commandTag = useV2 ? "LIS2" : "LIST"
        let expectedEntryTag = useV2 ? "DNT2" : "DENT"
        let deadline = Date().addingTimeInterval(totalTimeout)

        try await sendSyncPathRequest(
            connection: connection,
            tag: commandTag,
            pathBytes: pathBytes,
            timeout: min(idleTimeout, remainingTimeout(until: deadline, stage: commandTag)),
            stage: commandTag
        )

        var pendingBatch: [ADBRemoteEntry] = []
        var lastFlush = Date()

        while true {
            try Task.checkCancellation()
            let readTimeout = try remainingReadTimeout(until: deadline, idleTimeout: idleTimeout, stage: commandTag)
            let tagData = try await connection.readExact(4, timeout: readTimeout, stage: commandTag)
            guard let tag = String(data: tagData, encoding: .ascii) else {
                throw ADBFileError.protocolError(stage: commandTag, detail: "非法目录响应标签")
            }

            if tag == "DONE" {
                if useV2 {
                    // Consume exact remaining 72 bytes of the 76B dent_v2 DONE frame
                    let tail = try await connection.readExact(
                        72,
                        timeout: try remainingReadTimeout(until: deadline, idleTimeout: idleTimeout, stage: commandTag),
                        stage: commandTag
                    )
                    let nameLen = tail.readUInt32LE(at: 68)
                    guard nameLen == 0 else {
                        throw ADBFileError.protocolError(stage: commandTag, detail: "DONE 尾帧 namelen 非零: \(nameLen)")
                    }
                } else {
                    // Consume exact remaining 16 bytes of the 20B dent_v1 DONE frame
                    let tail = try await connection.readExact(
                        16,
                        timeout: try remainingReadTimeout(until: deadline, idleTimeout: idleTimeout, stage: commandTag),
                        stage: commandTag
                    )
                    let nameLen = tail.readUInt32LE(at: 12)
                    guard nameLen == 0 else {
                        throw ADBFileError.protocolError(stage: commandTag, detail: "DONE 尾帧 namelen 非零: \(nameLen)")
                    }
                }
                break
            }

            if tag == "FAIL" {
                let message = try await readSyncFailMessage(
                    connection: connection,
                    timeout: try remainingReadTimeout(until: deadline, idleTimeout: idleTimeout, stage: commandTag),
                    stage: commandTag
                )
                throw ADBFileError.protocolError(stage: commandTag, detail: message)
            }

            guard tag == expectedEntryTag else {
                throw ADBFileError.protocolError(stage: commandTag, detail: "未知目录响应标签: \(tag)")
            }

            let entry: ADBRemoteEntry?
            if useV2 {
                let body = try await connection.readExact(
                    72,
                    timeout: try remainingReadTimeout(until: deadline, idleTimeout: idleTimeout, stage: commandTag),
                    stage: commandTag
                )
                let nameLen = Int(body.readUInt32LE(at: 68))
                guard nameLen <= Self.maxEntryNameBytes else {
                    throw ADBFileError.protocolError(stage: commandTag, detail: "条目名称长度 \(nameLen) 超过 4096 字节上限")
                }
                let rawName = try await connection.readExact(
                    nameLen,
                    timeout: try remainingReadTimeout(until: deadline, idleTimeout: idleTimeout, stage: commandTag),
                    stage: commandTag
                )
                entry = parseDentV2(body: body, rawNameBytes: rawName, directoryComponents: directoryComponents)
            } else {
                let body = try await connection.readExact(
                    16,
                    timeout: try remainingReadTimeout(until: deadline, idleTimeout: idleTimeout, stage: commandTag),
                    stage: commandTag
                )
                let nameLen = Int(body.readUInt32LE(at: 12))
                guard nameLen <= Self.maxEntryNameBytes else {
                    throw ADBFileError.protocolError(stage: commandTag, detail: "条目名称长度 \(nameLen) 超过 4096 字节上限")
                }
                let rawName = try await connection.readExact(
                    nameLen,
                    timeout: try remainingReadTimeout(until: deadline, idleTimeout: idleTimeout, stage: commandTag),
                    stage: commandTag
                )
                entry = parseDentV1(body: body, rawNameBytes: rawName, directoryComponents: directoryComponents)
            }

            if let entry {
                pendingBatch.append(entry)
                if pendingBatch.count >= batchEntryThreshold || Date().timeIntervalSince(lastFlush) >= batchInterval {
                    let batchToSend = pendingBatch
                    pendingBatch.removeAll(keepingCapacity: true)
                    lastFlush = Date()
                    await onBatch(batchToSend)
                }
            }
        }

        if !pendingBatch.isEmpty {
            await onBatch(pendingBatch)
        }
    }

    /// Sends the mandatory 8-byte `QUIT` frame before closing a healthy `sync:` session.
    public func sendQuit(connection: ADBSocketConnection, timeout: TimeInterval = 2.0) async throws {
        var frame = Data("QUIT".utf8)
        frame.append(contentsOf: [0, 0, 0, 0])
        try await connection.writeAll(frame, timeout: timeout, stage: "QUIT")
    }

    // MARK: - Streaming Upload (`SEND`) & Download (`RECV`)

    /// Streams `localFileURL` over `SEND <remoteTempPath>,33188` in `<= 64 KiB` `DATA` chunks,
    /// concurrently listening for early `FAIL` responses, finishing with `DONE(mtime)` and 8B `OKAY(0)`.
    public func sendFile(
        connection: ADBSocketConnection,
        localFileURL: URL,
        remoteTempPath: String,
        mtime: Date?,
        idleTimeout: TimeInterval = transferIdleTimeout,
        onProgress: @escaping @Sendable (UInt64) -> Void
    ) async throws {
        let sendSpec = "\(remoteTempPath),33188"
        let specBytes = Data(sendSpec.utf8)
        try validatePathLength(specBytes)

        let fileHandle = try FileHandle(forReadingFrom: localFileURL)
        defer { try? fileHandle.close() }

        try await sendSyncPathRequest(
            connection: connection,
            tag: "SEND",
            pathBytes: specBytes,
            timeout: idleTimeout,
            stage: "SEND"
        )

        enum SendRaceEvent: Sendable {
            case serverOkay
            case writerDone
        }

        let mtimeU32 = Self.clampMtimeToUInt32(mtime)

        try await withThrowingTaskGroup(of: SendRaceEvent.self) { group in
            // 1. Reader task: listens for early FAIL during streaming or OKAY after DONE.
            group.addTask {
                let tagData = try await connection.readExact(4, timeout: nil, stage: "SEND")
                guard let tag = String(data: tagData, encoding: .ascii) else {
                    throw ADBFileError.protocolError(stage: "SEND", detail: "非法上传响应标签")
                }
                if tag == "OKAY" {
                    let lenData = try await connection.readExact(4, timeout: idleTimeout, stage: "SEND")
                    let msgLen = lenData.readUInt32LE(at: 0)
                    guard msgLen == 0 else {
                        throw ADBFileError.protocolError(stage: "SEND", detail: "SEND OKAY 确认帧 msglen 非零: \(msgLen)")
                    }
                    return .serverOkay
                } else if tag == "FAIL" {
                    let msg = try await self.readSyncFailMessage(
                        connection: connection,
                        timeout: idleTimeout,
                        stage: "SEND"
                    )
                    throw Self.mapSyncFailure(stage: "SEND", message: msg)
                } else {
                    throw ADBFileError.protocolError(stage: "SEND", detail: "未知上传响应标签: \(tag)")
                }
            }

            // 2. Writer task: streams <= 64 KiB DATA chunks sequentially, then sends DONE(mtime).
            group.addTask {
                var totalSent: UInt64 = 0
                while true {
                    try Task.checkCancellation()
                    let chunk: Data?
                    do {
                        chunk = try fileHandle.read(upToCount: Self.maxDataChunkBytes)
                    } catch {
                        throw ADBFileError.protocolError(stage: "SEND", detail: "读取本地文件失败: \(error.localizedDescription)")
                    }

                    guard let chunk, !chunk.isEmpty else {
                        break
                    }

                    var frame = Data(capacity: 8 + chunk.count)
                    frame.append(contentsOf: "DATA".utf8)
                    frame.appendUInt32LE(UInt32(chunk.count))
                    frame.append(chunk)
                    try await connection.writeAll(frame, timeout: idleTimeout, stage: "SEND")

                    totalSent &+= UInt64(chunk.count)
                    onProgress(totalSent)
                }

                var doneFrame = Data(capacity: 8)
                doneFrame.append(contentsOf: "DONE".utf8)
                doneFrame.appendUInt32LE(mtimeU32)
                try await connection.writeAll(doneFrame, timeout: idleTimeout, stage: "SEND")
                return .writerDone
            }

            guard let first = try await group.next() else {
                throw ADBFileError.protocolError(stage: "SEND", detail: "上传状态异常结束")
            }

            switch first {
            case .serverOkay:
                group.cancelAll()
                throw ADBFileError.protocolError(stage: "SEND", detail: "服务端在发送 DONE 前提前返回 OKAY")
            case .writerDone:
                // Enforce idleTimeout while awaiting final OKAY/FAIL after DONE.
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(max(0.05, idleTimeout) * 1_000_000_000))
                    throw ADBFileError.protocolError(stage: "SEND", detail: "等待上传确认响应超时")
                }
                guard let second = try await group.next(), case .serverOkay = second else {
                    group.cancelAll()
                    throw ADBFileError.protocolError(stage: "SEND", detail: "上传确认异常结束")
                }
                group.cancelAll()
            }
        }
    }

    /// Streams `remotePathBytes` via `RECV` into an already-opened local file descriptor `destinationFD`.
    /// Enforces `<= 64 KiB` `DATA` chunks and `30s` I/O idle timeout (no total duration cap).
    @discardableResult
    public func receiveFile(
        connection: ADBSocketConnection,
        remotePathBytes: Data,
        destinationFD: Int32,
        idleTimeout: TimeInterval = transferIdleTimeout,
        onProgress: @escaping @Sendable (UInt64) -> Void
    ) async throws -> UInt64 {
        try validatePathLength(remotePathBytes)

        try await sendSyncPathRequest(
            connection: connection,
            tag: "RECV",
            pathBytes: remotePathBytes,
            timeout: idleTimeout,
            stage: "RECV"
        )

        var totalReceived: UInt64 = 0
        while true {
            try Task.checkCancellation()
            let tagData = try await connection.readExact(4, timeout: idleTimeout, stage: "RECV")
            guard let tag = String(data: tagData, encoding: .ascii) else {
                throw ADBFileError.protocolError(stage: "RECV", detail: "非法下载响应标签")
            }

            if tag == "DONE" {
                // Consume trailing 4-byte length/mtime field (0) of 8B DONE frame
                _ = try await connection.readExact(4, timeout: idleTimeout, stage: "RECV")
                break
            }

            if tag == "FAIL" {
                let message = try await readSyncFailMessage(
                    connection: connection,
                    timeout: idleTimeout,
                    stage: "RECV"
                )
                throw Self.mapSyncFailure(stage: "RECV", message: message)
            }

            guard tag == "DATA" else {
                throw ADBFileError.protocolError(stage: "RECV", detail: "未知下载响应标签: \(tag)")
            }

            let lenData = try await connection.readExact(4, timeout: idleTimeout, stage: "RECV")
            let dataLen = Int(lenData.readUInt32LE(at: 0))
            guard dataLen <= Self.maxDataChunkBytes else {
                throw ADBFileError.protocolError(stage: "RECV", detail: "DATA 分块长度 \(dataLen) 超过 64 KiB 上限")
            }

            if dataLen > 0 {
                let chunk = try await connection.readExact(dataLen, timeout: idleTimeout, stage: "RECV")
                try Self.writeAllToFileDescriptor(destinationFD, data: chunk)
                totalReceived &+= UInt64(dataLen)
                onProgress(totalReceived)
            }
        }

        return totalReceived
    }

    private static func clampMtimeToUInt32(_ date: Date?) -> UInt32 {
        let raw = date?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
        if raw >= 0 && raw <= Double(UInt32.max) {
            return UInt32(raw)
        }
        let now = Date().timeIntervalSince1970
        if now >= 0 && now <= Double(UInt32.max) {
            return UInt32(now)
        }
        return 0
    }

    private static func mapSyncFailure(stage: String, message: String) -> ADBFileError {
        let lower = message.lowercased()
        if lower.contains("no space") || lower.contains("enospc") || lower.contains("disk full") {
            return .diskFull(message)
        }
        if lower.contains("permission denied") || lower.contains("eacces") || lower.contains("eperm") {
            return .permissionDenied(message)
        }
        return .protocolError(stage: stage, detail: message)
    }

    private static func writeAllToFileDescriptor(_ fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var written = 0
            while written < data.count {
                let ptr = base.advanced(by: written)
                let res = Darwin.write(fd, ptr, data.count - written)
                if res > 0 {
                    written += res
                } else if res == -1 && errno == EINTR {
                    continue
                } else {
                    let errCode = errno
                    let errStr = String(cString: strerror(errCode))
                    if errCode == ENOSPC {
                        throw ADBFileError.diskFull(errStr)
                    }
                    throw ADBFileError.protocolError(stage: "RECV", detail: "写入本地临时文件失败: \(errStr)")
                }
            }
        }
    }

    // MARK: - Helpers

    private func parseDentV2(
        body: Data,
        rawNameBytes: Data,
        directoryComponents: [Data]
    ) -> ADBRemoteEntry? {
        if isDotOrDotDot(rawNameBytes) { return nil }

        let errRaw = body.readUInt32LE(at: 0)
        let (displayName, isLossless) = ADBPathUtils.decodeEntryName(rawNameBytes)
        let isRestricted = ADBPathUtils.isRestrictedEntry(in: directoryComponents, entryBytes: rawNameBytes)

        if errRaw != 0 {
            return ADBRemoteEntry(
                rawNameBytes: rawNameBytes,
                displayName: displayName,
                isLosslessUTF8: isLossless,
                kind: .other,
                size: nil,
                isSizeReliable: false,
                mtime: nil,
                dev: nil,
                ino: nil,
                posixMode: nil,
                entryErrno: Int32(bitPattern: errRaw),
                isRestricted: isRestricted
            )
        }

        let dev = body.readUInt64LE(at: 4)
        let ino = body.readUInt64LE(at: 12)
        let mode = body.readUInt32LE(at: 20)
        let size64 = body.readUInt64LE(at: 36)
        let mtime64 = body.readInt64LE(at: 52)
        let kind = ADBRemoteEntryKind.fromPOSIXMode(mode)

        return ADBRemoteEntry(
            rawNameBytes: rawNameBytes,
            displayName: displayName,
            isLosslessUTF8: isLossless,
            kind: kind,
            size: kind == .directory ? nil : size64,
            isSizeReliable: true,
            mtime: Date(timeIntervalSince1970: TimeInterval(mtime64)),
            dev: dev,
            ino: ino,
            posixMode: mode,
            entryErrno: nil,
            isRestricted: isRestricted
        )
    }

    private func parseDentV1(
        body: Data,
        rawNameBytes: Data,
        directoryComponents: [Data]
    ) -> ADBRemoteEntry? {
        if isDotOrDotDot(rawNameBytes) { return nil }

        let mode = body.readUInt32LE(at: 0)
        let mtime32 = body.readUInt32LE(at: 8)
        let kind = ADBRemoteEntryKind.fromPOSIXMode(mode)
        let (displayName, isLossless) = ADBPathUtils.decodeEntryName(rawNameBytes)
        let isRestricted = ADBPathUtils.isRestrictedEntry(in: directoryComponents, entryBytes: rawNameBytes)
        let mtime: Date? = mtime32 > 0 ? Date(timeIntervalSince1970: TimeInterval(mtime32)) : nil

        return ADBRemoteEntry(
            rawNameBytes: rawNameBytes,
            displayName: displayName,
            isLosslessUTF8: isLossless,
            kind: kind,
            size: nil,
            isSizeReliable: false,
            mtime: mtime,
            dev: nil,
            ino: nil,
            posixMode: mode,
            entryErrno: nil,
            isRestricted: isRestricted
        )
    }

    private func isDotOrDotDot(_ rawNameBytes: Data) -> Bool {
        rawNameBytes == Data([0x2E]) || rawNameBytes == Data([0x2E, 0x2E])
    }

    private func validatePathLength(_ pathBytes: Data) throws {
        guard pathBytes.count <= Self.maxSyncPathBytes else {
            throw ADBFileError.pathTooLong(pathBytes.count)
        }
    }

    private func sendSyncPathRequest(
        connection: ADBSocketConnection,
        tag: String,
        pathBytes: Data,
        timeout: TimeInterval,
        stage: String
    ) async throws {
        var packet = Data(capacity: 8 + pathBytes.count)
        packet.append(contentsOf: tag.utf8)
        packet.appendUInt32LE(UInt32(pathBytes.count))
        packet.append(pathBytes)
        try await connection.writeAll(packet, timeout: timeout, stage: stage)
    }

    private func readSyncFailMessage(
        connection: ADBSocketConnection,
        timeout: TimeInterval,
        stage: String
    ) async throws -> String {
        let lenData = try await connection.readExact(4, timeout: timeout, stage: stage)
        let msgLen = Int(lenData.readUInt32LE(at: 0))
        guard msgLen <= Self.maxFailMessageBytes else {
            throw ADBFileError.protocolError(stage: stage, detail: "Sync FAIL 消息长度 \(msgLen) 超出 64 KiB 上限")
        }
        let msgData = try await connection.readExact(msgLen, timeout: timeout, stage: stage)
        return String(data: msgData, encoding: .utf8) ?? "<non-utf8>"
    }

    private func remainingTimeout(until deadline: Date, stage: String) -> TimeInterval {
        max(0.001, deadline.timeIntervalSinceNow)
    }

    private func remainingReadTimeout(until deadline: Date, idleTimeout: TimeInterval, stage: String) throws -> TimeInterval {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            throw ADBFileError.protocolError(stage: stage, detail: "目录枚举超过总超时上限")
        }
        return min(idleTimeout, remaining)
    }
}

extension Data {
    func readUInt32LE(at offset: Int) -> UInt32 {
        precondition(offset >= 0 && offset + 4 <= count)
        let base = startIndex + offset
        return UInt32(self[base])
            | (UInt32(self[base + 1]) << 8)
            | (UInt32(self[base + 2]) << 16)
            | (UInt32(self[base + 3]) << 24)
    }

    func readUInt64LE(at offset: Int) -> UInt64 {
        precondition(offset >= 0 && offset + 8 <= count)
        let lo = UInt64(readUInt32LE(at: offset))
        let hi = UInt64(readUInt32LE(at: offset + 4))
        return lo | (hi << 32)
    }

    func readInt64LE(at offset: Int) -> Int64 {
        Int64(bitPattern: readUInt64LE(at: offset))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
