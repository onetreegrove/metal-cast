import Foundation

public struct ADBShellResult: Sendable, Equatable {
    public let exitCode: UInt8
    public let stdout: String
    public let stderr: String
    public let usedStdinFallback: Bool

    public init(exitCode: UInt8, stdout: String, stderr: String, usedStdinFallback: Bool) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.usedStdinFallback = usedStdinFallback
    }
}

public enum ADBUploadCommitOutcome: Sendable, Equatable {
    case committedAndCleaned
    case committedPendingDirCleanup
    case targetConflict
}

/// Implements ADB `shell,v2,raw:` binary framing (`stdin`/`stdout`/`stderr`/`exit`/`close_stdin`),
/// automatic `>= 3800` byte `sh` stdin fallback, and fixed POSIX templates for root & directory checks.
public struct ADBShellClient: Sendable {
    public static let inlineServiceByteThreshold = 3800
    public static let maxCommandBytes = 32 * 1024
    public static let maxFramePayloadBytes = 1024 * 1024
    public static let maxStdoutBytes = 256 * 1024
    public static let maxStderrBytes = 64 * 1024
    public static let defaultTimeout: TimeInterval = 10.0

    private static let idStdin: UInt8 = 0
    private static let idStdout: UInt8 = 1
    private static let idStderr: UInt8 = 2
    private static let idExit: UInt8 = 3
    private static let idCloseStdin: UInt8 = 4
    private static let idWindowSizeChange: UInt8 = 5

    public init() {}

