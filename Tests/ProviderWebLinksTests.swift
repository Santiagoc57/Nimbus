import Foundation

@main struct ProviderWebLinksTests {
    static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value, label); checks += 1
        }
        let copy = ProviderWebLinks.Action.copy.rawValue
        for (action, domain, ids) in [
            ("unexpected", "google-drive", ["a"]),
            (copy, "another-provider", ["a"]),
            (copy, "google-drive", []),
            (copy, "google-drive", [""]),
            (copy, "google-drive", ["a\0b"]),
            (copy, "google-drive", [String(repeating: "x", count: 1025)]),
            (copy, "google-drive", Array(repeating: "a", count: 101))
        ] {
            do { _ = try ProviderWebLinks(action: action, domain: domain, identifiers: ids); preconditionFailure("Invalid request accepted") }
            catch { checks += 1 }
        }
        do { _ = try ProviderWebLinks(action: copy, domain: nil, identifiers: ["a"]); preconditionFailure("Missing domain accepted") }
        catch { checks += 1 }

        let secondary = "google-drive-account-secondary"
        let request = try ProviderWebLinks(action: copy, domain: secondary, identifiers: ["a", "a", "b"])
        var visited: [String] = []
        let links = try await request.resolve { domain, id in
            visited.append(domain + ":" + id)
            return URL(string: "https://drive.google.com/file/d/\(id)/view?resourcekey=example")!
        }
        check(visited == [secondary + ":a", secondary + ":b"], "Deduplicate without losing the originating account")
        check(links.count == 2 && links.allSatisfy { $0.query == "resourcekey=example" }, "Preserve resource keys")
        let local = try ProviderWebLinks(action: copy, domain: secondary, identifiers: ["__fp/fs/docID(7047)"])
        let canonical = try await local.resolve(identify: { domain, id in
            check(id == "__fp/fs/docID(7047)", "Pass opaque identifiers to the system unchanged")
            return (domain, "real-drive-id")
        }) { domain, id in
            check(domain == secondary && id == "real-drive-id", "Resolve with the canonical ID and original account")
            return URL(string: "https://drive.google.com/file/d/\(id)/view")!
        }
        check(canonical.count == 1, "Filesystem identifier resolves without reading the file")
        do {
            _ = try await local.resolve(identify: { _, _ in ("google-drive", "real-drive-id") }) { _, _ in
                preconditionFailure("Cross-account lookup must not reach Google")
            }
            preconditionFailure("Mismatched account accepted")
        } catch { checks += 1 }
        let shared = try ProviderWebLinks(action: ProviderWebLinks.Action.preview.rawValue, domain: "google-drive-shared-team", identifiers: ["NSFileProviderRootContainerItemIdentifier"])
        check(shared.action == .preview && shared.identifiers.count == 1, "Shared root can resolve through its domain")
        do {
            _ = try await request.resolve { _, _ in URL(string: "https://drive.google.com.attacker.example/a")! }
            preconditionFailure("Untrusted URL accepted")
        } catch { checks += 1 }
        do {
            _ = try await request.resolve { _, id in
                if id == "b" { throw CocoaError(.fileReadNoPermission) }
                return URL(string: "https://drive.google.com/file/d/a/view")!
            }
            preconditionFailure("Partial batch reported success")
        } catch { checks += 1 }
        let task = Task { () throws -> [URL] in
            try await request.resolve { _, _ in
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return URL(string: "https://drive.google.com/file/d/a/view")!
            }
        }
        task.cancel()
        do { _ = try await task.value; preconditionFailure("Cancelled request completed") }
        catch is CancellationError { checks += 1 }
        for action in [ProviderWebLinks.Action.share, .revoke] {
            let selection = try ProviderWebLinks(action: action.rawValue, domain: secondary, identifiers: ["opaque1", "opaque2"])
            let file = URL(fileURLWithPath: "/tmp/prueba & más #1.txt")
            let route = try await selection.confirmationURL { domain, _ in (domain, "drive-id", file) }
            let parts = URLComponents(url: route, resolvingAgainstBaseURL: false)!
            check(parts.scheme == "nimbo" && parts.host == (action == .share ? "share" : "revoke-share"), "Correct confirmation route")
            check(parts.queryItems == [URLQueryItem(name: "domain", value: secondary), URLQueryItem(name: "path", value: file.path), URLQueryItem(name: "item", value: "drive-id")], "Stable identity, safe path encoding and deduplication")
            do {
                _ = try await selection.confirmationURL { domain, opaque in (opaque == "opaque1" ? domain : "google-drive", "id", file) }
                preconditionFailure("Mixed-domain batch handed off")
            } catch { checks += 1 }
        }
        print("PASS: \(checks) File Provider action, account, batch and cancellation checks; no network")
    }
}
