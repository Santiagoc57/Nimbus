import Foundation

final class SharedMockGoogle: URLProtocol {
    static var sawDrives = false
    static var cycle = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.path == "/drive/v3/drives" {
            Self.sawDrives = true
            let token=URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name=="pageToken"})?.value
            if Self.cycle { respond(200, "{\"drives\":[],\"nextPageToken\":\"next\"}") }
            else if token == "next" { respond(200, "{\"drives\":[{\"id\":\"1XYZ\",\"name\":\"Equipo Norte\",\"createdTime\":\"2026-02-03T04:05:06Z\",\"hidden\":false}]}") }
            else { respond(200, "{\"drives\":[{\"id\":\"0ABC\",\"name\":\"Equipo Café\",\"createdTime\":\"2026-01-02T03:04:05Z\",\"hidden\":false}],\"nextPageToken\":\"next\"}") }
        }
        else { respond(400, "{}") }
    }
    private func respond(_ status: Int, _ body: String) { let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!; client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() {}
}

@main struct DriveSharedTests {
    static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/nimbo/shared-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let config = root.appendingPathComponent("rclone.conf")
        try Data("[GoogleDrive]\nscope = drive\ntoken = {\"access_token\":\"synthetic\",\"expiry\":\"2099-01-01T00:00:00Z\"}\n".utf8).write(to: config, options: .atomic)
        let sessionConfig = URLSessionConfiguration.ephemeral; sessionConfig.protocolClasses = [SharedMockGoogle.self]
        let api = DriveAPI(configuration: config, session: URLSession(configuration: sessionConfig)); let page = try await api.sharedDrives(); let all = try await api.allSharedDrives()
        guard page.drives.count == 1, page.drives[0].id == "0ABC", page.drives[0].name == "Equipo Café", page.nextPageToken == "next", all.map(\.id) == ["0ABC","1XYZ"], SharedMockGoogle.sawDrives else { throw DriveFailure.invalidResponse }
        SharedMockGoogle.cycle = true
        var rejected=false
        do { _ = try await api.allSharedDrives() } catch DriveFailure.invalidResponse { rejected=true }
        guard rejected else { throw DriveFailure.invalidResponse }
        let report: [String: Any] = ["status":"PASS", "count":4, "checks":["Shared Drive metadata decodes with Unicode names", "Drive listing preserves pagination token", "Shared Drive helper follows every page with a bounded repeated-token guard", "Repeated Shared Drive page tokens are rejected"], "synthetic_only":true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: "outputs/Nimbo/DRIVE_SHARED_TESTS.json"))
        print("PASS: Shared Drive discovery and pagination")
    }
}
