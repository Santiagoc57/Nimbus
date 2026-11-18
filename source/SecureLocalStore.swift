import Foundation
import CryptoKit
import Security

/// Encrypts Nimbo's local journals and relation metadata. Existing plaintext
/// JSON remains readable once so an upgrade can migrate it on the next save.
enum NimboSecureFile {
    private static let magic = Data("NIMBO-ENC-1\n".utf8)
    #if SECURE_KEYCHAIN_TESTS
    static var testRoot: URL!
    static var testRead: (() -> (OSStatus, Data?))!
    static var testAdd: ((Data) -> OSStatus)!
    #endif
    private static var keyRoot: URL {
        #if SECURE_KEYCHAIN_TESTS
        precondition(testRoot != nil)
        return testRoot
        #else
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Nimbo/Keys", isDirectory: true)
        #endif
    }

    static func load<Value: Decodable>(_ type: Value.Type, from url: URL, account: String) throws -> Value? {
        #if NIMBO_TESTING
        guard let clear = try loadData(from: url, account: account, keychain: false) else { return nil }
        #else
        guard let clear = try loadData(from: url, account: account) else { return nil }
        #endif
        return try JSONDecoder().decode(Value.self, from: clear)
    }

    static func save<Value: Encodable>(_ value: Value, to url: URL, account: String) throws {
        #if NIMBO_TESTING
        try saveData(JSONEncoder().encode(value), to: url, account: account, keychain: false)
        #else
        try saveData(JSONEncoder().encode(value), to: url, account: account)
        #endif
    }

    /// Raw-data variant used for the OAuth configuration. It keeps the same
    /// authenticated envelope as the local JSON journals while allowing the
    /// plaintext format required by rclone to exist only in a short-lived
    /// runtime file.
    static func loadData(from url: URL, account: String, keychain: Bool = true, preferKeychain: Bool = false) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.starts(with: magic) else { return data }
        let combined = Data(data.dropFirst(magic.count))
        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(box, using: key(account: account, allowKeychain: keychain, preferKeychain: preferKeychain, create: false), authenticating: magic)
    }

    static func saveData(_ clear: Data, to url: URL, account: String, keychain: Bool = true, preferKeychain: Bool = false) throws {
        let sealed = try AES.GCM.seal(clear, using: key(account: account, allowKeychain: keychain, preferKeychain: preferKeychain), authenticating: magic)
        guard let combined = sealed.combined else { throw CocoaError(.coderInvalidValue) }
        var output = magic; output.append(combined)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try output.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func removeFallbackKey(account: String) {
        let digest = SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
        let root = keyRoot
        try? FileManager.default.removeItem(at: root.appendingPathComponent(digest + ".key"))
    }

    private static func key(account: String, allowKeychain: Bool = true, preferKeychain: Bool = false, create: Bool = true) throws -> SymmetricKey {
        let service = "local.nimbo.secure-state"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true]
        let digest = SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
        let root = keyRoot
        let fallback = root.appendingPathComponent(digest + ".key")
        func readKeychain() -> (OSStatus, Data?) {
            #if SECURE_KEYCHAIN_TESTS
            precondition(testRead != nil)
            return testRead()
            #else
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
            #endif
        }
        func failure(_ status: OSStatus) -> NSError {
            NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "No se pudo acceder a la clave del llavero. La configuración anterior se conserva."])
        }
        // A migration can explicitly prefer the old Keychain item. This is
        // needed when a private fallback with the same account was created by
        // a newer build before it discovered a legacy Keychain envelope.
        if allowKeychain && preferKeychain {
            let (status, data) = readKeychain()
            if status == errSecSuccess, let data, data.count == 32 { return SymmetricKey(data: data) }
            guard status == errSecItemNotFound && create else { throw failure(status == errSecSuccess ? errSecDecode : status) }
        }
        // Prefer an existing fallback before creating a new Keychain item so a
        // temporary Keychain outage cannot strand previously encrypted state.
        if !preferKeychain, let existing = try? Data(contentsOf: fallback), existing.count == 32 { return SymmetricKey(data: existing) }
        if !allowKeychain {
            guard create else { throw failure(errSecItemNotFound) }
            let bytes = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try bytes.write(to: fallback, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fallback.path)
            return SymmetricKey(data: bytes)
        }
        let (readStatus, existing) = readKeychain()
        if readStatus == errSecSuccess, let existing, existing.count == 32 { return SymmetricKey(data: existing) }
        guard create else { throw failure(readStatus == errSecSuccess ? errSecDecode : readStatus) }
        if preferKeychain && readStatus != errSecItemNotFound { throw failure(readStatus == errSecSuccess ? errSecDecode : readStatus) }
        let bytes = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let attributes: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                         kSecAttrService as String: service,
                                         kSecAttrAccount as String: account,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                         kSecValueData as String: bytes]
        #if SECURE_KEYCHAIN_TESTS
        precondition(testAdd != nil)
        let status = testAdd(bytes)
        #else
        let status = SecItemAdd(attributes as CFDictionary, nil)
        #endif
        if status == errSecSuccess { return SymmetricKey(data: bytes) }
        if status == errSecDuplicateItem {
            let (duplicateStatus, data) = readKeychain()
            if duplicateStatus == errSecSuccess, let data, data.count == 32 { return SymmetricKey(data: data) }
        }
        if preferKeychain { throw failure(status) }
        // A locked/unavailable keychain should not make the app lose state.
        // Keep a random 0600 fallback in the private support directory; the
        // JSON itself is still encrypted and a later run can use Keychain.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try bytes.write(to: fallback, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fallback.path)
        return SymmetricKey(data: bytes)
    }
}


