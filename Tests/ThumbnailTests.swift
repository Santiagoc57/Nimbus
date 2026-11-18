#if THUMBNAIL_TESTS
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

final class ThumbnailGoogle: URLProtocol {
    static let lock = NSLock()
    static var mode = "ok", image = Data(), requests: [URLRequest] = []
    static var active = 0, maximumActive = 0
    private var counted = false, stopped = false
    static func reset(_ mode: String, image: Data) {
        lock.lock(); self.mode = mode; self.image = image; requests = []; active = 0; maximumActive = 0; lock.unlock()
    }
    static func snapshot() -> ([URLRequest], Int) { lock.lock(); defer { lock.unlock() }; return (requests, maximumActive) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request); let mode = Self.mode, png = Self.image; Self.lock.unlock()
        let url = request.url!
        if url.host == "oauth2.googleapis.com" {
            reply(Data("{\"access_token\":\"fresh-preview\",\"expires_in\":3600}".utf8), mime: "application/json"); return
        }
        if url.host == "www.googleapis.com" {
            var meta: [String: Any] = ["id": url.lastPathComponent, "mimeType": "image/png", "thumbnailLink": "https://lh3.googleusercontent.com/preview"]
            if mode == "absent" { meta.removeValue(forKey: "thumbnailLink") }
            if mode == "folder" { meta["mimeType"] = "application/vnd.google-apps.folder" }
            if mode == "denied" { meta["capabilities"] = ["canDownload": false] }
            if mode == "evil" { meta["thumbnailLink"] = "https://example.invalid/private" }
            reply(try! JSONSerialization.data(withJSONObject: meta), mime: "application/json"); return
        }
        Self.lock.lock(); counted = true; Self.active += 1; Self.maximumActive = max(Self.maximumActive, Self.active); Self.lock.unlock()
        if mode == "slow" { return }
        if mode == "delayed" {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) { self.reply(png) }; return
        }
        if mode == "image401", request.value(forHTTPHeaderField: "Authorization") != "Bearer fresh-preview" { reply(Data(), status: 401); return }
        if mode == "html" { reply(Data("<html>not a preview</html>".utf8), mime: "text/html"); return }
        if mode == "redirect" { reply(Data(), status: 302, extra: ["Location": "https://example.invalid/steal"]); return }
        if mode == "length" { reply(png, extra: ["Content-Length": "3000000"]); return }
        if mode == "stream" { reply(Data(repeating: 1, count: 2 * 1024 * 1024 + 1)); return }
        reply(png)
    }
    private func reply(_ data: Data, mime: String = "image/png", status: Int = 200, extra: [String: String] = [:]) {
        Self.lock.lock()
        if stopped { Self.lock.unlock(); return }
        if counted { Self.active -= 1; counted = false }
        Self.lock.unlock()
        var headers = ["Content-Type": mime]; extra.forEach { headers[$0] = $1 }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        Self.lock.lock(); stopped = true
        if counted { Self.active -= 1; counted = false }
        Self.lock.unlock()
    }
}

