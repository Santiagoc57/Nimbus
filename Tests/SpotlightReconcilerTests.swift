#if SPOTLIGHT_TESTS
import Foundation

actor SpotlightFixture: NimboSpotlightSink {
    var records: [String: RemoteEntry] = [:]
    var calls: [String] = []
    var batchCounts: [Int] = []
    var failPublish = false
    var failRemove = false
    var failLegacy = false
    var holdPublish = false
    var gate: CheckedContinuation<Void, Never>?
    var waiting: [CheckedContinuation<Void, Never>] = []

    func fail(_ stage: String) { failPublish = stage == "publish"; failRemove = stage == "remove"; failLegacy = stage == "legacy" }
    func hold() { holdPublish = true }
    func waitUntilHeld() async {
        if gate != nil { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() { gate?.resume(); gate = nil }
    func snapshot() -> ([String: RemoteEntry], [String], [Int]) { (records, calls, batchCounts) }

    func publish(_ entries: [RemoteEntry], aliases: [String: String]) async throws {
        calls.append("publish"); batchCounts.append(entries.count)
        for entry in entries { records[SpotlightReconciler.identifier(entry)!] = entry }
        if holdPublish {
            holdPublish = false
            await withCheckedContinuation { continuation in
                gate = continuation
                waiting.forEach { $0.resume() }; waiting.removeAll()
            }
        }
        if failPublish { throw NSError(domain: "SpotlightFixture", code: 1) }
    }
    func remove(_ identifiers: [String]) async throws {
        calls.append("remove")
        if failRemove { throw NSError(domain: "SpotlightFixture", code: 2) }
        identifiers.forEach { records.removeValue(forKey: $0) }
    }
    func removeLegacyIndex() async throws {
        calls.append("legacy")
        if failLegacy { throw NSError(domain: "SpotlightFixture", code: 3) }
    }
}

@main
struct SpotlightReconcilerTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else { throw NSError(domain: "SpotlightTests", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
        checks += 1
    }
    static func expectFailure(_ operation: () async throws -> Void) async throws {
        var failed = false
        do { try await operation() } catch { failed = true }
        try check(failed, "Expected index operation to report failure")
    }
    static func entry(_ remote: String, _ id: String?, _ name: String) -> RemoteEntry {
        RemoteEntry(remote: remote, item: CloudItem(Path: name, Name: name, Size: 12, IsDir: false, ID: id))
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NimboSpotlightTests-" + UUID().uuidString)
        var reconcilers: [SpotlightReconciler] = []
        defer {
            reconcilers.forEach { NimboSecureFile.removeFallbackKey(account: $0.keyAccount) }
            try? FileManager.default.removeItem(at: root)
        }
        func make(_ name: String, _ sink: SpotlightFixture, maximum: Int = 200_000) -> SpotlightReconciler {
            let r = SpotlightReconciler(support: root.appendingPathComponent(name), sink: sink, batchSize: 2, maximumEntries: maximum)
            reconcilers.append(r); return r
        }
        let a = entry("A", "same-id", "a.txt"), b = entry("B", "same-id", "b.txt")
        let route = SpotlightReconciler.route(SpotlightReconciler.identifier(a)!)
        try check(route?.remote == "A" && route?.id == "same-id", "Indexed identity restores the correct account and Drive ID")
        try check(SpotlightReconciler.route("nimbo:Cuenta 2:file_123")?.remote == "Cuenta 2", "Legacy results remain routable during migration")
        try check(SpotlightReconciler.route("nimbo-v2:Personal:file_123")?.id == "file_123", "Current result routes preserve stable IDs")
        for bad in ["other:A:file", "nimbo-v2::file", "nimbo-v2:A:", "nimbo-v2:A:../../file", "nimbo-v2:A&other=B:file", "nimbo-v2:A:file:other"] {
            try check(SpotlightReconciler.route(bad) == nil, "Malformed or foreign result is rejected")
        }
        let old = entry("A", "old", "old.txt"), added = entry("A", "new", "new.txt")
        let sink = SpotlightFixture(), reconciler = make("basic", sink)
        let first = try await reconciler.reconcile([a, b, old, a, entry("A", nil, "unknown"), entry("A", "bad/id", "invalid")], aliases: ["A": "Personal", "B": "Trabajo"])
        var state = await sink.snapshot()
        try check(first.indexed == 3 && first.skipped == 2, "Unique valid IDs and truthful skipped count")
        try check(state.0.count == 3, "Same Drive ID in different accounts stays separate")
        try check(state.2 == [2, 1], "Publication uses bounded batches")
        try check(state.1.last == "legacy", "Legacy cleanup follows successful publication")
        let enriched = try await reconciler.enrich(a, alias: "Personal")
        try check(enriched, "A preview can enrich the exact indexed metadata")
        let wrongAlias = try await reconciler.enrich(a, alias: "Another alias")
        try check(!wrongAlias, "Late preview cannot restore an old account alias")
        let stalePreview = try await reconciler.enrich(entry("A", "same-id", "stale.txt"), alias: "Personal")
        try check(!stalePreview, "Late preview cannot overwrite a newer name or path")
        let disk = try Data(contentsOf: reconciler.stateURL)
        try check(disk.starts(with: Data("NIMBO-ENC-1\n".utf8)), "Index manifest is encrypted")
        let attrs = try FileManager.default.attributesOfItem(atPath: reconciler.stateURL.path)
        try check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Index manifest is private")
        let renamed = entry("A", "same-id", "renamed.txt")
        let partial = try await reconciler.reconcile([renamed], aliases: ["A": "Personal", "B": "Trabajo"], preservingRemotes: ["B"])
        state = await sink.snapshot()
        try check(partial.removed == 1 && partial.preservedAccounts == 1, "Partial refresh removes only authoritative stale entries")
        try check(state.0[SpotlightReconciler.identifier(b)!] == b, "Unavailable account retains previous results")
        try check(state.0[SpotlightReconciler.identifier(a)!]?.item.Name == "renamed.txt", "Stable ID updates renamed files")
        _ = try await reconciler.reconcile([], aliases: ["A": "Personal", "B": "Trabajo"], preservingRemotes: ["B"])
        state = await sink.snapshot()
        try check(state.0.count == 1, "Authoritative empty account removes previous entries")
        _ = try await reconciler.reconcile([], aliases: [:], preservingRemotes: ["B"])
        state = await sink.snapshot()
        try check(state.0.isEmpty, "Disconnected accounts are removed even if marked unavailable")
        let disconnectedPreview = try await reconciler.enrich(a, alias: "Personal")
        try check(!disconnectedPreview, "Late preview cannot resurrect a removed account")
        try check(state.1.filter { $0 == "legacy" }.count == 1, "Legacy index migration is durable and not repeated")

        let incompleteSink = SpotlightFixture(), incomplete = make("incomplete", incompleteSink)
        _ = try await incomplete.reconcile([a], aliases: ["A": "A", "B": "B"], preservingRemotes: ["B"])
        var incompleteState = await incompleteSink.snapshot()
        try check(!incompleteState.1.contains("legacy"), "Missing cache cannot clear the legacy index")
        _ = try await incomplete.reconcile([a, b], aliases: ["A": "A", "B": "B"])
        incompleteState = await incompleteSink.snapshot()
        try check(incompleteState.1.last == "legacy", "Migration finishes after every account is authoritative")

        let failureSink = SpotlightFixture(), failure = make("failure", failureSink)
        _ = try await failure.reconcile([old], aliases: ["A": "A"])
        await failureSink.fail("publish")
        try await expectFailure { _ = try await failure.reconcile([added], aliases: ["A": "A"]) }
        var failureState = await failureSink.snapshot()
        try check(failureState.0[SpotlightReconciler.identifier(old)!] != nil && !failureState.1.contains("remove"), "Partial publication failure preserves previous results")
        await failureSink.fail("")
        let recovered = try await failure.reconcile([old], aliases: ["A": "A"])
        failureState = await failureSink.snapshot()
        try check(recovered.removed == 1 && failureState.0.count == 1, "Retry removes orphan IDs from an interrupted publication")
        await failureSink.fail("remove")
        try await expectFailure { _ = try await failure.reconcile([added], aliases: ["A": "A"]) }
        await failureSink.fail("")
        _ = try await failure.reconcile([added], aliases: ["A": "A"])
        failureState = await failureSink.snapshot()
        try check(failureState.0.count == 1 && failureState.0[SpotlightReconciler.identifier(added)!] != nil, "Delete failure can be retried to convergence")

        let legacySink = SpotlightFixture(), legacy = make("legacy-fail", legacySink)
        await legacySink.fail("legacy")
        try await expectFailure { _ = try await legacy.reconcile([a], aliases: ["A": "A"]) }
        await legacySink.fail("")
        _ = try await legacy.reconcile([a], aliases: ["A": "A"])
        let legacyState = await legacySink.snapshot()
        try check(legacyState.1.filter { $0 == "legacy" }.count == 2, "Legacy failure does not falsely mark migration complete")

        let limitSink = SpotlightFixture(), limit = make("limit", limitSink, maximum: 1)
        try await expectFailure { _ = try await limit.reconcile([a, b], aliases: ["A": "A", "B": "B"]) }
        let limitState = await limitSink.snapshot()
        try check(limitState.1.isEmpty && !FileManager.default.fileExists(atPath: limit.stateURL.path), "Oversized snapshot is rejected without truncation or mutations")
        try await expectFailure { _ = try await limit.reconcile([a], aliases: [:]) }
        try check(!FileManager.default.fileExists(atPath: limit.stateURL.path), "Unconfigured account is rejected before mutation")

        let corruptSink = SpotlightFixture(), corrupt = make("corrupt", corruptSink)
        try FileManager.default.createDirectory(at: corrupt.support, withIntermediateDirectories: true)
        try Data("invalid journal".utf8).write(to: corrupt.stateURL)
        try await expectFailure { _ = try await corrupt.reconcile([a], aliases: ["A": "A"]) }
        let corruptState = await corruptSink.snapshot()
        try check(corruptState.1.isEmpty, "Corrupt state cannot trigger index deletion")

        let heldSink = SpotlightFixture(), held = make("locked", heldSink)
        await heldSink.hold()
        let task = Task { try await held.reconcile([a], aliases: ["A": "A"]) }
        await heldSink.waitUntilHeld()
        let contender = SpotlightReconciler(support: held.support, sink: SpotlightFixture())
        do {
            _ = try await contender.reconcile([], aliases: [:])
            throw NSError(domain: "SpotlightTests", code: 2)
        } catch NimboSpotlightFailure.busy { checks += 1 }
        await heldSink.release()
        let completed = try await task.value
        try check(completed.indexed == 1, "First writer finishes after competing writer is rejected")
        _ = try await contender.reconcile([], aliases: [:])
        checks += 1
        print("PASS: \(checks) Spotlight reconciliation checks; fake index; no cloud accounts accessed")
    }
}
#endif
