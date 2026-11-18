#if NATIVE_FINDER_CYCLE_PROBE
import Foundation
import Darwin

/// Exercises only one UUID-named fixture in an existing Nimbo domain. The
/// command host is invoked directly in its non-GUI mode, never via `open`.
#if !NATIVE_FOLDER_CYCLE_PROBE && !NATIVE_SAFETY_PROBE && !NATIVE_READONLY_PROBE
@main
#endif
struct NativeFinderCycleProbe {
    static func require(_ value: Bool) throws { if !value { throw DriveFailure.invalidResponse } }
    static func coordinateWrite(_ file: URL, bytes: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                var error: NSError?, outcome: Result<Void, Error>?
                NSFileCoordinator().coordinate(writingItemAt: file, options: [], error: &error) { coordinated in
                    outcome = Result { try bytes.write(to: coordinated, options: .atomic) }
                }
                continuation.resume(with: outcome ?? .failure(error ?? CocoaError(.fileWriteUnknown)))
            }
        }
    }
    static func command(_ executable: URL, args: [String], work: URL) throws -> Data {
        let output = work.appendingPathComponent(UUID().uuidString + ".out"), errors = work.appendingPathComponent(UUID().uuidString + ".err")
        let fm = FileManager.default
        fm.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        fm.createFile(atPath: errors.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let out = try FileHandle(forWritingTo: output), err = try FileHandle(forWritingTo: errors)
        defer { try? out.close(); try? err.close(); try? fm.removeItem(at: output); try? fm.removeItem(at: errors) }
        let process = Process(); process.executableURL = executable; process.arguments = args
        process.standardInput = FileHandle.nullDevice; process.standardOutput = out; process.standardError = err
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + 80
        while process.isRunning {
            if ProcessInfo.processInfo.systemUptime > deadline {
                process.terminate()
                for _ in 0..<20 where process.isRunning { Thread.sleep(forTimeInterval: 0.05) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit(); throw DriveFailure.unavailable
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        let data = try Data(contentsOf: output)
        guard data.count < 1024 * 1024 else { throw DriveFailure.invalidResponse }
        guard process.terminationStatus == 0 else {
            // Preserve the structured command error for diagnosis, never logs
            // from authenticated transports or names of unrelated files.
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: work.appendingPathComponent("command-error.json"))
            }
            throw DriveFailure.unavailable
        }
        return data
    }
    static func state(_ action: String, file: URL, host: URL, work: URL) throws -> [String: Any] {
        let data = try command(host, args: ["--native-file-action", action, "--path", file.path], work: work)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], json["result"] as? String == "OK" else { throw DriveFailure.invalidResponse }
        return json
    }
    static func awaitState(dataless: Bool, pinned: Bool, file: URL, host: URL, work: URL) async throws -> [String: Any] {
        for _ in 0..<30 {
            let value = try state("status", file: file, host: host, work: work)
            if value["dataless"] as? Bool == dataless && value["pinned"] as? Bool == pinned && value["providerDownloaded"] as? Bool == !dataless { return value }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw DriveFailure.unavailable
    }
    static func main() async {
        let fm = FileManager.default
        let work = URL(fileURLWithPath: "work/nimbo/native-cycle-" + UUID().uuidString)
        var report: [String: Any] = ["result": "FAIL"], id: String?, writer: DriveWriteAPI?, file: URL?, phase = "setup"
        do {
            guard CommandLine.arguments.count == 4 else { throw DriveFailure.invalidResponse }
            let support = URL(fileURLWithPath: CommandLine.arguments[1]), host = URL(fileURLWithPath: CommandLine.arguments[2]), mount = URL(fileURLWithPath: CommandLine.arguments[3])
            let config = support.appendingPathComponent(".rclone-runtime.conf")
            guard fm.fileExists(atPath: config.path), mount.lastPathComponent.hasPrefix("Nimbo-GoogleDrive") else { throw DriveFailure.notAuthenticated }
            try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let api = DriveAPI(configuration: config), drive = DriveWriteAPI(api: api); writer = drive
            let name = "Nimbo-availability-probe-" + UUID().uuidString + ".txt"
            let target = mount.appendingPathComponent(name); file = target
            let expected = Data(String(repeating: "Nimbo synthetic availability fixture.\n", count: 128).utf8)
            try JSONSerialization.data(withJSONObject: ["path": target.path, "synthetic": true]).write(to: work.appendingPathComponent("cleanup.json"))
            phase = "native-create-upload"
            try await coordinateWrite(target, bytes: expected)
            let reference = work.appendingPathComponent("expected.txt"); try expected.write(to: reference)
            let checksum = try DriveWriteAPI.fingerprint(reference).md5
            var url = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            url.queryItems = [.init(name: "q", value: "'root' in parents and name = '\(name)' and trashed = false"), .init(name: "fields", value: "files(\(DriveAPI.fields))"), .init(name: "pageSize", value: "10")]
            for _ in 0..<60 {
                let (data, response) = try await api.send(url.url!, method: "GET"); try DriveAPI.validate(response.statusCode, data: data)
                let items = try JSONDecoder().decode(DrivePage.self, from: data).files
                try require(items.count <= 1)
                if let item = items.first { id = item.id; if item.md5Checksum == checksum { break } }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard let id else { throw DriveFailure.unavailable }
            try require(try await api.item(id).md5Checksum == checksum)
            report["nativeUploadMatchesDrive"] = true
            var states: [[String: Any]] = []
            for (label, action, dataless, pinned) in [("cloud", "unsync", true, false), ("downloaded-unpinned", "sync", false, false), ("offline-pinned", "pin", false, true), ("released", "unsync", true, false)] {
                phase = label
                _ = try state(action, file: target, host: host, work: work)
                var value = try await awaitState(dataless: dataless, pinned: pinned, file: target, host: host, work: work)
                value.removeValue(forKey: "id"); value["phase"] = label
                let evaluation = try command(URL(fileURLWithPath: "/usr/bin/fileproviderctl"), args: ["evaluate", target.path], work: work)
                let text = String(data: evaluation, encoding: .utf8) ?? ""
                try evaluation.write(to: work.appendingPathComponent(label + "-evaluation.txt"))
                let expectedLabel = dataless ? "Sólo en la nube" : "Disponible sin conexión"
                try require(text.contains(expectedLabel))
                value["decoration"] = expectedLabel
                states.append(value)
            }
            report["states"] = states; report["result"] = "PASS"
        } catch { report["failedPhase"] = phase; report["errorDomain"] = (error as NSError).domain; report["errorCode"] = (error as NSError).code }
        if let id, let writer {
            do {
                let item = try await writer.revision(id)
                _ = try await writer.updateMetadata(id, etag: item.etag, trashed: true)
                report["fixtureTrashed"] = true
            } catch { report["cleanup"] = "PENDING"; report["result"] = "FAIL" }
        } else if file != nil { report["cleanup"] = "PENDING: inspect owned local fixture" }
        report["evidenceDirectory"] = work.path; report["visualAcceptance"] = "PENDING"; report["testedAt"] = ISO8601DateFormatter().string(from: Date())
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
        if report["result"] as? String != "PASS" { exit(1) }
    }
}
#endif
