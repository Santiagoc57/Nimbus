import Foundation

@main struct SecureConfigTests {
    static func main() throws {
        let fm = FileManager.default, workspace = URL(fileURLWithPath: fm.currentDirectoryPath)
        let root = workspace.appendingPathComponent("work/nimbo/secure-config-" + UUID().uuidString.prefix(6))
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let clear = Data("[GoogleDrive]\ntype = drive\nclient_id = demo.apps.googleusercontent.com\nclient_secret = GOCSPX-demo\ntoken = {\"refresh_token\":\"refresh-secret\"}\n".utf8)
        var checks: [String] = []
        func check(_ ok: Bool, _ label: String) throws { guard ok else { throw SyncFailure.message("FAIL: " + label) }; checks.append(label); print("PASS: " + label) }
        let runtime = try NimboSecureConfig.publishApp(clear, support: root)
        let encrypted = root.appendingPathComponent("rclone.conf.enc")
        try check(fm.fileExists(atPath: encrypted.path), "OAuth configuration has an encrypted envelope")
        try check(!fm.fileExists(atPath: root.appendingPathComponent("rclone.conf").path), "Legacy plaintext OAuth file is removed after publication")
        try check(Data(contentsOf: encrypted).range(of: clear) == nil, "Encrypted OAuth file does not contain plaintext credentials")
        let attrs = try fm.attributesOfItem(atPath: runtime.path)
        try check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Runtime configuration is private to the user")
        try check(Data(contentsOf: runtime) == clear, "Runtime rclone configuration is usable while Nimbo is active")
        try NimboSecureConfig.resealApp(runtime: runtime, support: root)
        try check(!fm.fileExists(atPath: runtime.path), "Runtime configuration is removed after resealing")
        let prepared = try NimboSecureConfig.prepareApp(support: root)
        try check(Data(contentsOf: prepared) == clear, "Encrypted configuration decrypts on the next launch")
        var tampered = try Data(contentsOf: encrypted); tampered[tampered.index(tampered.startIndex, offsetBy: tampered.count - 1)] ^= 1
        try tampered.write(to: encrypted, options: .atomic)
        var rejected = false
        do { _ = try NimboSecureConfig.prepareApp(support: root) } catch { rejected = true }
        try check(rejected, "Tampered OAuth envelope is rejected")
        let legacy = workspace.appendingPathComponent("work/nimbo/secure-config-legacy-" + UUID().uuidString.prefix(6))
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        let legacyFile = legacy.appendingPathComponent("rclone.conf"); try clear.write(to: legacyFile, options: .atomic)
        let migrated = try NimboSecureConfig.prepareApp(support: legacy)
        try check(fm.fileExists(atPath: legacy.appendingPathComponent("rclone.conf.enc").path) && !fm.fileExists(atPath: legacyFile.path), "Existing plaintext installations migrate on launch")
        try check(Data(contentsOf: migrated) == clear, "Migrated configuration remains readable by rclone")
        let native = root.appendingPathComponent("native-domain")
        let nativeRuntime = try NimboSecureConfig.publishNative(clear, directory: native)
        try check(fm.fileExists(atPath: native.appendingPathComponent("google.conf.enc").path) && Data(contentsOf: nativeRuntime) == clear, "File Provider domain stores its OAuth copy encrypted at rest")
        try NimboSecureConfig.resealNative(directory: native)
        try check(!fm.fileExists(atPath: nativeRuntime.path) && fm.fileExists(atPath: native.appendingPathComponent("google.conf.enc").path), "File Provider runtime is removed after provider cleanup")
        let report: [String: Any] = ["status": "PASS", "count": checks.count, "checks": checks, "synthetic_only": true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: workspace.appendingPathComponent("outputs/Nimbo/SECURE_CONFIG_TESTS.json"))
    }
}
