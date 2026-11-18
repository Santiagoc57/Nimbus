#if DRIVE_OVERVIEW_TESTS
import Foundation

@main struct DriveOverviewTests {
    static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "DriveOverviewTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1
        }
        let known = try JSONDecoder().decode(DriveAccountOverview.self, from: Data(#"{"storageQuota":{"limit":"1000","usage":"400","usageInDrive":"250"}}"#.utf8))
        try check(known.storageQuota?.freeBytes == 600, "Free space uses total account usage")
        try check(known.storageQuota?.fraction == 0.4, "Usage ratio is exact")
        try check(known.storageQuota?.driveBytes == 250, "Drive usage is kept distinct from account usage")
        let unlimited = DriveStorageQuota(limit:nil, usage:"100", usageInDrive:nil)
        try check(unlimited.fraction == nil && unlimited.freeBytes == nil, "Missing limit must never display a fake zero percent or free space")
        let exceeded = DriveStorageQuota(limit:"100", usage:"200", usageInDrive:nil)
        try check(exceeded.fraction == 1 && exceeded.freeBytes == 0, "Over-quota values are bounded")
        try check(DriveStorageQuota(limit:"0",usage:"0",usageInDrive:nil).fraction == nil, "Zero capacity does not divide by zero")
        try check(DriveStorageQuota(limit:"-1",usage:"1",usageInDrive:nil).limitBytes == nil, "Negative quota is invalid")
        try check(DriveStorageQuota(limit:"9999999999999999999999",usage:"1",usageInDrive:nil).limitBytes == nil, "Overflow is unknown, not wrapped")
        let missing = try JSONDecoder().decode(DriveAccountOverview.self, from: Data("{}".utf8))
        try check(missing.storageQuota == nil, "Partial response remains unknown")
        print("PASS: \(checks) storage overview checks")
        if CommandLine.arguments.count == 2 {
            let config = URL(fileURLWithPath:CommandLine.arguments[1])
            for remote in ["GoogleDrive","GoogleDrive-2"] {
                let overview = try await DriveAPI(configuration:config,remoteName:remote).accountOverview()
                // No account identity, secrets or raw quota values in the test log.
                print("PASS: \(remote) live about request; quota=\(overview.storageQuota != nil); usage=\(overview.storageQuota?.usageBytes != nil); limit=\(overview.storageQuota?.limitBytes != nil)")
            }
        }
    }
}
#endif
