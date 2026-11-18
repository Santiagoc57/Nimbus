#if CORE_TESTS
import Foundation
import Darwin

@main
struct CoreTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw NSError(domain: "CoreTests", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
        checks += 1
    }
    static func expect(_ error: CloudBackendError, _ label: String, _ body: () throws -> Void) throws {
        do { try body(); throw NSError(domain: "CoreTests", code: 2, userInfo: [NSLocalizedDescriptionKey: label + " did not fail"]) }
        catch let actual as CloudBackendError { try check(actual == error, label + ": wrong failure \(actual)") }
    }
    static let good = CloudItem(Path: "Projects/2026/Résumé.txt", Name: "Résumé.txt", Size: 3, IsDir: false, ModTime: "2026-11-10T00:00:00Z")

    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("listremotes") || args.contains("lsjson") || args.contains("copyto") {
            try fixture(args)
            return
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("NimboCoreTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        TransferCenter.shared.configure(support: temp)
        let config = temp.appendingPathComponent("fixture-config")
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let cache = temp.appendingPathComponent("cache")
        let backend = CloudBackend(configURL: config, binaryURL: executable, cacheDirectory: cache, operationTimeout: 2, downloadTimeout: 2)
        func scenario(_ name: String) throws { try Data(name.utf8).write(to: config) }

        try check(matchesQuery("  resume 2026  ", item: good), "AND search folds case and accents")
        try check(matchesQuery("RE\u{301}SUME\u{301}", item: good), "decomposed Unicode normalization")
        try check(matchesQuery("", item: good), "empty query")
        try check(!matchesQuery("resume 2025", item: good), "AND token miss")
        try check(!matchesQuery(".*", item: good), "regex is a literal")
        try check(!matchesQuery("$(touch /tmp/should-not-exist)", item: good), "shell syntax is literal")
        try check(matchesQuery("[a]", item: CloudItem(Path: "[a].txt", Name: "[a].txt", Size: 0, IsDir: false)), "brackets are literal")

        for unsafe in ["", ".", "..", "../x", "/tmp/x", "a/b", "a\\b", "a:b", "bad\nname", "bad\0name"] {
            try expect(.unsafePath, "reject basename \(unsafe.debugDescription)") { _ = try CloudBackend.safeBasename(unsafe) }
        }
        try check(try CloudBackend.safeBasename("$(echo hi).txt") == "$(echo hi).txt", "shell metacharacters safe as literal basename")
        for remote in ["", "../drive", "/drive", "drive:", "--config", "drive\nother", "drive\\other"] {
            try expect(.invalidRemote, "reject remote") { try CloudBackend.validateRemote(remote) }
        }
        try CloudBackend.validateRemote("Work Drive-2")

        try expect(.invalidMetadata, "broken JSON") { _ = try CloudBackend.decodeListing(Data("{bad".utf8)) }
        try expect(.invalidMetadata, "wrong shape") { _ = try CloudBackend.decodeListing(Data("{}".utf8)) }
        try expect(.invalidMetadata, "missing keys") { _ = try CloudBackend.decodeListing(Data("[{\"Name\":\"x\"}]".utf8)) }
        let invalid = CloudItem(Path: "../outside", Name: "outside", Size: 0, IsDir: false)
        try check(try CloudBackend.decodeListing(JSONEncoder().encode([invalid, good])).count == 2, "listing preserves non-downloadable names without losing good entries")
        let unsupported = CloudItem(Path: "Folder/a:b\\c\nname", Name: "a:b\\c\nname", Size: 0, IsDir: false)
        try check(try CloudBackend.decodeListing(JSONEncoder().encode([unsupported, good])) == [unsupported, good], "listing permits provider-specific separators and controls")
        try check(try CloudBackend.decodeListing(JSONEncoder().encode([good, good])).count == 2, "preserve duplicate provider names")
        let folder = CloudItem(Path: "Projects", Name: "Projects", Size: -1, IsDir: true)
        try check(try CloudBackend.decodeListing(JSONEncoder().encode([folder])) == [folder], "directory size sentinel")
        let catalogAtLimit = (0..<200000).map { index in
            CloudItem(Path: "f\(index)", Name: "f\(index)", Size: 0, IsDir: false)
        }
        try check(try CloudBackend.decodeListing(JSONEncoder().encode(catalogAtLimit)).count == 200000, "catalog accepts the documented 200000-entry boundary")
        let catalogOverLimit = catalogAtLimit + [CloudItem(Path: "overflow", Name: "overflow", Size: 0, IsDir: false)]
        try expect(.outputLimitExceeded, "catalog rejects the 200001st entry") { _ = try CloudBackend.decodeListing(JSONEncoder().encode(catalogOverLimit)) }

        try check(try backend.loadCache(remote: "test") == nil, "missing cache")
        try scenario("valid")
        try check(try backend.listRemotes() == ["test", "Work Drive"], "remote enumeration")
        try check(try backend.list(remote: "test") == [good], "metadata listing")
        let firstCache = try backend.loadCache(remote: "test")
        try check(firstCache?.entries == [good], "cache persisted")
        let cacheFiles = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
        try check(cacheFiles.count == 1, "one atomic cache file")
        let cacheFile = cacheFiles[0]
        let before = try Data(contentsOf: cacheFile)
        try check(cacheFile.pathExtension == "enc", "catalog cache uses encrypted extension")
        try check(before.range(of: Data("Projects/2026/Résumé.txt".utf8)) == nil, "catalog cache does not expose plaintext paths")
        let permissions = try FileManager.default.attributesOfItem(atPath: cacheFile.path)[.posixPermissions] as? NSNumber
        try check(permissions?.intValue == 0o600, "cache file mode 0600")

        try scenario("malformed")
        try expect(.invalidMetadata, "malformed response") { _ = try backend.list(remote: "test") }
        try check(try Data(contentsOf: cacheFile) == before, "malformed listing preserves cache bytes")
        try scenario("failure")
        try expect(.commandFailed(7), "connector failure") { _ = try backend.list(remote: "test") }
        try check(try Data(contentsOf: cacheFile) == before, "connector error preserves cache bytes")
        try check(!(CloudBackendError.commandFailed(7).localizedDescription.contains("SECRET_SENTINEL")), "stderr is not exposed")

        // Force failure at atomic rename publication, leaving the old destination tree intact.
        let retained = cache.appendingPathComponent("previous-cache")
        try FileManager.default.moveItem(at: cacheFile, to: retained)
        try FileManager.default.createDirectory(at: cacheFile, withIntermediateDirectories: false)
        let sentinel = cacheFile.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel)
        try expect(.cacheUnavailable, "atomic publication failure") {
            try backend.saveCache(RemoteCache(remote: "test", fetchedAt: Date(), entries: []))
        }
        try check(try Data(contentsOf: sentinel) == Data("keep".utf8), "publication failure keeps destination")
        try check(try Data(contentsOf: retained) == before, "previous bytes preserved on publication failure")
        try FileManager.default.removeItem(at: cacheFile)
        try FileManager.default.moveItem(at: retained, to: cacheFile)
        try check(try backend.loadCache(remote: "test") == firstCache, "valid cache survives restored publication failure fixture")
        try check(try FileManager.default.contentsOfDirectory(atPath: cache.path).allSatisfy { !$0.hasPrefix(".index-") }, "no abandoned partial cache")

        // Deterministically cancel after subprocess/decode/temp-write, immediately before publication.
        try scenario("valid")
        backend.cachePublicationWillBegin = { backend.cancelAll() }
        try expect(.cancelled, "cancellation at cache publication boundary") { _ = try backend.list(remote: "test") }
        backend.cachePublicationWillBegin = nil
        try check(try Data(contentsOf: cacheFile) == before, "late cancellation keeps previous cache bytes")
        try check(try FileManager.default.contentsOfDirectory(atPath: cache.path).allSatisfy { !$0.hasPrefix(".index-") }, "late cancellation removes unpublished temp")
        try check(try backend.list(remote: "test") == [good], "new listing succeeds after late cancellation")

        let legacyRemote = "legacy"
        let legacyEncoded = Data(legacyRemote.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        let legacyURL = cache.appendingPathComponent("remote-" + legacyEncoded + ".json")
        let legacyValue = RemoteCache(remote: legacyRemote, fetchedAt: Date(), entries: [good])
        try JSONEncoder().encode(legacyValue).write(to: legacyURL, options: .atomic)
        let migrated = try backend.loadCache(remote: legacyRemote)
        try check(migrated == legacyValue, "legacy plaintext catalog remains readable")
        try check(FileManager.default.fileExists(atPath: cache.appendingPathComponent("remote-" + legacyEncoded + ".json.enc").path) && !FileManager.default.fileExists(atPath: legacyURL.path), "legacy catalog migrates and plaintext is removed")

        let downloads = temp.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try scenario("valid")
        let first = try backend.download(remote: "test", item: good, destinationDirectory: downloads)
        let second = try backend.download(remote: "test", item: good, destinationDirectory: downloads)
        try check(first != second && first.deletingLastPathComponent() != second.deletingLastPathComponent(), "downloads never replace existing file")
        try check(try Data(contentsOf: first) == Data("abc".utf8), "download contents")
        try check(first.lastPathComponent == good.Name, "Unicode filename preserved")
        let googleDoc = CloudItem(Path: "Projects/2026/Plan", Name: "Plan", Size: -1, IsDir: false, MimeType: "application/vnd.google-apps.document")
        let exported = try backend.download(remote: "test", item: googleDoc, destinationDirectory: downloads)
        try check(exported.lastPathComponent == "Plan.docx", "Google document download receives the documented export extension")
        let dottedDoc = CloudItem(Path: "Projects/2026/Plan.v1", Name: "Plan.v1", Size: -1, IsDir: false, MimeType: "application/vnd.google-apps.document")
        let dottedExport = try backend.download(remote: "test", item: dottedDoc, destinationDirectory: downloads)
        try check(dottedExport.lastPathComponent == "Plan.v1.docx", "Google document export extends dotted names without ambiguity")
        let exportTransfer = TransferCenter.shared.recent().first { $0.name == dottedDoc.Name }
        let exportedBytes = try Data(contentsOf: dottedExport).count
        try check(exportTransfer?.completedBytes == Int64(exportedBytes), "export ledger records actual bytes")
        try check(exportTransfer?.state == .completed && exportTransfer?.verified == false, "export completion does not claim an unknown size was verified")
        let alreadyExported = CloudItem(Path: "Projects/2026/Plan.docx", Name: "Plan.docx", Size: -1, IsDir: false, MimeType: "application/vnd.google-apps.document")
        let preservedExport = try backend.download(remote: "test", item: alreadyExported, destinationDirectory: downloads)
        try check(preservedExport.lastPathComponent == "Plan.docx", "Google document export does not duplicate an existing extension")
        try expect(.foldersCannotBeDownloaded, "directory download refused") { _ = try backend.download(remote: "test", item: folder, destinationDirectory: downloads) }
        try expect(.unsafePath, "download traversal refused") { _ = try backend.download(remote: "test", item: invalid, destinationDirectory: downloads) }
        let literal = CloudItem(Path: "$(touch sentinel).txt", Name: "$(touch sentinel).txt", Size: 3, IsDir: false)
        let literalURL = try backend.download(remote: "test", item: literal, destinationDirectory: downloads)
        try check(literalURL.lastPathComponent == literal.Name, "download argument is not shell-expanded")
        try backend.saveCache(RemoteCache(remote: "test", fetchedAt: Date(), entries: [good, good]))
        try expect(.duplicateMetadataPath, "ambiguous download refused") { _ = try backend.download(remote: "test", item: good, destinationDirectory: downloads) }
        try backend.saveCache(RemoteCache(remote: "test", fetchedAt: Date(), entries: [good]))
        let downloadCount = try FileManager.default.contentsOfDirectory(atPath: downloads.path).count
        try scenario("wrong-size")
        try expect(.incompleteDownload, "wrong-size download") { _ = try backend.download(remote: "test", item: good, destinationDirectory: downloads) }
        try check(try FileManager.default.contentsOfDirectory(atPath: downloads.path).count == downloadCount, "partial download cleaned up")
        try scenario("partial-failure")
        try expect(.commandFailed(7), "connector failure during download") { _ = try backend.download(remote: "test", item: good, destinationDirectory: downloads) }
        try check(try FileManager.default.contentsOfDirectory(atPath: downloads.path).count == downloadCount, "failed download removes its partial file and directory")
        let failedTransfer = TransferCenter.shared.recent().first
        try check(failedTransfer?.state == .failed && failedTransfer?.completedBytes == 0, "failed connector download does not invent 100 percent progress")

        try scenario("progress")
        let observed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for _ in 0..<100 {
                if TransferCenter.shared.active().contains(where: { $0.completedBytes == 1 && $0.bytesPerSecond == 2 }) { observed.signal(); return }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        _ = try backend.download(remote: "test", item: good, destinationDirectory: downloads)
        try check(observed.wait(timeout: .now() + 1) == .success, "split JSON stats update progress before completion")

        try scenario("progress-cancel")
        let cancelled = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for _ in 0..<100 {
                if let row = TransferCenter.shared.active().first(where: { $0.completedBytes == 1 }) {
                    TransferCenter.shared.requestCancellation(row.id); cancelled.signal(); return
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        let countBeforeCancel = try FileManager.default.contentsOfDirectory(atPath: downloads.path).count
        try expect(.cancelled, "individual cancellation interrupts the active subprocess") { _ = try backend.download(remote: "test", item: good, destinationDirectory: downloads) }
        try check(cancelled.wait(timeout: .now() + 1) == .success, "cancellation targets the measured transfer")
        let cancelledRecord = TransferCenter.shared.recent().first
        try check(cancelledRecord?.state == .cancelled && cancelledRecord?.completedBytes == 1, "cancelled download preserves measured bytes")
        try check(try FileManager.default.contentsOfDirectory(atPath: downloads.path).count == countBeforeCancel, "cancelled download removes partial artifacts")

        let settingsDirectory = temp.appendingPathComponent("Sync")
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        var asymmetric = SyncSettings()
        asymmetric.downloadKBps = 1024
        asymmetric.uploadKBps = 5120
        try JSONEncoder().encode(asymmetric).write(to: settingsDirectory.appendingPathComponent("settings.json"))
        try scenario("bandwidth")
        _ = try backend.download(remote: "test", item: good, destinationDirectory: downloads)
        try check(TransferCenter.shared.recent().first?.state == .completed, "download applies the saved menu bandwidth limit")

        try scenario("valid")
        let beforeCommitCancellation = try FileManager.default.contentsOfDirectory(atPath: downloads.path).count
        backend.downloadWillCommit = { id in TransferCenter.shared.requestCancellation(id) }
        try expect(.cancelled, "cancellation at download publication boundary") { _ = try backend.download(remote: "test", item: good, destinationDirectory: downloads) }
        backend.downloadWillCommit = nil
        try check(TransferCenter.shared.recent().first?.state == .cancelled && TransferCenter.shared.recent().first?.verified == false, "late cancellation cannot publish verified success")
        try check(try FileManager.default.contentsOfDirectory(atPath: downloads.path).count == beforeCommitCancellation, "late cancellation removes uncommitted download")
        backend.downloadWillCommit = { _ in backend.cancelAll() }
        try expect(.cancelled, "global cancellation at download publication boundary") { _ = try backend.download(remote: "test", item: good, destinationDirectory: downloads) }
        backend.downloadWillCommit = nil

        let impatient = CloudBackend(configURL: config, binaryURL: executable, cacheDirectory: cache, operationTimeout: 0.15)
        try scenario("slow")
        try expect(.timedOut, "timeout") { _ = try impatient.listRemotes() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { backend.cancelAll() }
        try expect(.cancelled, "cancellation") { _ = try backend.listRemotes() }
        try scenario("valid")
        try check(try backend.listRemotes().count == 2, "backend reusable after cancellation")
        print("PASS: \(checks) checks; isolated subprocess fixtures; no cloud accounts accessed.")
    }

    static func fixture(_ args: [String]) throws {
        guard let configIndex = args.firstIndex(of: "--config"), configIndex + 1 < args.count else { exit(9) }
        let scenario = try String(contentsOfFile: args[configIndex + 1], encoding: .utf8)
        if scenario == "slow" { Thread.sleep(forTimeInterval: 5) }
        if scenario == "failure" {
            FileHandle.standardError.write(Data("SECRET_SENTINEL_TOKEN=private\n".utf8))
            exit(7)
        }
        if args.contains("listremotes") {
            FileHandle.standardOutput.write(Data("Work Drive:\ntest:\n".utf8)); return
        }
        if args.contains("lsjson") {
            if scenario == "malformed" { FileHandle.standardOutput.write(Data("not JSON".utf8)); return }
            FileHandle.standardOutput.write(try JSONEncoder().encode([good])); return
        }
        if let index = args.firstIndex(of: "copyto"), index + 2 < args.count {
            if scenario.hasPrefix("progress") {
                guard args.contains("--use-json-log"), args.contains("--stats"), args.contains("--stats-log-level") else { exit(8) }
                FileHandle.standardError.write(Data("{\"stats\":{\"bytes\":".utf8))
                Thread.sleep(forTimeInterval: 0.1)
                FileHandle.standardError.write(Data("1,\"totalBytes\":3,\"speed\":2,\"eta\":1}}\n".utf8))
                Thread.sleep(forTimeInterval: scenario == "progress-cancel" ? 5 : 0.4)
            }
            if scenario == "bandwidth" {
                guard let index = args.firstIndex(of: "--bwlimit"), index + 1 < args.count, args[index + 1] == "5120k:1024k" else { exit(8) }
            }
            if scenario == "partial-failure" {
                try Data("partial".utf8).write(to: URL(fileURLWithPath: args[index + 2]), options: .withoutOverwriting)
                exit(7)
            }
            let data = Data((scenario == "wrong-size" ? "incomplete" : "abc").utf8)
            try data.write(to: URL(fileURLWithPath: args[index + 2]), options: .withoutOverwriting)
            return
        }
        exit(8)
    }
}
#endif
