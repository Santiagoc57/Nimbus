#if OAUTH_DESKTOP_TESTS
import Foundation
@main struct OAuthDesktopClientTests {
    static func main() throws {
        let valid = Data(#"{"installed":{"client_id":"synthetic.apps.googleusercontent.com","client_secret":"synthetic-only"}}"#.utf8)
        let client = try OAuthDesktopClient.parse(valid)
        guard client.id == "synthetic.apps.googleusercontent.com", client.secret == "synthetic-only" else { fatalError("Invalid extraction") }
        let invalid = [
            Data(#"{"web":{"client_id":"synthetic.apps.googleusercontent.com","client_secret":"synthetic"}}"#.utf8),
            Data(#"{"installed":{"client_id":"invalid","client_secret":"synthetic"}}"#.utf8),
            Data(#"{"installed":{"client_id":"synthetic.apps.googleusercontent.com","client_secret":""}}"#.utf8),
            Data(#"{"installed":{"client_id":"synthetic.apps.googleusercontent.com","client_secret":"secret\n[Injected]"}}"#.utf8),
            Data(#"{"installed":{"client_id":" synthetic.apps.googleusercontent.com","client_secret":"synthetic"}}"#.utf8),
            Data("not json".utf8), Data(repeating:32,count:65537)
        ]
        for data in invalid {
            do { _ = try OAuthDesktopClient.parse(data); fatalError("Unsafe or unsupported import accepted") }
            catch OAuthDesktopClient.ImportError.invalidDesktopFile {}
        }
        print("PASS: 8 OAuth desktop import checks; synthetic data only")
    }
}
#endif
