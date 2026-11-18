import Foundation
import Darwin

/// Login is opt-in. Updating that preference must not terminate the current
/// menu-bar app or launch a second instance beside it.
enum LaunchAtLogin {
    static let label = "local.nimbo.cloudsearch"
    private static var target: String { "gui/\(getuid())/\(label)" }
    #if NIMBO_TESTING
    static var directoryOverride: URL?
    static var commandHandler: (([String]) throws -> String)?
    #endif

    static var launchAgentsDirectory: URL {
        #if NIMBO_TESTING
        if let directoryOverride { return directoryOverride }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    static var plistURL: URL { launchAgentsDirectory.appendingPathComponent(label + ".plist") }

    static func isEnabled() -> Bool {
        guard let data = try? Data(contentsOf: plistURL),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let plist = object as? [String: Any],
              plist["Label"] as? String == label,
              let arguments = plist["ProgramArguments"] as? [String],
              arguments.count == 2, arguments[1] == "--background" else { return false }
        return (plist["RunAtLoad"] as? Bool) == true
    }

    private static func definition(executable: String) -> [String: Any] {
        ["Label": label,
         "ProgramArguments": [executable, "--background"],
         "RunAtLoad": true,
         // Recover from a crash; an intentional clean quit must stay closed.
         "KeepAlive": ["SuccessfulExit": false],
         "ProcessType": "Background",
         "ThrottleInterval": 10,
         "LimitLoadToSessionType": "Aqua"]
    }

    /// Persist path/policy migration for the next login. Never bootout the
    /// calling process while it is still initializing its controllers.
    static func refreshExecutablePathIfEnabled() {
        guard isEnabled(), let executable = Bundle.main.executableURL?.path else { return }
        do {
            let old = try Data(contentsOf: plistURL)
            let object = try PropertyListSerialization.propertyList(from: old, options: [], format: nil) as? [String: Any]
            let policy = object?["KeepAlive"] as? [String: Bool]
            if (object?["ProgramArguments"] as? [String])?.first == executable,
               policy == ["SuccessfulExit": false] { return }
            try writeDefinition(executable: executable)
        } catch { NSLog("Nimbo: no se pudo actualizar el inicio automático: %@", error.localizedDescription) }
    }

    static func setEnabled(_ enabled: Bool, executablePath: String? = nil) throws {
        let previous = try existingDefinition()
        do {
            if enabled {
                let executable = executablePath ?? Bundle.main.executableURL?.path ?? ProcessInfo.processInfo.arguments[0]
                guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
                    throw failure("No se encontró el ejecutable de Nimbo para iniciar sesión.")
                }
                try writeDefinition(executable: executable)
                // A previous disable persists across logins; explicitly undo it.
                _ = try control(["enable", target])
            } else {
                if previous != nil { try FileManager.default.removeItem(at: plistURL) }
                _ = try control(["disable", target])
            }
            // The running app already handles scheduled work. Bootstrap here
            // would create a duplicate process; login loads this plist later.
        } catch {
            // The checkbox and file must not report success after launchctl fails.
            if let previous {
                try previous.write(to: plistURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plistURL.path)
            }
            else if FileManager.default.fileExists(atPath: plistURL.path) { try FileManager.default.removeItem(at: plistURL) }
            throw error
        }
    }

    /// Called only after work has stopped and configuration has been sealed.
    /// Unregister this process for the rest of this login; keep its opt-in plist
    /// for the next login. This also handles a legacy KeepAlive=true job already
    /// loaded by an older Nimbo. Never stop a different Nimbo instance.
    static func unregisterForExit(processID: Int32 = getpid()) {
        guard let state = try? control(["print", target]),
              loadedPID(in: state) == processID else { return }
        // bootout can terminate the caller. No required cleanup may follow it.
        _ = try? control(["bootout", target])
    }

    static func loadedPID(in state: String) -> Int32? {
        let matches = state.split(separator: "\n").compactMap { line -> Int32? in
            let fields = line.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            guard fields.count == 2, fields[0].trimmingCharacters(in: .whitespaces) == "pid" else { return nil }
            return Int32(fields[1].trimmingCharacters(in: .whitespaces))
        }
        return matches.count == 1 ? matches.first : nil
    }

    private static func existingDefinition() throws -> Data? {
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return nil }
        return try Data(contentsOf: plistURL)
    }

    private static func writeDefinition(executable: String) throws {
        try FileManager.default.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try PropertyListSerialization.data(fromPropertyList: definition(executable: executable), format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plistURL.path)
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "NimboLaunchAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func control(_ arguments: [String]) throws -> String {
        #if NIMBO_TESTING
        if directoryOverride != nil {
            guard let commandHandler else { throw failure("Las pruebas requieren un ejecutor aislado de launchctl.") }
            return try commandHandler(arguments)
        }
        #endif
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("nimbo-launchctl-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw failure("No se pudo preparar la respuesta del servicio de inicio.")
        }
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = output; process.standardError = output
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + 3) == .success else {
            if process.isRunning { process.terminate() }
            if finished.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw failure("El servicio de inicio no respondió a tiempo.")
        }
        let input = try FileHandle(forReadingFrom: outputURL)
        defer { try? input.close() }
        let text = String(data: try input.read(upToCount: 256 * 1024) ?? Data(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { throw failure(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return text
    }
}