import Foundation
import CryptoKit

/// Keeps OAuth material encrypted at rest while presenting a 0600 plaintext
/// file only to rclone and the File Provider process that currently needs it.
/// The runtime file is recreated from the authenticated envelope at launch and
/// removed after the owning process exits.
enum NimboSecureConfig {
    private static let account = "oauth-config"
    private static let encryptedName = "rclone.conf.enc"
    private static let legacyName = "rclone.conf"
    private static let runtimeName = ".rclone-runtime.conf"
    private static let keychainPreference = "NimboKeychainLock"

    #if SECURE_KEYCHAIN_TESTS
    static var testDefaults: UserDefaults!
    #endif
    private static var preferences: UserDefaults {
        #if SECURE_KEYCHAIN_TESTS
        precondition(testDefaults != nil)
        return testDefaults
        #else
        // Foundation rejects a suite named after the running app itself.
        // Bundled processes must use their standard defaults. The standalone
        // CLI has no bundle ID and must explicitly read the host's domain.
        if Bundle.main.bundleIdentifier != nil { return .standard }
        if let shared=UserDefaults(suiteName:"local.nimbo.cloudsearch") { return shared }
        // A failed host-domain lookup must not silently select local-key mode.
        let fallback=UserDefaults.standard
        fallback.register(defaults:[keychainPreference:true])
        return fallback
        #endif
    }
    static var isKeychainLocked: Bool { preferences.bool(forKey: keychainPreference) }

    static func prepareApp(support: URL) throws -> URL {
        try prepare(directory: support, encrypted: encryptedName, legacy: legacyName, runtime: runtimeName, account: account, preferKeychain: isKeychainLocked)
    }

    static func publishApp(_ data: Data, support: URL) throws -> URL {
        try publish(data, directory: support, encrypted: encryptedName, legacy: legacyName, runtime: runtimeName, account: account, preferKeychain: isKeychainLocked)
    }

    static func resealApp(runtime: URL, support: URL) throws {
        try reseal(runtime: runtime, directory: support, encrypted: encryptedName, legacy: legacyName, account: account, preferKeychain: isKeychainLocked)
    }

    static func setKeychainLock(_ enabled: Bool, support: URL) throws {
        let encrypted = support.appendingPathComponent(encryptedName)
        if FileManager.default.fileExists(atPath: encrypted.path) {
            let clear = try NimboSecureFile.loadData(from: encrypted, account: account, keychain: true, preferKeychain: isKeychainLocked) ?? Data()
            guard !clear.isEmpty else { throw DriveFailure.unsupportedCredentials }
            try NimboSecureFile.saveData(clear, to: encrypted, account: account, keychain: enabled, preferKeychain: enabled)
            preferences.set(enabled, forKey: keychainPreference)
            if enabled { NimboSecureFile.removeFallbackKey(account: account) }
        } else {
            preferences.set(enabled, forKey: keychainPreference)
        }
    }

    /// Re-encrypts the temporary configuration owned by one File Provider
    /// domain and removes its plaintext runtime file.  The provider process
    /// can keep the runtime open for its lifetime, so cleanup is best-effort
    /// and deliberately idempotent.
    static func resealNative(directory: URL) throws {
        let runtime = directory.appendingPathComponent(".google-runtime.conf")
        try reseal(runtime: runtime,
                   directory: directory,
                   encrypted: "google.conf.enc",
                   legacy: "google.conf",
                   account: nativeAccount(directory: directory))
    }

    static func checkpointRuntime(_ runtime: URL) throws {
        let directory = runtime.deletingLastPathComponent()
        if runtime.lastPathComponent == runtimeName {
            try checkpoint(runtime: runtime, directory: directory, encrypted: encryptedName, account: account, preferKeychain: isKeychainLocked)
        } else if runtime.lastPathComponent == ".google-runtime.conf" {
            try checkpoint(runtime: runtime, directory: directory, encrypted: "google.conf.enc", account: nativeAccount(directory: directory))
        }
    }

