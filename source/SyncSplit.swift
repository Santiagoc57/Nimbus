import Foundation
import CryptoKit

/// «Sincronizar carpeta» con documentos divididos.
///
/// En Drive un documento dividido es una carpeta física de partes con
/// propiedades `nimboSplit`. En el Mac es un único archivo con su nombre y sus
/// bytes. rclone bisync nunca ve esas rutas (se excluyen por ruta exacta en
/// ambos lados); este módulo decide y ejecuta cada transferencia lógica.
///
/// Garantías:
/// - Una edición conserva el ID del documento en Drive (nueva generación + commit con ETag).
/// - Cada subida tiene un diario en `State/<relación>/split/` y se retoma con los
///   mismos IDs, así una interrupción no duplica nada.
/// - Antes de sobrescribir o quitar una copia local se guarda en Versions.
/// - Los borrados sólo se propagan cuando el usuario aprobó la lista exacta.

struct SyncSplitBaseline: Codable, Equatable {
    var id: String
    var md5: String
    var size: Int64
    /// Tamaño y fecha locales observados cuando ambos lados coincidían. Si
    /// cambian, se vuelve a calcular el MD5 antes de decidir que hubo una edición.
    var localSize: Int64
    var localModTime: Date?
}

struct SyncSplitRemoteFile: Equatable {
    let id: String
    let size: Int64
    let md5: String
}

struct SyncSplitLocalFile: Equatable {
    let size: Int64
    let modTime: Date?
}

enum SyncSplitAction: Equatable {
    case adopt(String, SyncSplitRemoteFile)          // mismo contenido: sólo registrar
    case download(String, SyncSplitRemoteFile)       // Drive cambió o es nuevo
    case upload(String)                              // archivo local nuevo que supera el umbral
    case edit(String, SyncSplitRemoteFile)           // el Mac cambió: nueva generación con el mismo ID
    case conflict(String, SyncSplitRemoteFile)       // ambos cambiaron con contenidos distintos
    case deleteRemote(String, SyncSplitRemoteFile)   // falta en el Mac: requiere aprobación
    case deleteLocal(String)                         // falta en Drive: requiere aprobación
    case forget(String)                              // ya no existe en ningún lado

    var path: String {
        switch self {
        case .adopt(let p, _), .download(let p, _), .upload(let p), .edit(let p, _), .conflict(let p, _),
             .deleteRemote(let p, _), .deleteLocal(let p), .forget(let p): return p
        }
    }
    var deletion: SyncDeletion? {
        switch self {
        case .deleteRemote(let p, _): return SyncDeletion(path: p, missingFrom: "Mac")
        case .deleteLocal(let p): return SyncDeletion(path: p, missingFrom: "Google Drive")
        default: return nil
        }
    }
}

struct SyncSplitPlan {
    /// Rutas lógicas que bisync debe ignorar en esta ejecución.
    var managedPaths: [String]
    var actions: [SyncSplitAction]
    var deletions: [SyncDeletion] { actions.compactMap(\.deletion) }

