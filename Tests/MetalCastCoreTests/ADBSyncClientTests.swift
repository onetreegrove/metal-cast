import Foundation
import Testing
@testable import MetalCastCore

@Suite("ADBSyncClient")
struct ADBSyncClientTests {
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

    private static func makeDentV2Frame(
        tag: String = "DNT2",
        errno: UInt32 = 0,
        dev: UInt64 = 2049,
        ino: UInt64 = 1001,
        mode: UInt32 = 0o100644,
        size: UInt64 = 1234,
        mtime: Int64 = 1764123600,
        nameBytes: Data = Data()
    ) -> Data {
        var d = Data(tag.utf8)
        appendLE32(&d, errno)
        appendLE64(&d, dev)
        appendLE64(&d, ino)
        appendLE32(&d, mode)
        appendLE32(&d, 1) // nlink
        appendLE32(&d, 1000) // uid
        appendLE32(&d, 1000) // gid
        appendLE64(&d, size)
        appendLE64(&d, UInt64(bitPattern: mtime)) // atime
        appendLE64(&d, UInt64(bitPattern: mtime)) // mtime
        appendLE64(&d, UInt64(bitPattern: mtime)) // ctime
        appendLE32(&d, UInt32(nameBytes.count))
        d.append(nameBytes)
        return d
    }

    private static func makeStatV2Response(
        tag: String = "LST2",
        errno: UInt32 = 0,
        dev: UInt64 = 77,
        ino: UInt64 = 8899,
        mode: UInt32 = 0o100644,
        size: UInt64 = 5_000_000_000,
        mtime: Int64 = 1764123600
    ) -> Data {
        var d = Data(tag.utf8)
        appendLE32(&d, errno)
        appendLE64(&d, dev)
        appendLE64(&d, ino)
        appendLE32(&d, mode)
        appendLE32(&d, 1)
        appendLE32(&d, 1000)
        appendLE32(&d, 1000)
        appendLE64(&d, size)
        appendLE64(&d, UInt64(bitPattern: mtime))
        appendLE64(&d, UInt64(bitPattern: mtime))
        appendLE64(&d, UInt64(bitPattern: mtime))
        return d
    }

    private static func makeStatV1Response(mode: UInt32, size: UInt32, mtime: UInt32) -> Data {
        var d = Data("STAT".utf8)
        appendLE32(&d, mode)
        appendLE32(&d, size)
        appendLE32(&d, mtime)
        return d
    }

    private static func makeDentV1Frame(tag: String = "DENT", mode: UInt32, size: UInt32, mtime: UInt32, nameBytes: Data) -> Data {
        var d = Data(tag.utf8)
        appendLE32(&d, mode)
        appendLE32(&d, size)
        appendLE32(&d, mtime)
        appendLE32(&d, UInt32(nameBytes.count))
        d.append(nameBytes)
        return d
    }

    private static func readSyncRequest(from conn: MockADBTCPServer.MockConnection) async throws -> (String, Data) {
        let tagData = try await conn.readExact(4)
        let lenData = try await conn.readExact(4)
        let len = Int(lenData.readUInt32LE(at: 0))
        let pathData = len > 0 ? try await conn.readExact(len) : Data()
        return (String(decoding: tagData, as: UTF8.self), pathData)
    }

