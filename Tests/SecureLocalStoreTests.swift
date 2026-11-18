import Foundation

@main struct SecureLocalStoreTests {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/nimbo/secure-state-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent("state.json"), account = "test-" + UUID().uuidString
        var checks: [String] = []
        func check(_ value: Bool, _ label: String) throws { guard value else { throw NSError(domain: "SecureStateTests", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }; checks.append(label); print("PASS: " + label) }
        let value = ["scope": "drive", "count": "3"]
        try NimboSecureFile.save(value, to: file, account: account)
        let bytes = try Data(contentsOf: file)
        try check(bytes.starts(with: Data("NIMBO-ENC-1\n".utf8)), "State is encrypted with the Nimbo envelope")
        try check((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber).intValue == 0o600, "Encrypted state uses private permissions")
        try check(try NimboSecureFile.load([String:String].self, from: file, account: account) == value, "Encrypted state round-trips through the keychain key")
        let legacy = root.appendingPathComponent("legacy.json"); try JSONEncoder().encode(value).write(to: legacy)
        try check(try NimboSecureFile.load([String:String].self, from: legacy, account: account) == value, "Existing plaintext state remains readable for migration")
        var tampered = bytes; tampered[tampered.index(before: tampered.endIndex)] ^= 1; try tampered.write(to: file, options: .atomic)
        var rejected = false; do { _ = try NimboSecureFile.load([String:String].self, from: file, account: account) } catch { rejected = true }
        try check(rejected, "Authentication tag rejects tampered state")
        let report: [String: Any] = ["status": "PASS", "count": checks.count, "checks": checks, "synthetic_only": true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: "outputs/Nimbo/SECURE_STATE_TESTS.json"))
    }
}
