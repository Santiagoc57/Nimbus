#if FINDER_WEB_LINK_TESTS
import Foundation

actor LinkCalls {
    var values: [FinderWebLinks.Identity] = []
    func add(_ value: FinderWebLinks.Identity) { values.append(value) }
}
@main struct FinderWebLinksTests {
    static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        let home = URL(fileURLWithPath: "/Users/fixture"), base = "/Users/fixture/Library/CloudStorage/Nimbo/"
        let calls = LinkCalls()
        let resolver = FinderWebLinks(identify: { url in
            let domain = url.lastPathComponent == "primary" ? "google-drive" : url.lastPathComponent == "shared" ? "google-drive-shared-account-test" : "google-drive-account-two"
            return .init(id: "same-id", domain: domain)
        }, resolve: { identity in
            await calls.add(identity)
            return URL(string: "https://docs.google.com/document/d/\(identity.id)/edit?resourcekey=\(identity.domain)")!
        })
        let links = try await resolver.links(paths: [base+"primary", base+"secondary", base+"shared", base+"primary"], home: home)
        check(links.count == 3, "duplicate paths produce only one link")
        check(await calls.values.map(\.domain) == ["google-drive", "google-drive-account-two", "google-drive-shared-account-test"], "each path uses its actual domain, including shared drives")
        check(Set(links).count == 3, "same file ID in separate domains keeps separate resource keys")
        check(links[0].query?.contains("resourcekey=") == true, "official URL query preserved")
        for paths in [[], Array(repeating: base+"primary", count: 101), ["relative"], ["/Users/fixture/Desktop/file"], [base+"../../../Desktop/file"], ["/Users/fixture/Library/CloudStorageOther/file"]] {
            let before = await calls.values.count; var rejected = false
            do { _ = try await resolver.links(paths: paths, home: home) } catch { rejected = true }
            let after = await calls.values.count
            check(rejected && after == before, "invalid selection cannot resolve links")
        }
        let unrelated = FinderWebLinks(identify: { _ in .init(id: "same-id", domain: "another-provider") }, resolve: { _ in fatalError("unrelated provider reached resolver") })
        var rejected = false
        do { _ = try await unrelated.links(paths: [base+"other"], home: home) } catch { rejected = true }
        check(rejected, "other provider rejected before opening or copying")
        let unsafe = FinderWebLinks(identify: { _ in .init(id: "same-id", domain: "google-drive") }, resolve: { _ in URL(string: "https://example.invalid/evil")! })
        rejected = false
        do { _ = try await unsafe.links(paths: [base+"primary"], home: home) } catch { rejected = true }
        check(rejected, "untrusted provider URL rejected")
        let partial = FinderWebLinks(identify: { url in .init(id: url.lastPathComponent, domain: "google-drive") }, resolve: { identity in
            if identity.id == "fail" { throw DriveFailure.denied }
            return URL(string: "https://drive.google.com/open?id=good")!
        })
        rejected = false
        do { _ = try await partial.links(paths: [base+"good", base+"fail"], home: home) } catch { rejected = true }
        check(rejected, "partial batch failure returns no completed clipboard batch")
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await resolver.links(paths: [base+"primary"], home: home) }
        do { _ = try await task.value; fatalError("cancelled action accepted") } catch is CancellationError { checks += 1 }
        print("PASS: \(checks) Finder path, domain, batch, cancellation and link-validation checks; no network")
    }
}
#endif
