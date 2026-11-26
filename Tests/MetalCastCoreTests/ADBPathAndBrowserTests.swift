import Foundation
import Testing
@testable import MetalCastCore

@Suite("ADBPathAndBrowser")
struct ADBPathAndBrowserTests {
    private static func appendLE32(_ data: inout Data, _ v: UInt32) {
        data.append(UInt8(v & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8((v >> 16) & 0xFF))
        data.append(UInt8((v >> 24) & 0xFF))
    }

    private static func appendLE64(_ data: inout Data, _ v: UInt64) {
        appendLE32(&data, UInt32(v & 0xFFFFFFFF))
        appendLE32(&data, UInt32(v >> 32))
    }

    private static func makeDentV2Frame(tag: String = "DNT2", mode: UInt32 = 0o100644, name: String = "") -> Data {
        let nameBytes = Data(name.utf8)
        var d = Data(tag.utf8)
        appendLE32(&d, 0) // errno
        appendLE64(&d, 1) // dev
        appendLE64(&d, 2) // ino
        appendLE32(&d, mode)
        appendLE32(&d, 1)
        appendLE32(&d, 1000)
        appendLE32(&d, 1000)
        appendLE64(&d, 42)
        appendLE64(&d, 0)
        appendLE64(&d, 0)
        appendLE64(&d, 0)
        appendLE32(&d, UInt32(nameBytes.count))
        d.append(nameBytes)
        return d
    }

    @Test("Blocks Android/data and Android/obb including case variants")
    func blocksRestrictedPaths() throws {
        let blocked: [[String]] = [
            ["Android", "data"],
            ["Android", "obb"],
            ["ANDROID", "DATA"],
            ["android", "Obb", "com.demo"]
        ]
        for parts in blocked {
            let comps = parts.map { Data($0.utf8) }
            #expect(ADBPathUtils.isRestrictedComponents(comps))
            #expect(throws: ADBFileError.self) {
                _ = try ADBPathUtils.buildRemotePath(physicalRoot: "/storage/emulated/0", components: comps)
            }
        }

        let allowed = ["Android", "media"].map { Data($0.utf8) }
        #expect(!ADBPathUtils.isRestrictedComponents(allowed))
        let path = try ADBPathUtils.buildRemotePath(physicalRoot: "/storage/emulated/0", components: allowed)
        #expect(path == "/storage/emulated/0/Android/media")

        #expect(ADBPathUtils.isRestrictedEntry(in: [Data("Android".utf8)], entryBytes: Data("DATA".utf8)))
        #expect(!ADBPathUtils.isRestrictedEntry(in: [Data("Android".utf8)], entryBytes: Data("media".utf8)))
    }

    @Test("Rejects ., .., /, NUL, invalid UTF-8, upload forbidden chars, and escapes control chars")
    func componentAndFilenameRules() throws {
        let badComponents: [Data] = [
            Data(),
            Data(".".utf8),
            Data("..".utf8),
            Data("a/b".utf8),
            Data([0x61, 0x00, 0x62]),
            Data([0xFF, 0xFE])
        ]
        for comp in badComponents {
            #expect(throws: ADBFileError.self) {
                _ = try ADBPathUtils.validateComponent(comp)
            }
        }

        let (brokenText, isLossless) = ADBPathUtils.decodeEntryName(Data([0xFF, 0xFE]))
        #expect(!isLossless)
        #expect(!brokenText.isEmpty)

        let (escapedDisplay, hasCtrl) = ADBPathUtils.sanitizeControlCharactersForDisplay("report\n\u{07}x\u{7F}")
        #expect(hasCtrl)
        #expect(escapedDisplay == "report\\n^Gx^?")

