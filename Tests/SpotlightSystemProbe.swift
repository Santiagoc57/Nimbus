import Foundation
import CoreSpotlight
import UniformTypeIdentifiers
import Darwin

/// Run only in its own uniquely identified probe bundle. Never uses Nimbo's
/// index, domain, credentials, or catalog. No windows are created.
@main
struct SpotlightSystemProbe {
    static func query(_ title: String) async throws -> Set<String> {
        let query = CSSearchQuery(queryString: "title == '\(title)'", attributes: ["title"])
        let lock = NSLock()
        var identifiers: Set<String> = []
        let result: Set<String> = try await withCheckedThrowingContinuation { continuation in
            query.foundItemsHandler = { items in
                lock.lock(); identifiers.formUnion(items.map { $0.uniqueIdentifier }); lock.unlock()
            }
            query.completionHandler = { error in
                if let error { continuation.resume(throwing: error) }
                else {
                    lock.lock(); let copy = identifiers; lock.unlock()
                    continuation.resume(returning: copy)
                }
            }
            query.start()
        }
        withExtendedLifetime(query) {}
        return result
    }

    static func waitFor(_ title: String, ids: Set<String>) async throws {
        for _ in 0..<12 {
            if try await query(title) == ids { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw NSError(domain: "NimboSpotlightProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Search did not converge to expected synthetic IDs"])
    }

    static func main() async {
        guard let bundle = Bundle.main.bundleIdentifier, bundle.hasPrefix("local.nimbo.spotlightprobe.") else {
            print("Refusing to run outside a unique Spotlight probe bundle")
            exit(2)
        }
        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard !Task.isCancelled else { return }
            print("FAIL: CoreSpotlight probe timed out; synthetic index cleanup unconfirmed")
            exit(2)
        }
        let index = CSSearchableIndex(name: bundle)
        let title = "NimboFixture" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var checks: [String] = []
        var failure: Error?
        func item(_ id: String, title: String) -> CSSearchableItem {
            let attributes = CSSearchableItemAttributeSet(contentType: .plainText)
            attributes.title = title
            attributes.contentDescription = "Synthetic Nimbo index test; no user content"
            return CSSearchableItem(uniqueIdentifier: id, domainIdentifier: bundle, attributeSet: attributes)
        }
        do {
            try await index.indexSearchableItems([item("first", title: title), item("second", title: title)])
            checks.append("publish acknowledged")
            try await waitFor(title, ids: ["first", "second"])
            checks.append("synthetic entries discoverable via CSSearchQuery")
            try await index.deleteSearchableItems(withIdentifiers: ["second"])
            try await waitFor(title, ids: ["first"])
            checks.append("stale ID removed from search results")
            try await index.indexSearchableItems([item("first", title: title + "Renamed")])
            try await waitFor(title, ids: [])
            try await waitFor(title + "Renamed", ids: ["first"])
            checks.append("rename reflected in search results")
        } catch { failure = error }
        do {
            try await index.deleteAllSearchableItems()
            checks.append("unique synthetic index cleared")
        } catch { failure = failure ?? error }
        watchdog.cancel()
        var result: [String: Any] = ["bundle": bundle, "checks": checks, "status": failure == nil ? "PASS" : "FAIL"]
        if let failure { result["error"] = failure.localizedDescription }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        }
        exit(failure == nil ? 0 : 1)
    }
}