    private final class Collector<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T] = []
        func append(contentsOf newItems: [T]) {
            lock.lock()
            items.append(contentsOf: newItems)
            lock.unlock()
        }
        func snapshot() -> [T] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    @Test("LIS2 consumes exact 76B DNT2/DONE, keeps entry errno, and sends QUIT")
    func lis2ExactConsumptionAndEntryErrno() async throws {
        final class ContBox: @unchecked Sendable {
            var cont: AsyncStream<Bool>.Continuation?
        }
        let quitBox = ContBox()
        let quitStream = AsyncStream<Bool> { quitBox.cont = $0 }
        let quitContinuation = quitBox.cont!

        let server = try await MockADBTCPServer { conn in
            Task {
                defer { conn.close() }
                guard try await conn.readHostRequest() == "host:transport-id:3" else { return }
                try await conn.send(Data("OKAY".utf8))
                guard try await conn.readHostRequest() == "sync:" else { return }
                try await conn.send(Data("OKAY".utf8))

                let (tag, _) = try await Self.readSyncRequest(from: conn)
                #expect(tag == "LIS2")

                var payload = Data()
                payload.append(Self.makeDentV2Frame(mode: 0o040755, size: 0, nameBytes: Data(".".utf8)))
                payload.append(Self.makeDentV2Frame(mode: 0o040755, size: 0, nameBytes: Data("..".utf8)))
                payload.append(Self.makeDentV2Frame(dev: 11, ino: 22, mode: 0o100644, size: 4_800_000_000, nameBytes: Data("4k.mp4".utf8)))
                payload.append(Self.makeDentV2Frame(errno: 13, nameBytes: Data("locked.bin".utf8)))
                payload.append(Self.makeDentV2Frame(mode: 0o100644, size: 12, nameBytes: Data([0xFF, 0xFE])))
                payload.append(Self.makeDentV2Frame(tag: "DONE", errno: 0, dev: 0, ino: 0, mode: 0, size: 0, mtime: 0, nameBytes: Data()))

                // Send first 9 bytes fragmented 1 byte at a time, then rest coalesced
                try await conn.sendFragmentedOneByte(Data(payload.prefix(9)), delayNanoseconds: 200_000)
                try await conn.send(Data(payload.dropFirst(9)))

                let (quitTag, quitBody) = try await Self.readSyncRequest(from: conn)
                quitContinuation.yield(quitTag == "QUIT" && quitBody.isEmpty)
                quitContinuation.finish()
            }
        }
        defer { server.stop() }

        let endpoint = try ADBServerEndpoint(host: "127.0.0.1", port: server.port)
        let conn = ADBSocketConnection(endpoint: endpoint)
        defer { conn.close() }
        try await conn.connect()
        try await conn.openDeviceService(transportId: "3", service: "sync:")

        let sync = ADBSyncClient()
        let collected = Collector<ADBRemoteEntry>()
        try await sync.listDirectory(
            connection: conn,
            pathBytes: Data("/storage/emulated/0/Download".utf8),
            directoryComponents: [Data("Download".utf8)],
            useV2: true
        ) { batch in
            collected.append(contentsOf: batch)
        }
        try await sync.sendQuit(connection: conn)

        var receivedQuit = false
        for await ok in quitStream {
            receivedQuit = ok
        }
        #expect(receivedQuit)

        let entries = collected.snapshot()
        #expect(entries.count == 3)

        #expect(entries[0].displayName == "4k.mp4")
        #expect(entries[0].isSizeReliable == true)
        #expect(entries[0].size == 4_800_000_000)
        #expect(entries[0].dev == 11)
        #expect(entries[0].ino == 22)
        #expect(entries[0].entryErrno == nil)

        #expect(entries[1].displayName == "locked.bin")
        #expect(entries[1].entryErrno == 13)
        #expect(entries[1].isSizeReliable == false)

        #expect(entries[2].isLosslessUTF8 == false)
        #expect(entries[2].rawNameBytes == Data([0xFF, 0xFE]))
    }

    @Test("STAT 16B zero-metadata fallback and LST2 72B 64-bit stat")
    func statV1AndV2() async throws {
        let server = try await MockADBTCPServer { conn in
            Task {
                defer { conn.close() }
                guard try await conn.readHostRequest() == "host:transport-id:3" else { return }
                try await conn.send(Data("OKAY".utf8))
                guard try await conn.readHostRequest() == "sync:" else { return }
                try await conn.send(Data("OKAY".utf8))

                let (tag1, _) = try await Self.readSyncRequest(from: conn)
                #expect(tag1 == "STAT")
                try await conn.send(Self.makeStatV1Response(mode: 0, size: 0, mtime: 0))

                let (tag2, _) = try await Self.readSyncRequest(from: conn)
                #expect(tag2 == "LST2")
                try await conn.send(Self.makeStatV2Response(dev: 99, ino: 1002, mode: 0o100644, size: 5_368_709_120))

                _ = try? await Self.readSyncRequest(from: conn)
            }
        }
        defer { server.stop() }

        let endpoint = try ADBServerEndpoint(host: "127.0.0.1", port: server.port)
        let conn = ADBSocketConnection(endpoint: endpoint)
        defer { conn.close() }
        try await conn.connect()
        try await conn.openDeviceService(transportId: "3", service: "sync:")

        let sync = ADBSyncClient()
        let v1 = try await sync.stat(connection: conn, pathBytes: Data("/storage/emulated/0/x".utf8), useV2: false)
        #expect(v1.isAllZeroV1 == true)
        #expect(v1.isSizeReliable == false)
        #expect(v1.size == nil)

        let v2 = try await sync.stat(connection: conn, pathBytes: Data("/storage/emulated/0/big.mp4".utf8), useV2: true)
        #expect(v2.isAllZeroV1 == false)
        #expect(v2.isSizeReliable == true)
        #expect(v2.size == 5_368_709_120)
        #expect(v2.dev == 99)
        #expect(v2.ino == 1002)
    }

    @Test("LIST v1 drops unreliable 32-bit size and rejects Sync paths > 1024 bytes")
    func listV1AndPathLengthGuard() async throws {
        let server = try await MockADBTCPServer { conn in
            Task {
                defer { conn.close() }
                guard try await conn.readHostRequest() == "host:transport-id:3" else { return }
                try await conn.send(Data("OKAY".utf8))
                guard try await conn.readHostRequest() == "sync:" else { return }
                try await conn.send(Data("OKAY".utf8))

                let (tag, _) = try await Self.readSyncRequest(from: conn)
                #expect(tag == "LIST")
                var resp = Self.makeDentV1Frame(mode: 0o100644, size: 123456, mtime: 1764100000, nameBytes: Data("dump.zip".utf8))
                resp.append(Self.makeDentV1Frame(tag: "DONE", mode: 0, size: 0, mtime: 0, nameBytes: Data()))
                try await conn.send(resp)
            }
        }
        defer { server.stop() }

        let endpoint = try ADBServerEndpoint(host: "127.0.0.1", port: server.port)
        let conn = ADBSocketConnection(endpoint: endpoint)
        defer { conn.close() }
        try await conn.connect()
        try await conn.openDeviceService(transportId: "3", service: "sync:")

        let sync = ADBSyncClient()
        let overlong = Data(repeating: 0x61, count: 1025)
        await #expect(throws: ADBFileError.pathTooLong(1025)) {
            _ = try await sync.stat(connection: conn, pathBytes: overlong, useV2: true)
        }

        let collected = Collector<ADBRemoteEntry>()
        try await sync.listDirectory(
            connection: conn,
            pathBytes: Data("/storage/emulated/0/Download".utf8),
            directoryComponents: [Data("Download".utf8)],
            useV2: false
        ) { batch in
            collected.append(contentsOf: batch)
        }
        let listed = collected.snapshot()
        #expect(listed.count == 1)
        #expect(listed[0].displayName == "dump.zip")
        #expect(listed[0].isSizeReliable == false)
        #expect(listed[0].size == nil)
    }

    @Test("sendFile tolerates immediate OKAY right after DONE begins and still rejects premature OKAY")
    func sendFileImmediateAndPrematureOkay() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metalcast-send-race-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let emptyFile = tempDir.appendingPathComponent("zero.bin")
        try Data().write(to: emptyFile)

        // 1. Immediate OKAY after DONE across repeated 0-byte uploads must succeed
        let okServer = try await MockADBTCPServer { conn in
            Task {
                defer { conn.close() }
                guard try await conn.readHostRequest() == "host:transport-id:3" else { return }
                try await conn.send(Data("OKAY".utf8))
                guard try await conn.readHostRequest() == "sync:" else { return }
                try await conn.send(Data("OKAY".utf8))

                let (tag, _) = try await Self.readSyncRequest(from: conn)
                guard tag == "SEND" else { return }
                let doneTag = String(decoding: try await conn.readExact(4), as: UTF8.self)
                _ = try await conn.readExact(4)
                if doneTag == "DONE" {
                    var okay = Data("OKAY".utf8)
                    Self.appendLE32(&okay, 0)
                    try await conn.send(okay)
                }
                _ = try? await Self.readSyncRequest(from: conn) // QUIT
            }
        }
        defer { okServer.stop() }

        let okEndpoint = try ADBServerEndpoint(host: "127.0.0.1", port: okServer.port)
        let sync = ADBSyncClient()
        for _ in 0..<5 {
            let conn = ADBSocketConnection(endpoint: okEndpoint)
            defer { conn.close() }
            try await conn.connect()
            try await conn.openDeviceService(transportId: "3", service: "sync:")
            try await sync.sendFile(
                connection: conn,
                localFileURL: emptyFile,
                remoteTempPath: "/storage/emulated/0/Download/.tmp/payload",
                mtime: Date()
            ) { _ in }
            try await sync.sendQuit(connection: conn)
        }

        // 2. Genuine premature OKAY sent before any DONE while chunks are still streaming must throw
        let bigFile = tempDir.appendingPathComponent("multi.bin")
        try Data(repeating: 0x5A, count: 200_000).write(to: bigFile)

        let prematureServer = try await MockADBTCPServer { conn in
            Task {
                defer { conn.close() }
                guard try await conn.readHostRequest() == "host:transport-id:3" else { return }
                try await conn.send(Data("OKAY".utf8))
                guard try await conn.readHostRequest() == "sync:" else { return }
                try await conn.send(Data("OKAY".utf8))

                let _ = try await Self.readSyncRequest(from: conn)
                // Send OKAY immediately before client sends DONE
                var okay = Data("OKAY".utf8)
                Self.appendLE32(&okay, 0)
                try await conn.send(okay)
            }
        }
        defer { prematureServer.stop() }

        let badEndpoint = try ADBServerEndpoint(host: "127.0.0.1", port: prematureServer.port)
        let badConn = ADBSocketConnection(endpoint: badEndpoint)
        defer { badConn.close() }
        try await badConn.connect()
        try await badConn.openDeviceService(transportId: "3", service: "sync:")

        await #expect(throws: ADBFileError.self) {
            try await sync.sendFile(
                connection: badConn,
                localFileURL: bigFile,
                remoteTempPath: "/storage/emulated/0/Download/.tmp/payload",
                mtime: Date()
            ) { _ in }
        }
    }
}
