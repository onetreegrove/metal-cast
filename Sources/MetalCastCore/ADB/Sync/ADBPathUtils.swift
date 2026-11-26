import Foundation

public enum ADBPathUtils {
    public static let syncMaxPathBytes = 1024
    public static let maxFileNameUTF8Bytes = 255

    private static let forbiddenUploadScalars: Set<Unicode.Scalar> = [
        "?", "\"", "*", ":", "<", ">", "\\", "|"
    ]

    /// Decodes raw directory entry bytes, distinguishing lossless UTF-8 from broken encodings.
    public static func decodeEntryName(_ rawBytes: Data) -> (displayName: String, isLosslessUTF8: Bool) {
        if let decoded = String(data: rawBytes, encoding: .utf8), Data(decoded.utf8) == rawBytes {
            return (decoded, true)
        }
        return (String(decoding: rawBytes, as: UTF8.self), false)
    }

    /// Formats control characters (`0x00...0x1F`, `0x7F`) into visible escapes for single-line UI rendering.
    public static func sanitizeControlCharactersForDisplay(_ name: String) -> (text: String, hasControlCharacters: Bool) {
        var out = ""
        out.reserveCapacity(name.count)
        var hasControl = false

        for scalar in name.unicodeScalars {
            let v = scalar.value
            if v == 0x0A {
                hasControl = true
                out.append("\\n")
            } else if v == 0x0D {
                hasControl = true
                out.append("\\r")
            } else if v == 0x09 {
                hasControl = true
                out.append("\\t")
            } else if v < 0x20 {
                hasControl = true
                let letter = Unicode.Scalar(v + 64)!
                out.append("^")
                out.append(Character(letter))
            } else if v == 0x7F {
                hasControl = true
                out.append("^?")
            } else {
                out.append(Character(scalar))
            }
        }
        return (out, hasControl)
    }

    /// Validates a single navigation/operation path component (`rawNameBytes`).
    /// Rejects empty, `.`, `..`, `/`, `\0`, and non-lossless UTF-8.
    public static func validateComponent(_ rawBytes: Data) throws -> String {
        guard !rawBytes.isEmpty else {
            throw ADBFileError.invalidFileName("路径分量不能为空")
        }
        if rawBytes == Data([0x2E]) || rawBytes == Data([0x2E, 0x2E]) {
            throw ADBFileError.invalidFileName("路径分量不能为 '.' 或 '..'")
        }
        if rawBytes.contains(0x2F) {
            throw ADBFileError.invalidFileName("路径分量不能包含 '/'")
        }
        if rawBytes.contains(0x00) {
            throw ADBFileError.invalidFileName("路径分量不能包含 NUL 字节")
        }
        let (decoded, isLossless) = decodeEntryName(rawBytes)
        guard isLossless else {
            throw ADBFileError.invalidFileName("文件名编码不是有效 UTF-8")
        }
        return decoded
    }

    /// Validates a new or renamed upload filename against Android `/sdcard` (`sdcardfs`/FUSE) restrictions.
    public static func validateUploadFileName(_ name: String) throws {
        guard !name.isEmpty else {
            throw ADBFileError.invalidFileName("文件名不能为空")
        }
        if name == "." || name == ".." {
            throw ADBFileError.invalidFileName("文件名不能为 '.' 或 '..'")
        }
        for scalar in name.unicodeScalars {
            let v = scalar.value
            if v == 0x00 {
                throw ADBFileError.invalidFileName("文件名包含非法 NUL 字节")
            }
            if v == 0x2F {
                throw ADBFileError.invalidFileName("文件名不能包含 '/'")
            }
            if v < 0x20 || v == 0x7F {
                throw ADBFileError.invalidFileName("文件名包含控制字符或换行符")
            }
            if forbiddenUploadScalars.contains(scalar) {
                throw ADBFileError.invalidFileName("文件名包含 /sdcard 禁止字符: \(scalar)")
            }
        }
        let byteCount = name.utf8.count
        guard byteCount <= maxFileNameUTF8Bytes else {
            throw ADBFileError.invalidFileName("文件名超过 255 UTF-8 字节上限（当前 \(byteCount) 字节）")
        }
    }

    /// ASCII case-insensitive check for `Android/data` and `Android/obb` (Plan §3.2).
    public static func isRestrictedComponents(_ components: [Data]) -> Bool {
        guard components.count >= 2 else { return false }
        let first = asciiLowercased(components[0])
        let second = asciiLowercased(components[1])
        return first == "android" && (second == "data" || second == "obb")
    }

    /// Checks whether a directory entry inside `directoryComponents` represents a restricted `Android/data` or `Android/obb` entry.
    public static func isRestrictedEntry(in directoryComponents: [Data], entryBytes: Data) -> Bool {
        guard directoryComponents.count == 1 else { return false }
        return asciiLowercased(directoryComponents[0]) == "android" && {
            let sub = asciiLowercased(entryBytes)
            return sub == "data" || sub == "obb"
        }()
    }

    /// Validates that `components` does not target `Android/data` or `Android/obb` (or any descendant).
    public static func ensureNotRestricted(_ components: [Data]) throws {
        if isRestrictedComponents(components) {
            let display = components.map { decodeEntryName($0).displayName }.joined(separator: "/")
            throw ADBFileError.restrictedPath(display)
        }
    }

    /// Builds a validated remote path string under `physicalRoot`.
    public static func buildRemotePath(physicalRoot: String, components: [Data]) throws -> String {
        guard physicalRoot.hasPrefix("/"), !physicalRoot.isEmpty, !physicalRoot.utf8.contains(0x00) else {
            throw ADBFileError.pathChanged("非法共享存储物理根路径")
        }
        try ensureNotRestricted(components)
        let validatedParts = try components.map { try validateComponent($0) }
        if validatedParts.isEmpty {
            return physicalRoot
        }
        let base = physicalRoot == "/" ? "" : (physicalRoot.hasSuffix("/") ? String(physicalRoot.dropLast()) : physicalRoot)
        return base + "/" + validatedParts.joined(separator: "/")
    }

    /// Builds UTF-8 bytes for Sync protocol requests and enforces the `<= 1024` byte limit.
    public static func buildSyncPathBytes(physicalRoot: String, components: [Data]) throws -> Data {
        let path = try buildRemotePath(physicalRoot: physicalRoot, components: components)
        let bytes = Data(path.utf8)
        guard bytes.count <= syncMaxPathBytes else {
            throw ADBFileError.pathTooLong(bytes.count)
        }
        return bytes
    }

    /// Escapes a parameter using POSIX single quotes, preserving non-NUL UTF-8 bytes (including `\n`)
    /// so existing files on the device can be inspected and deleted safely.
    public static func escapeShellSingleQuoted(_ value: String) throws -> String {
        guard !value.utf8.contains(0x00) else {
            throw ADBFileError.invalidFileName("Shell 参数包含非法 NUL 字节")
        }
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    private static func asciiLowercased(_ data: Data) -> String? {
        var bytes = [UInt8]()
        bytes.reserveCapacity(data.count)
        for b in data {
            if b >= 0x41 && b <= 0x5A {
                bytes.append(b + 32)
            } else {
                bytes.append(b)
            }
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}
