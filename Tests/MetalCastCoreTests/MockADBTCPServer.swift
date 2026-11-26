import Foundation
import Network

/// Lightweight local TCP mock server for deterministic ADB Host protocol testing.
final class MockADBTCPServer: @unchecked Sendable {
    typealias ConnectionHandler = @Sendable (MockConnection) -> Void

    final class MockConnection: @unchecked Sendable {
        private let conn: NWConnection
        private let queue: DispatchQueue
        private var buffer = Data()

        init(conn: NWConnection, queue: DispatchQueue) {
            self.conn = conn
            self.queue = queue
        }

        func start() {
            conn.start(queue: queue)
        }

        func close() {
            conn.cancel()
        }

        func readHostRequest() async throws -> String {
            let lenBytes = try await readExact(4)
            guard let hex = String(data: lenBytes, encoding: .ascii),
                  let len = Int(hex, radix: 16) else {
                throw NSError(domain: "MockADB", code: 1)
            }
            let payload = try await readExact(len)
            return String(data: payload, encoding: .utf8) ?? ""
        }

        func readExact(_ count: Int) async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.readExactLocked(count, continuation: continuation)
                }
            }
        }

        private func readExactLocked(_ count: Int, continuation: CheckedContinuation<Data, Error>) {
            if buffer.count >= count {
                let out = Data(buffer.prefix(count))
                buffer.removeFirst(count)
                continuation.resume(returning: out)
                return
            }
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { content, _, isComplete, error in
                if let content, !content.isEmpty {
                    self.buffer.append(content)
                }
                if self.buffer.count >= count {
                    let out = Data(self.buffer.prefix(count))
                    self.buffer.removeFirst(count)
                    continuation.resume(returning: out)
                } else if let error {
                    continuation.resume(throwing: error)
                } else if isComplete {
                    continuation.resume(throwing: NSError(domain: "MockADB", code: 2))
                } else {
                    self.readExactLocked(count, continuation: continuation)
                }
            }
        }

        func send(_ data: Data) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                conn.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                })
            }
        }

        func sendFragmentedOneByte(_ data: Data, delayNanoseconds: UInt64 = 1_000_000) async throws {
            for byte in data {
                try await send(Data([byte]))
                if delayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                }
            }
        }

        static func hostFrame(_ payload: String) -> Data {
            let utf8 = Data(payload.utf8)
            let header = Data(String(format: "%04x", utf8.count).utf8)
            return header + utf8
        }

        static func hostFail(_ message: String) -> Data {
            Data("FAIL".utf8) + hostFrame(message)
        }
    }

    private let listener: NWListener
    private let queue: DispatchQueue
    public let port: UInt16

    init(port: UInt16 = 0, handler: @escaping ConnectionHandler) async throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let nwPort: NWEndpoint.Port = port == 0 ? .any : NWEndpoint.Port(rawValue: port)!
        let listener = try NWListener(using: params, on: nwPort)
        let listenerQueue = DispatchQueue(label: "com.metalcast.mock.adb.server")
        self.listener = listener
        self.queue = listenerQueue

        let boundPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            final class Box: @unchecked Sendable {
                var resumed = false
                let lock = NSLock()
            }
            let box = Box()

            listener.newConnectionHandler = { nwConn in
                let mockConn = MockConnection(conn: nwConn, queue: DispatchQueue(label: "com.metalcast.mock.adb.conn.\(UUID().uuidString)"))
                mockConn.start()
                handler(mockConn)
            }

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.lock.lock()
                    defer { box.lock.unlock() }
                    if !box.resumed, let p = listener.port?.rawValue {
                        box.resumed = true
                        continuation.resume(returning: p)
                    }
                case .failed(let error):
                    box.lock.lock()
                    defer { box.lock.unlock() }
                    if !box.resumed {
                        box.resumed = true
                        continuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }

            listener.start(queue: listenerQueue)
        }

        self.port = boundPort
    }

    func stop() {
        listener.cancel()
    }
}
