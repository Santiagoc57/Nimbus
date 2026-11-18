#if NATIVE_SPLIT_WRITE_TESTS
import Foundation

// Stop once after the Drive folder is allocated but before its final rename.
// A fresh journal reader must recognize the hidden folder and resume it.
extension NativeFixtureDrive: DriveSplitCreating {
    func createSplit(id: String, parent: String, name: String, file: URL, layout: DriveSplitLayout,
                     journalAccount: String, keychain: Bool,
                     checkCancellation: @escaping () throws -> Void,
                     progress: @escaping (Int64, Int64) -> Void) async throws -> DriveRevision {
        if all().contains(where: { $0.id == id }) {
            let pending = try revision(id)
            guard pending.object.splitPending, pending.object.splitLayout == layout else { throw DriveFailure.conflict }
            let updated = try updateMetadata(id, etag: pending.etag, name: name, parent: parent, trashed: nil)
            return DriveRevision(object: updated.object.projected(), etag: updated.etag)
        }
        let folder = try createFolder(id: id, parent: parent, name: ".nimbo-upload-" + id)
        var object = folder.object
        object.properties = layout.properties
        try merge([object])
        throw DriveFailure.unavailable
    }
}

@main struct NativeSplitWriteTests {
    static func main() async throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: directory) }
        let root = DriveObject(id: "root", name: "Drive", mimeType: "application/vnd.google-apps.folder")
        let writer = try NativeFixtureDrive(directory: directory.appendingPathComponent("remote"), seed: [root.id: root])
        let operations = directory.appendingPathComponent("operations")
        let file = directory.appendingPathComponent("large")
        guard fm.createFile(atPath: file.path, contents: nil) else { throw DriveFailure.unavailable }
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 100_000_001)
        try handle.close()
        func create(_ threshold: Int) async throws -> NativeMutationOutcome {
            let engine = try NativeWriteStore(directory: operations, writer: writer)
            return try await engine.create(template: "finder-copy", parent: root.id, name: "large.bin", mime: "application/octet-stream", isFolder: false, contents: file, segmentMB: threshold)
        }
        var interrupted = false
        do { _ = try await create(100) } catch DriveFailure.unavailable { interrupted = true }
        let first = await writer.all().filter { $0.splitPending }
        guard interrupted, first.count == 1 else { throw DriveFailure.invalidResponse }
        let resumed = try await create(0)
        guard resumed.item?.id == first[0].id, resumed.item?.splitLayout?.count == 2, resumed.item?.splitPending == false else { throw DriveFailure.invalidResponse }
        let replay = try await create(500)
        guard replay.item == resumed.item, await writer.all().count == 2 else { throw DriveFailure.invalidResponse }
        let legacy = try JSONDecoder().decode(SyncSettings.self, from: Data(#"{"backupSegmentMB":500}"#.utf8))
        guard legacy.finderSegmentMB == 0, legacy.backupSegmentMB == 500 else { throw DriveFailure.invalidResponse }
        let digest = "d41d8cd98f00b204e9800998ecf8427e"
        guard DriveSplitLayout(size: 0, partBytes: 100_000_000, md5: digest) == nil,
              let empty = DriveSplitLayout(size: 0, partBytes: 100_000_000, md5: digest, editing: true, generation: "revision-1"),
              empty.count == 0, DriveSplitLayout(empty.properties) == empty else { throw DriveFailure.invalidResponse }
        var malformed = empty.properties
        malformed["nimboRevision"] = "../other-folder"
        guard DriveSplitLayout(malformed) == nil else { throw DriveFailure.invalidResponse }
        var remoteFolder = root
        remoteFolder.properties = empty.properties
        remoteFolder.capabilities = DriveObject.Capabilities(canDownload: true, canEdit: true, canAddChildren: false)
        let readOnly = NativeItem(remoteFolder.projected(), rootID: "outside", pinned: false, writable: true)
        guard !readOnly.capabilities.contains(.allowsWriting) else { throw DriveFailure.invalidResponse }
        remoteFolder.capabilities?.canAddChildren = true
        guard NativeItem(remoteFolder.projected(), rootID: "outside", pinned: false, writable: true).capabilities.contains(.allowsWriting),
              !NativeItem(remoteFolder.projected(), rootID: "outside", pinned: false, writable: false).capabilities.contains(.allowsWriting) else { throw DriveFailure.invalidResponse }
        print("PASS zero-byte edits, generation metadata round trip, invalid reference rejection and effective write capabilities")
        print("PASS interrupted Finder copy resumes with the same Drive ID and original threshold after restart; replay creates no duplicate; existing backup settings leave Finder splitting disabled")
    }
}
#endif
