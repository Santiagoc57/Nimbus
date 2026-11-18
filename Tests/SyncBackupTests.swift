import Foundation

@main struct SyncBackupTests {
    static func main() throws {
        let fm = FileManager.default, workspace = URL(fileURLWithPath: fm.currentDirectoryPath)
        let root = workspace.appendingPathComponent("work/nimbo/backup-" + UUID().uuidString.prefix(6))
        let remoteRoot = root.appendingPathComponent("remote"), remote = remoteRoot.appendingPathComponent("Proyecto")
        try fm.createDirectory(at: remote, withIntermediateDirectories: true)
        func write(_ text: String, _ url: URL) throws { try Data(text.utf8).write(to: url, options: .atomic) }
        try write("remote", remote.appendingPathComponent("base.txt"))
        let config = root.appendingPathComponent("rclone.conf")
        try write("[GoogleDrive]\ntype = alias\nremote = \(remoteRoot.path)\nscope = drive\n", config)
        let binary = workspace.appendingPathComponent("outputs/Nimbo/Nimbo.app/Contents/Resources/rclone")
        let engine = try SyncEngine(root: root.appendingPathComponent("state"), offlineRoot: root.appendingPathComponent("offline"), config: config, binary: binary, testing: true)
        var checks: [String] = []
        func check(_ ok: Bool, _ label: String) throws { guard ok else { throw SyncFailure.message("FAIL: " + label) }; checks.append(label); print("PASS: " + label) }
        let id = try engine.add(remote: "GoogleDrive", item: CloudItem(Path: "Proyecto", Name: "Proyecto", Size: 0, IsDir: true))
        try engine.synchronize(id)
        let local = URL(fileURLWithPath: engine.relations[0].localPath)
        try write("backup-content", local.appendingPathComponent("backup.txt"))
        try engine.setBackupSchedule(id, enabled: true, intervalMinutes: 15, retention: 1)
        try check(engine.backupIsDue(id), "Backup is due before its first run")
        try engine.runBackup(id)
        let backupRoot = remoteRoot.appendingPathComponent(".Nimbo Backups").appendingPathComponent(id.uuidString)
        let firstSnapshots = try fm.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: [.isDirectoryKey], options: []).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        try check(firstSnapshots.count == 1 && fm.fileExists(atPath: firstSnapshots[0].appendingPathComponent("backup.txt").path), "Manual backup copies local content to a timestamped Drive snapshot")
        try check(engine.relations[0].backupSchedule?.lastSuccess != nil && !(engine.backupIsDue(id)), "Successful backup persists status and interval")
        let legacy = String(firstSnapshots[0].lastPathComponent.prefix(15))
        try fm.moveItem(at: firstSnapshots[0], to: backupRoot.appendingPathComponent(legacy))
        let legacyRestore = root.appendingPathComponent("legacy-restored")
        try engine.restoreRemoteBackup(id, snapshot: legacy, destination: legacyRestore)
        try check(try String(contentsOf: legacyRestore.appendingPathComponent("backup.txt"), encoding: .utf8) == "backup-content", "A snapshot named by older Nimbo versions can still be restored")
        Thread.sleep(forTimeInterval: 1.1)
        try write("backup-content-2", local.appendingPathComponent("backup.txt"))
        try engine.runBackup(id)
        let secondSnapshots = try fm.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: [.isDirectoryKey], options: []).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        try check(secondSnapshots.count == 1, "Retention removes only older Nimbo snapshots")
        let reloaded = try SyncEngine(root: root.appendingPathComponent("state"), offlineRoot: root.appendingPathComponent("offline"), config: config, binary: binary, testing: true)
        try check(reloaded.relations[0].backupSchedule?.enabled == true && reloaded.relations[0].backupSchedule?.retention == 1, "Backup schedule survives restart")
        var rejected = false
        do { try reloaded.setBackupSchedule(id, enabled: true, intervalMinutes: 2, retention: 7) } catch { rejected = true }
        try check(rejected, "Unsupported backup frequency is rejected")
        let beforeEncrypted = Set((try? fm.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil, options: [])) ?? [])
        try reloaded.setBackupSchedule(id, enabled: true, intervalMinutes: 15, retention: 1, encrypted: true, passphrase: "test-passphrase")
        try reloaded.runBackup(id)
        var rawNames: [String] = [], rawBytes = Data()
        let encryptedRoots = ((try? fm.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil, options: [])) ?? []).filter { !beforeEncrypted.contains($0) }
        for encryptedRoot in encryptedRoots {
            guard let rawFiles = fm.enumerator(at: encryptedRoot, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { continue }
            for case let file as URL in rawFiles {
                if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    rawNames.append(file.lastPathComponent); rawBytes.append((try? Data(contentsOf: file)) ?? Data())
                }
            }
        }
        let rawText = String(data: rawBytes, encoding: .utf8) ?? ""
        try check(!rawNames.contains("backup.txt") && !rawText.contains("backup-content-2") && !rawText.contains("test-passphrase"), "Encrypted backup hides filenames and content in the Drive storage")
        try check(reloaded.relations[0].backupSchedule?.encrypted == true, "Encrypted backup mode survives in the schedule")
        var shortRejected = false
        do { try reloaded.setBackupSchedule(id, enabled: true, intervalMinutes: 15, retention: 1, encrypted: true, passphrase: "short") } catch { shortRejected = true }
        try check(shortRejected, "Short encryption phrases are rejected")
        try reloaded.setBackupSchedule(id, enabled: true, intervalMinutes: 15, retention: 7)
        try reloaded.setBackupSegmentSize(100)
        let large = local.appendingPathComponent("Movie.bin")
        let bytes = Data(repeating: 0x6E, count: 100_000_113)
        try bytes.write(to: large)
        let boundary = local.appendingPathComponent("Exact.bin")
        try Data().write(to: boundary)
        let boundaryHandle = try FileHandle(forWritingTo: boundary)
        try boundaryHandle.truncate(atOffset: 100_000_000)
        try boundaryHandle.close()
        try reloaded.runBackup(id)
        let names = try reloaded.remoteBackups(id)
        guard let split = names.last(where: { $0.contains("-s100-") }) else { throw SyncFailure.message("Missing published split snapshot") }
        let raw = backupRoot.appendingPathComponent(split + "/contents")
        let parts = try fm.contentsOfDirectory(at: raw, includingPropertiesForKeys: [.fileSizeKey]).filter { $0.lastPathComponent.contains(".nimbo.segment.") }.sorted { $0.path < $1.path }
        try check(try parts.map { try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }.sorted() == [113, 100_000_000], "The 100 MB preset produces two physical files of the expected sizes")
        let exact = raw.appendingPathComponent("Exact.bin")
        try check(try exact.resourceValues(forKeys: [.fileSizeKey]).fileSize == 100_000_000, "A file exactly at the threshold stays in one piece")
        try reloaded.setBackupSegmentSize(0)
        let restored = root.appendingPathComponent("restored")
        try reloaded.restoreRemoteBackup(id, snapshot: split, destination: restored)
        try check(try Data(contentsOf: restored.appendingPathComponent("Movie.bin")) == bytes, "Turning splitting off still restores the full original")
        var overwrite = false
        do { try reloaded.restoreRemoteBackup(id, snapshot: split, destination: restored) } catch { overwrite = true }
        try check(overwrite, "Restore refuses an existing destination")
        let tail = parts[1]
        let original = try Data(contentsOf: tail)
        try Data(repeating: 0xEF, count: original.count).write(to: tail)
        let altered = root.appendingPathComponent("corrupt-destination")
        var damaged = false
        do { try reloaded.restoreRemoteBackup(id, snapshot: split, destination: altered) } catch { damaged = true }
        try check(damaged && !fm.fileExists(atPath: altered.path), "A corrupt part with an unchanged length cannot publish a restore")
        try original.write(to: tail)
        // Losing an entire composite including its metadata can look like a
        // legitimate empty listing to the overlay. The independent index catches it.
        for file in parts + [raw.appendingPathComponent("Movie.bin")] { try fm.removeItem(at: file) }
        let missing = root.appendingPathComponent("must-not-exist")
        var corrupt = false
        do { try reloaded.restoreRemoteBackup(id, snapshot: split, destination: missing) } catch { corrupt = true }
        try check(corrupt && !fm.fileExists(atPath: missing.path), "A missing logical file prevents publication of a partial restore")
        try reloaded.setBackupSegmentSize(100)
        try reloaded.setBackupSchedule(id, enabled: true, intervalMinutes: 15, retention: 7, encrypted: true, passphrase: "fixture-only-key")
        try reloaded.runBackup(id)
        guard let encryptedSplit = try reloaded.remoteBackups(id).last(where: { $0.contains("-s100-") }) else { throw SyncFailure.message("Missing encrypted split snapshot") }
        let clear = root.appendingPathComponent("decrypted")
        try reloaded.restoreRemoteBackup(id, snapshot: encryptedSplit, destination: clear)
        try check(try Data(contentsOf: clear.appendingPathComponent("Movie.bin")) == bytes, "An encrypted split snapshot restores the original 100000113 bytes")
        try fm.removeItem(at: large)
        let report: [String: Any] = ["status": "PASS", "count": checks.count, "checks": checks, "synthetic_only": true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: workspace.appendingPathComponent("outputs/Nimbo/SYNC_BACKUP_TESTS.json"))
    }
}
