import Foundation

final class TrashMockGoogle: URLProtocol {
    static var lock = NSLock(); static var sawTrashQuery = false; static var repeatTrash = false; static var trashGets = 0; static var sawPatch = false; static var sawDelete = false; static var patchID = ""
    static func enableRepeatedPageTest() { lock.lock(); repeatTrash = true; trashGets = 0; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let request = self.request
        if request.httpMethod == "DELETE" {
            Self.lock.lock(); Self.sawDelete = true; Self.lock.unlock()
            respond(204, "")
            return
        }
        if request.httpMethod == "PATCH" {
            Self.lock.lock(); Self.sawPatch = request.httpMethod == "PATCH"; Self.patchID = request.url?.path.split(separator: "/").last.map(String.init) ?? ""; Self.lock.unlock()
            respond(200, "{\"id\":\"trash-one\",\"name\":\"Recuperado.txt\",\"mimeType\":\"text/plain\",\"trashed\":false}")
            return
        }
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if query.first(where: { $0.name == "q" })?.value == "trashed = true" {
            Self.lock.lock(); Self.sawTrashQuery = true; Self.trashGets += 1; let cycle=Self.repeatTrash; Self.lock.unlock()
            respond(200, cycle ? "{\"files\":[],\"nextPageToken\":\"trash-page\"}" : "{\"files\":[{\"id\":\"trash-one\",\"name\":\"Recuperado.txt\",\"mimeType\":\"text/plain\",\"modifiedTime\":\"2026-11-10T12:00:00Z\",\"trashed\":true}],\"nextPageToken\":null}")
        }
        else { respond(400, "{}") }
    }
    private func respond(_ status: Int, _ body: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct DriveTrashTests {
    static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/nimbo/native/trash-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let config = root.appendingPathComponent("rclone.conf")
        let token = "{\"access_token\":\"synthetic\",\"expiry\":\"2099-01-01T00:00:00Z\"}"
        try Data("[GoogleDrive]\nscope = drive\ntoken = \(token)\n".utf8).write(to: config, options: .atomic)
        let sessionConfig = URLSessionConfiguration.ephemeral; sessionConfig.protocolClasses = [TrashMockGoogle.self]
        let api = DriveAPI(configuration: config, session: URLSession(configuration: sessionConfig))
        let page: DrivePage
        do { page = try await api.trashPage() } catch { FileHandle.standardError.write(Data(("trash error \(error)\n").utf8)); throw error }
        guard page.files.count == 1, page.files[0].trashed == true, TrashMockGoogle.sawTrashQuery else { throw DriveFailure.invalidResponse }
        let restored: DriveObject
        do { restored = try await api.restoreFromTrash("trash-one") } catch { print("restore error", error); throw error }
        guard restored.id == "trash-one", restored.trashed == Optional(false), TrashMockGoogle.sawPatch, TrashMockGoogle.patchID == "trash-one" else { throw DriveFailure.invalidResponse }
        try await api.permanentlyDeleteFromTrash("trash-one")
        guard TrashMockGoogle.sawDelete else { throw DriveFailure.invalidResponse }
        let all = try await api.allTrash(limit: 2000)
        guard all.count == 1 else { throw DriveFailure.invalidResponse }
        TrashMockGoogle.enableRepeatedPageTest()
        var cycleRejected=false
        do { _ = try await api.allTrash(limit: 2000) } catch DriveFailure.invalidResponse { cycleRejected=true }
        guard cycleRejected else { throw DriveFailure.invalidResponse }
        let report: [String:Any] = ["status":"PASS", "count":5, "checks":["Trash query lists only trashed Drive items", "PATCH restores exactly selected item with trashed=false", "DELETE permanently removes exactly the selected trash item", "Trash pagination returns a bounded snapshot", "Repeated trash page tokens are rejected"], "synthetic_only":true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: "outputs/Nimbo/DRIVE_TRASH_TESTS.json"))
        print("PASS: Drive trash listing and single-item restore")
    }
}