    /// Decide sin tocar disco ni red. `localMD5` sólo se llama cuando el tamaño
    /// o la fecha local cambiaron respecto de la última coincidencia.
    static func make(remote: [String: SyncSplitRemoteFile],
                     remoteOrdinary: Set<String>,
                     local: [String: SyncSplitLocalFile],
                     knownOrdinary: Set<String>,
                     baseline: [String: SyncSplitBaseline],
                     thresholdBytes: Int64,
                     localMD5: (String) throws -> String) throws -> SyncSplitPlan {
        func key(_ p: String) -> String { p.precomposedStringWithCanonicalMapping }
        let ordinaryRemote = Set(remoteOrdinary.map(key)), ordinaryKnown = Set(knownOrdinary.map(key))
        var candidates = Set(remote.keys).union(baseline.keys)
        if thresholdBytes > 0 {
            for (path, file) in local where file.size > thresholdBytes && remote[path] == nil && baseline[path] == nil
                && !ordinaryKnown.contains(key(path)) && !ordinaryRemote.contains(key(path)) {
                candidates.insert(path)
            }
        }
        var actions: [SyncSplitAction] = []
        for path in candidates.sorted() {
            let r = remote[path], l = local[path], b = baseline[path]
            if let r, ordinaryRemote.contains(key(path)) { _ = r; throw SyncFailure.message("«\(path)» existe en Drive como documento dividido y como archivo común. Renombrá uno antes de sincronizar.") }
            guard let b else {
                switch (r, l) {
                case (nil, nil): actions.append(.forget(path))
                case (let r?, nil): actions.append(.download(path, r))
                case (nil, _?): actions.append(.upload(path))
                case (let r?, _?): actions.append(try localMD5(path) == r.md5 ? .adopt(path, r) : .conflict(path, r))
                }
                continue
            }
            let localChanged: Bool
            if let l, l.size != b.localSize || l.modTime != b.localModTime { localChanged = try localMD5(path) != b.md5 }
            else { localChanged = false }
            let remoteChanged = r.map { $0.id != b.id || $0.md5 != b.md5 } ?? false
            switch (r, l) {
            case (nil, nil): actions.append(.forget(path))
            case (nil, _?): actions.append(localChanged ? .upload(path) : .deleteLocal(path))
            case (let r?, nil): actions.append(remoteChanged ? .download(path, r) : .deleteRemote(path, r))
            case (let r?, _?):
                switch (localChanged, remoteChanged) {
                case (false, false): actions.append(.adopt(path, r))
                case (true, false): actions.append(.edit(path, r))
                case (false, true): actions.append(.download(path, r))
                case (true, true): actions.append(try localMD5(path) == r.md5 ? .adopt(path, r) : .conflict(path, r))
                }
            }
        }
        let managed = actions.compactMap { action -> String? in if case .forget = action { return nil }; return action.path }
        return SyncSplitPlan(managedPaths: managed, actions: actions)
    }
}

/// Acceso a Drive que necesita el coordinador. La implementación real usa la
/// API de Drive; las pruebas usan un Drive simulado en memoria.
protocol SyncSplitRemote: AnyObject {
    func allocateID() throws -> String
    /// ID de la carpeta `relative` (vacío = carpeta vinculada); la crea si falta.
    func folderID(_ relative: String) throws -> String
    func current(_ id: String) throws -> (etag: String, file: SyncSplitRemoteFile, partBytes: Int64, name: String, parent: String)?
    func download(_ id: String, to destination: URL) throws
    func create(id: String, parent: String, name: String, file: URL, size: Int64, md5: String, partBytes: Int64) throws
    func edit(id: String, etag: String, name: String, parent: String, generation: String, file: URL, size: Int64, md5: String, partBytes: Int64) throws
    func trash(_ id: String) throws
}

/// Una operación pendiente. Se guarda antes de la primera escritura en Drive.
struct SyncSplitOperation: Codable {
    var kind: String          // "create" | "edit"
    var path: String
    var md5: String
    var size: Int64
    var partBytes: Int64
    var id: String
    var parent: String
    var generation: String?
    var etag: String?
}

final class SyncSplitCoordinator {
    let remote: SyncSplitRemote
    let local: URL
    let work: URL
    let versions: URL
    let thresholdBytes: Int64
    var onActivity: ((String) -> Void)?
    private let fm = FileManager.default

    init(remote: SyncSplitRemote, local: URL, work: URL, versions: URL, thresholdBytes: Int64) {
        self.remote = remote; self.local = local; self.work = work; self.versions = versions; self.thresholdBytes = thresholdBytes
    }

