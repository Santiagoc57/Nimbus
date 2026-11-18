import Foundation
import Darwin
import CryptoKit

protocol NimboSpotlightSink {
    func publish(_ entries: [RemoteEntry], aliases: [String: String]) async throws
    func remove(_ identifiers: [String]) async throws
    func removeLegacyIndex() async throws
}

struct NimboSpotlightReport {
    let indexed: Int
    let removed: Int
    let skipped: Int
    let preservedAccounts: Int
}

enum NimboSpotlightFailure: Error, LocalizedError {
    case busy, tooLarge, invalidSnapshot, invalidState, timedOut
    var errorDescription: String? {
        switch self {
        case .busy: return "Otra instancia está actualizando Spotlight. Volvé a intentarlo al terminar."
        case .tooLarge: return "El catálogo supera el límite de Spotlight de Nimbo; se conserva el índice anterior."
        case .invalidSnapshot: return "No se pudo validar la cuenta de las entradas de Spotlight."
        case .invalidState: return "No se pudo leer el estado de Spotlight; se conserva el índice existente."
        case .timedOut: return "Spotlight no confirmó la actualización a tiempo; no se puede dar por completada."
        }
    }
}

/// Reconciles an account-scoped metadata snapshot. Journal before publishing,
/// then delete stale IDs only after all upserts have succeeded. A failed or
/// interrupted operation keeps enough IDs to clean up on a subsequent refresh.
final class SpotlightReconciler {
    struct State: Codable {
        var schema = 1
        var known: [String: String] = [:] // Index identifier -> remote account
        var legacyRemoved = false
        var fingerprints: [String: String]?
    }

    let support: URL
    private let sink: NimboSpotlightSink
    private let batchSize: Int
    private let maximumEntries: Int
    var stateURL: URL { support.appendingPathComponent("SpotlightCatalog.json.enc") }
    var keyAccount: String { "spotlight-catalog:" + support.standardizedFileURL.path }

    init(support: URL, sink: NimboSpotlightSink, batchSize: Int = 500, maximumEntries: Int = 200_000) {
        self.support = support; self.sink = sink
        self.batchSize = max(1, batchSize); self.maximumEntries = max(1, maximumEntries)
    }

    static func identifier(_ entry: RemoteEntry) -> String? {
        guard (try? CloudBackend.validateRemote(entry.remote)) != nil,
              let id = entry.item.ID, !id.isEmpty,
              id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        return "nimbo-v2:\(entry.remote):\(id)"
    }

    static func route(_ identifier: String) -> (remote: String, id: String)? {
        let prefix: String
        if identifier.hasPrefix("nimbo-v2:") { prefix = "nimbo-v2:" }
        else if identifier.hasPrefix("nimbo:") { prefix = "nimbo:" }
        else { return nil }
        let payload = identifier.dropFirst(prefix.count)
        guard let split = payload.lastIndex(of: ":") else { return nil }
        let remote = String(payload[..<split]), id = String(payload[payload.index(after: split)...])
        guard (try? CloudBackend.validateRemote(remote)) != nil,
              id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        return (remote, id)
    }

    private static func fingerprint(_ entry: RemoteEntry, alias: String) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(entry); data.append(Data(alias.utf8))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// An asynchronously fetched preview may finish after a rename, refresh or
    /// account removal. Only enrich the exact metadata snapshot still indexed.
    func enrich(_ entry: RemoteEntry, alias: String) async throws -> Bool {
        guard let id = Self.identifier(entry), FileManager.default.fileExists(atPath: stateURL.path) else { return false }
        let descriptor = open(support.appendingPathComponent("SpotlightCatalog.lock").path, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else { throw NimboSpotlightFailure.invalidState }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw NimboSpotlightFailure.busy }
        defer { flock(descriptor, LOCK_UN) }
        let state = try loadState()
        guard state.known[id] == entry.remote, state.fingerprints?[id] == (try Self.fingerprint(entry, alias: alias)) else { return false }
        try await sink.publish([entry], aliases: [entry.remote: alias])
        return true
    }

    func reconcile(_ entries: [RemoteEntry], aliases: [String: String], preservingRemotes: Set<String> = []) async throws -> NimboSpotlightReport {
        guard entries.count <= maximumEntries else { throw NimboSpotlightFailure.tooLarge }
        guard entries.allSatisfy({ aliases[$0.remote] != nil }) else { throw NimboSpotlightFailure.invalidSnapshot }
        let preserved = preservingRemotes.intersection(Set(aliases.keys))
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(support.appendingPathComponent("SpotlightCatalog.lock").path, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else { throw NimboSpotlightFailure.invalidState }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw NimboSpotlightFailure.busy }
        defer { flock(descriptor, LOCK_UN) }

        var old = try loadState()
        var unique: [String: RemoteEntry] = [:]
        var skipped = 0
        for entry in entries {
            guard let id = Self.identifier(entry) else { skipped += 1; continue }
            if let existing = unique[id], existing.item.Path <= entry.item.Path { continue }
            unique[id] = entry
        }
        let identifiers = unique.keys.sorted()
        var desired = old.known.filter { preserved.contains($0.value) }
        for id in identifiers { desired[id] = unique[id]!.remote }
        var fingerprints = (old.fingerprints ?? [:]).filter { desired[$0.key] != nil }
        for id in identifiers { fingerprints[id] = try Self.fingerprint(unique[id]!, alias: aliases[unique[id]!.remote]!) }
        let stale = old.known.keys.filter { desired[$0] == nil }.sorted()
        // Preserve the union before any framework mutation. If publication
        // partially succeeds, the next pass still knows those orphan IDs.
        for (id, remote) in desired { old.known[id] = remote }
        old.fingerprints = fingerprints
        try saveState(old)
        for start in stride(from: 0, to: identifiers.count, by: batchSize) {
            try Task.checkCancellation()
            let batch = identifiers[start..<min(start + batchSize, identifiers.count)].compactMap { unique[$0] }
            try await sink.publish(batch, aliases: aliases)
        }
        for start in stride(from: 0, to: stale.count, by: batchSize) {
            try Task.checkCancellation()
            try await sink.remove(Array(stale[start..<min(start + batchSize, stale.count)]))
        }
        // The legacy default index had no manifest. Migrate to a separately
        // named index and clear only Nimbo's old domain once all accounts are
        // authoritative. A failed/missing cache keeps its old results meanwhile.
        if !old.legacyRemoved && preserved.isEmpty {
            try await sink.removeLegacyIndex()
            old.legacyRemoved = true
        }
        old.known = desired
        try saveState(old)
        return NimboSpotlightReport(indexed: unique.count, removed: stale.count, skipped: skipped, preservedAccounts: preserved.count)
    }

    private func loadState() throws -> State {
        guard let data = try NimboSecureFile.loadData(from: stateURL, account: keyAccount, keychain: false) else { return State() }
        guard let state = try? JSONDecoder().decode(State.self, from: data), state.schema == 1 else { throw NimboSpotlightFailure.invalidState }
        return state
    }

    private func saveState(_ state: State) throws {
        try NimboSecureFile.saveData(JSONEncoder().encode(state), to: stateURL, account: keyAccount, keychain: false)
    }
}
