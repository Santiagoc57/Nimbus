import Foundation
import Darwin

func oauthConfiguration(_ original: String, writeAccess: Bool, remote: String = "GoogleDrive") throws -> String {
    var lines = original.components(separatedBy:.newlines)
    var selected = false, found = false
    for index in lines.indices {
        let value = lines[index].trimmingCharacters(in:.whitespaces)
        if value.hasPrefix("[") { selected = value == "[\(remote)]" }
        if selected, let equal = value.firstIndex(of:"="), value[..<equal].trimmingCharacters(in:.whitespaces) == "scope" {
            lines[index] = "scope = " + (writeAccess ? "drive" : "drive.readonly"); found = true
        }
    }
    guard found else { throw SyncFailure.message("La conexión \(remote) no contiene un alcance OAuth reconocido. Se conservó la configuración anterior.") }
    return lines.joined(separator:"\n")
}

/// Builds or replaces one Google Drive section while preserving every other
/// rclone remote. It is used when a second Drive identity is authorized from
/// the UI; credentials never need to be copied into an existing section.
func oauthConfigurationWithRemote(_ original: String, remote: String, clientID: String, clientSecret: String, writeAccess: Bool) throws -> String {
    guard !remote.isEmpty, !remote.contains("["), !remote.contains("]"), !remote.contains("\n"), !remote.contains("\r"),
          !clientID.contains("\n"), !clientID.contains("\r"), !clientSecret.contains("\n"), !clientSecret.contains("\r") else {
        throw SyncFailure.message("El nombre o las credenciales de Google Drive no son válidos.")
    }
    let section = "[\(remote)]\ntype = drive\nscope = \(writeAccess ? "drive" : "drive.readonly")\nclient_id = \(clientID)\nclient_secret = \(clientSecret)\n"
    var lines = original.components(separatedBy: .newlines)
    var start: Int?
    var end: Int?
    for index in lines.indices {
        let value = lines[index].trimmingCharacters(in: .whitespaces)
        if value == "[\(remote)]" { start = index; continue }
        if start != nil, value.hasPrefix("[") { end = index; break }
    }
    if let start {
        let stop = end ?? lines.count
        lines.replaceSubrange(start..<stop, with: section.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
    } else {
        while lines.last == "" { lines.removeLast() }
        if !lines.isEmpty { lines.append("") }
        lines.append(contentsOf: section.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
    }
    return lines.joined(separator: "\n")
}

struct SyncDeletion: Codable, Equatable {
    let path: String
    let missingFrom: String
}
struct SyncBackupEntry:Equatable {
    let relationID:UUID
    let relativePath:String
    let url:URL
}
struct SyncBackupSchedule: Codable, Equatable {
    static let intervals = [15, 60, 360, 1440]
    static let retentions = [1, 3, 7, 14, 30]
    var enabled = false
    var intervalMinutes = 1440
    var retention = 7
    var lastRun: Date?
    var lastSuccess: Date?
    var message = "Backup programado desactivado."
    var encrypted = false
    var passphrase: String?
    var encryptionSalt: String?
    var intervalLabel: String {
        switch intervalMinutes { case 15: return "Cada 15 minutos"; case 60: return "Cada hora"; case 360: return "Cada 6 horas"; default: return "Cada día" }
    }
}
struct SyncSchedule: Codable, Equatable {
    static let intervals = [15, 60, 360, 1440]
    var enabled = false
    var intervalMinutes = 60
    var lastRun: Date?
    var lastSuccess: Date?
    var message = "Sincronización continua mientras Nimbo está abierto."
    var intervalLabel: String {
        switch intervalMinutes { case 15: return "Cada 15 minutos"; case 60: return "Cada hora"; case 360: return "Cada 6 horas"; default: return "Cada día" }
    }
}
struct SyncRelation: Codable, Identifiable {
    let id: UUID
    let remote: String
    let remotePath: String
    let remoteID: String?
    let localPath: String
    let name: String
    var initialized = false
    var paused = false
    var lastSuccess: Date?
    var localFiles: [String] = []
    var remoteFiles: [String] = []
    var pendingDeletes: [SyncDeletion] = []
    var message = "Preparando carpeta…"
    var externalIdentity:SyncLocalIdentity?
    var initialAttempted:Bool?
    var syncSchedule: SyncSchedule?
    var backupSchedule: SyncBackupSchedule?
    var filters: SyncFilters?
    /// Last agreed state of each split document (logical path → Drive ID, MD5, size, local mtime).
    var splitFiles: [String: SyncSplitBaseline]?
    var remoteLocation: String { remote + ":" + remotePath }
    var marker: String { ".nimbo-check-" + id.uuidString }
}
enum SyncFailure: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// One queue in the app owns this engine. flock also excludes another Nimbo process.
/// No automatic resync after an error, no unconditional overwrite on conflicts,
/// and no propagation of deleted files without reviewing the exact pending set.
final class SyncEngine {
    let root: URL, offlineRoot: URL, config: URL, binary: URL
    let testing: Bool
    private(set) var relations: [SyncRelation] = []
    private let processLock = NSLock()
    private var process: Process?
    private var cancelled = false
    private let activityLog: ActivityLog?
    var onActivity: ((String) -> Void)?
    var onEvent: ((ActivityEvent) -> Void)?
    private var store: URL { root.appendingPathComponent("relations.json") }
    private var settingsFile: URL { root.appendingPathComponent("settings.json") }
    private let settingsLock = NSLock()
    private var storedSettings = SyncSettings()
    var settings: SyncSettings {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        return storedSettings
    }
    init(root: URL, offlineRoot: URL, config: URL, binary: URL, testing: Bool = false, activityFile: URL? = nil) throws {
        self.root = root; self.offlineRoot = offlineRoot; self.config = config; self.binary = binary; self.testing = testing; self.activityLog = activityFile.map(ActivityLog.init)
        try Self.privateDirectory(root)
        storedSettings = SyncSettings.read(at: settingsFile)
        if FileManager.default.fileExists(atPath:store.path) {
            relations = try NimboSecureFile.load([SyncRelation].self, from: store, account: "sync-relations") ?? []
        }
    }
    private func event(_ operation: String, _ detail: String, success: Bool) {
        let value = ActivityEvent(id: UUID(), date: Date(), operation: operation, detail: detail, success: success)
        activityLog?.append(operation: operation, detail: detail, success: success); onEvent?(value)
    }
    private func updateSettings(_ change: (inout SyncSettings) -> Void) throws {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        var next = storedSettings
        change(&next)
        try JSONEncoder().encode(next).write(to: settingsFile, options: .atomic)
        storedSettings = next
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsFile.path)
    }

    func setBandwidthLimit(_ kbps: Int, for direction: TransferDirection) throws {
        guard SyncSettings.allowed.contains(kbps) else { throw SyncFailure.message("Límite de transferencia desconocido.") }
        try updateSettings { $0[direction] = kbps }
    }

    func setFinderSegmentSize(_ mb: Int) throws {
        guard SyncSettings.segmentSizes.contains(mb) else { throw SyncFailure.message("Tamaño de segmento desconocido.") }
        try updateSettings { $0.finderSegmentMB = mb }
    }

    func setLinkedSegmentSize(_ mb: Int) throws {
        guard SyncSettings.segmentSizes.contains(mb) else { throw SyncFailure.message("Tamaño de segmento desconocido.") }
        try updateSettings { $0.linkedSegmentMB = mb }
    }

    func setBackupSegmentSize(_ mb: Int) throws {
        guard SyncSettings.segmentSizes.contains(mb) else { throw SyncFailure.message("Tamaño de segmento desconocido.") }
        try updateSettings { $0.backupSegmentMB = mb }
    }

    func setSplitLargeFiles(_ enabled: Bool) throws {
        try updateSettings { $0.splitLargeFiles = enabled }
    }
    func hasWriteAuthorization(remote: String = "GoogleDrive") -> Bool {
        if testing { return true }
        guard let text = try? String(contentsOf:config,encoding:.utf8) else { return false }
        var selected = false
        for line in text.components(separatedBy:.newlines) {
            let value = line.trimmingCharacters(in:.whitespaces)
            if value.hasPrefix("[") { selected = value == "[\(remote)]" }
            if selected, let equals = value.firstIndex(of:"="), value[..<equals].trimmingCharacters(in:.whitespaces) == "scope" {
                return value[value.index(after:equals)...].trimmingCharacters(in:.whitespaces).split(separator:",").contains("drive")
            }
        }
        return false
    }
    func cancel() {
        processLock.lock(); cancelled = true
        if let process, process.isRunning { kill(process.processIdentifier,SIGINT) }
        processLock.unlock()
    }
    func resetCancellation() { processLock.lock(); cancelled = false; processLock.unlock() }
    func add(remote: String, item: CloudItem) throws -> UUID {
        try validateRemoteSelection(remote,item)
        let id = UUID()
        let name = try CloudBackend.safeBasename(item.Name)
        try Self.privateDirectory(offlineRoot)
        let local = offlineRoot.appendingPathComponent(name + " - " + id.uuidString.prefix(8))
        guard !FileManager.default.fileExists(atPath:local.path) else { throw SyncFailure.message("La carpeta local ya existe.") }
        try Self.privateDirectory(local)
        relations.append(SyncRelation(id:id,remote:remote,remotePath:item.Path,remoteID:item.ID,localPath:local.path,name:name))
        try save()
        return id
    }
    private func validateRemoteSelection(_ remote:String,_ item:CloudItem)throws {
        guard hasWriteAuthorization(remote: remote) else { throw SyncFailure.message("Esta cuenta de Google Drive permite sólo lectura. Habilitá la sincronización para autorizar cambios.") }
        try CloudBackend.validateRemote(remote)
        guard item.IsDir, !item.Path.isEmpty, item.Path != ".Nimbo Versiones", !item.Path.hasPrefix(".Nimbo Versiones/"),
              testing || item.ID?.isEmpty == false else {
            throw SyncFailure.message("Elegí una carpeta de Google Drive, no la raíz ni la carpeta de versiones.")
        }
        for component in item.Path.split(separator:"/",omittingEmptySubsequences:false) { _ = try CloudBackend.safeBasename(String(component)) }
        guard !relations.contains(where:{ $0.remote == remote && ($0.remotePath == item.Path || $0.remotePath.hasPrefix(item.Path + "/") || item.Path.hasPrefix($0.remotePath + "/")) }) else {
            throw SyncFailure.message("Esa carpeta ya está incluida en una sincronización. No se permiten carpetas superpuestas.")
        }
    }
    private func validateExternal(_ local:URL,excluding:UUID?=nil)throws->SyncLocalIdentity {
        let path=local.standardizedFileURL.path,home=FileManager.default.homeDirectoryForCurrentUser.path
        let forbidden=[root.path,offlineRoot.path,home+"/Library","/System","/Library","/Applications"]
        guard !SyncFolderPlan.contains(path,home), !forbidden.contains(where:{SyncFolderPlan.contains($0,path) || SyncFolderPlan.contains(path,$0)}),
              !path.contains("/Library/CloudStorage/"),!path.hasSuffix(".app"),
              !relations.contains(where:{$0.id != excluding && (SyncFolderPlan.contains($0.localPath,path) || SyncFolderPlan.contains(path,$0.localPath))}) else {
            throw SyncFailure.message("Esta carpeta se superpone con otra sincronización, datos de Nimbo o una carpeta del sistema. Elegí otra ubicación.")
        }
        return try SyncLocalIdentity.read(local)
    }
    private func validateLocalTree(_ local:URL)throws {
        var rootInfo=stat();guard lstat(local.path,&rootInfo)==0 else{throw SyncFailure.message("La carpeta local no está disponible.")}
        var enumerationError:Error?
        guard let iterator=FileManager.default.enumerator(at:local,includingPropertiesForKeys:nil,errorHandler:{_,error in enumerationError=error;return false}) else {
            throw SyncFailure.message("No se pudo revisar la carpeta local.")
        }
        var count=0
        for case let file as URL in iterator {
            count+=1;var info=stat()
            guard count<=200000,lstat(file.path,&info)==0,info.st_dev==rootInfo.st_dev,
                  [mode_t(S_IFREG),mode_t(S_IFDIR)].contains(info.st_mode & S_IFMT),info.st_flags & UInt32(SF_DATALESS)==0 else {
                throw SyncFailure.message("La carpeta incluye enlaces, archivos de otra nube, volúmenes anidados, tipos especiales o demasiadas entradas. No se inició la vinculación.")
            }
        }
        if let enumerationError{throw enumerationError}
    }
    func previewExisting(remote:String,item:CloudItem,local:URL)throws->SyncFolderPlan {
        resetCancellation();try validateRemoteSelection(remote,item)
        let identity=try validateExternal(local)
        try validateLocalTree(local)
        let relation=SyncRelation(id:UUID(),remote:remote,remotePath:item.Path,remoteID:item.ID,localPath:local.standardizedFileURL.path,name:item.Name)
        try verifyRemoteDirectory(relation)
        let own=try listing(local.path,hashes:true),cloud=try logicalListing(relation.remoteLocation,hashes:true)
        return try SyncFolderPlan.make(remote:remote,folder:item,localPath:local.standardizedFileURL.path,identity:identity,local:own,cloud:cloud)
    }
    func addExisting(_ plan:SyncFolderPlan)throws->UUID {
        try validateRemoteSelection(plan.remote,plan.folder)
        let local=URL(fileURLWithPath:plan.localPath)
        guard try validateExternal(local)==plan.identity else{throw SyncFailure.message("Cambió la identidad de la carpeta local. Volvé a elegirla.")}
        try validateLocalTree(local)
        var relation=SyncRelation(id:plan.id,remote:plan.remote,remotePath:plan.folder.Path,remoteID:plan.folder.ID,localPath:plan.localPath,name:plan.folder.Name)
        try verifyRemoteDirectory(relation)
        guard SyncFolderPlan.sameSnapshot(try listing(local.path,hashes:true),plan.local),
              SyncFolderPlan.sameSnapshot(try logicalListing(relation.remoteLocation,hashes:true),plan.cloud) else {
            throw SyncFailure.message("Los archivos cambiaron desde la revisión. No se vinculó la carpeta; volvé a revisar el plan.")
        }
        let planDirectory=root.appendingPathComponent("InitialPlans")
        try Self.privateDirectory(planDirectory)
        let planFile=planDirectory.appendingPathComponent(plan.id.uuidString+".json")
        try JSONEncoder().encode(plan).write(to:planFile,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:planFile.path)
        relation.externalIdentity=plan.identity
        relations.append(relation);try save();return relation.id
    }
    func setPaused(_ id: UUID, _ paused: Bool) throws {
        guard let index = relations.firstIndex(where:{$0.id == id}) else { return }
        relations[index].paused = paused
        relations[index].message = paused ? "Pausada. Los archivos locales se conservan." : "Lista para sincronizar."
        try save()
    }
    func setBackupSchedule(_ id: UUID, enabled: Bool, intervalMinutes: Int, retention: Int, encrypted: Bool = false, passphrase: String? = nil) throws {
        guard SyncBackupSchedule.intervals.contains(intervalMinutes), SyncBackupSchedule.retentions.contains(retention) else {
            throw SyncFailure.message("Elegí una frecuencia y una retención válidas para el backup.")
        }
        guard let index = relations.firstIndex(where: {$0.id == id}) else { throw SyncFailure.message("No se encontró la sincronización seleccionada.") }
        var schedule = relations[index].backupSchedule ?? SyncBackupSchedule()
        schedule.enabled = enabled; schedule.intervalMinutes = intervalMinutes; schedule.retention = retention
        if encrypted {
            let candidate: String?
            if let value = passphrase?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { candidate = value }
            else { candidate = schedule.passphrase }
            guard let candidate, candidate.utf8.count >= 8 else {
                throw SyncFailure.message("Para cifrar el backup elegí una frase de al menos 8 caracteres. Nimbo no puede recuperarla.")
            }
            schedule.encrypted = true
            schedule.passphrase = candidate
            if schedule.encryptionSalt == nil { schedule.encryptionSalt = UUID().uuidString }
        } else {
            schedule.encrypted = false
            schedule.passphrase = nil
            schedule.encryptionSalt = nil
        }
        schedule.message = enabled ? "Backup programado: \(schedule.intervalLabel), conserva \(retention) copias." : "Backup programado desactivado."
        relations[index].backupSchedule = schedule
        try save()
    }
    func setSyncSchedule(_ id: UUID, enabled: Bool, intervalMinutes: Int) throws {
        guard SyncSchedule.intervals.contains(intervalMinutes) else {
            throw SyncFailure.message("Elegí una frecuencia válida para la sincronización.")
        }
        guard let index = relations.firstIndex(where: {$0.id == id}) else { throw SyncFailure.message("No se encontró la sincronización seleccionada.") }
        var schedule = relations[index].syncSchedule ?? SyncSchedule()
        schedule.enabled = enabled; schedule.intervalMinutes = intervalMinutes
        if !enabled { schedule.lastRun = nil; schedule.lastSuccess = nil }
        schedule.message = enabled ? "Sincronización programada: \(schedule.intervalLabel)." : "Sincronización continua mientras Nimbo está abierto."
        relations[index].syncSchedule = schedule
        try save()
    }
    func setFilters(_ id: UUID, patterns: [String]) throws {
        guard let index = relations.firstIndex(where: {$0.id == id}) else { throw SyncFailure.message("No se encontró la sincronización seleccionada.") }
        let valid = try SyncFilters.validate(patterns)
        relations[index].filters = SyncFilters(patterns: valid)
        event("Reglas", "Exclusiones actualizadas para \(relations[index].name): \(valid.joined(separator: ", ")).", success: true)
        try save()
    }
    private func filters(for relation: SyncRelation) -> [String] { (try? SyncFilters.validate(relation.filters?.patterns ?? SyncFilters.defaults)) ?? SyncFilters.defaults }
    func backupIsDue(_ id: UUID, now: Date = Date()) -> Bool {
        guard let relation = relations.first(where: {$0.id == id}), let schedule = relation.backupSchedule, schedule.enabled else { return false }
        guard let last = schedule.lastRun else { return true }
        return now.timeIntervalSince(last) >= TimeInterval(schedule.intervalMinutes * 60)
    }
    func syncIsDue(_ id: UUID, now: Date = Date()) -> Bool {
        guard let relation = relations.first(where: {$0.id == id}) else { return false }
        guard let schedule = relation.syncSchedule, schedule.enabled else { return true }
        guard let last = schedule.lastRun else { return true }
        return now.timeIntervalSince(last) >= TimeInterval(schedule.intervalMinutes * 60)
    }
    private func acquireEngineLock() throws -> Int32 {
        let fd = open(root.appendingPathComponent("engine.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SyncFailure.message("No se pudo abrir el estado de sincronización.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw SyncFailure.message("Otra operación de Nimbo está en curso.")
        }
        return fd
    }

    func runBackup(_ id: UUID) throws {
        let lock = try acquireEngineLock()
        defer { close(lock) }
        guard let index = relations.firstIndex(where: {$0.id == id}) else { throw SyncFailure.message("No se encontró la sincronización seleccionada.") }
        guard let authRelation = relations.first(where: {$0.id == id}), hasWriteAuthorization(remote: authRelation.remote) else { throw SyncFailure.message("Falta autorizar cambios en esta cuenta de Google Drive.") }
        var relation = relations[index]
        var schedule = relation.backupSchedule ?? SyncBackupSchedule(enabled: true)
        guard schedule.retention > 0 else { throw SyncFailure.message("La retención del backup debe ser mayor que cero.") }
        let local = URL(fileURLWithPath: relation.localPath)
        if let identity = relation.externalIdentity {
            guard try validateExternal(local, excluding: relation.id) == identity else { throw SyncFailure.message("Cambió la identidad de la carpeta local. No se inició el backup.") }
            try validateLocalTree(local)
        } else {
            guard local.deletingLastPathComponent().standardizedFileURL == offlineRoot.standardizedFileURL,
                  local.resolvingSymlinksInPath() == local.standardizedFileURL,
                  (try local.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
                throw SyncFailure.message("La carpeta local fue movida o no está disponible. No se inició el backup.")
            }
        }
        try verifyRemoteDirectory(relation)
        resetCancellation()
        let stampFormatter = DateFormatter(); stampFormatter.locale = Locale(identifier: "en_US_POSIX"); stampFormatter.timeZone = TimeZone(secondsFromGMT: 0); stampFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = stampFormatter.string(from: Date())
        let segmentMB = settings.backupSegmentMB
        let unique = UUID().uuidString
        let name = stamp + (segmentMB > 0 ? "-s" + String(segmentMB) : "") + "-" + unique
        let location = try backupLocation(relation)
        defer { if let config = location.config { try? FileManager.default.removeItem(at: config) } }
        let staging = location.path + ".pending-" + unique
        let destination = location.path + name
        let overlay = segmentArguments(remote: staging + "/contents", megabytes: segmentMB)
        let target = overlay.isEmpty ? staging : segmentRemote(megabytes: segmentMB)
        let temporaryConfig = location.config
        schedule.lastRun = Date(); schedule.message = "Backup en curso…"; relation.backupSchedule = schedule; relations[index] = relation; try save()
        event("Backup", "Iniciado para \(relation.name).", success: true)
        do {
            var exclusions = ["--exclude", relation.marker]
            for pattern in filters(for: relation) { exclusions += ["--exclude", pattern] }
            let sourceIndex = segmentMB > 0 ? try backupIndex(of: local, exclusions: exclusions) : nil
            var arguments = ["copy", local.path, target, "--create-empty-src-dirs", "--retries", "1", "--checkers", "4", "--transfers", "2"]
            if settings.splitLargeFiles { arguments += ["--drive-chunk-size", "64M"] }
            onActivity?("Guardando backup de \(relation.name)…")
            _ = try run(["mkdir", target] + overlay, configURL: temporaryConfig)
            _ = try run(arguments + exclusions + overlay, timeout: 86400, configURL: temporaryConfig)
            let readBack = segmentMB > 0 ? ["--download"] : []
            _ = try run(["check", local.path, target] + readBack + exclusions + overlay, timeout: 86400, configURL: temporaryConfig)
            if let sourceIndex {
                guard try backupIndex(of: local, exclusions: exclusions) == sourceIndex else { throw SyncFailure.message("La carpeta cambió durante el respaldo. Volvé a intentarlo.") }
                let file = root.appendingPathComponent(".backup-index-" + unique)
                defer { try? FileManager.default.removeItem(at: file) }
                try sourceIndex.write(to: file, options: .atomic)
                _ = try run(["copyto", file.path, staging + "/index-v1.json"], configURL: temporaryConfig)
            }
            _ = try run(["moveto", staging, destination, "--retries", "1"], timeout: 86400, configURL: temporaryConfig)
            let snapshots = try snapshotNames(at: location.path, config: temporaryConfig)
            guard snapshots.contains(name) else { throw SyncFailure.message("Drive no confirmó la publicación del respaldo.") }
            let removeCount = max(0, snapshots.count - schedule.retention)
            for old in snapshots.prefix(removeCount) where old != name {
                _ = try run(["purge", location.path + old, "--retries", "1"], configURL: temporaryConfig)
            }
            schedule.lastSuccess = Date(); schedule.message = "Backup al día: \(stamp). Conserva \(min(schedule.retention, snapshots.count)) copias."; relation.backupSchedule = schedule; relations[index] = relation; try save()
            event("Backup", schedule.message, success: true)
        } catch {
            // This unique staging directory was allocated by this invocation.
            // A failed move may already have published the final snapshot.
            _ = try? run(["purge", staging, "--retries", "1"], configURL: temporaryConfig)
            schedule.message = "Backup detenido: \(error.localizedDescription)"; relation.backupSchedule = schedule; relations[index] = relation; try? save(); event("Backup", schedule.message, success: false); throw error
        }
    }
    private func backupLocation(_ relation: SyncRelation) throws -> (path: String, config: URL?) {
        let folder = ".Nimbo Backups/" + relation.id.uuidString
        guard let schedule = relation.backupSchedule, schedule.encrypted else { return (relation.remote + ":" + folder + "/", nil) }
        guard let passphrase = schedule.passphrase, let salt = schedule.encryptionSalt else { throw SyncFailure.message("Falta la clave del respaldo cifrado.") }
        let alias = "NimboBackup_" + relation.id.uuidString.replacingOccurrences(of: "-", with: "")
        let config = try encryptedBackupConfig(alias: alias, baseRemote: relation.remote, backupRoot: folder, passphrase: passphrase, salt: salt)
        return (alias + ":", config)
    }

    private struct BackupIndexEntry: Encodable {
        let path: String
        let bytes: Int64?
        let sha256: String?
    }

    private func backupIndex(of local: URL, exclusions: [String] = []) throws -> Data {
        let listing = try run(["lsjson", local.path, "-R", "--hash", "--hash-type", "sha256", "--no-mimetype"] + exclusions, timeout: 86400)
        var entries: [BackupIndexEntry] = []
        for item in try CloudBackend.decodeListing(listing) {
            guard !item.Path.lowercased().contains(".nimbo.segment.") else { throw SyncFailure.message("El nombre contiene .nimbo.segment., reservado para partes de un respaldo dividido.") }
            let hash = item.Hashes?.first { $0.key.lowercased().replacingOccurrences(of: "-", with: "") == "sha256" }?.value
            guard item.IsDir || hash?.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else { throw SyncFailure.message("No se pudo verificar la integridad de un archivo del respaldo.") }
            entries.append(BackupIndexEntry(path: item.Path, bytes: item.IsDir ? nil : item.Size, sha256: item.IsDir ? nil : hash))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(entries.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) })
    }

    private func segmentRemote(megabytes: Int) -> String {
        // In rclone 1.76 a SizeSuffix CLI override is formatted to three
        // decimals before backend creation. The inline value preserves bytes.
        ":chunker,chunk_size=" + String(Int64(megabytes) * 1_000_000) + "B:"
    }

    private func segmentArguments(remote: String, megabytes: Int) -> [String] {
        guard megabytes > 0 else { return [] }
        return ["--chunker-remote", remote,
                "--chunker-name-format", "*.nimbo.segment.######", "--chunker-hash-type", "md5", "--chunker-meta-format", "simplejson"]
    }

    // Older snapshots used a bare timestamp. New snapshots identify their own
    // layout so a later change of threshold cannot change how they are read.
    private func snapshotSegmentSize(_ name: String) -> Int? {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard name.range(of: #"^[0-9]{8}-[0-9]{6}($|-)"#, options: .regularExpression) != nil else { return nil }
        if parts.count == 2 { return 0 }
        let segmented = parts[2].hasPrefix("s")
        let uuid = parts.dropFirst(segmented ? 3 : 2).joined(separator: "-")
        guard UUID(uuidString: uuid)?.uuidString == uuid else { return nil }
        if !segmented { return 0 }
        guard let size = Int(parts[2].dropFirst()), size > 0, SyncSettings.segmentSizes.contains(size), parts[2] == "s" + String(size) else { return nil }
        return size
    }

    private func snapshotNames(at location: String, config: URL?) throws -> [String] {
        let data = try run(["lsjson", location, "--dirs-only", "--no-mimetype"], configURL: config, missingListingIsEmpty: true)
        return try CloudBackend.decodeListing(data).filter { $0.IsDir && snapshotSegmentSize($0.Name) != nil }.map(\.Name).sorted()
    }

    func remoteBackups(_ id: UUID) throws -> [String] {
        guard let relation = relations.first(where: { $0.id == id }) else { throw SyncFailure.message("Sincronización desconocida.") }
        let location = try backupLocation(relation)
        defer { if let config = location.config { try? FileManager.default.removeItem(at: config) } }
        return try snapshotNames(at: location.path, config: location.config)
    }

    func restoreRemoteBackup(_ id: UUID, snapshot: String, destination: URL) throws {
        let lock = try acquireEngineLock()
        defer { close(lock) }
        resetCancellation()
        guard let relation = relations.first(where: { $0.id == id }), let size = snapshotSegmentSize(snapshot) else { throw SyncFailure.message("Respaldo desconocido.") }
        let target = destination.standardizedFileURL
        let parent = target.deletingLastPathComponent()
        let fm = FileManager.default
        guard !fm.fileExists(atPath: target.path), try parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw SyncFailure.message("Elegí un nombre nuevo en una carpeta existente.")
        }
        let location = try backupLocation(relation)
        defer { if let config = location.config { try? fm.removeItem(at: config) } }
        guard try snapshotNames(at: location.path, config: location.config).contains(snapshot) else { throw SyncFailure.message("No se encontró el respaldo en Google Drive.") }
        let remote = location.path + snapshot
        let overlay = segmentArguments(remote: remote + "/contents", megabytes: size)
        let source = overlay.isEmpty ? remote : segmentRemote(megabytes: size)
        let staging = parent.appendingPathComponent(".nimbo-restore-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        _ = try run(["copy", source, staging.path, "--create-empty-src-dirs"] + overlay, timeout: 86400, configURL: location.config)
        _ = try run(["check", source, staging.path] + overlay, timeout: 86400, configURL: location.config)
        if size > 0 {
            let expected = try run(["cat", remote + "/index-v1.json"], configURL: location.config)
            guard try backupIndex(of: staging) == expected else { throw SyncFailure.message("El respaldo está incompleto o dañado. No se publicó la restauración.") }
        }
        guard renamex_np(staging.path, target.path, UInt32(RENAME_EXCL)) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
    func backupEntries(_ id:UUID)throws->[SyncBackupEntry] {
        guard relations.contains(where:{$0.id==id}) else{throw SyncFailure.message("No se encontró la sincronización seleccionada.")}
        let root = self.root.appendingPathComponent("Versions/"+id.uuidString)
        guard FileManager.default.fileExists(atPath:root.path) else{return []}
        var entries:[SyncBackupEntry]=[]
        guard let e=FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey],options:[.skipsHiddenFiles]) else{return []}
        for case let url as URL in e {
            let values=try url.resourceValues(forKeys:[.isRegularFileKey])
            guard values.isRegularFile==true else{continue}
            entries.append(SyncBackupEntry(relationID:id,relativePath:String(url.path.dropFirst(root.path.count+1)),url:url))
        }
        return entries.sorted{$0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending}
    }
    func restoreLocalBackup(_ id:UUID,url source:URL)throws {
        guard let index=relations.firstIndex(where:{$0.id==id}) else{throw SyncFailure.message("No se encontró la sincronización seleccionada.")}
        let backupRoot=root.appendingPathComponent("Versions/"+id.uuidString).standardizedFileURL
        let sourceURL=source.standardizedFileURL
        guard sourceURL.path.hasPrefix(backupRoot.path+"/"),
              (try sourceURL.resourceValues(forKeys:[.isRegularFileKey])).isRegularFile==true else{throw SyncFailure.message("Elegí un archivo dentro de las versiones conservadas de esta sincronización.")}
        let relation=relations[index],local=URL(fileURLWithPath:relation.localPath)
        if let identity=relation.externalIdentity {guard try validateExternal(local,excluding:id)==identity else{throw SyncFailure.message("Cambió la identidad de la carpeta local. No se restauró la versión.")}}
        try validateLocalTree(local)
        let relative=String(sourceURL.path.dropFirst(backupRoot.path.count+1))
        let components=relative.split(separator:"/").map(String.init)
        guard !components.isEmpty,components.allSatisfy({(try? CloudBackend.safeBasename($0)) != nil}) else{throw SyncFailure.message("La ruta de la versión no es segura.")}
        let target=components.dropFirst().reduce(local){$0.appendingPathComponent($1)}
        let targetParent=target.deletingLastPathComponent();try FileManager.default.createDirectory(at:targetParent,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        if FileManager.default.fileExists(atPath:target.path) {
            let oldName=target.lastPathComponent+" (conflicto antes de restaurar "+id.uuidString.prefix(8)+")"
            let conflict=targetParent.appendingPathComponent(oldName)
            guard !FileManager.default.fileExists(atPath:conflict.path) else{throw SyncFailure.message("Ya existe la copia de conflicto para esta restauración. No se sobrescribió nada.")}
            try FileManager.default.moveItem(at:target,to:conflict)
        }
        let temporary=targetParent.appendingPathComponent(".nimbo-restore-"+UUID().uuidString)
        try FileManager.default.copyItem(at:sourceURL,to:temporary)
        try FileManager.default.moveItem(at:temporary,to:target)
        relations[index].message="Versión restaurada localmente. Revisá el conflicto conservado y pulsá Sincronizar ahora para subir el cambio."
        try save()
    }
    func forget(_ id: UUID) throws {
        // Deliberately preserve local files, remote files, versions, and recovery state.
        relations.removeAll { $0.id == id }; try save()
    }
    func verifyRemoteDirectory(_ relation: SyncRelation) throws {
        // lsjson --stat synthesizes the root directory and omits its Drive ID.
        // Enumerating its parent gives the actual child ID and detects duplicates.
        var components = relation.remotePath.components(separatedBy:"/")
        let leaf = components.removeLast()
        let data = try run(["lsjson",relation.remote + ":" + components.joined(separator:"/"),"--dirs-only","--no-mimetype","--metadata"])
        let candidates = try CloudBackend.decodeListing(data).filter { $0.Name == leaf }
        guard candidates.count == 1, candidates[0].IsDir, testing || candidates[0].ID == relation.remoteID else {
            throw SyncFailure.message("La carpeta remota cambió de identidad, tiene duplicados o no está disponible. Se detuvo la sincronización.")
        }
    }
    func synchronize(_ id: UUID, approving deletions: [SyncDeletion]? = nil) throws {
        guard let index = relations.firstIndex(where:{$0.id == id}) else { return }
        guard let candidate = relations.first(where: {$0.id == id}), hasWriteAuthorization(remote: candidate.remote) else { throw SyncFailure.message("Falta autorizar cambios en esta cuenta de Google Drive.") }
        resetCancellation()
        let lock = try acquireEngineLock()
        defer { close(lock) }
        var relation = relations[index]
        if var schedule = relation.syncSchedule, schedule.enabled {
            schedule.lastRun = Date(); schedule.message = "Sincronización programada en curso…"
            relation.syncSchedule = schedule; relations[index] = relation; try save()
        }
        event("Sincronización", "Iniciada para \(relation.name).", success: true)
        do {
            let local = URL(fileURLWithPath:relation.localPath)
            if let identity=relation.externalIdentity {
                guard try validateExternal(local,excluding:relation.id)==identity else {
                    throw SyncFailure.message("El disco o la carpeta local cambió de identidad. No se propagó ningún borrado.")
                }
                try validateLocalTree(local)
            } else {
              guard local.deletingLastPathComponent().standardizedFileURL == offlineRoot.standardizedFileURL,
                  local.resolvingSymlinksInPath() == local.standardizedFileURL,
                  (try local.resourceValues(forKeys:[.isDirectoryKey])).isDirectory == true else {
                throw SyncFailure.message("La carpeta local fue movida o no está disponible. No se propagó ningún borrado.")
              }
            }
            try verifyRemoteDirectory(relation)
            // Use the same file set for deletion review, package detection and bisync.
            // The access marker must survive even a rule that excludes all dotfiles.
            let exclusions = filters(for: relation)
            // Temporary objects of split uploads/downloads never travel through bisync.
            var rules = ["--filter", "+ /" + relation.marker,
                         "--filter", "- .nimbo-upload-*/", "--filter", "- .nimbo-split-*"] +
                exclusions.flatMap { ["--filter", "- " + $0] }
            let initialData = try listingData(relation.remoteLocation, rules: rules)
            let projection = try CloudBackend.projectListing(initialData)
            let packages = projection.items.filter { $0.splitFile == true }
            let excludedPackages = packages.filter { SyncFilters.excludesLogicalFile($0.Path, patterns: exclusions) }
            let managedPackages = packages.filter { !SyncFilters.excludesLogicalFile($0.Path, patterns: exclusions) }
            // Split documents: decide with the logical view of both sides.
            let localView = try listing(local.path, rules: rules)
            var remoteSplit: [String: SyncSplitRemoteFile] = [:]
            for item in managedPackages {
                guard let fileID = item.ID, let md5 = item.Hashes?["md5"] else { throw CloudBackendError.invalidMetadata }
                remoteSplit[item.Path] = SyncSplitRemoteFile(id: fileID, size: item.Size, md5: md5)
            }
            var localFiles: [String: SyncSplitLocalFile] = [:]
            for item in localView where !item.IsDir && item.Path != relation.marker {
                let values = try local.appendingPathComponent(item.Path).resourceValues(forKeys: [.contentModificationDateKey])
                localFiles[item.Path] = SyncSplitLocalFile(size: item.Size, modTime: values.contentModificationDate)
            }
            for item in localView where item.IsDir && remoteSplit[item.Path] != nil {
                throw SyncFailure.message("«\(item.Path)» es una carpeta en el Mac y un documento dividido en Drive. Renombrá una antes de sincronizar.")
            }
            let ordinaryRemote = Set(projection.items.filter { !$0.IsDir && $0.splitFile != true }.map(\.Path))
            let splitWork = root.appendingPathComponent("State/" + id.uuidString + "/split")
            let thresholdBytes = Int64(settings.linkedSegmentMB) * 1_000_000
            var splitBaseline = relation.splitFiles ?? [:]
            // Finish uploads interrupted by a previous run (same IDs, frozen copy)
            // before planning, so the plan never schedules them a second time.
            if FileManager.default.fileExists(atPath: splitWork.path) {
                let recovery = SyncSplitCoordinator(remote: try splitRemote(relation), local: local, work: splitWork,
                                                    versions: root.appendingPathComponent("Versions/" + id.uuidString + "/recovered"),
                                                    thresholdBytes: thresholdBytes)
                recovery.onActivity = onActivity
                try recovery.recover(baseline: &splitBaseline, save: { [self] current in
                    var snapshot = relations[index]; snapshot.splitFiles = current; relations[index] = snapshot; try save() })
                relation.splitFiles = splitBaseline
                remoteSplit = [:]
                let refreshed = try CloudBackend.projectListing(try listingData(relation.remoteLocation, rules: rules)).items
                for item in refreshed where item.splitFile == true && !SyncFilters.excludesLogicalFile(item.Path, patterns: exclusions) {
                    guard let fileID = item.ID, let md5 = item.Hashes?["md5"] else { throw CloudBackendError.invalidMetadata }
                    remoteSplit[item.Path] = SyncSplitRemoteFile(id: fileID, size: item.Size, md5: md5)
                }
            }
            let splitPlan = try SyncSplitPlan.make(remote: remoteSplit, remoteOrdinary: ordinaryRemote, local: localFiles,
                                                   knownOrdinary: Set(relation.localFiles + relation.remoteFiles),
                                                   baseline: splitBaseline, thresholdBytes: thresholdBytes,
                                                   localMD5: { try SyncSplitCoordinator.md5(local.appendingPathComponent($0)) })
            let splitExclusions = excludedPackages.map(\.Path) + splitPlan.managedPaths
            rules += SyncFilters.exactDirectoryRules(splitExclusions) + SyncFilters.exactFileRules(splitExclusions)
            let remoteEntries = try listing(relation.remoteLocation, rules: rules)
            let work = root.appendingPathComponent("State/" + id.uuidString)
            try Self.privateDirectory(work)
            let marker = local.appendingPathComponent(relation.marker)
            if !relation.initialized {
              if relation.externalIdentity != nil {
                guard relation.initialAttempted != true else {
                    throw SyncFailure.message("La vinculación inicial quedó interrumpida. Se conservan los archivos y el plan; revisá ambas carpetas y desvinculá antes de preparar una nueva unión.")
                }
                let planFile=root.appendingPathComponent("InitialPlans/"+id.uuidString+".json")
                let plan=try JSONDecoder().decode(SyncFolderPlan.self,from:Data(contentsOf:planFile))
                guard plan.id==id,plan.localPath==relation.localPath,plan.identity==relation.externalIdentity,
                      plan.remote==relation.remote,plan.folder.Path==relation.remotePath,plan.folder.ID==relation.remoteID,
                      try SyncFolderPlan.make(id:plan.id,remote:plan.remote,folder:plan.folder,localPath:plan.localPath,identity:plan.identity,local:plan.local,cloud:plan.cloud).moves==plan.moves,
                      SyncFolderPlan.sameSnapshot(try listing(local.path,hashes:true),plan.local),
                      SyncFolderPlan.sameSnapshot(try logicalListing(relation.remoteLocation,hashes:true),plan.cloud) else {
                    throw SyncFailure.message("El contenido cambió después de revisar el plan. Se detuvo la vinculación sin sobrescribir archivos.")
                }
                // Persist before the first mutation. An interrupted first union
                // is never automatically replayed over the user's existing data.
                relation.initialAttempted=true;relations[index]=relation;try save()
                for move in plan.moves {
                    let from=local.appendingPathComponent(move.from),to=local.appendingPathComponent(move.to)
                    guard !FileManager.default.fileExists(atPath:to.path) else{throw SyncFailure.message("Apareció un archivo en el destino de una copia de conflicto. La preparación se detuvo.")}
                    try FileManager.default.moveItem(at:from,to:to)
                }
              } else {
                // The app creates a new, empty local folder. Never bootstrap over arbitrary user data.
                let entries = try FileManager.default.contentsOfDirectory(atPath:local.path).filter { $0 != relation.marker && $0 != ".DS_Store" }
                guard entries.isEmpty else { throw SyncFailure.message("La preparación anterior quedó incompleta. Se conservó todo; no se reiniciará sobrescribiendo archivos.") }
              }
                try Data("Nimbo sync anchor\n".utf8).write(to:marker,options:.atomic)
                _ = try run(["copyto",marker.path,relation.remoteLocation + "/" + relation.marker,"--ignore-existing"])
            } else {
                guard FileManager.default.fileExists(atPath:marker.path), remoteEntries.contains(where:{$0.Path == relation.marker}) else {
                    throw SyncFailure.message("No se encontró la marca de seguridad en ambas carpetas. Se detuvo la sincronización.")
                }
                let localEntries = try listing(local.path, rules: rules)
                let localPaths = Set(localEntries.map(\.Path)), remotePaths = Set(remoteEntries.map(\.Path))
                let pending = Set(relation.localFiles).subtracting(localPaths).intersection(remotePaths).map { SyncDeletion(path:$0,missingFrom:"Mac") }
                    + Set(relation.remoteFiles).subtracting(remotePaths).intersection(localPaths).map { SyncDeletion(path:$0,missingFrom:"Google Drive") }
                    + splitPlan.deletions
                let sorted = pending.sorted { ($0.path,$0.missingFrom) < ($1.path,$1.missingFrom) }
                relation.pendingDeletes = sorted
                if !sorted.isEmpty && deletions != sorted {
                    relation.message = "Hay \(sorted.count) borrados para revisar. No se propagaron."
                    if var schedule = relation.syncSchedule, schedule.enabled { schedule.message = "Sincronización programada pausada: hay borrados para revisar."; relation.syncSchedule = schedule }
                    relations[index] = relation; try save(); return
                }
            }
            let stamp = String(Int(Date().timeIntervalSince1970)) + "-" + UUID().uuidString.prefix(8)
            let backup = root.appendingPathComponent("Versions/" + id.uuidString + "/" + stamp)
            try Self.privateDirectory(backup)
            var arguments = ["bisync",local.path,relation.remoteLocation,"--workdir",work.path,
                "--compare","size,modtime,checksum","--conflict-resolve","none","--conflict-loser","num",
                "--conflict-suffix","conflict-mac,conflict-drive","--check-access","--check-filename",relation.marker,
                "--resilient","--recover","--max-lock","2m","--max-delete",deletions == nil ? "0" : "100",
                "--backup-dir1",backup.path,"--backup-dir2",relation.remote + ":.Nimbo Versiones/" + id.uuidString + "/" + stamp,
                "--drive-skip-gdocs","--disable","ListR",
                "--create-empty-src-dirs",
                "--retries","1","--checkers","4","--transfers","2"]
            if settings.splitLargeFiles { arguments += ["--drive-chunk-size", "64M"] }
            arguments += rules
            if !relation.initialized { arguments += ["--resync-mode","path2"] }
            onActivity?("Sincronizando \(relation.name)…")
            _ = try run(arguments,timeout:86400)
            if !splitPlan.actions.isEmpty {
                let coordinator = SyncSplitCoordinator(
                    remote: try splitRemote(relation),
                    local: local, work: splitWork, versions: backup, thresholdBytes: thresholdBytes)
                coordinator.onActivity = onActivity
                let persist: ([String: SyncSplitBaseline]) throws -> Void = { [self] current in
                    var snapshot = relations[index]; snapshot.splitFiles = current; relations[index] = snapshot; try save() }
                let conflicts = try coordinator.execute(splitPlan, approved: deletions != nil, tag: String(id.uuidString.prefix(8)),
                                                        baseline: &splitBaseline, save: persist)
                if !conflicts.isEmpty { event("Sincronización", "\(relation.name): se conservaron \(conflicts.count) copias de conflicto.", success: true) }
                relation.splitFiles = splitBaseline.isEmpty ? nil : splitBaseline
            }
            relation.initialized = true
            let finalRules = rules + SyncFilters.exactDirectoryRules(Array(splitBaseline.keys)) + SyncFilters.exactFileRules(Array(splitBaseline.keys))
            rules = finalRules
            relation.localFiles = try listing(local.path, rules: rules).map(\.Path)
            relation.remoteFiles = try listing(relation.remoteLocation, rules: rules).map(\.Path)
            relation.pendingDeletes = []; relation.lastSuccess = Date()
            if var schedule = relation.syncSchedule, schedule.enabled {
                schedule.lastSuccess = Date(); schedule.message = "Sincronización programada: \(schedule.intervalLabel)."; relation.syncSchedule = schedule
            }
            relation.message = "Al día. Disponible sin conexión; los cambios se sincronizan mientras Nimbo está abierto."
            relations[index] = relation; try save()
            event("Sincronización", "\(relation.name): operación completada.", success: true)
        } catch {
            relation.message = error.localizedDescription
            if var schedule = relation.syncSchedule, schedule.enabled { schedule.message = "Sincronización programada detenida: \(error.localizedDescription)"; relation.syncSchedule = schedule }
            if relation.externalIdentity != nil && !relation.initialized {relation.paused=true}
            relations[index] = relation; try? save()
            event("Sincronización", "\(relation.name): \(error.localizedDescription)", success: false)
            throw error
        }
    }
    private func listing(_ location: String, hashes: Bool = false, rules: [String] = ["--exclude", ".DS_Store", "--exclude", "._*"]) throws -> [CloudItem] {
        let data = try listingData(location, hashes: hashes, rules: rules)
        return try checkedEntries(CloudBackend.decodeListing(data, refusePackages: true))
    }

    /// Drive as the user sees it: a split document is one file with its own MD5.
    private func logicalListing(_ location: String, hashes: Bool = false) throws -> [CloudItem] {
        let data = try listingData(location, hashes: hashes, rules: ["--exclude", ".DS_Store", "--exclude", "._*", "--filter", "- .nimbo-upload-*/"])
        return try checkedEntries(CloudBackend.projectListing(data).items)
    }

    var splitRemoteFactory: ((SyncRelation) throws -> SyncSplitRemote)?
    private func splitRemote(_ relation: SyncRelation) throws -> SyncSplitRemote {
        if let factory = splitRemoteFactory { return try factory(relation) }
        guard let rootID = relation.remoteID, !rootID.isEmpty else { throw SyncFailure.message("Falta el identificador de la carpeta de Drive.") }
        return GoogleSyncSplitRemote(config: config, remote: relation.remote, rootID: rootID, downloadRate: settings.downloadKBps,
                                     isCancelled: { [weak self] in self?.isCancelled ?? true })
    }
    private var isCancelled: Bool { processLock.lock(); defer { processLock.unlock() }; return cancelled }

    private func listingData(_ location: String, hashes: Bool = false, rules: [String]) throws -> Data {
        var arguments = ["lsjson", location, "-R", "--no-mimetype", "--drive-skip-gdocs"] + rules
        if !location.hasPrefix("/") { arguments.append("--metadata") }
        if hashes { arguments += ["--hash-type", "MD5"] }
        return try run(arguments)
    }

    private func checkedEntries(_ entries: [CloudItem]) throws -> [CloudItem] {
        var names = Set<String>()
        for item in entries {
            for component in item.Path.split(separator:"/",omittingEmptySubsequences:false) { _ = try CloudBackend.safeBasename(String(component)) }
            let normalized = item.Path.precomposedStringWithCanonicalMapping.lowercased()
            guard names.insert(normalized).inserted else { throw SyncFailure.message("Hay nombres duplicados o incompatibles con este Mac. Corregilos antes de sincronizar.") }
        }
        return entries
    }
    private func save() throws {
        try NimboSecureFile.save(relations, to: store, account: "sync-relations")
    }
    private static func privateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        guard url.resolvingSymlinksInPath() == url.standardizedFileURL else { throw SyncFailure.message("No se admiten enlaces simbólicos en el estado de sincronización.") }
    }
    private func encryptedBackupConfig(alias: String, baseRemote: String, backupRoot: String, passphrase: String, salt: String) throws -> URL {
        let password = try String(data: run(["obscure", passphrase]), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let password2 = try String(data: run(["obscure", salt]), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let password, !password.isEmpty, let password2, !password2.isEmpty else { throw SyncFailure.message("No se pudo preparar el cifrado del backup.") }
        let original = try String(contentsOf: config, encoding: .utf8)
        let section = "\n[\(alias)]\ntype = crypt\nremote = \(baseRemote):\(backupRoot)\nfilename_encryption = standard\ndirectory_name_encryption = true\npassword = \(password)\npassword2 = \(password2)\n"
        let url = root.appendingPathComponent(".backup-config-" + UUID().uuidString)
        try Data((original + section).utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
        return url
    }
    private func run(_ arguments: [String], timeout: TimeInterval = 120, configURL: URL? = nil, missingListingIsEmpty: Bool = false) throws -> Data {
        let temporary = root.appendingPathComponent(".run-" + UUID().uuidString)
        try Self.privateDirectory(temporary)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let stdout = temporary.appendingPathComponent("out"), stderr = temporary.appendingPathComponent("error")
        for file in [stdout,stderr] { FileManager.default.createFile(atPath:file.path,contents:nil,attributes:[.posixPermissions:0o600]) }
        let output = try FileHandle(forWritingTo:stdout), errors = try FileHandle(forWritingTo:stderr)
        defer { try? output.close(); try? errors.close() }
        let p = Process(); p.executableURL = binary
        if configURL == nil { NimboSecureConfig.ensureRuntime(config) }
        p.arguments = ["--config",(configURL ?? config).path,"--log-level","ERROR"] + arguments
        if ["copy", "copyto", "bisync"].contains(arguments.first ?? "") || (arguments.first == "check" && arguments.contains("--download")) { p.arguments?.append(contentsOf: settings.rcloneArguments) }
        p.environment = ["HOME":NSHomeDirectory(),"PATH":"/usr/bin:/bin:/usr/sbin:/sbin","TMPDIR":temporary.path]
        p.standardInput = FileHandle.nullDevice; p.standardOutput = output; p.standardError = errors
        processLock.lock()
        guard !cancelled else { processLock.unlock(); throw SyncFailure.message("Sincronización detenida. Los archivos se conservaron.") }
        process = p
        do { try p.run() } catch { process = nil; processLock.unlock(); throw error }
        processLock.unlock()
        defer { processLock.lock(); process = nil; processLock.unlock() }
        let start = ProcessInfo.processInfo.systemUptime
        var stopAt: TimeInterval?
        while p.isRunning {
            processLock.lock(); let stopping = cancelled; processLock.unlock()
            if (stopping || ProcessInfo.processInfo.systemUptime-start > timeout) && stopAt == nil {
                kill(p.processIdentifier,SIGINT); stopAt = ProcessInfo.processInfo.systemUptime
            }
            if let stopAt, ProcessInfo.processInfo.systemUptime-stopAt > 95 { kill(p.processIdentifier,SIGKILL) }
            let excessive = [stdout,stderr].contains { (((try? FileManager.default.attributesOfItem(atPath:$0.path)[.size]) as? NSNumber)?.intValue ?? 0) > 64*1024*1024 }
            if excessive { kill(p.processIdentifier,SIGINT); stopAt = stopAt ?? ProcessInfo.processInfo.systemUptime }
            Thread.sleep(forTimeInterval:0.1)
        }
        p.waitUntilExit()
        processLock.lock(); let stopped = cancelled; processLock.unlock()
        if stopped || stopAt != nil { throw SyncFailure.message("Sincronización detenida. Se conservaron los archivos y el estado de recuperación.") }
        if missingListingIsEmpty, arguments.first == "lsjson", p.terminationStatus == 3 { return Data("[]".utf8) }
        guard p.terminationStatus == 0 else {
            let message = (try? String(contentsOf:stderr,encoding:.utf8)) ?? ""
            if testing { FileHandle.standardError.write(Data((arguments.first! + ": " + message + "\n").utf8)) }
            if message.contains("file name too long") { throw SyncFailure.message("La ruta supera el límite del motor de sincronización. Se conservó todo. Elegí una carpeta con una ruta más corta.") }
            if message.contains("--resync") { throw SyncFailure.message("La sincronización necesita revisión antes de recuperarse. No se reinició ni sobrescribió automáticamente.") }
            if message.contains("delete") { throw SyncFailure.message("Se detuvo una operación de borrado. Revisá los cambios antes de continuar.") }
            throw SyncFailure.message("No se pudo sincronizar (código \(p.terminationStatus)). Comprobá internet y el acceso a Google Drive; los archivos se conservaron.")
        }
        return try Data(contentsOf:stdout)
    }
}
