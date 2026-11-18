import Foundation

@main struct SyncFilterIntegrationTests {
    static func main() throws {
        let fm = FileManager.default, workspace = URL(fileURLWithPath: fm.currentDirectoryPath), root = URL(fileURLWithPath: "/tmp").appendingPathComponent("nimbo-filter-" + UUID().uuidString)
        let remoteRoot = root.appendingPathComponent("remote"), remote = remoteRoot.appendingPathComponent("Proyecto"); try fm.createDirectory(at: remote, withIntermediateDirectories: true)
        func write(_ text: String, _ url: URL) throws { try Data(text.utf8).write(to: url, options: .atomic) }
        let config = root.appendingPathComponent("rclone.conf"); try write("[GoogleDrive]\ntype = alias\nremote = \(remoteRoot.path)\nscope = drive\n", config)
        // The local rclone backend lowercases macOS xattrs and omits Drive IDs.
        // Substitute Drive's metadata only for the fixture in lsjson responses.
        // rclone itself still performs all filtering, listing and transfers.
        let wrapper = root.appendingPathComponent("drive-fixture.py")
        let script = #"""
        #!/usr/bin/python3
        import hashlib, json, os, pathlib, subprocess, sys
        binary = str(pathlib.Path.cwd() / "outputs/Nimbo/Nimbo.app/Contents/Resources/rclone")
        args = sys.argv[1:]
        if "lsjson" in args and "--metadata" in args:
            result = subprocess.run([binary, *args], stdout=subprocess.PIPE)
            if result.returncode:
                sys.exit(result.returncode)
            items = json.loads(result.stdout)
            for item in items:
                if item["Name"] == "toma [01].dividido" and item["IsDir"]:
                    parts = sorted(pathlib.Path("\#(remote.path)", item["Path"]).glob("part-*"))
                    data = b"".join(p.read_bytes() for p in parts)
                    item["ID"] = "testPackage"
                    item["Metadata"] = {"nimboSplit": "2", "nimboBytes": str(len(data)), "nimboPartBytes": "100000000", "nimboMD5": hashlib.md5(data).hexdigest()}
            print(json.dumps(items))
        else:
            os.execv(binary, [binary, *args])
        """#
        try write(script, wrapper)
        try fm.setAttributes([.posixPermissions:0o700], ofItemAtPath:wrapper.path)
        let engine = try SyncEngine(root: root.appendingPathComponent("state"), offlineRoot: root.appendingPathComponent("offline"), config: config, binary: wrapper, testing: true)
        let id = try engine.add(remote: "GoogleDrive", item: CloudItem(Path: "Proyecto", Name: "Proyecto", Size: 0, IsDir: true)); try engine.synchronize(id)
        let local = URL(fileURLWithPath: engine.relations[0].localPath); try write("keep", local.appendingPathComponent("keep.txt")); try write("ignore", local.appendingPathComponent("ignore.tmp")); try engine.setFilters(id, patterns: ["*.tmp", ".*"]); try engine.synchronize(id)
        guard fm.fileExists(atPath: remote.appendingPathComponent("keep.txt").path), !fm.fileExists(atPath: remote.appendingPathComponent("ignore.tmp").path) else { throw SyncFailure.message("FAIL: custom exclusion was not applied") }
        guard let relation = engine.relations.first, !relation.localFiles.contains("ignore.tmp"),
              relation.localFiles.contains(relation.marker), relation.remoteFiles.contains(relation.marker) else {
            throw SyncFailure.message("FAIL: review, bisync and access checks use different file sets")
        }
        try write("local excluded", local.appendingPathComponent("shared.tmp"))
        try write("remote excluded", remote.appendingPathComponent("shared.tmp"))
        try engine.synchronize(id)
        try fm.removeItem(at: remote.appendingPathComponent("shared.tmp"))
        try write("from Drive", remote.appendingPathComponent("from-drive.txt"))
        try engine.synchronize(id)
        guard engine.relations[0].pendingDeletes.isEmpty,
              fm.fileExists(atPath: local.appendingPathComponent("shared.tmp").path),
              try String(contentsOf: local.appendingPathComponent("from-drive.txt")) == "from Drive" else {
            throw SyncFailure.message("FAIL: deletion of excluded data blocked unrelated downloads")
        }
        let package = remote.appendingPathComponent("toma [01].dividido")
        try fm.createDirectory(at: package, withIntermediateDirectories: false)
        try write("fragment", package.appendingPathComponent("part-000001"))
        try engine.setFilters(id, patterns:["*.dividido", "*.tmp", ".*"])
        try write("neighbor", local.appendingPathComponent("toma 0.txt"))
        try engine.synchronize(id)
        guard !fm.fileExists(atPath:local.appendingPathComponent(package.lastPathComponent).path),
              try String(contentsOf:package.appendingPathComponent("part-000001")) == "fragment",
              try String(contentsOf:remote.appendingPathComponent("toma 0.txt")) == "neighbor" else {
            throw SyncFailure.message("FAIL: excluded package leaked its physical parts or blocked its neighbor")
        }
        // Included package: one logical file on the Mac, parts never travel,
        // the neighbor keeps syncing, and a Mac edit keeps the Drive ID.
        let fixture = FixtureSplitRemote(package: package)
        engine.splitRemoteFactory = { _ in fixture }
        try engine.setFilters(id, patterns:["*.tmp"])
        try write("neighbor 2", local.appendingPathComponent("toma 0.txt"))
        try engine.synchronize(id)
        let logical = local.appendingPathComponent(package.lastPathComponent)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: logical.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              try String(contentsOf: logical) == "fragment",
              !fm.fileExists(atPath: local.appendingPathComponent("part-000001").path),
              try String(contentsOf: remote.appendingPathComponent("toma 0.txt")) == "neighbor 2" else {
            throw SyncFailure.message("FAIL: included package was not presented as one local file")
        }
        try write("edited on Mac", logical)
        try engine.synchronize(id)
        guard try String(contentsOf: package.appendingPathComponent("part-000001")) == "edited on Mac",
              fixture.edits == 1, engine.relations[0].splitFiles?[package.lastPathComponent]?.id == "testPackage",
              (try fm.contentsOfDirectory(atPath: remote.path)).filter({ $0.hasPrefix("toma [01]") }).count == 1 else {
            throw SyncFailure.message("FAIL: Mac edit did not keep the Drive ID or duplicated the document")
        }
        try engine.synchronize(id)
        guard fixture.edits == 1, fixture.downloads == 1 else { throw SyncFailure.message("FAIL: an unchanged split document was transferred again") }
        let checks = ["Excluded file stays local", "Deletion review ignores excluded paths", "Marker survives dotfile exclusion", "Allowed changes still transfer in both directions", "Excluded split package stays intact while its neighbor syncs", "Included package appears as one local file without its parts", "Mac edit keeps the Drive ID without duplicates", "Unchanged split document is not transferred again"]
        let report: [String:Any] = ["status":"PASS", "count":checks.count, "checks":checks, "synthetic_only":true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: workspace.appendingPathComponent("outputs/Nimbo/SYNC_FILTER_INTEGRATION_TESTS.json"))
        for label in checks { print("PASS:", label) }
    }
}

/// Drive simulado sobre la carpeta física del paquete del fixture.
final class FixtureSplitRemote: SyncSplitRemote {
    let package: URL
    var edits = 0, downloads = 0
    init(package: URL) { self.package = package }
    private var part: URL { package.appendingPathComponent("part-000001") }
    func allocateID() throws -> String { UUID().uuidString }
    func folderID(_ relative: String) throws -> String { "folder:" + relative }
    func current(_ id: String) throws -> (etag: String, file: SyncSplitRemoteFile, partBytes: Int64, name: String, parent: String)? {
        guard id == "testPackage" else { return nil }
        let data = try Data(contentsOf: part)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return ("e", SyncSplitRemoteFile(id: id, size: Int64(data.count), md5: try SyncSplitCoordinator.md5(tmp)), 100_000_000, package.lastPathComponent, "folder:")
    }
    func download(_ id: String, to destination: URL) throws { downloads += 1; try FileManager.default.copyItem(at: part, to: destination) }
    func create(id: String, parent: String, name: String, file: URL, size: Int64, md5: String, partBytes: Int64) throws { throw SyncFailure.message("FAIL: unexpected create") }
    func edit(id: String, etag: String, name: String, parent: String, generation: String, file: URL, size: Int64, md5: String, partBytes: Int64) throws {
        edits += 1; try Data(contentsOf: file).write(to: part)
    }
    func trash(_ id: String) throws { throw SyncFailure.message("FAIL: unexpected trash") }
}
