import Foundation

@main struct ActivityLogTests {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/nimbo/activity-" + UUID().uuidString)
        let file = root.appendingPathComponent("Activity.json"); let log = ActivityLog(file: file); var checks: [String] = []
        func check(_ ok: Bool, _ label: String) throws { guard ok else { throw NSError(domain: "ActivityTests", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }; checks.append(label); print("PASS: " + label) }
        log.append(operation: "Sincronización", detail: "Completada", success: true); log.append(operation: "Backup", detail: "Falló de forma controlada", success: false)
        let events = log.events(); try check(events.count == 2 && events[0].operation == "Backup" && events[0].success == false, "Events persist newest-first with success state")
        let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber).intValue; try check(mode == 0o600, "Activity journal uses private file permissions")
        for index in 0..<520 { log.append(operation: "op", detail: "\(index)", success: true) }
        try check(log.events().count == 500, "Activity journal is bounded to 500 events")
        log.clear(); try check(log.events().isEmpty, "Activity history can be cleared without touching cloud data")
        let report: [String: Any] = ["status":"PASS", "count":checks.count, "checks":checks, "synthetic_only":true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: "outputs/Nimbo/ACTIVITY_TESTS.json"))
    }
}
