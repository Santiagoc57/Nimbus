import Foundation

struct ActivityEvent: Codable, Equatable, Identifiable {
    let id: UUID
    let date: Date
    let operation: String
    let detail: String
    let success: Bool
}

/// A bounded, private journal shared by sync workers and the activity window.
final class ActivityLog: @unchecked Sendable {
    private let file: URL
    private let lock = NSLock()
    private let limit = 500
    init(file: URL) { self.file = file }
    func append(operation: String, detail: String, success: Bool) {
        lock.lock(); defer { lock.unlock() }
        do {
            let parent = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var events = (try? NimboSecureFile.load([ActivityEvent].self, from: file, account: "activity")) ?? []
            events.append(ActivityEvent(id: UUID(), date: Date(), operation: String(operation.prefix(120)), detail: String(detail.prefix(2000)), success: success))
            if events.count > limit { events = Array(events.suffix(limit)) }
            try NimboSecureFile.save(events, to: file, account: "activity")
        } catch { /* Activity must never interrupt a cloud operation. */ }
    }
    func events() -> [ActivityEvent] {
        lock.lock(); defer { lock.unlock() }
        guard let value = try? NimboSecureFile.load([ActivityEvent].self, from: file, account: "activity") else { return [] }
        return value.sorted { $0.date > $1.date }
    }
    func clear() {
        lock.lock(); defer { lock.unlock() }
        try? NimboSecureFile.save([ActivityEvent](), to: file, account: "activity")
    }
}
