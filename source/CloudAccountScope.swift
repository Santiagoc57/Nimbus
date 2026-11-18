import Foundation
import CryptoKit

enum CloudAccountScope {
    // Preserve primary domains; other accounts must never share credentials or
    // a File Provider domain even if they can access the same shared drive.
    static func sharedDomainIdentifier(remote: String, driveID: String) -> String {
        if remote == "GoogleDrive" { return "google-drive-shared-" + driveID }
        let data = Data((String(remote.utf8.count) + ":" + remote + driveID).utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "google-drive-shared-account-" + digest
    }
}
