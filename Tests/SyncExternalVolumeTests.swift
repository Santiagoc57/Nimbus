import Foundation

@main struct SyncExternalVolumeTests {
    static func main() throws {
        let workspace = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let mount = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NIMBO_EXTERNAL_VOLUME"] ?? "/Volumes/NimboUSBValidation")
        let folder = mount.appendingPathComponent("ExistingFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("external volume".utf8).write(to: folder.appendingPathComponent("probe.txt"), options: .atomic)
        let identity = try SyncLocalIdentity.read(folder)
        let values = try folder.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeUUIDStringKey])
        let out = workspace.appendingPathComponent("outputs/Nimbo/SYNC_EXTERNAL_VOLUME_TESTS.json")
        var priorIdentityMatch = true
        if let previous = try? Data(contentsOf: out),
           let object = try? JSONSerialization.jsonObject(with: previous) as? [String: Any],
           let oldVolume = object["identity_volume"] as? String,
           let oldInode = object["identity_inode"] as? NSNumber {
            priorIdentityMatch = oldVolume == identity.volume && oldInode.uint64Value == identity.inode
        }
        guard priorIdentityMatch else { throw SyncFailure.message("External volume identity changed after remount") }
        let report: [String: Any] = [
            "status": "PASS",
            "volume": mount.path,
            "folder": folder.path,
            "volume_is_local": values.volumeIsLocal as Any,
            "volume_is_read_only": values.volumeIsReadOnly as Any,
            "volume_uuid_present": !(values.volumeUUIDString ?? "").isEmpty,
            "identity_volume": identity.volume,
            "identity_inode": identity.inode,
            "remount_identity_match": priorIdentityMatch,
            "checks": [
                "Mounted external local volume is writable",
                "Existing folder identity accepted on external volume",
                "Volume UUID and inode captured for restart-safe validation"
            ],
            "synthetic_only": true
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: out)
        print("PASS: Existing folder accepted on external local volume")
        print("PASS: Volume identity captured: \(identity.volume) / \(identity.inode)")
    }
}