    static func nativeAccount(directory: URL) -> String {
        let digest = SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "native-config-" + digest
    }

    static func prepareNative(directory: URL) throws -> URL {
        let account = nativeAccount(directory: directory)
        return try prepare(directory: directory, encrypted: "google.conf.enc", legacy: "google.conf", runtime: ".google-runtime.conf", account: account)
    }

    static func publishNative(_ data: Data, directory: URL) throws -> URL {
        let account = nativeAccount(directory: directory)
        return try publish(data, directory: directory, encrypted: "google.conf.enc", legacy: "google.conf", runtime: ".google-runtime.conf", account: account)
    }

    /// Recreates a plaintext runtime file from its encrypted envelope when
    /// another process (or a previous quit) removed it. Every reader calls this
    /// first, so "Actualizar conexión", rclone and Drive API calls never fail
    /// with "no such file" while the encrypted authorization still exists.
    @discardableResult
    static func ensureRuntime(_ runtime: URL) -> Bool {
        if FileManager.default.fileExists(atPath: runtime.path) { return true }
        let directory = runtime.deletingLastPathComponent()
        switch runtime.lastPathComponent {
        case runtimeName: _ = try? prepareApp(support: directory)
        case ".google-runtime.conf": _ = try? prepareNative(directory: directory)
        default: break
        }
        return FileManager.default.fileExists(atPath: runtime.path)
    }

    static func appRuntimeURL(support: URL) -> URL { support.appendingPathComponent(runtimeName) }

    static func removeRuntime(_ runtime: URL) {
        try? FileManager.default.removeItem(at: runtime)
    }

    private static func prepare(directory: URL, encrypted: String, legacy: String, runtime: String, account: String, preferKeychain: Bool = false) throws -> URL {
        try privateDirectory(directory)
        let encryptedURL = directory.appendingPathComponent(encrypted)
        let legacyURL = directory.appendingPathComponent(legacy)
        let runtimeURL = directory.appendingPathComponent(runtime)
        if FileManager.default.fileExists(atPath: encryptedURL.path) {
            let clear = try NimboSecureFile.loadData(from: encryptedURL, account: account, keychain: preferKeychain, preferKeychain: preferKeychain) ?? Data()
            guard !clear.isEmpty else { throw DriveFailure.unsupportedCredentials }
            try writeRuntime(clear, to: runtimeURL)
            return runtimeURL
        }
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return runtimeURL }
        let clear = try Data(contentsOf: legacyURL)
        guard !clear.isEmpty else { throw DriveFailure.unsupportedCredentials }
            try NimboSecureFile.saveData(clear, to: encryptedURL, account: account, keychain: preferKeychain, preferKeychain: preferKeychain)
        try writeRuntime(clear, to: runtimeURL)
        try? FileManager.default.removeItem(at: legacyURL)
        return runtimeURL
    }

    private static func publish(_ data: Data, directory: URL, encrypted: String, legacy: String, runtime: String, account: String, preferKeychain: Bool = false) throws -> URL {
        try privateDirectory(directory)
        let encryptedURL = directory.appendingPathComponent(encrypted)
        let legacyURL = directory.appendingPathComponent(legacy)
        let runtimeURL = directory.appendingPathComponent(runtime)
        guard !data.isEmpty else { throw DriveFailure.unsupportedCredentials }
        try NimboSecureFile.saveData(data, to: encryptedURL, account: account, keychain: preferKeychain, preferKeychain: preferKeychain)
        try writeRuntime(data, to: runtimeURL)
        try? FileManager.default.removeItem(at: legacyURL)
        return runtimeURL
    }

    private static func reseal(runtime: URL, directory: URL, encrypted: String, legacy: String, account: String, preferKeychain: Bool = false) throws {
        guard FileManager.default.fileExists(atPath: runtime.path) else { return }
        let data = try Data(contentsOf: runtime)
        guard !data.isEmpty else { return }
        try privateDirectory(directory)
        try NimboSecureFile.saveData(data, to: directory.appendingPathComponent(encrypted), account: account, keychain: preferKeychain, preferKeychain: preferKeychain)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(legacy))
        try? FileManager.default.removeItem(at: runtime)
    }

    private static func checkpoint(runtime: URL, directory: URL, encrypted: String, account: String, preferKeychain: Bool = false) throws {
        guard FileManager.default.fileExists(atPath: runtime.path) else { return }
        let data = try Data(contentsOf: runtime)
        guard !data.isEmpty else { return }
        try privateDirectory(directory)
        try NimboSecureFile.saveData(data, to: directory.appendingPathComponent(encrypted), account: account, keychain: preferKeychain, preferKeychain: preferKeychain)
    }

    private static func writeRuntime(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
    }

    private static func privateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: url.path)
    }
}
