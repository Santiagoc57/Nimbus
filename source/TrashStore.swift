import Foundation

protocol TrashAccess: Sendable {
    func allTrash(limit: Int) async throws -> [DriveObject]
    func permitsWrites() async throws -> Bool
    func restoreFromTrash(_ id: String) async throws -> DriveObject
}
extension DriveAPI: TrashAccess {}

/// One owner for both reads and writes. Selection changes and reopening a
/// window cannot start another request while a restore is in flight.
@MainActor final class TrashStore {
    private let service: any TrashAccess
    private(set) var items: [DriveObject] = []
    private(set) var isBusy = false
    private(set) var permitsRestoration = false
    var onChange: (() -> Void)?
    init(service: any TrashAccess) { self.service = service }

    @discardableResult func load() async throws -> Bool {
        guard !isBusy else { return false }
        permitsRestoration = false
        isBusy = true; onChange?()
        defer { isBusy = false; onChange?() }
        let values = try await service.allTrash(limit: 2000)
        permitsRestoration = (try? await service.permitsWrites()) == true
        items = values.sorted { ($0.modifiedTime ?? "") > ($1.modifiedTime ?? "") }
        return true
    }

    @discardableResult func restore(id: String) async throws -> Bool {
        guard !isBusy, items.contains(where: { $0.id == id }) else { return false }
        isBusy = true; onChange?()
        defer { isBusy = false; onChange?() }
        permitsRestoration = try await service.permitsWrites()
        guard permitsRestoration else { throw DriveFailure.denied }
        let restored = try await service.restoreFromTrash(id)
        guard restored.id == id, restored.trashed == false else { throw DriveFailure.invalidResponse }
        items.removeAll { $0.id == id }
        return true
    }
}
