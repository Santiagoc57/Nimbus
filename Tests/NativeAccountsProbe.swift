#if NATIVE_ACCOUNTS_PROBE
import Foundation

/// Reads only root metadata through each existing account's own authorization.
/// Does not print root IDs, account emails, tokens or user filenames.
@main struct NativeAccountsProbe {
    static func main() async {
        guard CommandLine.arguments.count==2 else{exit(2)}
        let config=URL(fileURLWithPath:CommandLine.arguments[1])
        var rows:[[String:Any]]=[],ids=[String](),success=true
        for remote in ["GoogleDrive","GoogleDrive-2"] {
            let api=DriveAPI(configuration:config,remoteName:remote)
            do {
                let root=try await api.item("root")
                guard root.isFolder else{throw DriveFailure.invalidResponse}
                ids.append(root.id)
                rows.append(["remote":remote,"authenticatedRootRead":"PASS","writeScope":try await api.permitsWrites()])
            } catch {
                success=false
                rows.append(["remote":remote,"authenticatedRootRead":"FAIL","errorDomain":(error as NSError).domain,"errorCode":(error as NSError).code])
            }
        }
        let distinct=ids.count==2 && Set(ids).count==2
        let report:[String:Any]=["result":success && distinct ? "PASS":"FAIL","accounts":rows,"distinctDriveRoots":distinct,"requestedContentDownloads":0,"testedAt":ISO8601DateFormatter().string(from:Date())]
        if let data=try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),let text=String(data:data,encoding:.utf8){print(text)}
        if !success || !distinct{exit(1)}
    }
}
#endif
