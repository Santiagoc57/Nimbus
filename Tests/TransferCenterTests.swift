#if TRANSFER_TESTS
import Foundation

@main
struct TransferCenterTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw NSError(domain: "TransferCenterTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        checks += 1
    }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NimboTransferTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = TransferCenter()
        ledger.configure(support: root)
        func row(_ id: UUID) -> NimboTransfer { ledger.recent().first { $0.id == id }! }

        let failed = ledger.begin(remote: "Fixture", name: "partial", operation: "Descarga", totalBytes: 100)
        ledger.update(failed, completedBytes: 27)
        ledger.finish(failed, verified: true, error: "Connection interrupted")
        try check(row(failed).state == .failed, "Failure is terminal")
        try check(row(failed).completedBytes == 27 && row(failed).fraction == 0.27, "Failure preserves measured progress")
        try check(!row(failed).verified, "Failure cannot claim verification")
        ledger.update(failed, completedBytes: 100, verified: true)
        ledger.finish(failed, verified: true)
        try check(row(failed).completedBytes == 27 && row(failed).state == .failed, "Late callbacks cannot overwrite a failure")

        let empty = ledger.begin(remote: "Fixture", name: "early failure", operation: "Descarga", totalBytes: 200)
        ledger.finish(empty, verified: false, error: "Unavailable")
        try check(row(empty).completedBytes == 0 && row(empty).fraction == 0, "Failure before progress stays at zero")

        let success = ledger.begin(remote: "Fixture", name: "complete", operation: "Descarga", totalBytes: 100)
        ledger.update(success, completedBytes: 100)
        ledger.finish(success, verified: true)
        try check(row(success).fraction == 1 && row(success).verified && row(success).state == .completed, "Successful known-size completion")
        ledger.update(success, completedBytes: 5)
        ledger.finish(success, verified: false, error: "Late error")
        try check(row(success).state == .completed && row(success).completedBytes == 100, "Late callback cannot regress success")

        let export = ledger.begin(remote: "Fixture", name: "export", operation: "Descarga", totalBytes: -1)
        ledger.update(export, completedBytes: 375)
        ledger.finish(export, verified: false)
        try check(row(export).fraction == nil && row(export).completedBytes == 375, "Unknown-size export records bytes without inventing a percentage")
        try check(!row(export).verified && ledger.active().isEmpty, "Terminal exports are no longer active")

        let restored = TransferCenter()
        restored.configure(support: root)
        try check(restored.recent() == ledger.recent(), "Failure and success states survive reload")
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("Transfers.json").path)
        try check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Ledger stays private")

        let active = ledger.begin(remote: "Fixture", name: "cancel", operation: "Descarga", totalBytes: 100, canCancel: true)
        let stats = RcloneProgress.decode(Data("{\"stats\":{\"bytes\":27,\"totalBytes\":100,\"speed\":12.5,\"eta\":6}}".utf8))!
        ledger.progress(active, snapshot: stats)
        try check(row(active).completedBytes == 27 && row(active).bytesPerSecond == 12.5 && row(active).estimatedSeconds == 6, "Measured stats reach the ledger")
        try check(ledger.requestCancellation(active) && !ledger.canCancel(active), "Individual cancellation is requested once")
        try check(!ledger.finish(active, verified: true), "Cancellation wins over late success")
        try check(row(active).state == .cancelled && row(active).completedBytes == 27 && !row(active).verified, "Cancellation preserves bytes and cannot claim success")
        ledger.progress(active, snapshot: stats)
        try check(row(active).bytesPerSecond == nil && row(active).estimatedSeconds == nil, "Late progress cannot revive a completed transfer")
        let unmeasured = ledger.begin(remote: "Fixture", name: "no measurement", operation: "Descarga", totalBytes: 100)
        ledger.finish(unmeasured, verified: false)
        try check(row(unmeasured).completedBytes == 0, "Success alone does not fabricate byte measurements")
        for text in ["not json", "{\"msg\":\"PRIVATE\"}", "{\"stats\":{\"bytes\":-1}}", "{\"stats\":{\"bytes\":1,\"speed\":-2}}"] {
            try check(RcloneProgress.decode(Data(text.utf8)) == nil, "Malformed or non-stat lines cannot become progress")
        }
        let interrupted = ledger.begin(remote: "Fixture", name: "interrupted", operation: "Descarga", totalBytes: 100, canCancel: true)
        let journal = root.appendingPathComponent("Transfers.json")
        var records = ledger.recent(); records.append(row(interrupted))
        try JSONEncoder().encode(records).write(to: journal)
        let recovered = TransferCenter(); recovered.configure(support: root)
        try check(recovered.recent().filter { $0.id == interrupted }.count == 1 && recovered.active().isEmpty, "Restart deduplicates records and reports interrupted work")
        try check(recovered.recent().first { $0.id == interrupted }?.state == .failed, "A stale running record is not presented as a live transfer")
        print("PASS: \(checks) transfer checks")
    }
}
#endif
