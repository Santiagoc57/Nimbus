#if DRIVE_WEB_LINK_TESTS
import Foundation

private final class WebLinkProtocol: URLProtocol {
    static let lock = NSLock()
    static var calls: [URLRequest] = []
    static var mode = "normal"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.lock.lock(); Self.calls.append(request); let mode = Self.mode; Self.lock.unlock()
        let account = request.value(forHTTPHeaderField: "Authorization") == "Bearer secondary" ? "secondary" : "primary"
        let object: [String: Any] = ["id": mode == "wrong-id" ? "other" : "same-id", "name": "test", "mimeType": "text/plain", "trashed": mode == "trashed", "webViewLink": "https://docs.google.com/document/d/same-id/edit?resourcekey=\(account)-key"]
        let data = try! JSONSerialization.data(withJSONObject: object)
        let response = HTTPURLResponse(url: request.url!, statusCode: mode == "denied" ? 403 : 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    static func setMode(_ mode: String) { lock.lock(); Self.mode = mode; lock.unlock() }
    static func snapshot() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return calls }
}
@main struct DriveWebLinkTests {
    static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ name: String) { precondition(value, name); checks += 1 }
        func object(_ link: String?, key: String? = nil) -> DriveObject { DriveObject(id: "same-id", name: "test", mimeType: "text/plain", webViewLink: link, resourceKey: key) }
        let official = "https://docs.google.com/document/d/same-id/edit?resourcekey=a%2Bb&usp=drivesdk#heading=h.test"
        check(try DriveAPI.browserLink(for: object(official)).absoluteString == official, "official editor URL and resource key survive unchanged")
        check(try DriveAPI.browserLink(for: object("https://drive.google.com/file/d/same-id/view")).host == "drive.google.com", "Drive viewer accepted")
        let fallback = try DriveAPI.browserLink(for: object(nil, key: "key+& /"))
        let query = URLComponents(url: fallback, resolvingAgainstBaseURL: false)!.queryItems!
        check(query.first { $0.name == "resourcekey" }?.value == "key+& /", "fallback safely encodes resource key")
        check(query.first { $0.name == "id" }?.value == "same-id", "fallback preserves file identity")
        check(!fallback.absoluteString.contains("/u/0/"), "no first-browser-account routing")
        for value in ["http://drive.google.com/x", "file:///tmp/x", "javascript:alert(1)", "https://drive.google.com.evil.test/x", "https://user:secret@drive.google.com/x", "https://drive.google.com:444/x", "https://example.invalid/x"] {
            var rejected = false
            do { _ = try DriveAPI.browserLink(for: object(value)) } catch { rejected = true }
            check(rejected, "reject untrusted destination " + value)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nimbo-web-links-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("test.conf")
        let body = ["primary", "secondary"].map { "[\($0)]\ntype = drive\nclient_id = synthetic.apps.googleusercontent.com\nclient_secret = synthetic\nscope = drive.readonly\ntoken = {\"access_token\":\"\($0)\",\"refresh_token\":\"unused\",\"expiry\":\"2099-01-01T00:00:00Z\"}\n" }.joined(separator: "\n")
        try Data(body.utf8).write(to: config)
        let settings = URLSessionConfiguration.ephemeral; settings.protocolClasses = [WebLinkProtocol.self]
        let session = URLSession(configuration: settings)
        let first = DriveAPI(configuration: config, remoteName: "primary", session: session)
        let second = DriveAPI(configuration: config, remoteName: "secondary", session: session)
        check(try await first.browserLink("same-id").query?.contains("primary-key") == true, "primary account metadata used")
        check(try await second.browserLink("same-id").query?.contains("secondary-key") == true, "same ID in second account uses second credential")
        let calls = WebLinkProtocol.snapshot()
        check(calls.count == 2 && calls.allSatisfy { $0.httpMethod == "GET" && $0.url?.path == "/drive/v3/files/same-id" }, "preview only reads metadata; no upload, download or sharing mutation")
        check(calls.allSatisfy { $0.url?.query?.contains("resourceKey") == true }, "resource key requested from Google")
        for mode in ["denied", "wrong-id", "trashed"] {
            WebLinkProtocol.setMode(mode); var rejected = false
            do { _ = try await second.browserLink("same-id") } catch { rejected = true }
            check(rejected, "do not open after " + mode)
        }
        let before = WebLinkProtocol.snapshot().count
        do { _ = try await second.browserLink("../unsafe"); fatalError("unsafe ID accepted") } catch {}
        check(WebLinkProtocol.snapshot().count == before, "invalid ID rejected before request")
        print("PASS: \(checks) official-link, resource-key, account-isolation and metadata-only checks; no network")
    }
}
#endif
