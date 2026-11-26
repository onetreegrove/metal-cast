import Foundation

/// Atomically persists unfinished staging upload records (`~/Library/Application Support/MetalCast/file-transfer-ledger.json`).
public actor ADBLedgerStore {
    public let fileURL: URL
    private var ledger: ADBLedgerFile

    private static let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }()

    private static let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()

    public static func defaultLedgerURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("MetalCast", isDirectory: true)
            .appendingPathComponent("file-transfer-ledger.json", isDirectory: false)
    }

    public init(fileURL: URL = defaultLedgerURL()) {
        self.fileURL = fileURL
        self.ledger = Self.loadFromDisk(url: fileURL)
    }

    public func entries() -> [ADBLedgerEntry] {
        ledger.entries
    }

    public func entry(id: UUID) -> ADBLedgerEntry? {
        ledger.entries.first { $0.id == id }
    }

    public func upsert(_ entry: ADBLedgerEntry) throws {
        if let idx = ledger.entries.firstIndex(where: { $0.id == entry.id }) {
            ledger.entries[idx] = entry
        } else {
            ledger.entries.insert(entry, at: 0)
        }
        try persist()
    }

    public func updateState(id: UUID, state: ADBLedgerEntryState) throws {
        guard let idx = ledger.entries.firstIndex(where: { $0.id == id }) else { return }
        ledger.entries[idx].state = state
        ledger.entries[idx].updatedAt = Date()
        try persist()
    }

    public func updateFinalTargetName(id: UUID, finalTargetName: String) throws {
        guard let idx = ledger.entries.firstIndex(where: { $0.id == id }) else { return }
        ledger.entries[idx].finalTargetName = finalTargetName
        ledger.entries[idx].updatedAt = Date()
        try persist()
    }

    public func remove(id: UUID) throws {
        let before = ledger.entries.count
        ledger.entries.removeAll { $0.id == id }
        if ledger.entries.count != before {
            try persist()
        }
    }

    public func markUnfinishedForTermination() throws {
        var changed = false
        let now = Date()
        for idx in ledger.entries.indices {
            switch ledger.entries[idx].state {
            case .committing:
                ledger.entries[idx].state = .pendingConfirmation
                ledger.entries[idx].updatedAt = now
                changed = true
            case .planned, .created:
                ledger.entries[idx].state = .cleanupPending
                ledger.entries[idx].updatedAt = now
                changed = true
            case .pendingConfirmation, .cleanupPending:
                break
            }
        }
        if changed {
            try persist()
        }
    }

    public func persist() throws {
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(ledger)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func loadFromDisk(url: URL) -> ADBLedgerFile {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? decoder.decode(ADBLedgerFile.self, from: data) else {
            return ADBLedgerFile(schemaVersion: 1, entries: [])
        }
        return decoded
    }
}