        // Upload prohibits special chars & >255 bytes
        for badName in ["a?b", "a\"b", "a*b", "a:b", "a<b", "a>b", "a\\b", "a|b", "a\nb", String(repeating: "a", count: 256)] {
            #expect(throws: ADBFileError.self) {
                try ADBPathUtils.validateUploadFileName(badName)
            }
        }
        try ADBPathUtils.validateUploadFileName("合法文件名_v2 (1).apk")

        // Shell escaping preserves \n and single quotes, rejecting only \0
        #expect(try ADBPathUtils.escapeShellSingleQuoted("a'b\nc") == "'a'\\''b\nc'")
        #expect(throws: ADBFileError.self) {
            _ = try ADBPathUtils.escapeShellSingleQuoted("a\0b")
        }
    }

    @Test("Browser probes empty dirs and drops late batches on rapid directory switch")
    func emptyProbeAndRapidSwitch() async throws {
        let server = try await MockADBTCPServer { conn in
            Task {
                defer { conn.close() }
                guard try await conn.readHostRequest() == "host:transport-id:3" else { return }
                try await conn.send(Data("OKAY".utf8))
                let service = try await conn.readHostRequest()
                try await conn.send(Data("OKAY".utf8))

                if service == "sync:" {
                    let tagData = try await conn.readExact(4)
                    let lenData = try await conn.readExact(4)
                    let len = Int(lenData.readUInt32LE(at: 0))
                    let path = String(decoding: try await conn.readExact(len), as: UTF8.self)
                    #expect(String(decoding: tagData, as: UTF8.self) == "LIS2")

                    if path.hasSuffix("/SlowDir") {
                        // Delay first batch so rapid switch invalidates req1 before arrival
                        try await Task.sleep(nanoseconds: 250_000_000)
                        try? await conn.send(Self.makeDentV2Frame(name: "stale.txt"))
                        try? await conn.send(Self.makeDentV2Frame(tag: "DONE"))
                    } else if path.hasSuffix("/FastDir") {
                        var resp = Self.makeDentV2Frame(name: "fresh.txt")
                        resp.append(Self.makeDentV2Frame(tag: "DONE"))
                        try await conn.send(resp)
                    } else if path.hasSuffix("/RestrictedEmpty") {
                        try await conn.send(Self.makeDentV2Frame(tag: "DONE"))
                    }
                } else if service.hasPrefix("shell,v2,raw:") {
                    var exit = Data([3])
                    exit.appendUInt32LE(1)
                    exit.append(13) // EACCES probe result
                    try await conn.send(exit)
                }
            }
        }
        defer { server.stop() }

        let endpoint = try ADBServerEndpoint(host: "127.0.0.1", port: server.port)
        let session = ADBFileSessionID(endpoint: endpoint, serverGeneration: 1, transportId: "3", serial: "s1")
        let caps = ADBDeviceCapabilities(hasShellV2: true, hasStatV2: true, hasLsV2: true, commitMode: .mvNoClobberNoTarget)
        let browser = ADBDirectoryBrowser()

        // 1. Empty directory returning probe exit 13 -> permissionDenied
        let deniedStream = browser.listDirectory(
            sessionId: session,
            physicalRoot: "/storage/emulated/0",
            relativeComponents: [Data("RestrictedEmpty".utf8)],
            capabilities: caps
        )
        await #expect(throws: ADBFileError.permissionDenied("无权限访问此目录")) {
            for try await _ in deniedStream {}
        }

        // 2. Rapid directory switch: req1 invalidated by req2 immediately
        let req1 = UUID()
        let req2 = UUID()
        let slowStream = browser.listDirectory(
            sessionId: session,
            physicalRoot: "/storage/emulated/0",
            relativeComponents: [Data("SlowDir".utf8)],
            capabilities: caps,
            requestId: req1
        )
        let fastStream = browser.listDirectory(
            sessionId: session,
            physicalRoot: "/storage/emulated/0",
            relativeComponents: [Data("FastDir".utf8)],
            capabilities: caps,
            requestId: req2
        )

        var slowEntries: [ADBRemoteEntry] = []
        for try await batch in slowStream {
            slowEntries.append(contentsOf: batch.entries)
        }
        #expect(slowEntries.isEmpty)

        var fastEntries: [ADBRemoteEntry] = []
        for try await batch in fastStream {
            fastEntries.append(contentsOf: batch.entries)
        }
        #expect(fastEntries.map(\.displayName) == ["fresh.txt"])
    }
}
