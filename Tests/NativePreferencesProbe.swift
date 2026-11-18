#if NATIVE_PREFERENCES_PROBE
import Foundation
import CoreFoundation

/// Runs both as a non-UI .app executable and as a standalone CLI. The app
/// branch uses a unique test bundle ID and never touches Nimbo's preferences.
@main struct NativePreferencesProbe {
    static func main() throws {
        if let identifier=Bundle.main.bundleIdentifier {
            guard identifier.hasPrefix("local.nimbo.preferences-probe.") else{throw CocoaError(.coderInvalidValue)}
            let defaults=UserDefaults.standard
            defer{defaults.removePersistentDomain(forName:identifier)}
            defaults.set(false,forKey:"NimboKeychainLock")
            guard !NimboSecureConfig.isKeychainLocked else{throw CocoaError(.coderInvalidValue)}
            defaults.set(true,forKey:"NimboKeychainLock")
            guard NimboSecureConfig.isKeychainLocked else{throw CocoaError(.coderInvalidValue)}
            print("PASS: bundled process reads standard preferences without creating a suite for itself")
        } else {
            let expected=(CFPreferencesCopyAppValue("NimboKeychainLock" as CFString,"local.nimbo.cloudsearch" as CFString) as? Bool) ?? false
            guard NimboSecureConfig.isKeychainLocked==expected else{throw CocoaError(.coderInvalidValue)}
            print("PASS: standalone process reads the existing host preference without changing it")
        }
    }
}
#endif
