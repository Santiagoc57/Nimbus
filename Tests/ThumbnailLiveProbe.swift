#if THUMBNAIL_LIVE_PROBE
import Foundation
import ImageIO

/// Read-only Drive preview probe. Does not print file names, IDs, links,
/// credentials or image content. Uses the running app's existing configuration.
@main
struct ThumbnailLiveProbe {
    static func main() async {
        do {
            let arguments = CommandLine.arguments
            guard arguments.count == 3 else { throw DriveFailure.invalidResponse }
            let support = URL(fileURLWithPath: arguments[1], isDirectory: true)
            let config = support.appendingPathComponent(".rclone-runtime.conf")
            guard FileManager.default.fileExists(atPath: config.path) else { throw DriveFailure.notAuthenticated }
            let backend = CloudBackend(configURL: config, binaryURL: URL(fileURLWithPath: arguments[2]), cacheDirectory: support.appendingPathComponent("Catalogs"))
            var attempts = 0
            for remote in try backend.listRemotes() {
                guard let cache = try backend.loadCache(remote: remote) else { continue }
                let candidates = cache.entries.filter { !$0.IsDir && $0.ID != nil && ($0.MimeType?.hasPrefix("image/") ?? false) }
                let api = DriveAPI(configuration: config, remoteName: remote)
                for item in candidates.prefix(3) {
                    attempts += 1
                    guard let raw = try await api.thumbnail(item.ID!) else { continue }
                    let image = try ThumbnailCache.normalized(raw)
                    guard let source = CGImageSourceCreateWithData(image as CFData, nil),
                          let dimensions = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { throw DriveFailure.invalidResponse }
                    let report: [String: Any] = ["result": "PASS", "attempts": attempts,
                        "previewBytes": raw.count, "normalizedBytes": image.count,
                        "width": dimensions[kCGImagePropertyPixelWidth] ?? 0,
                        "height": dimensions[kCGImagePropertyPixelHeight] ?? 0,
                        "originalDownloaded": false, "driveModified": false,
                        "imageRetained": false, "testedAt": ISO8601DateFormatter().string(from: Date())]
                    print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
                    return
                }
            }
            print("{\"result\":\"UNCONFIRMED\",\"reason\":\"No cached image with available preview\"}")
            exit(2)
        } catch {
            // Error text can contain a path or server body. Report only type/code.
            let e = error as NSError
            print("{\"result\":\"FAIL\",\"errorCode\":\(e.code)}")
            exit(1)
        }
    }
}
#endif
