import Foundation

private struct SplitSendJournal: Codable {
    struct Part: Codable { let id: String; let md5: String }
    var parts: [Part] = []
    var session: DriveUploadSession?
}

protocol DriveSplitCreating: Sendable {
    func createSplit(id: String, parent: String, name: String, file: URL, layout: DriveSplitLayout,
                     journalAccount: String, keychain: Bool,
                     checkCancellation: @escaping () throws -> Void,
                     progress: @escaping (Int64, Int64) -> Void) async throws -> DriveRevision
}

extension DriveWriteAPI: DriveSplitCreating {
    func createSplit(id: String, parent: String, name finalName: String, file: URL, layout: DriveSplitLayout,
                     journalAccount: String, keychain: Bool,
                     checkCancellation: @escaping () throws -> Void,
                     progress: @escaping (Int64, Int64) -> Void) async throws -> DriveRevision {
        let staging = ".nimbo-upload-" + id
        let root = file.deletingLastPathComponent()
        let journal = root.appendingPathComponent("parts.enc")
        let saved = try NimboSecureFile.loadData(from: journal, account: journalAccount, keychain: keychain)
        var state = try saved.map { try JSONDecoder().decode(SplitSendJournal.self, from: $0) } ?? SplitSendJournal()
        func save() throws {
            try NimboSecureFile.saveData(JSONEncoder().encode(state), to: journal, account: journalAccount, keychain: keychain)
        }
        func revision(_ id: String) async throws -> DriveRevision? {
            do { return try await self.revision(id) } catch DriveFailure.notFound { return nil }
        }
        try checkCancellation()
        let folder: DriveRevision
        if let existing = try await revision(id) { folder = existing }
        else { folder = try await self.createFolder(id: id, parent: parent, name: staging, split: layout) }
        guard folder.object.parents == [parent], folder.object.splitLayout == layout, folder.object.trashed != true,
              folder.object.name == staging || folder.object.name == finalName, state.parts.count <= layout.count else { throw DriveFailure.conflict }
        // A retry after a lost rename reply already has all part IDs in its journal.
        let committed = !folder.object.splitPending
        guard !committed || state.parts.count == layout.count else { throw DriveFailure.conflict }
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        let temporary = root.appendingPathComponent("segment-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        for index in 0..<layout.count {
            try checkCancellation()
            let length = layout.length(index)
            let name = layout.name(index)
            let offset = Int64(index) * layout.partBytes
            if index < state.parts.count {
                let part = state.parts[index]
                if let previous = try await revision(part.id) {
                    guard previous.object.name == name, previous.object.parents == [id],
                          previous.object.size == String(length), previous.object.md5Checksum == part.md5,
                          previous.object.trashed != true else { throw DriveFailure.conflict }
                    progress(offset + length, layout.size)
                    continue
                }
                guard !committed else { throw DriveFailure.conflict }
            }
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw DriveFailure.unavailable }
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try input.seek(toOffset: UInt64(offset))
                var remaining = length
                while remaining > 0 {
                    try checkCancellation()
                    guard let data = try input.read(upToCount: Int(min(remaining, 1024 * 1024))), !data.isEmpty else { throw DriveFailure.invalidResponse }
                    try handle.write(contentsOf: data)
                    remaining -= Int64(data.count)
                }
                try handle.close()
            } catch { try? handle.close(); throw error }
            let hash = try DriveWriteAPI.fingerprint(temporary).md5
            if state.parts.count == index {
                state.parts.append(.init(id: try await self.allocateID(), md5: hash))
                state.session = nil
                try save()
            }
            let part = state.parts[index]
            guard part.md5 == hash else { throw DriveFailure.conflict }
            if state.session?.fileID != part.id {
                state.session = try await self.beginUpload(id: part.id, parent: id, name: name, mime: "application/octet-stream", file: temporary, baseETag: nil)
                try save()
            }
            guard let session = state.session else { throw DriveFailure.invalidResponse }
            let result: DriveRevision
            do {
                result = try await self.upload(temporary, session: session, checkpoint: { updated in
                    try checkCancellation()
                    state.session = updated
                    try save()
                }, progress: { bytes, _ in progress(offset + bytes, layout.size) })
            } catch {
                switch error {
                case DriveFailure.notFound, DriveFailure.http(410), DriveFailure.anchorExpired:
                    state.session = nil
                    try save()
                default: break
                }
                throw error
            }
            guard result.object.id == part.id, result.object.md5Checksum == hash, result.object.size == String(length),
                  result.object.parents == [id] else { throw DriveFailure.invalidResponse }
            state.session = nil
            try save()
            try FileManager.default.removeItem(at: temporary)
        }
        // Check membership again before publishing. Missing, moved or extra
        // objects must not be silently incorporated into the logical file.
        var ids = Set<String>(), page: String?, tokens = Set<String>()
        let expected = Dictionary(uniqueKeysWithValues: state.parts.enumerated().map { (layout.name($0.offset), $0.element) })
        repeat {
            try checkCancellation()
            let result = try await api.rawChildren(id, page: page)
            for child in result.files {
                guard let part = expected[child.name], child.id == part.id, child.md5Checksum == part.md5,
                      ids.insert(child.id).inserted else { throw DriveFailure.conflict }
            }
            page = result.nextPageToken
            if let page, !tokens.insert(page).inserted { throw DriveFailure.invalidResponse }
        } while page != nil
        guard ids.count == layout.count, let current = try await revision(id),
              current.object.splitLayout == layout, current.object.trashed != true, current.object.parents == [parent] else { throw DriveFailure.conflict }
        if current.object.name == finalName && !current.object.splitPending { return current }
        guard current.object.name == staging else { throw DriveFailure.conflict }
        return try await self.updateMetadata(id, etag: current.etag, name: finalName)
    }
}

