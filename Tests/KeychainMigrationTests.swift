#if SECURE_KEYCHAIN_TESTS
import Foundation
import Security

@main struct KeychainMigrationTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("NimboKeychainMigration-" + UUID().uuidString)
        let suite = "local.nimbo.keychaintest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? fm.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        NimboSecureFile.testRoot = root.appendingPathComponent("Keys")
        NimboSecureConfig.testDefaults = defaults
        var key: Data?, readError: OSStatus?, addError: OSStatus?, reads = 0, adds = 0
        NimboSecureFile.testRead = { reads += 1; return (readError ?? (key == nil ? errSecItemNotFound : errSecSuccess), key) }
        NimboSecureFile.testAdd = { data in
            adds += 1
            if let addError { return addError }
            if key != nil { return errSecDuplicateItem }
            key = data; return errSecSuccess
        }
        var checks = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw NSError(domain: "KeychainMigrationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
            checks += 1
        }
        func fails(_ body: () throws -> Void) throws {
            var failed = false; do { try body() } catch { failed = true }
            try check(failed, "Expected failure")
        }
        func localKeys() throws -> [Data] {
            let paths = (try? fm.contentsOfDirectory(at: NimboSecureFile.testRoot, includingPropertiesForKeys: nil)) ?? []
            return try paths.map { try Data(contentsOf: $0) }
        }
        let support = root.appendingPathComponent("Support")
        let original = Data("[GoogleDrive]\ntoken = synthetic-secret\n".utf8)
        let runtime = try NimboSecureConfig.publishApp(original, support: support)
        let envelope = support.appendingPathComponent("rclone.conf.enc")
        let initial = try Data(contentsOf: envelope), local = try localKeys()
        try check(reads == 0 && adds == 0 && local.count == 1, "Local config does not touch Keychain")

        readError = errSecInteractionNotAllowed
        try fails { try NimboSecureConfig.setKeychainLock(true, support: support) }
        try check(!NimboSecureConfig.isKeychainLocked && (try Data(contentsOf: envelope)) == initial && (try localKeys()) == local,
                  "Locked Keychain preserves preference, encrypted credentials and local key")
        readError = nil; addError = errSecAuthFailed
        try fails { try NimboSecureConfig.setKeychainLock(true, support: support) }
        try check(!NimboSecureConfig.isKeychainLocked && (try Data(contentsOf: envelope)) == initial && (try localKeys()) == local,
                  "Failed Keychain creation cannot remove the local key")

        addError = nil
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: support.path)
        do {
            defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path) }
            try fails { try NimboSecureConfig.setKeychainLock(true, support: support) }
            try check(!NimboSecureConfig.isKeychainLocked && (try Data(contentsOf: envelope)) == initial && (try localKeys()) == local,
                      "Disk write failure preserves original protection and credentials")
        }
        try NimboSecureConfig.setKeychainLock(true, support: support)
        try check(NimboSecureConfig.isKeychainLocked && key?.count == 32 && (try localKeys()).isEmpty, "Successful migration commits protection and removes fallback")
        try check(try Data(contentsOf: NimboSecureConfig.prepareApp(support: support)) == original, "Protected config survives reopen")
        try NimboSecureConfig.setKeychainLock(true, support: support)
        try check(try Data(contentsOf: NimboSecureConfig.prepareApp(support: support)) == original, "Enabling again is idempotent")

        let protectedEnvelope = try Data(contentsOf: envelope)
        readError = errSecInteractionNotAllowed
        try fails { try NimboSecureConfig.setKeychainLock(false, support: support) }
        try check(NimboSecureConfig.isKeychainLocked && (try Data(contentsOf: envelope)) == protectedEnvelope && (try localKeys()).isEmpty,
                  "Failed unlock preserves protected credentials and preference")
        try fails { try NimboSecureConfig.checkpointRuntime(runtime) }
        try check((try Data(contentsOf: envelope)) == protectedEnvelope && (try localKeys()).isEmpty, "Token checkpoint cannot silently downgrade a locked Keychain")
        try fails { _ = try NimboSecureConfig.prepareApp(support: support) }
        try check((try localKeys()).isEmpty, "Failed protected read does not generate a random replacement key")

        readError = nil
        let refreshed = Data("[GoogleDrive]\ntoken = synthetic-refreshed\n".utf8)
        try refreshed.write(to: runtime)
        try NimboSecureConfig.checkpointRuntime(runtime)
        try check(try Data(contentsOf: NimboSecureConfig.prepareApp(support: support)) == refreshed, "Token checkpoint retains Keychain protection")
        try NimboSecureConfig.setKeychainLock(false, support: support)
        try check(!NimboSecureConfig.isKeychainLocked && (try localKeys()).count == 1, "Disabling creates durable local protection")
        readError = errSecInteractionNotAllowed
        try check(try Data(contentsOf: NimboSecureConfig.prepareApp(support: support)) == refreshed, "Local mode reopens without Keychain access")
        print("PASS: \(checks) Keychain migration checks; isolated keys/preferences; no real Keychain calls")
    }
}
#endif
