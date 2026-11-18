import Foundation

/// Durable, lightweight transfer ledger used by the dashboard and Activity.
/// It records progress without retaining file contents or OAuth material.
struct NimboTransfer: Codable, Equatable {
    enum State: String, Codable { case queued, running, completed, failed, cancelled }
    let id: UUID
    var remote: String
    var name: String
    var operation: String
    var completedBytes: Int64
    var totalBytes: Int64
    var state: State
    var verified: Bool
    var startedAt: Date
    var finishedAt: Date?
    var error: String?
    var bytesPerSecond: Double?
    var estimatedSeconds: Double?
    var cancellationRequested: Bool?

    var fraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }
}

final class TransferCenter {
    static let shared = TransferCenter()
    private let lock = NSLock()
    private var file: URL?
    private var values: [UUID: NimboTransfer] = [:]
    private var cancellable = Set<UUID>()

    func configure(support: URL) {
        lock.lock(); defer { lock.unlock() }
        file = support.appendingPathComponent("Transfers.json")
        values = [:]; cancellable = []
        guard let file, let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode([NimboTransfer].self, from: data) else { return }
        // A damaged or duplicated journal must not trap at startup.
        for var item in decoded.sorted(by: { $0.startedAt < $1.startedAt }) {
            if item.state == .running || item.state == .queued {
                item.state = .failed; item.verified = false; item.finishedAt = Date()
                item.error = "La transferencia se interrumpió al cerrar Nimbo."
                item.bytesPerSecond = nil; item.estimatedSeconds = nil
            }
            values[item.id] = item
        }
    }

    @discardableResult
    func begin(remote: String, name: String, operation: String, totalBytes: Int64, canCancel: Bool = false) -> UUID {
        let item = NimboTransfer(id: UUID(), remote: remote, name: name, operation: operation,
                                 completedBytes: 0, totalBytes: max(0, totalBytes), state: .running,
                                 verified: false, startedAt: Date(), finishedAt: nil, error: nil)
        lock.lock(); values[item.id] = item; if canCancel { cancellable.insert(item.id) }; persistLocked(); lock.unlock()
        notify()
        return item.id
    }

    func update(_ id: UUID, completedBytes: Int64, verified: Bool = false) {
        lock.lock()
        guard var item = values[id], item.state == .running || item.state == .queued else { lock.unlock(); return }
        item.completedBytes = max(0, completedBytes); item.verified = verified
        values[id] = item; persistLocked(); lock.unlock(); notify()
    }

    @discardableResult
    func finish(_ id: UUID, verified: Bool, error: String? = nil, cancelled: Bool = false, confirmedCommit: Bool = false) -> Bool {
        lock.lock()
        guard var item = values[id], item.state == .running || item.state == .queued else { lock.unlock(); return false }
        // Only a verified remote commit may override a late cancellation request.
        let committed = confirmedCommit && verified && error == nil
        let wasCancelled = !committed && (cancelled || item.cancellationRequested == true)
        item.state = wasCancelled ? .cancelled : (error == nil ? .completed : .failed)
        item.verified = !wasCancelled && error == nil && verified
        item.error = wasCancelled ? "Descarga cancelada." : error; item.finishedAt = Date()
        item.bytesPerSecond = nil; item.estimatedSeconds = nil; cancellable.remove(id)
        values[id] = item; persistLocked(); lock.unlock(); notify()
        return item.state == .completed
    }

    func progress(_ id: UUID, snapshot: RcloneProgress) {
        lock.lock()
        guard var item = values[id], item.state == .running, item.cancellationRequested != true else { lock.unlock(); return }
        if item.totalBytes == 0, let total = snapshot.totalBytes { item.totalBytes = max(0, total) }
        let measured = item.totalBytes > 0 ? min(item.totalBytes, snapshot.bytes) : snapshot.bytes
        item.completedBytes = max(item.completedBytes, measured)
        item.bytesPerSecond = snapshot.speed
        item.estimatedSeconds = snapshot.eta
        values[id] = item; persistLocked(); lock.unlock(); notify()
    }

    func canCancel(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancellable.contains(id) && values[id]?.state == .running && values[id]?.cancellationRequested != true
    }
    @discardableResult
    func requestCancellation(_ id: UUID) -> Bool {
        lock.lock()
        guard cancellable.contains(id), var item = values[id], item.state == .running else { lock.unlock(); return false }
        item.cancellationRequested = true; values[id] = item
        lock.unlock(); notify(); return true
    }
    func isCancellationRequested(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }; return values[id]?.cancellationRequested == true
    }

    func recent(limit: Int = 100) -> [NimboTransfer] {
        lock.lock(); defer { lock.unlock() }
        return values.values.sorted { $0.startedAt > $1.startedAt }.prefix(limit).map { $0 }
    }

    func active() -> [NimboTransfer] {
        lock.lock(); defer { lock.unlock() }
        return values.values.filter { $0.state == .queued || $0.state == .running }.sorted { $0.startedAt < $1.startedAt }
    }

    private func persistLocked() {
        guard let file else { return }
        let items = values.values.sorted { $0.startedAt > $1.startedAt }.prefix(200)
        guard let data = try? JSONEncoder().encode(Array(items)) else { return }
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: file.path)
    }

    private func notify() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .nimboTransfersChanged, object: nil) }
    }
}

/// Only the numeric stats field is consumed. Server messages and file names
/// never enter the transfer ledger through this parser.
struct RcloneProgress: Decodable {
    let bytes: Int64
    let totalBytes: Int64?
    let speed: Double?
    let eta: Double?
    static func decode(_ line: Data) -> RcloneProgress? {
        struct Envelope: Decodable { let stats: RcloneProgress? }
        guard let value = try? JSONDecoder().decode(Envelope.self, from: line).stats,
              value.bytes >= 0, value.totalBytes == nil || value.totalBytes! >= 0,
              value.speed == nil || (value.speed!.isFinite && value.speed! >= 0),
              value.eta == nil || (value.eta!.isFinite && value.eta! >= 0) else { return nil }
        return value
    }
}

final class RcloneProgressReader {
    private let input: FileHandle
    private var pending = Data()
    init(url: URL) throws { input = try FileHandle(forReadingFrom: url) }
    deinit { try? input.close() }
    func poll(_ receive: (RcloneProgress) -> Void) throws {
        if let data = try input.read(upToCount: 64 * 1024), !data.isEmpty { pending.append(data) }
        while let end = pending.firstIndex(of: 10) {
            let line = Data(pending[..<end]); pending.removeSubrange(...end)
            if line.count > 128 * 1024 { throw CocoaError(.fileReadTooLarge) }
            if let stats = RcloneProgress.decode(line) { receive(stats) }
        }
        if pending.count > 128 * 1024 { throw CocoaError(.fileReadTooLarge) }
    }
}

extension Notification.Name {
    static let nimboTransfersChanged = Notification.Name("NimboTransfersChanged")
}
