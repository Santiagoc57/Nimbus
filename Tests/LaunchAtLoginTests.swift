import Foundation

@main
struct LaunchAtLoginTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw NSError(domain: "LaunchAtLoginTests", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
        checks += 1
    }
    static func mustFail(_ operation: () throws -> Void) throws {
        var failed = false
        do { try operation() } catch { failed = true }
        try check(failed, "Expected operation to fail")
    }

    static func main() throws {
        #if NIMBO_TESTING
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nimbo-launch-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        LaunchAtLogin.directoryOverride = root
        var commands: [[String]] = []
        LaunchAtLogin.commandHandler = { args in commands.append(args); return "" }
        try check(!LaunchAtLogin.isEnabled(), "Absent configuration is disabled")
        LaunchAtLogin.refreshExecutablePathIfEnabled()
        try check(!FileManager.default.fileExists(atPath: LaunchAtLogin.plistURL.path) && commands.isEmpty, "Startup cannot opt the user in")

        try LaunchAtLogin.setEnabled(true, executablePath: "/usr/bin/true")
        try check(LaunchAtLogin.isEnabled(), "Enable persists")
        let manifest = try Data(contentsOf: LaunchAtLogin.plistURL)
        let plist = try PropertyListSerialization.propertyList(from: manifest, options: [], format: nil) as! [String: Any]
        try check(plist["KeepAlive"] as? [String: Bool] == ["SuccessfulExit": false], "Clean exit does not demand restart")
        try check(plist["RunAtLoad"] as? Bool == true, "Login launches the app")
        try check(plist["ProgramArguments"] as? [String] == ["/usr/bin/true", "--background"], "Executable arguments are literal")
        try check(commands.map { $0[0] } == ["enable"], "Enabling cannot bootstrap a duplicate or stop the current app")
        let attributes = try FileManager.default.attributesOfItem(atPath: LaunchAtLogin.plistURL.path)
        try check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Manifest is private")

        var legacy = plist
        legacy["ProgramArguments"] = ["/old/location/Nimbo", "--background"]
        legacy["KeepAlive"] = true
        try PropertyListSerialization.data(fromPropertyList: legacy, format: .xml, options: 0).write(to: LaunchAtLogin.plistURL)
        let countBeforeMigration = commands.count
        LaunchAtLogin.refreshExecutablePathIfEnabled()
        let migratedData = try Data(contentsOf: LaunchAtLogin.plistURL)
        let migrated = try PropertyListSerialization.propertyList(from: migratedData, options: [], format: nil) as! [String: Any]
        try check((migrated["ProgramArguments"] as? [String])?.first == Bundle.main.executableURL?.path, "Moved app gets the current path")
        try check(migrated["KeepAlive"] as? [String: Bool] == ["SuccessfulExit": false], "Legacy always-restart policy is migrated")
        try check(commands.count == countBeforeMigration, "Migration never bootouts a running process")
        LaunchAtLogin.refreshExecutablePathIfEnabled()
        try check(try Data(contentsOf: LaunchAtLogin.plistURL) == migratedData, "Migration is idempotent")

        LaunchAtLogin.commandHandler = { args in commands.append(args); throw NSError(domain: "fixture", code: 5) }
        try mustFail { try LaunchAtLogin.setEnabled(false) }
        try check(LaunchAtLogin.isEnabled() && (try Data(contentsOf: LaunchAtLogin.plistURL)) == migratedData, "Disable failure restores prior definition")
        try mustFail { try LaunchAtLogin.setEnabled(true, executablePath: "/usr/bin/false") }
        try check(try Data(contentsOf: LaunchAtLogin.plistURL) == migratedData, "Enable failure restores old executable and settings")
        let restoredAttributes = try FileManager.default.attributesOfItem(atPath: LaunchAtLogin.plistURL.path)
        try check((restoredAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Rollback preserves private permissions")
        try mustFail { try LaunchAtLogin.setEnabled(true, executablePath: "/missing/Nimbo") }
        try check(try Data(contentsOf: LaunchAtLogin.plistURL) == migratedData, "Invalid executable does not erase a valid setting")

        LaunchAtLogin.commandHandler = { args in commands.append(args); return "" }
        commands.removeAll()
        try LaunchAtLogin.setEnabled(false)
        try check(!LaunchAtLogin.isEnabled() && !FileManager.default.fileExists(atPath: LaunchAtLogin.plistURL.path), "Disable removes next-login definition")
        try check(commands.map { $0[0] } == ["disable"], "Disabling never terminates the current process")
        LaunchAtLogin.commandHandler = nil
        try mustFail { try LaunchAtLogin.setEnabled(true, executablePath: "/usr/bin/true") }
        try check(!LaunchAtLogin.isEnabled(), "Missing test runner cannot call real launchctl and rolls back")

        commands.removeAll()
        LaunchAtLogin.commandHandler = { args in
            commands.append(args)
            return args.first == "print" ? "service = {\n\tpid = 4242\n}" : ""
        }
        LaunchAtLogin.unregisterForExit(processID: 4242)
        try check(commands.map { $0[0] } == ["print", "bootout"], "Final cleanup unregisters its own loaded job")
        commands.removeAll()
        LaunchAtLogin.unregisterForExit(processID: 9999)
        try check(commands.map { $0[0] } == ["print"], "Manual copy never stops another instance")
        try check(LaunchAtLogin.loadedPID(in: "pid = 1\npid = 2") == nil, "Ambiguous PID output is rejected")
        try check(LaunchAtLogin.loadedPID(in: "pid = invalid") == nil, "Malformed PID output is rejected")
        try check(LaunchAtLogin.loadedPID(in: "no pid available") == nil, "Unloaded job has no owner")
        LaunchAtLogin.commandHandler = { args in commands.append(args); throw NSError(domain: "fixture", code: 3) }
        commands.removeAll()
        LaunchAtLogin.unregisterForExit(processID: 4242)
        try check(commands.map { $0[0] } == ["print"], "Missing launchd job does not trigger bootout")

        let args = Array(CommandLine.arguments.dropFirst())
        if args.count == 2, args[0] == "--emit-manifest" { try manifest.write(to: URL(fileURLWithPath: args[1])) }
        print("PASS: \(checks) login-service checks; injected launchctl; no production service changed")
        #else
        fatalError("LaunchAtLoginTests requires NIMBO_TESTING")
        #endif
    }
}
