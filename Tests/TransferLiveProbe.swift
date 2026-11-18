#if TRANSFER_LIVE_PROBE
import Foundation
import CryptoKit

@main struct TransferLiveProbe {
    static func require(_ value: Bool) throws { if !value { throw DriveFailure.invalidResponse } }
    static func waitFor(_ test: () -> NimboTransfer?) async throws -> NimboTransfer {
        for _ in 0..<600 {
            if let value = test() { return value }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw DriveFailure.unavailable
    }
    static func exercise(_ backend: CloudBackend, item: CloudItem, destination: URL, expected: Data) async throws -> [String: Any] {
        let first = Task.detached { try backend.download(remote: "GoogleDrive", item: item, destinationDirectory: destination) }
        var second: Task<URL, Error>?
        do {
            let firstRow = try await waitFor { TransferCenter.shared.active().first { $0.completedBytes > 0 && $0.completedBytes < $0.totalBytes && ($0.bytesPerSecond ?? 0) > 0 && $0.estimatedSeconds != nil } }
            second = Task.detached { try backend.download(remote: "GoogleDrive", item: item, destinationDirectory: destination) }
            let other = try await waitFor { TransferCenter.shared.active().first { $0.id != firstRow.id && $0.completedBytes > 0 && $0.completedBytes < $0.totalBytes } }
            try require(TransferCenter.shared.requestCancellation(other.id))
            var cancellationConfirmed = false
            do { _ = try await second!.value } catch CloudBackendError.cancelled { cancellationConfirmed = true }
            let downloaded = try await first.value
            try require(cancellationConfirmed && (try Data(contentsOf: downloaded)) == expected)
            let rows = TransferCenter.shared.recent()
            let success = rows.first { $0.id == firstRow.id }!, cancelled = rows.first { $0.id == other.id }!
            try require(success.state == .completed && success.verified && cancelled.state == .cancelled && !cancelled.verified)
            try require(try FileManager.default.contentsOfDirectory(atPath: destination.path).count == 1)
            return ["liveProgressObserved": true, "sampleBytes": firstRow.completedBytes,
                    "sampleSpeed": firstRow.bytesPerSecond ?? 0, "sampleETA": firstRow.estimatedSeconds ?? -1,
                    "completedBytes": success.completedBytes, "cancelledBytes": cancelled.completedBytes,
                    "cancelDidNotStopOtherDownload": true, "partialFilesRemoved": true,
                    "downloadMatchesSyntheticOriginal": true]
        } catch {
            backend.cancelAll()
            _ = await first.result
            if let second { _ = await second.result }
            throw error
        }
    }
    static func main() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("NimboTransferProbe-" + UUID().uuidString)
        var report: [String: Any] = ["result": "FAIL"], uploadedID: String?, writer: DriveWriteAPI?
        let marker = URL(fileURLWithPath: "work/nimbo/transfer-live-fixture.json")
        do {
            guard CommandLine.arguments.count == 3 else { throw DriveFailure.invalidResponse }
            let support = URL(fileURLWithPath: CommandLine.arguments[1]), config = support.appendingPathComponent(".rclone-runtime.conf")
            guard fm.fileExists(atPath: config.path) else { throw DriveFailure.notAuthenticated }
            try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let destination = root.appendingPathComponent("Downloads")
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            TransferCenter.shared.configure(support: root)
            let api = DriveAPI(configuration: config)
            try require(try await api.permitsWrites())
            let drive = DriveWriteAPI(api: api); writer = drive
            let id = try await drive.allocateID(), name = "Nimbo-transfer-probe-" + UUID().uuidString + ".bin"
            let data = Data(repeating: 0x43, count: 16 * 1024 * 1024), file = root.appendingPathComponent(name)
            try data.write(to: file)
            uploadedID = id
            try JSONSerialization.data(withJSONObject: ["id": id, "name": name, "synthetic": true]).write(to: marker, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
            let upload = try await drive.beginUpload(id: id, parent: "root", name: name, mime: "application/octet-stream", file: file, baseETag: nil)
            _ = try await drive.upload(file, session: upload, checkpoint: { _ in })
            let backend = CloudBackend(configURL: config, binaryURL: URL(fileURLWithPath: CommandLine.arguments[2]), cacheDirectory: root.appendingPathComponent("Catalogs"), downloadBandwidthKBps: 1024)
            let item = CloudItem(Path: name, Name: name, Size: Int64(data.count), IsDir: false, ID: id, MimeType: "application/octet-stream")
            report.merge(try await exercise(backend, item: item, destination: destination, expected: data)) { _, new in new }
            report["result"] = "PASS"
        } catch { report["errorCode"] = (error as NSError).code }
        if let uploadedID, let writer {
            do {
                let current = try await writer.revision(uploadedID)
                _ = try await writer.updateMetadata(uploadedID, etag: current.etag, trashed: true)
                report["syntheticFixtureTrashed"] = true
                try? fm.removeItem(at: marker)
            } catch DriveFailure.notFound { report["syntheticFixtureAbsent"] = true; try? fm.removeItem(at: marker) }
            catch { report["cleanup"] = "PENDING"; report["result"] = "FAIL" }
        }
        try? fm.removeItem(at: root)
        report["testedAt"] = ISO8601DateFormatter().string(from: Date())
        if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), let text = String(data: bytes, encoding: .utf8) { print(text) }
        else { print("{\"result\":\"FAIL\",\"reason\":\"report encoding\"}") }
        if report["result"] as? String != "PASS" { exit(1) }
    }
}
#endif
