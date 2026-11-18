import Foundation

@main struct SyncScheduleTests {
    static func main() throws {
        let fm = FileManager.default, workspace = URL(fileURLWithPath: fm.currentDirectoryPath)
        let root = workspace.appendingPathComponent("work/nimbo/schedule-" + UUID().uuidString.prefix(6))
        let remoteRoot = root.appendingPathComponent("remote"), remote = remoteRoot.appendingPathComponent("Proyecto")
        try fm.createDirectory(at: remote, withIntermediateDirectories: true)
        try Data("remote".utf8).write(to: remote.appendingPathComponent("base.txt"), options: .atomic)
        let config = root.appendingPathComponent("rclone.conf")
        try Data("[GoogleDrive]\ntype = alias\nremote = \(remoteRoot.path)\nscope = drive\n".utf8).write(to: config, options: .atomic)
        let binary = workspace.appendingPathComponent("outputs/Nimbo/Nimbo.app/Contents/Resources/rclone")
        let engine = try SyncEngine(root: root.appendingPathComponent("state"), offlineRoot: root.appendingPathComponent("offline"), config: config, binary: binary, testing: true)
        var checks: [String] = []
        func check(_ ok: Bool, _ label: String) throws { guard ok else { throw SyncFailure.message("FAIL: " + label) }; checks.append(label); print("PASS: " + label) }
        let id = try engine.add(remote: "GoogleDrive", item: CloudItem(Path: "Proyecto", Name: "Proyecto", Size: 0, IsDir: true))
        try engine.synchronize(id)
        try engine.setSyncSchedule(id, enabled: true, intervalMinutes: 15)
        try check(engine.syncIsDue(id), "Scheduled sync is due before its first run")
        try engine.synchronize(id)
        let after = engine.relations[0].syncSchedule
        try check(after?.lastRun != nil && after?.lastSuccess != nil, "Scheduled sync records run and success timestamps")
        try check(after?.message == "Sincronización programada: Cada 15 minutos.", "Scheduled status uses the selected human-readable interval")
        try check(!engine.syncIsDue(id), "Successful scheduled sync waits for its interval")
        let before = Date().addingTimeInterval(-16 * 60)
        try check(engine.syncIsDue(id, now: before) == false, "Older reference time does not make a future run due")
        try check(engine.syncIsDue(id, now: Date().addingTimeInterval(16 * 60)), "Elapsed interval makes scheduled sync due")
        let reloaded = try SyncEngine(root: root.appendingPathComponent("state"), offlineRoot: root.appendingPathComponent("offline"), config: config, binary: binary, testing: true)
        try check(reloaded.relations[0].syncSchedule?.intervalMinutes == 15 && reloaded.relations[0].syncSchedule?.enabled == true, "Schedule survives restart")
        try reloaded.setSyncSchedule(id, enabled: false, intervalMinutes: 60)
        try check(reloaded.relations[0].syncSchedule?.enabled == false && reloaded.syncIsDue(id), "Disabling returns to continuous sync")
        var rejected = false
        do { try reloaded.setSyncSchedule(id, enabled: true, intervalMinutes: 2) } catch { rejected = true }
        try check(rejected, "Unsupported sync frequency is rejected")
        let report: [String: Any] = ["status": "PASS", "count": checks.count, "checks": checks, "synthetic_only": true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: workspace.appendingPathComponent("outputs/Nimbo/SYNC_SCHEDULE_TESTS.json"))
    }
}
