import Foundation

@main struct SyncFilterTests {
    static func main() throws {
        var checks: [String] = []
        func check(_ ok: Bool, _ label: String) throws { guard ok else { throw SyncFailure.message("FAIL: " + label) }; checks.append(label); print("PASS: " + label) }
        let valid = try SyncFilters.validate(["*.tmp", "Cache/**", "*.tmp", "  "])
        try check(valid == ["*.tmp", "Cache/**"], "Valid patterns are trimmed and de-duplicated")
        try check(try SyncFilters.validate([]) == SyncFilters.defaults, "Empty rules keep safe defaults")
        var rejected = false; do { _ = try SyncFilters.validate(["/Users/private"]) } catch { rejected = true }
        try check(rejected, "Absolute paths are rejected")
        rejected = false; do { _ = try SyncFilters.validate(["../secrets"]) } catch { rejected = true }
        try check(rejected, "Parent traversal is rejected")
        try check(SyncFilters.excludesLogicalFile("Carpeta/video.mov", patterns: ["*.mov"]), "File glob applies to a split file nested in Drive")
        try check(SyncFilters.excludesLogicalFile("Clientes/A/2026/video.mov", patterns: ["Clientes/**/video.mo?"]), "Nested glob and single-character wildcard")
        try check(!SyncFilters.excludesLogicalFile("Clientes/A/video.mov.bak", patterns: ["*.mov", "video.mov/"]), "Folder-only rules and partial suffixes keep a logical file")
        try check(!SyncFilters.excludesLogicalFile("Clientes/A/B/video.mov", patterns: ["Clientes/*/video.mov"]), "Single wildcard cannot cross a folder separator")
        let report: [String: Any] = ["status":"PASS", "count":checks.count, "checks":checks, "synthetic_only":true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: "outputs/Nimbo/SYNC_FILTER_TESTS.json"))
    }
}