    static func md5(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = Insecure.MD5()
        while let block = try handle.read(upToCount: 4 * 1024 * 1024), !block.isEmpty { hash.update(data: block) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func file(_ path: String) -> URL { local.appendingPathComponent(path) }
    private func stats(_ url: URL) throws -> SyncSplitLocalFile {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw SyncFailure.message("«\(url.lastPathComponent)» no es un archivo común. Se detuvo la sincronización.") }
        return SyncSplitLocalFile(size: Int64(values.fileSize ?? 0), modTime: values.contentModificationDate)
    }
    private func opDirectory(_ path: String) -> URL {
        let digest = SHA256.hash(data: Data(path.precomposedStringWithCanonicalMapping.utf8)).map { String(format: "%02x", $0) }.joined()
        return work.appendingPathComponent(String(digest.prefix(32)), isDirectory: true)
    }
    private func privateDirectory(_ url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private func split(_ path: String) -> (dir: String, name: String) {
        let ns = path as NSString
        let dir = ns.deletingLastPathComponent
        return (dir == "." ? "" : dir, ns.lastPathComponent)
    }

    /// Termina las subidas que una ejecución anterior dejó a medias, con los
    /// mismos IDs y la copia congelada del contenido. Devuelve las rutas
    /// completadas y registra su estado acordado.
    func recover(baseline: inout [String: SyncSplitBaseline], save: ([String: SyncSplitBaseline]) throws -> Void) throws {
        guard fm.fileExists(atPath: work.path) else { return }
        for dir in try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil) {
            let opFile = dir.appendingPathComponent("op.json")
            guard let data = try? Data(contentsOf: opFile), let op = try? JSONDecoder().decode(SyncSplitOperation.self, from: data) else {
                try? fm.removeItem(at: dir); continue
            }
            onActivity?("Retomando «\(op.path)»…")
            try finish(op, directory: dir)
            // Baseline con tamaño local imposible: obliga a comparar MD5 en el
            // próximo plan, así un cambio local posterior no se pierde.
            baseline[op.path] = SyncSplitBaseline(id: op.id, md5: op.md5, size: op.size, localSize: -1, localModTime: nil)
            try save(baseline)
            try? fm.removeItem(at: dir)
        }
    }

    private func finish(_ op: SyncSplitOperation, directory: URL) throws {
        let content = directory.appendingPathComponent("content")
        guard fm.fileExists(atPath: content.path) else { throw SyncFailure.message("Falta la copia preparada de «\(op.path)». Se conservaron los archivos.") }
        let name = split(op.path).name
        if op.kind == "create" {
            try remote.create(id: op.id, parent: op.parent, name: name, file: content, size: op.size, md5: op.md5, partBytes: op.partBytes)
        } else {
            guard let generation = op.generation, let etag = op.etag else { throw SyncFailure.message("Diario de edición incompleto para «\(op.path)».") }
            try remote.edit(id: op.id, etag: etag, name: name, parent: op.parent, generation: generation, file: content, size: op.size, md5: op.md5, partBytes: op.partBytes)
        }
    }

    /// Congela el contenido local (clon APFS cuando es posible) y guarda el
    /// diario antes de escribir en Drive.
    private func stage(_ path: String, kind: String, id: String, parent: String, partBytes: Int64, generation: String?, etag: String?) throws -> (SyncSplitOperation, URL) {
        let dir = opDirectory(path)
        try? fm.removeItem(at: dir)
        try privateDirectory(dir)
        let content = dir.appendingPathComponent("content")
        try fm.copyItem(at: file(path), to: content)
        let size = Int64(try content.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let op = SyncSplitOperation(kind: kind, path: path, md5: try Self.md5(content), size: size, partBytes: partBytes,
                                    id: id, parent: parent, generation: generation, etag: etag)
        let journal = dir.appendingPathComponent("op.json")
        try JSONEncoder().encode(op).write(to: journal, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
        return (op, dir)
    }

    /// Guarda la copia local en Versions antes de sobrescribirla o quitarla.
    private func preserve(_ path: String) throws {
        let source = file(path)
        guard fm.fileExists(atPath: source.path) else { return }
        let target = versions.appendingPathComponent(path)
        try privateDirectory(target.deletingLastPathComponent())
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: source, to: target)
    }

    private func downloadInto(_ path: String, _ r: SyncSplitRemoteFile) throws {
        let destination = file(path)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".nimbo-split-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        try remote.download(r.id, to: temporary)
        let size = Int64(try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1)
        guard size == r.size, try Self.md5(temporary) == r.md5 else {
            throw SyncFailure.message("La descarga de «\(path)» no coincide con Drive. Se conservó la copia local.")
        }
        try preserve(path)
        try fm.moveItem(at: temporary, to: destination)
    }

    private func conflictName(_ path: String, tag: String) -> String {
        let parts = split(path), leaf = parts.name as NSString
        let ext = leaf.pathExtension, stem = ext.isEmpty ? parts.name : leaf.deletingPathExtension
        var n = 0, candidate: String
        repeat {
            n += 1
            let name = stem + " (conflicto Mac \(tag)" + (n > 1 ? "-\(n)" : "") + ")" + (ext.isEmpty ? "" : "." + ext)
            candidate = parts.dir.isEmpty ? name : parts.dir + "/" + name
        } while fm.fileExists(atPath: file(candidate).path)
        return candidate
    }

    private func record(_ path: String, id: String, md5: String, size: Int64) throws -> SyncSplitBaseline {
        let s = try stats(file(path))
        return SyncSplitBaseline(id: id, md5: md5, size: size, localSize: s.size, localModTime: s.modTime)
    }

    private func createNew(_ path: String, partBytes: Int64) throws -> SyncSplitBaseline {
        let parent = try remote.folderID(split(path).dir)
        let (op, dir) = try stage(path, kind: "create", id: try remote.allocateID(), parent: parent, partBytes: partBytes, generation: nil, etag: nil)
        onActivity?("Subiendo «\(path)» en partes…")
        try finish(op, directory: dir)
        try? fm.removeItem(at: dir)
        return try record(path, id: op.id, md5: op.md5, size: op.size)
    }

    /// Ejecuta el plan. Las acciones de borrado sólo corren si `approved`.
    /// Devuelve las rutas nuevas que quedaron como copias de conflicto.
    @discardableResult
    func execute(_ plan: SyncSplitPlan, approved: Bool, tag: String,
                 baseline: inout [String: SyncSplitBaseline], save: ([String: SyncSplitBaseline]) throws -> Void) throws -> [String] {
        var conflicts: [String] = []
        for action in plan.actions {
            switch action {
            case .forget(let path):
                baseline[path] = nil
            case .adopt(let path, let r):
                baseline[path] = try record(path, id: r.id, md5: r.md5, size: r.size)
            case .download(let path, let r):
                onActivity?("Descargando «\(path)»…")
                try downloadInto(path, r)
                baseline[path] = try record(path, id: r.id, md5: r.md5, size: r.size)
            case .upload(let path):
                let partBytes = Int64(baseline[path].map { _ in thresholdBytes } ?? thresholdBytes)
                guard partBytes > 0 else { continue }
                baseline[path] = try createNew(path, partBytes: partBytes)
            case .edit(let path, let r):
                guard let current = try remote.current(r.id) else {
                    // Desapareció de Drive mientras tanto: conservar como documento nuevo.
                    baseline[path] = try createNew(path, partBytes: thresholdBytes > 0 ? thresholdBytes : 100_000_000)
                    break
                }
                guard current.file.md5 == r.md5 else {
                    // Drive cambió después del plan: tratarlo como conflicto.
                    let copy = conflictName(path, tag: tag)
                    try fm.moveItem(at: file(path), to: file(copy)); conflicts.append(copy)
                    try downloadInto(path, current.file)
                    baseline[path] = try record(path, id: current.file.id, md5: current.file.md5, size: current.file.size)
                    break
                }
                let (op, dir) = try stage(path, kind: "edit", id: r.id, parent: current.parent, partBytes: current.partBytes,
                                          generation: try remote.allocateID(), etag: current.etag)
                onActivity?("Subiendo la edición de «\(path)»…")
                try finish(op, directory: dir)
                try? fm.removeItem(at: dir)
                baseline[path] = try record(path, id: r.id, md5: op.md5, size: op.size)
            case .conflict(let path, let r):
                // Drive conserva su documento (y su ID); la versión del Mac pasa a una copia.
                let copy = conflictName(path, tag: tag)
                try fm.moveItem(at: file(path), to: file(copy)); conflicts.append(copy)
                try downloadInto(path, r)
                baseline[path] = try record(path, id: r.id, md5: r.md5, size: r.size)
                // Con umbral activo, la copia grande también viaja dividida; con
                // «Nunca» queda como archivo común y bisync la sube en la próxima pasada.
                if thresholdBytes > 0, try stats(file(copy)).size > thresholdBytes {
                    baseline[copy] = try createNew(copy, partBytes: thresholdBytes)
                }
            case .deleteRemote(let path, let r):
                guard approved else { continue }
                onActivity?("Moviendo «\(path)» a la papelera de Drive…")
                try remote.trash(r.id)
                baseline[path] = nil
            case .deleteLocal(let path):
                guard approved else { continue }
                try preserve(path)
                baseline[path] = nil
            }
            try save(baseline)
        }
        return conflicts
    }
}

/// Drive real: API de Google con escritura condicional y diario de partes.
final class GoogleSyncSplitRemote: SyncSplitRemote {
    private let api: DriveAPI
    private let writer: DriveWriteAPI
    private let rootID: String
    private let isCancelled: () -> Bool
    private var folders: [String: String] = [:]
    private let rate: Int

    init(config: URL, remote: String, rootID: String, downloadRate: Int, isCancelled: @escaping () -> Bool) {
        let api = DriveAPI(configuration: config, remoteName: remote)
        self.api = api; writer = DriveWriteAPI(api: api); self.rootID = rootID; self.isCancelled = isCancelled; rate = downloadRate
        folders[""] = rootID
    }

    private func blocking<T>(_ body: @escaping () async throws -> T) throws -> T {
        let done = DispatchSemaphore(value: 0)
        var result: Result<T, Error>?
        let task = Task.detached { do { result = .success(try await body()) } catch { result = .failure(error) }; done.signal() }
        while done.wait(timeout: .now() + .milliseconds(200)) == .timedOut {
            if isCancelled() { task.cancel() }
        }
        guard let result else { throw SyncFailure.message("Operación de Drive incompleta.") }
        return try result.get()
    }
    private var cancelCheck: () throws -> Void { { [isCancelled] in if isCancelled() { throw CancellationError() } } }

    func allocateID() throws -> String { try blocking { try await self.writer.allocateID() } }

    func folderID(_ relative: String) throws -> String {
        if let known = folders[relative] { return known }
        let ns = relative as NSString
        let parentPath = ns.deletingLastPathComponent == "." ? "" : ns.deletingLastPathComponent
        let parent = try folderID(parentPath), name = ns.lastPathComponent
        let id: String = try blocking {
            var page: String?, matches: [DriveObject] = []
            repeat {
                let result = try await self.api.children(parent, page: page)
                matches += result.files.filter { $0.name == name && $0.isFolder && $0.splitLayout == nil && $0.trashed != true }
                page = result.nextPageToken
            } while page != nil
            if matches.count > 1 { throw SyncFailure.message("Hay carpetas duplicadas llamadas «\(name)» en Drive. Renombrá una antes de sincronizar.") }
            if let found = matches.first { return found.id }
            let id = try await self.writer.allocateID()
            return try await self.writer.createFolder(id: id, parent: parent, name: name).object.id
        }
        folders[relative] = id
        return id
    }

    func current(_ id: String) throws -> (etag: String, file: SyncSplitRemoteFile, partBytes: Int64, name: String, parent: String)? {
        try blocking {
            let revision: DriveRevision
            do { revision = try await self.writer.revision(id) } catch DriveFailure.notFound { return nil }
            guard revision.object.trashed != true, let layout = revision.object.splitLayout, !revision.object.splitPending,
                  let parent = revision.object.parents?.first else { return nil }
            return (revision.etag, SyncSplitRemoteFile(id: id, size: layout.size, md5: layout.md5), layout.partBytes, revision.object.name, parent)
        }
    }

    func download(_ id: String, to destination: URL) throws {
        try blocking {
            let object = try await self.api.item(id)
            try await self.api.downloadSplit(object, to: destination, rate: self.rate)
        }
    }

    func create(id: String, parent: String, name: String, file: URL, size: Int64, md5: String, partBytes: Int64) throws {
        guard let layout = DriveSplitLayout(size: size, partBytes: partBytes, md5: md5) else {
            throw SyncFailure.message("«\(name)» no supera el tamaño de división elegido.")
        }
        let check = cancelCheck
        _ = try blocking {
            try await self.writer.createSplit(id: id, parent: parent, name: name, file: file, layout: layout,
                                              journalAccount: "linked-split-writes", keychain: false,
                                              checkCancellation: check, progress: { _, _ in })
        }
    }

    func edit(id: String, etag: String, name: String, parent: String, generation: String, file: URL, size: Int64, md5: String, partBytes: Int64) throws {
        guard let inner = DriveSplitLayout(size: size, partBytes: partBytes, md5: md5, editing: true),
              let next = DriveSplitLayout(size: size, partBytes: partBytes, md5: md5, editing: true, generation: generation) else {
            throw SyncFailure.message("No se pudo preparar la edición de «\(name)».")
        }
        let check = cancelCheck
        _ = try blocking {
            // Si una ejecución anterior ya publicó esta generación, no repetir.
            let now = try await self.writer.revision(id)
            if now.object.splitLayout == next { return now }
            _ = try await self.writer.createSplit(id: generation, parent: id, name: ".nimbo-version-" + generation,
                                                  file: file, layout: inner, journalAccount: "linked-split-writes", keychain: false,
                                                  checkCancellation: check, progress: { _, _ in })
            return try await self.writer.commitSplit(id, etag: etag, name: name, parent: parent, layout: next)
        }
    }

    func trash(_ id: String) throws {
        _ = try blocking {
            let revision = try await self.writer.revision(id)
            return try await self.writer.updateMetadata(id, etag: revision.etag, name: nil, parent: nil, trashed: true)
        }
    }
}