    /// Executes `command` over `shell,v2,raw:` on a fresh `ADBSocketConnection` bound to `transportId`.
    /// Automatically switches to `shell,v2,raw:sh` + stdin feeding when the service string is `>= 3800` bytes.
    public func execute(
        connection: ADBSocketConnection,
        transportId: String,
        command: String,
        timeout: TimeInterval = defaultTimeout
    ) async throws -> ADBShellResult {
        let cmdBytes = Data(command.utf8)
        guard cmdBytes.count <= Self.maxCommandBytes else {
            throw ADBFileError.pathTooLong(cmdBytes.count)
        }

        let inlineService = "shell,v2,raw:\(command)"
        let useStdinFallback = inlineService.utf8.count >= Self.inlineServiceByteThreshold
        let openedService = useStdinFallback ? "shell,v2,raw:sh" : inlineService

        let deadline = Date().addingTimeInterval(timeout)
        try await connection.openDeviceService(
            transportId: transportId,
            service: openedService,
            timeout: min(ADBSocketConnection.defaultHandshakeTimeout, remaining(until: deadline)),
            stage: "shell_v2"
        )

        if useStdinFallback {
            var script = cmdBytes
            if script.last != 0x0A {
                script.append(0x0A)
            }
            let chunkSize = 16 * 1024
            var offset = 0
            while offset < script.count {
                let end = min(script.count, offset + chunkSize)
                let slice = Data(script[offset..<end])
                try await sendFrame(
                    connection: connection,
                    id: Self.idStdin,
                    payload: slice,
                    timeout: try remainingChecked(until: deadline)
                )
                offset = end
            }
            try await sendFrame(
                connection: connection,
                id: Self.idCloseStdin,
                payload: Data(),
                timeout: try remainingChecked(until: deadline)
            )
        }

        var stdoutData = Data()
        var stderrData = Data()
        var exitCode: UInt8?

        while true {
            try Task.checkCancellation()
            let header = try await readShellHeaderOrEOF(
                connection: connection,
                timeout: try remainingChecked(until: deadline)
            )
            guard let header else {
                break
            }

            let frameId = header.id
            let length = header.length
            guard length <= Self.maxFramePayloadBytes else {
                throw ADBFileError.protocolError(
                    stage: "shell_v2",
                    detail: "Shell v2 帧长度 \(length) 超过 1 MiB 上限"
                )
            }

            let payload = length > 0
                ? try await connection.readExact(length, timeout: try remainingChecked(until: deadline), stage: "shell_v2")
                : Data()

            switch frameId {
            case Self.idStdout:
                guard stdoutData.count + payload.count <= Self.maxStdoutBytes else {
                    throw ADBFileError.protocolError(stage: "shell_v2", detail: "Shell stdout 超过 256 KiB 上限")
                }
                stdoutData.append(payload)
            case Self.idStderr:
                guard stderrData.count + payload.count <= Self.maxStderrBytes else {
                    throw ADBFileError.protocolError(stage: "shell_v2", detail: "Shell stderr 超过 64 KiB 上限")
                }
                stderrData.append(payload)
            case Self.idExit:
                guard payload.count == 1 else {
                    throw ADBFileError.protocolError(stage: "shell_v2", detail: "Shell 退出帧长度非法: \(payload.count)")
                }
                exitCode = payload[payload.startIndex]
            case Self.idWindowSizeChange:
                break
            default:
                throw ADBFileError.protocolError(stage: "shell_v2", detail: "未知 Shell v2 帧 ID: \(frameId)")
            }
        }

        guard let finalExit = exitCode else {
            throw ADBFileError.operationUnconfirmed("Shell v2 流已结束但未收到退出帧 (kIdExit)")
        }

        return ADBShellResult(
            exitCode: finalExit,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self),
            usedStdinFallback: useStdinFallback
        )
    }

    // MARK: - Built-in POSIX Templates

    /// Resolves `/sdcard` physical root without relying on external `realpath`.
    public func resolveSharedStorageRoot(
        connection: ADBSocketConnection,
        transportId: String,
        timeout: TimeInterval = defaultTimeout
    ) async throws -> String {
        let script = """
        if [ ! -e /sdcard ]; then exit 10; fi
        cd -P -- /sdcard 2>/dev/null || { [ -d /sdcard ] && exit 13 || exit 10; }
        [ -r . ] || exit 13
        pwd -P
        """
        let result = try await execute(connection: connection, transportId: transportId, command: script, timeout: timeout)
        switch result.exitCode {
        case 0:
            var path = result.stdout
            if path.hasSuffix("\n") {
                path.removeLast()
            }
            if path.hasSuffix("\r") {
                path.removeLast()
            }
            guard path.hasPrefix("/"), !path.isEmpty, !path.contains("\n"), !path.contains("\0") else {
                throw ADBFileError.protocolError(stage: "resolveRoot", detail: "解析共享存储根返回异常路径: \(path)")
            }
            return path
        case 10:
            throw ADBFileError.pathChanged("设备共享存储 /sdcard 不存在或未挂载")
        case 13:
            throw ADBFileError.permissionDenied("无权读取设备共享存储 /sdcard")
        default:
            throw ADBFileError.protocolError(stage: "resolveRoot", detail: "解析共享存储根退出码 \(result.exitCode)")
        }
    }

    /// Probes an empty directory to distinguish true empty (`0`), missing (`10`), non-dir/symlink (`11`),
    /// path drift (`12`), or permission denied (`13`) using trailing `\nx` sentinel verification.
    public func probeEmptyDirectory(
        connection: ADBSocketConnection,
        transportId: String,
        physicalRoot: String,
        components: [Data],
        timeout: TimeInterval = defaultTimeout
    ) async throws -> ADBEmptyDirectoryProbeResult {
        let script: String
        if components.isEmpty {
            let escapedRoot = try ADBPathUtils.escapeShellSingleQuoted(physicalRoot)
            let escapedExpected = try ADBPathUtils.escapeShellSingleQuoted(physicalRoot + "\nx")
            script = """
            [ -e \(escapedRoot) ] || exit 10
            [ -L \(escapedRoot) ] && exit 11
            [ -d \(escapedRoot) ] || exit 11
            cd -P -- \(escapedRoot) 2>/dev/null || exit 13
            p=$(pwd -P && echo x) || exit 12
            [ "$p" = \(escapedExpected) ] || exit 12
            [ -r . ] && [ -x . ] || exit 13
            """
        } else {
            let parentComponents = Array(components.dropLast())
            let dirName = try ADBPathUtils.validateComponent(components.last!)
            let parentPhysicalPath = try ADBPathUtils.buildRemotePath(
                physicalRoot: physicalRoot,
                components: parentComponents
            )
            let escapedParent = try ADBPathUtils.escapeShellSingleQuoted(parentPhysicalPath)
            let escapedExpected = try ADBPathUtils.escapeShellSingleQuoted(parentPhysicalPath + "\nx")
            let escapedDir = try ADBPathUtils.escapeShellSingleQuoted(dirName)

            script = """
            cd -P -- \(escapedParent) 2>/dev/null || exit 12
            p=$(pwd -P && echo x) || exit 12
            [ "$p" = \(escapedExpected) ] || exit 12
            [ -e \(escapedDir) ] || exit 10
            [ -L \(escapedDir) ] && exit 11
            [ -d \(escapedDir) ] || exit 11
            cd -P -- \(escapedDir) 2>/dev/null || exit 13
            [ -r . ] && [ -x . ] || exit 13
            """
        }

        let result = try await execute(connection: connection, transportId: transportId, command: script, timeout: timeout)
        guard let probeResult = ADBEmptyDirectoryProbeResult(rawValue: Int32(result.exitCode)) else {
            throw ADBFileError.protocolError(
                stage: "probeEmptyDirectory",
                detail: "未知空目录探测退出码 \(result.exitCode): \(result.stderr)"
            )
        }
        return probeResult
    }

    /// Probes whether the device supports `mv -nT`, falls back to `mv -n`, or reports `.unsupported`.
    public func probeCommitCapability(
        endpoint: ADBServerEndpoint,
        transportId: String,
        parentPhysicalPath: String,
        timeout: TimeInterval = defaultTimeout
    ) async throws -> ADBCommitMode {
        let probeDirName = ".metalcast-probe-\(UUID().uuidString.lowercased())"
        let escapedParent = try ADBPathUtils.escapeShellSingleQuoted(parentPhysicalPath)
        let escapedExpected = try ADBPathUtils.escapeShellSingleQuoted(parentPhysicalPath + "\nx")
        let escapedProbe = try ADBPathUtils.escapeShellSingleQuoted(probeDirName)

        let script = """
        cd -P -- \(escapedParent) 2>/dev/null || exit 20
        p=$(pwd -P && echo x) || exit 20
        [ "$p" = \(escapedExpected) ] || exit 20
        mkdir -- \(escapedProbe) 2>/dev/null || exit 25
        if ! cd -P -- \(escapedProbe) 2>/dev/null; then
          rmdir -- \(escapedProbe) 2>/dev/null
          exit 25
        fi
        if ! (: > a) 2>/dev/null; then
          cd .. 2>/dev/null
          rmdir -- \(escapedProbe) 2>/dev/null
          exit 25
        fi
        mode=3
        if mv -nT -- a b 2>/dev/null && [ -f b ] && [ ! -e a ]; then
          mode=0
          rm -- b 2>/dev/null
        elif mv -n -- a c 2>/dev/null && [ -f c ] && [ ! -e a ]; then
          mode=1
          rm -- c 2>/dev/null
        else
          [ -e a ] && rm -- a 2>/dev/null
          [ -e b ] && rm -- b 2>/dev/null
          [ -e c ] && rm -- c 2>/dev/null
        fi
        cd .. 2>/dev/null
        rmdir -- \(escapedProbe) 2>/dev/null
        exit "$mode"
        """

        let conn = ADBSocketConnection(endpoint: endpoint)
        defer { conn.close() }
        try await conn.connect()
        let result = try await execute(connection: conn, transportId: transportId, command: script, timeout: timeout)
        switch result.exitCode {
        case 0:
            return .mvNoClobberNoTarget
        case 1:
            return .mvNoClobberWithGuard
        case 3:
            return .unsupported
        case 20:
            throw ADBFileError.pathChanged("物理父目录发生变化，无法探测提交能力")
        case 25:
            throw ADBFileError.permissionDenied("无法在目标目录创建探测临时目录")
        default:
            throw ADBFileError.protocolError(stage: "probeCommit", detail: "探测退出码异常: \(result.exitCode)")
        }
    }

    /// Exclusively creates the hidden temporary staging directory `.metalcast-tmp-<uuid>` inside `parentPhysicalPath`.
    public func createTempUploadDirectory(
        connection: ADBSocketConnection,
        transportId: String,
        parentPhysicalPath: String,
        tempDirName: String,
        timeout: TimeInterval = defaultTimeout
    ) async throws {
        let escapedParent = try ADBPathUtils.escapeShellSingleQuoted(parentPhysicalPath)
        let escapedExpected = try ADBPathUtils.escapeShellSingleQuoted(parentPhysicalPath + "\nx")
        let escapedTmpDir = try ADBPathUtils.escapeShellSingleQuoted(tempDirName)

        let script = """
        cd -P -- \(escapedParent) 2>/dev/null || exit 20
        p=$(pwd -P && echo x) || exit 20
        [ "$p" = \(escapedExpected) ] || exit 20
        mkdir -- \(escapedTmpDir) || exit 25
        """
        let result = try await execute(connection: connection, transportId: transportId, command: script, timeout: timeout)
        switch result.exitCode {
        case 0:
            return
        case 20:
            throw ADBFileError.pathChanged("物理父目录发生变化")
        case 25:
            throw ADBFileError.permissionDenied("无法创建远端暂存目录 \(tempDirName): \(result.stderr)")
        default:
            throw ADBFileError.protocolError(stage: "mkdirTmp", detail: "退出码 \(result.exitCode): \(result.stderr)")
        }
    }

    /// Atomically commits `tempDirName/tempPayloadName` to `destinationName` and removes the empty staging dir.
    public func commitUploadedFile(
        connection: ADBSocketConnection,
        transportId: String,
        parentPhysicalPath: String,
        tempDirName: String,
        tempPayloadName: String,
        destinationName: String,
        commitMode: ADBCommitMode,
        timeout: TimeInterval = defaultTimeout
    ) async throws -> ADBUploadCommitOutcome {
        guard commitMode != .unsupported else {
            throw ADBFileError.unsupportedDevice("设备不支持 mv -n 安全提交")
        }

        let escapedParent = try ADBPathUtils.escapeShellSingleQuoted(parentPhysicalPath)
        let escapedExpected = try ADBPathUtils.escapeShellSingleQuoted(parentPhysicalPath + "\nx")
        let escapedTmpPayload = try ADBPathUtils.escapeShellSingleQuoted("\(tempDirName)/\(tempPayloadName)")
        let escapedTmpDir = try ADBPathUtils.escapeShellSingleQuoted(tempDirName)
        let escapedDst = try ADBPathUtils.escapeShellSingleQuoted(destinationName)

        let moveCmd = commitMode == .mvNoClobberNoTarget
            ? "mv -nT -- \(escapedTmpPayload) \(escapedDst) || exit 23"
            : "mv -n -- \(escapedTmpPayload) \(escapedDst) || exit 23"

        let script = """
        cd -P -- \(escapedParent) 2>/dev/null || exit 20
        p=$(pwd -P && echo x) || exit 20
        [ "$p" = \(escapedExpected) ] || exit 20
        [ -f \(escapedTmpPayload) ] && [ ! -L \(escapedTmpPayload) ] || exit 21
        [ ! -e \(escapedDst) ] && [ ! -L \(escapedDst) ] || exit 22
        \(moveCmd)
        [ ! -e \(escapedTmpPayload) ] && [ ! -L \(escapedTmpPayload) ] || exit 24
        [ -f \(escapedDst) ] && [ ! -L \(escapedDst) ] || exit 24
        rmdir -- \(escapedTmpDir) 2>/dev/null || exit 27
        """

        let result = try await execute(connection: connection, transportId: transportId, command: script, timeout: timeout)
        switch result.exitCode {
        case 0:
            return .committedAndCleaned
        case 20:
            throw ADBFileError.pathChanged("提交前物理父目录发生变化")
        case 21:
            throw ADBFileError.protocolError(stage: "commit", detail: "远端暂存文件丢失或类型异常")
        case 22:
            return .targetConflict
        case 23:
            throw ADBFileError.protocolError(stage: "commit", detail: "mv 提交执行失败: \(result.stderr)")
        case 24:
            if commitMode == .mvNoClobberWithGuard {
                throw ADBFileError.targetChanged("提交后复核失败：目标位置可能已变为同名目录导致暂存文件移入子目录，请刷新目录核对")
            }
            throw ADBFileError.targetChanged("提交后复核失败：暂存文件仍在或目标非普通文件")
        case 27:
            return .committedPendingDirCleanup
        default:
            throw ADBFileError.protocolError(stage: "commit", detail: "提交返回未知退出码 \(result.exitCode)")
        }
    }

    /// Removes a specific staging payload and its `.metalcast-tmp-*` directory without `rm -rf`.
    public func cleanupTempUploadDirectory(
        connection: ADBSocketConnection,
        transportId: String,
        parentPhysicalPath: String,
        tempDirName: String,
        tempPayloadName: String,
        timeout: TimeInterval = defaultTimeout
    ) async throws {
        let escapedParent = try ADBPathUtils.escapeShellSingleQuoted(parentPhysicalPath)
        let escapedExpected = try ADBPathUtils.escapeShellSingleQuoted(parentPhysicalPath + "\nx")
        let escapedTmpDir = try ADBPathUtils.escapeShellSingleQuoted(tempDirName)
        let escapedTmpPayload = try ADBPathUtils.escapeShellSingleQuoted("\(tempDirName)/\(tempPayloadName)")

        let script = """
        cd -P -- \(escapedParent) 2>/dev/null || exit 20
        p=$(pwd -P && echo x) || exit 20
        [ "$p" = \(escapedExpected) ] || exit 20
        [ -d \(escapedTmpDir) ] && [ ! -L \(escapedTmpDir) ] || exit 25
        if [ -f \(escapedTmpPayload) ] && [ ! -L \(escapedTmpPayload) ]; then
          rm -- \(escapedTmpPayload) || exit 26
        fi
        if [ -d \(escapedTmpDir) ]; then
          rmdir -- \(escapedTmpDir) || exit 27
        fi
        """

        let result = try await execute(connection: connection, transportId: transportId, command: script, timeout: timeout)
        switch result.exitCode {
        case 0, 25:
            // exit 25 means tempDir is already gone on device, so cleanup is converged.
            return
        case 20:
            throw ADBFileError.pathChanged("清理暂存时物理父目录发生变化")
        case 26, 27:
            throw ADBFileError.permissionDenied("清理暂存目录失败（退出码 \(result.exitCode)）: \(result.stderr)")
        default:
            throw ADBFileError.protocolError(stage: "cleanup", detail: "清理退出码 \(result.exitCode)")
        }
    }

    /// Read-only verification after a commit-stage disconnect (`pendingConfirmation`),
    /// optionally removing the leftover empty temp dir if the target regular file is already committed.
    public func verifyPendingUpload(
        connection: ADBSocketConnection,
        transportId: String,
        parentPhysicalPath: String,
        tempDirName: String,
        tempPayloadName: String,
        finalTargetName: String,
        timeout: TimeInterval = defaultTimeout
    ) async throws -> (committed: Bool, tempDirCleaned: Bool) {
        let escapedParent = try ADBPathUtils.escapeShellSingleQuoted(parentPhysicalPath)
        let escapedExpected = try ADBPathUtils.escapeShellSingleQuoted(parentPhysicalPath + "\nx")
        let escapedTmpDir = try ADBPathUtils.escapeShellSingleQuoted(tempDirName)
        let escapedTmpPayload = try ADBPathUtils.escapeShellSingleQuoted("\(tempDirName)/\(tempPayloadName)")
        let escapedDst = try ADBPathUtils.escapeShellSingleQuoted(finalTargetName)

        let script = """
        cd -P -- \(escapedParent) 2>/dev/null || exit 20
        p=$(pwd -P && echo x) || exit 20
        [ "$p" = \(escapedExpected) ] || exit 20
        if [ -f \(escapedDst) ] && [ ! -L \(escapedDst) ] && [ ! -e \(escapedTmpPayload) ]; then
          if [ -d \(escapedTmpDir) ] && [ ! -L \(escapedTmpDir) ]; then
            rmdir -- \(escapedTmpDir) 2>/dev/null && exit 0 || exit 2
          fi
          exit 0
        fi
        if [ -e \(escapedTmpPayload) ]; then
          exit 1
        fi
        exit 3
        """

        let result = try await execute(connection: connection, transportId: transportId, command: script, timeout: timeout)
        switch result.exitCode {
        case 0:
            return (committed: true, tempDirCleaned: true)
        case 2:
            return (committed: true, tempDirCleaned: false)
        case 1, 3:
            return (committed: false, tempDirCleaned: false)
        case 20:
            throw ADBFileError.pathChanged("核对时物理父目录发生变化")
        default:
            throw ADBFileError.protocolError(stage: "verifyPending", detail: "核对退出码 \(result.exitCode)")
        }
    }

    /// Non-recursive regular-file deletion (`rm --`, never `-r` / `-f`).
    public func deleteSingleFile(
        connection: ADBSocketConnection,
        transportId: String,
        parentPhysicalPath: String,
        targetName: String,
        timeout: TimeInterval = defaultTimeout
    ) async throws -> ADBDeleteItemStatus {
        let escapedParent = try ADBPathUtils.escapeShellSingleQuoted(parentPhysicalPath)
        let escapedExpected = try ADBPathUtils.escapeShellSingleQuoted(parentPhysicalPath + "\nx")
        let escapedTarget = try ADBPathUtils.escapeShellSingleQuoted(targetName)

        let script = """
        cd -P -- \(escapedParent) 2>/dev/null || exit 33
        p=$(pwd -P && echo x) || exit 33
        [ "$p" = \(escapedExpected) ] || exit 33
        if [ -L \(escapedTarget) ]; then exit 31; fi
        if [ ! -e \(escapedTarget) ]; then exit 30; fi
        if [ ! -f \(escapedTarget) ]; then exit 32; fi
        rm -- \(escapedTarget) || { [ -e \(escapedTarget) ] && exit 34 || exit 30; }
        """

        let result = try await execute(connection: connection, transportId: transportId, command: script, timeout: timeout)
        switch result.exitCode {
        case 0:
            return .deleted
        case 30:
            return .notFound
        case 31, 32:
            return .notRegularFile
        case 33:
            return .pathChanged
        case 34:
            return .permissionDenied
        default:
            throw ADBFileError.protocolError(stage: "delete", detail: "删除退出码 \(result.exitCode): \(result.stderr)")
        }
    }

    // MARK: - Helpers

    private func sendFrame(
        connection: ADBSocketConnection,
        id: UInt8,
        payload: Data,
        timeout: TimeInterval
    ) async throws {
        var frame = Data(capacity: 5 + payload.count)
        frame.append(id)
        frame.appendUInt32LE(UInt32(payload.count))
        frame.append(payload)
        try await connection.writeAll(frame, timeout: timeout, stage: "shell_v2")
    }

    private func readShellHeaderOrEOF(
        connection: ADBSocketConnection,
        timeout: TimeInterval
    ) async throws -> (id: UInt8, length: Int)? {
        guard let first = try await connection.readExactOrEOF(1, timeout: timeout, stage: "shell_v2") else {
            return nil
        }

        let rest = try await connection.readExact(4, timeout: timeout, stage: "shell_v2")
        let frameId = first[first.startIndex]
        let length = Int(rest.readUInt32LE(at: 0))
        return (frameId, length)
    }

    private func remaining(until deadline: Date) -> TimeInterval {
        max(0.001, deadline.timeIntervalSinceNow)
    }

    private func remainingChecked(until deadline: Date) throws -> TimeInterval {
        let rem = deadline.timeIntervalSinceNow
        guard rem > 0 else {
            throw ADBFileError.protocolError(stage: "shell_v2", detail: "Shell 命令执行超时")
        }
        return rem
    }
}