@main
struct ThumbnailTests {
    static var checks = 0
    static func check(_ condition: Bool, _ name: String) throws {
        guard condition else { throw NSError(domain: "ThumbnailTests", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
        checks += 1
    }
    static func mustFail(_ body: () async throws -> Void) async throws {
        var failed = false; do { try await body() } catch { failed = true }
        try check(failed, "Expected invalid thumbnail to fail")
    }
    static func png(width: Int = 512, height: Int = 256) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData(), image = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFSoftware: "PRIVATE-FIXTURE-METADATA"]] as CFDictionary)
        precondition(CGImageDestinationFinalize(dest)); return out as Data
    }
    static func entry(_ id: String, remote: String = "GoogleDrive", time: String = "2026-11-17T00:00:00Z") -> RemoteEntry {
        RemoteEntry(remote: remote, item: CloudItem(Path: id + ".png", Name: id + ".png", Size: 1000, IsDir: false, ModTime: time, ID: id, MimeType: "image/png"))
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NimboThumbnailTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var keys: [String] = []
        defer { keys.forEach { NimboSecureFile.removeFallbackKey(account: $0) }; try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("fixture.conf")
        try Data("[GoogleDrive]\nclient_id = synthetic.apps.googleusercontent.com\nclient_secret = GOCSPX-synthetic\ntoken = {\"access_token\":\"synthetic-preview\",\"refresh_token\":\"fake-refresh\",\"expiry\":\"2099-01-01T00:00:00Z\"}\n".utf8).write(to: config)
        let settings = URLSessionConfiguration.ephemeral; settings.protocolClasses = [ThumbnailGoogle.self]
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel() }
        let api = DriveAPI(configuration: config, session: session), image = png()
        ThumbnailGoogle.reset("ok", image: image)
        let downloaded = try await api.thumbnail("one")
        try check(downloaded == image, "Preview bytes are fetched separately")
        var calls = ThumbnailGoogle.snapshot().0
        try check(calls.count == 2 && calls.allSatisfy { !($0.url?.absoluteString.contains("alt=media") ?? false) && !($0.url?.path.contains("export") ?? false) }, "Only metadata and thumbnail are requested")
        try check(calls.last?.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-preview", "Private thumbnail request is authenticated")
        for mode in ["absent", "folder", "denied"] {
            ThumbnailGoogle.reset(mode, image: image)
            let absent = try await api.thumbnail("one")
            try check(absent == nil && ThumbnailGoogle.snapshot().0.count == 1, "Unavailable preview never requests the file body")
        }
        for mode in ["evil", "html", "redirect", "length", "stream"] {
            ThumbnailGoogle.reset(mode, image: image)
            try await mustFail { _ = try await api.thumbnail("one") }
            try check(ThumbnailGoogle.snapshot().0.allSatisfy { $0.url?.host != "example.invalid" }, "No credential sent to external/redirect target")
        }
        for url in ["http://lh3.googleusercontent.com/p", "https://lh3.googleusercontent.com.evil.test/p", "https://user@lh3.googleusercontent.com/p", "https://lh3.googleusercontent.com:444/p", "https://www.googleapis.com/drive/v3/files/one?alt=media"] {
            try check(!DriveAPI.isThumbnailURL(URL(string: url)!), "Unsafe thumbnail URL rejected")
        }
        ThumbnailGoogle.reset("image401", image: image)
        let refreshed = try await api.thumbnail("one")
        calls = ThumbnailGoogle.snapshot().0
        try check(refreshed == image && calls.filter { $0.url?.host == "oauth2.googleapis.com" }.count == 1, "Thumbnail 401 refreshes credentials once")
        ThumbnailGoogle.reset("slow", image: image)
        let cancelled = Task { try await api.thumbnail("one") }
        for _ in 0..<100 {
            if ThumbnailGoogle.snapshot().0.count >= 2 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        cancelled.cancel()
        try await mustFail { _ = try await cancelled.value }

        let normalized = try ThumbnailCache.normalized(image)
        let source = CGImageSourceCreateWithData(normalized as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
        try check(properties[kCGImagePropertyPixelWidth] as? Int == 256, "Decoded preview is reduced to 256 pixels")
        try check(properties[kCGImagePropertyTIFFDictionary] == nil, "Remote image metadata is stripped")
        try await mustFail { _ = try ThumbnailCache.normalized(Data("not an image".utf8)) }
        try await mustFail { _ = try ThumbnailCache.normalized(png(width: 4097, height: 1)) }
        let cache = ThumbnailCache(support: root.appendingPathComponent("cache"), maximumFiles: 2)
        keys.append(await cache.keyAccount)
        let one = entry("one"), two = entry("two"), three = entry("three")
        try await cache.store(normalized, for: one)
        try check(await cache.read(one)?.data == normalized, "Cached preview is readable")
        let expired = await cache.read(one, now: Date().addingTimeInterval(8 * 86400))
        try check(expired == nil, "Expired previews are refreshed")
        try check(await cache.read(entry("one", time: "2026-11-18T00:00:00Z")) == nil, "Changed remote version invalidates preview")
        try check(await cache.read(entry("one", remote: "Other")) == nil, "Accounts cannot share private previews by Drive ID")
        try await cache.store(nil, for: two)
        let negative = await cache.read(two)
        try check(negative != nil && negative?.data == nil, "Missing previews are negatively cached")
        try check(await cache.read(two, now: Date().addingTimeInterval(601)) == nil, "Negative cache has short expiry")
        try await cache.store(normalized, for: three)
        let cacheRoot = cache.root
        let files = FileManager.default.enumerator(at: cacheRoot, includingPropertiesForKeys: nil)!.allObjects.compactMap { $0 as? URL }.filter { $0.pathExtension == "thumb" }
        try check(files.count == 2, "Cache file count is bounded")
        let bytes = try Data(contentsOf: files[0])
        let attrs = try FileManager.default.attributesOfItem(atPath: files[0].path)
        try check(bytes.starts(with: Data("NIMBO-ENC-1\n".utf8)) && (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Previews are encrypted and private")
        try await cache.removeAccounts(except: [])
        try check(await cache.read(three) == nil, "Disconnect removes account previews")

        let tinyCache = ThumbnailCache(support: root.appendingPathComponent("tiny"), maximumBytes: 100)
        keys.append(await tinyCache.keyAccount)
        try await tinyCache.store(normalized, for: one)
        try check(await tinyCache.read(one) == nil, "A preview exceeding the total byte budget is evicted")

        ThumbnailGoogle.reset("delayed", image: image)
        let service = CloudThumbnails(configuration: config, support: root.appendingPathComponent("service"), session: session, concurrency: 2)
        let serviceCache = service.cache; keys.append(await serviceCache.keyAccount)
        await service.setAccounts(["GoogleDrive"])
        async let first = service.thumbnail(one)
        async let second = service.thumbnail(one)
        let pair = await (first, second)
        try check(pair.0 != nil && pair.0 == pair.1 && ThumbnailGoogle.snapshot().0.count == 2, "Concurrent consumers coalesce one preview request")
        let before = ThumbnailGoogle.snapshot().0.count
        _ = await service.thumbnail(one)
        try check(ThumbnailGoogle.snapshot().0.count == before, "Cache hits avoid network")
        await withTaskGroup(of: Data?.self) { group in
            for n in 0..<8 { group.addTask { await service.thumbnail(entry("parallel-\(n)")) } }
            for await _ in group {}
        }
        try check(ThumbnailGoogle.snapshot().1 <= 2, "Network concurrency is bounded")

        ThumbnailGoogle.reset("delayed", image: image)
        let sharedEntry = entry("shared-cancel")
        let departing = Task { await service.thumbnail(sharedEntry) }
        let remaining = Task { await service.thumbnail(sharedEntry) }
        for _ in 0..<100 {
            if ThumbnailGoogle.snapshot().0.count >= 2 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        departing.cancel()
        let survivingImage = await remaining.value
        let cancelledImage = await departing.value
        try check(survivingImage != nil && cancelledImage == nil && ThumbnailGoogle.snapshot().0.count == 2,
                  "Cancelling one consumer preserves the shared request for another")

        ThumbnailGoogle.reset("slow", image: image)
        let busy = (0..<6).map { n in Task { await service.thumbnail(entry("cancel-queue-\(n)")) } }
        for _ in 0..<100 {
            if ThumbnailGoogle.snapshot().0.count >= 4 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        busy.forEach { $0.cancel() }
        for task in busy { try check(await task.value == nil, "Cancelled queued/inflight preview terminates") }
        ThumbnailGoogle.reset("ok", image: image)
        let afterCancellation = await service.thumbnail(entry("after-cancellation"))
        try check(afterCancellation != nil, "Cancellation returns permits for subsequent previews")
        await service.setAccounts([])
        try check(await service.thumbnail(one) == nil, "Disconnected account cannot fetch previews")
        print("PASS: \(checks) thumbnail checks; synthetic credentials and images; no real network")
    }
}
#endif
