import Foundation
import Darwin

/// Metadata returned by rclone lsjson. No document contents are fetched by listing.
struct CloudItem: Codable, Equatable {
    let Path: String
    let Name: String
    let Size: Int64
    let IsDir: Bool
    let ModTime: String?
    let ID: String?
    let Hashes: [String:String]?
    let MimeType: String?
    var splitFile: Bool?

    init(Path: String, Name: String, Size: Int64, IsDir: Bool, ModTime: String? = nil, ID: String? = nil, Hashes: [String:String]? = nil, MimeType: String? = nil) {
        self.Path = Path
        self.Name = Name
        self.Size = Size
        self.IsDir = IsDir
        self.ModTime = ModTime
        self.ID = ID
        self.Hashes = Hashes
        self.MimeType = MimeType
    }
}

// Read just the four Nimbo properties from rclone's metadata; unrelated
// provider metadata never enters the catalog or Spotlight.
private struct CatalogRecord: Decodable {
    let item: CloudItem
    let layout: DriveSplitLayout?
    private enum Keys: String, CodingKey { case Metadata }
    init(from decoder: Decoder) throws {
        item = try CloudItem(from: decoder)
        let fields = try decoder.container(keyedBy: Keys.self)
        let metadata = try fields.decodeIfPresent([String: String].self, forKey: .Metadata)
        layout = item.IsDir ? DriveSplitLayout(metadata) : nil
    }
}

struct RemoteEntry: Codable, Equatable {
    let remote: String
    let item: CloudItem
}

struct RemoteCache: Codable, Equatable {
    let remote: String
    let fetchedAt: Date
    let entries: [CloudItem]
}

/// Tokens are literal substrings, ANDed together. There is no query language or regex execution.
func matchesQuery(_ query: String, item: CloudItem) -> Bool {
    let locale = Locale(identifier: "en_US_POSIX")
    func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
    }
    let haystack = fold(item.Name + "\n" + item.Path)
    let tokens = fold(query).split(whereSeparator: { $0.isWhitespace })
    return tokens.allSatisfy { haystack.contains($0) }
}

enum CloudBackendError: Error, LocalizedError, Equatable {
    case invalidRemote
    case unsafePath
    case foldersCannotBeDownloaded
    case invalidMetadata
    case duplicateMetadataPath
    case launchFailed
    case commandFailed(Int32)
    case timedOut
    case cancelled
    case outputLimitExceeded
    case cacheUnavailable
    case invalidCache
    case destinationUnavailable
    case incompleteDownload
    case packageInSyncFolder

    var errorDescription: String? {
        switch self {
        case .packageInSyncFolder: return "Esta carpeta contiene un envío dividido de Nimbo. Abrilo desde Finder o descargalo desde el catálogo. La sincronización de esta carpeta está detenida."
        case .invalidRemote: return "El nombre de la conexión no es válido."
        case .unsafePath: return "La ruta o el nombre de archivo no es seguro para esta operación."
        case .foldersCannotBeDownloaded: return "Seleccioná un archivo para descargar; las carpetas no se descargan desde esta vista."
        case .invalidMetadata: return "La conexión devolvió metadatos inválidos. Se conservó el índice anterior."
        case .duplicateMetadataPath: return "Hay varias entradas con la misma ruta. Elegí un archivo sin ambigüedad antes de descargar."
        case .launchFailed: return "No se pudo iniciar el conector de almacenamiento."
        case .commandFailed(let status): return "El conector no pudo completar la operación (código \(status)). Revisá la conexión y sus permisos."
        case .timedOut: return "La operación superó el tiempo de espera. Podés volver a intentarlo."
        case .cancelled: return "Operación cancelada."
        case .outputLimitExceeded: return "La respuesta supera el límite de este índice. Probá con una conexión de menor alcance."
        case .cacheUnavailable: return "No se pudo guardar el índice local. Se conservó la versión anterior."
        case .invalidCache: return "No se pudo leer el índice local. Actualizá la conexión para reconstruirlo."
        case .destinationUnavailable: return "No se pudo crear una carpeta privada para la descarga en el destino elegido."
        case .incompleteDownload: return "El conector no produjo un archivo completo en el destino esperado."
        }
    }
}

/// Synchronous methods. Run them off the main thread. cancelAll() may be called from any thread.
/// No shell is used, cloud mutation commands are not exposed, and stderr never reaches the UI.
final class CloudBackend: @unchecked Sendable {
    let configURL: URL
    let binaryURL: URL
    let cacheDirectory: URL
    private let operationTimeout: TimeInterval
    private let downloadTimeout: TimeInterval
    private let downloadBandwidthKBps: Int?
    private let stateLock = NSLock()
    private let cacheLock = NSLock()
    private var processes: [UUID: Process] = [:]
    private var cancellationGeneration: UInt64 = 0
    private var activeDownloads = Set<UUID>()
    private let metadataByteLimit = 64 * 1024 * 1024
    private let stderrByteLimit = 1024 * 1024
    #if CORE_TESTS
    // Test-only boundary hook, absent from the application build.
    var cachePublicationWillBegin: (() -> Void)?
    var downloadWillCommit: ((UUID) -> Void)?
    #endif

    init(configURL: URL, binaryURL: URL, cacheDirectory: URL? = nil,
         operationTimeout: TimeInterval = 120, downloadTimeout: TimeInterval = 600,
         downloadBandwidthKBps: Int? = nil) {
        self.configURL = configURL
        self.binaryURL = binaryURL
        self.cacheDirectory = cacheDirectory ?? configURL.deletingLastPathComponent().appendingPathComponent("Metadata", isDirectory: true)
        self.operationTimeout = max(0.05, operationTimeout)
        self.downloadTimeout = max(0.05, downloadTimeout)
        self.downloadBandwidthKBps = downloadBandwidthKBps
    }

    func listRemotes() throws -> [String] {
        let data = try run(arguments: ["listremotes"], timeout: operationTimeout)
        guard let text = String(data: data, encoding: .utf8) else { throw CloudBackendError.invalidMetadata }
        var result: [String] = []
        var seen = Set<String>()
        for line in text.split(whereSeparator: { $0.isNewline }) {
            let value = String(line)
            guard value.hasSuffix(":") else { throw CloudBackendError.invalidMetadata }
            let name = String(value.dropLast())
            try Self.validateRemote(name)
            guard seen.insert(name).inserted else { throw CloudBackendError.invalidMetadata }
            result.append(name)
        }
        return result.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Reads names, paths, sizes and times recursively. Successful metadata is atomically cached.
    /// An error, cancellation, or malformed response leaves the previous cache intact.
    /// Duplicate cloud names are preserved; the UI and download method reject ambiguous downloads.
    func list(remote: String) throws -> [CloudItem] {
        let generation = currentGeneration()
        try Self.validateRemote(remote)
        let data = try run(arguments: ["lsjson", remote + ":", "-R", "--metadata"], timeout: operationTimeout, expectedGeneration: generation)
        let entries = try Self.decodeListing(data)
        try saveCache(RemoteCache(remote: remote, fetchedAt: Date(), entries: entries), expectedGeneration: generation)
        return entries
    }

    func loadCache(remote: String) throws -> RemoteCache? {
        try Self.validateRemote(remote)
        cacheLock.lock()
        let encryptedURL = cacheFileURL(remote: remote)
        let legacyURL = legacyCacheFileURL(remote: remote)
        let source = FileManager.default.fileExists(atPath: encryptedURL.path) ? encryptedURL : legacyURL
        guard FileManager.default.fileExists(atPath: source.path) else {
            cacheLock.unlock()
            return nil
        }
        let attributes: [FileAttributeKey: Any]
        let bytes: Data
        var keychainMigration = false
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: source.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber,
                  size.intValue <= metadataByteLimit else { throw CloudBackendError.invalidCache }
            if source == encryptedURL {
                do {
                    bytes = try NimboSecureFile.loadData(from: source, account: cacheAccount(remote: remote), keychain: false) ?? Data()
                } catch {
                    // 1.10.0 can still open catalogs encrypted by 1.9.x,
                    // which used a Keychain-backed key before the offline
                    // private-key path was introduced.
                    bytes = try NimboSecureFile.loadData(from: source, account: cacheAccount(remote: remote), keychain: true, preferKeychain: true) ?? Data()
                    keychainMigration = true
                }
            } else {
                bytes = try Data(contentsOf: source)
            }
        } catch {
            cacheLock.unlock()
            throw CloudBackendError.invalidCache
        }
        cacheLock.unlock()
        do {
            let cache = try JSONDecoder().decode(RemoteCache.self, from: bytes)
            guard cache.remote == remote, cache.fetchedAt.timeIntervalSince1970.isFinite else {
                throw CloudBackendError.invalidCache
            }
            try Self.validateEntries(cache.entries)
            // A plaintext catalog from an older build is accepted once and
            // immediately replaced by the encrypted form.
            if source == legacyURL {
                do {
                    try saveCache(cache)
                    try FileManager.default.removeItem(at: legacyURL)
                } catch {
                    // Keep the legacy index if encryption/publication failed;
                    // the next run can retry without losing the catalog.
                }
            } else if keychainMigration {
                // Replace the old Keychain-backed envelope once it has been
                // read successfully; future CLI calls stay independent of
                // the interactive Keychain service.
                try? saveCache(cache)
            }
            return cache
        } catch {
            throw CloudBackendError.invalidCache
        }
    }

    func saveCache(_ cache: RemoteCache) throws {
        try saveCache(cache, expectedGeneration: nil)
    }

    private func saveCache(_ cache: RemoteCache, expectedGeneration: UInt64?) throws {
        try Self.validateRemote(cache.remote)
        try Self.validateEntries(cache.entries)
        guard cache.fetchedAt.timeIntervalSince1970.isFinite else { throw CloudBackendError.invalidCache }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        do {
            try ensurePrivateDirectory(cacheDirectory)
            let temp = cacheDirectory.appendingPathComponent(".index-" + UUID().uuidString)
            let destination = cacheFileURL(remote: cache.remote)
            defer { try? FileManager.default.removeItem(at: temp) }
            let data = try JSONEncoder().encode(cache)
            guard data.count <= metadataByteLimit else { throw CloudBackendError.outputLimitExceeded }
            // Encrypt names, paths and metadata before the atomic publication
            // point.  The old plaintext file is never overwritten in place.
            try NimboSecureFile.saveData(data, to: temp, account: cacheAccount(remote: cache.remote), keychain: false)
            #if CORE_TESTS
            cachePublicationWillBegin?()
            #endif
            // Serialize only the publication point with cancelAll, not encoding or disk writes.
            // A cancellation that wins this lock cannot be followed by publishing this operation.
            stateLock.lock()
            defer { stateLock.unlock() }
            if let expectedGeneration, cancellationGeneration != expectedGeneration {
                throw CloudBackendError.cancelled
            }
            // rename is atomic on this filesystem; publication happens only after the full write.
            guard rename(temp.path, destination.path) == 0 else { throw CloudBackendError.cacheUnavailable }
        } catch let error as CloudBackendError where error == .cancelled {
            throw error
        } catch {
            throw CloudBackendError.cacheUnavailable
        }
    }

    /// Explicit file download. Each download gets its own new private folder; existing files are never replaced.
    func download(remote: String, item: CloudItem, destinationDirectory: URL) throws -> URL {
        try Self.validateRemote(remote)
        try Self.validateItem(item)
        guard !item.IsDir else { throw CloudBackendError.foldersCannotBeDownloaded }
        if let cache = try loadCache(remote: remote), cache.entries.filter({ $0.Path == item.Path }).count > 1 {
            throw CloudBackendError.duplicateMetadataPath
        }
        let basename = try Self.safeBasename(Self.exportedBasename(item))
        let values: URLResourceValues
        do { values = try destinationDirectory.resourceValues(forKeys: [.isDirectoryKey]) }
        catch { throw CloudBackendError.destinationUnavailable }
        guard values.isDirectory == true else { throw CloudBackendError.destinationUnavailable }
        let directory = destinationDirectory.appendingPathComponent("Nimbo-" + UUID().uuidString, isDirectory: true)
        // mkdir must create a new directory exclusively, including in the extremely unlikely UUID collision case.
        guard mkdir(directory.path, mode_t(0o700)) == 0 else { throw CloudBackendError.destinationUnavailable }
        let destination = directory.appendingPathComponent(basename, isDirectory: false)
        let transferID = TransferCenter.shared.begin(remote: remote, name: item.Name, operation: "Descarga", totalBytes: item.Size, canCancel: true)
        stateLock.lock(); let generation = cancellationGeneration; activeDownloads.insert(transferID); stateLock.unlock()
        var completed = false
        defer {
            stateLock.lock(); activeDownloads.remove(transferID); stateLock.unlock()
            if !completed {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        do {
        var arguments = ["copyto", remote + ":" + item.Path, destination.path,
                         "--immutable", "--no-traverse", "--retries", "1", "--low-level-retries", "1"]
        let settingsURL = configURL.deletingLastPathComponent().appendingPathComponent("Sync/settings.json")
        var limits = SyncSettings.read(at: settingsURL)
        if let downloadBandwidthKBps, SyncSettings.allowed.contains(downloadBandwidthKBps) { limits.downloadKBps = downloadBandwidthKBps }
        arguments += limits.rcloneArguments
        if item.splitFile == true {
            guard let id = item.ID else { throw CloudBackendError.invalidMetadata }
            try downloadPackage(remote: remote, id: id, item: item, destination: destination, transfer: transferID, rate: limits.downloadKBps)
        } else {
            _ = try run(arguments: arguments, timeout: downloadTimeout, expectedGeneration: generation, transferID: transferID)
        }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: destination.path)
            let dirAttrs = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular,
                  dirAttrs[.type] as? FileAttributeType == .typeDirectory else {
                throw CloudBackendError.incompleteDownload
            }
            if item.Size >= 0, let size = attrs[.size] as? NSNumber, size.int64Value != item.Size {
                throw CloudBackendError.incompleteDownload
            }
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: destination.path)
            let actualBytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            // Export size is unknown before downloading. Count its actual bytes
            // without claiming a size/checksum comparison that never happened.
            let verified = item.Size >= 0 && actualBytes == item.Size
            TransferCenter.shared.update(transferID, completedBytes: actualBytes, verified: verified)
            #if CORE_TESTS
            downloadWillCommit?(transferID)
            #endif
            // Serialize publication with cancellation. A cancellation that wins
            // this boundary cannot be followed by a completed download.
            stateLock.lock()
            let current = generation == cancellationGeneration
            let published = TransferCenter.shared.finish(transferID, verified: verified, cancelled: !current)
            stateLock.unlock()
            if !published { throw CloudBackendError.cancelled }
        } catch let error as CloudBackendError { throw error }
        catch { throw CloudBackendError.incompleteDownload }
        completed = true
        return destination
        } catch {
            TransferCenter.shared.finish(transferID, verified: false, error: error.localizedDescription,
                                         cancelled: (error as? CloudBackendError) == .cancelled)
            throw error
        }
    }

    // The existing UI and CLI call this synchronous backend on a worker.
    // Wait for cancellation cleanup before returning ownership of its directory.
    private func downloadPackage(remote: String, id: String, item: CloudItem, destination: URL, transfer: UUID, rate: Int) throws {
        let done = DispatchSemaphore(value: 0)
        var result: Result<Void, Error>?
        let api = DriveAPI(configuration: configURL, remoteName: remote)
        let task = Task.detached {
            do {
                let object = try await api.item(id)
                guard let layout = object.splitLayout, !object.splitPending, object.trashed != true,
                      layout.size == item.Size, layout.md5 == item.Hashes?["md5"] else { throw CloudBackendError.incompleteDownload }
                try await api.downloadSplit(object, to: destination, rate: rate) { bytes in
                    TransferCenter.shared.update(transfer, completedBytes: bytes)
                }
                result = .success(())
            } catch { result = .failure(error) }
            done.signal()
        }
        let deadline = DispatchTime.now() + downloadTimeout
        var reason: CloudBackendError?
        while done.wait(timeout: .now() + .milliseconds(150)) == .timedOut {
            if reason == nil {
                if TransferCenter.shared.isCancellationRequested(transfer) { reason = .cancelled }
                else if DispatchTime.now() >= deadline { reason = .timedOut }
                if reason != nil { task.cancel() }
            }
        }
        if let reason { throw reason }
        guard let result else { throw CloudBackendError.incompleteDownload }
        try result.get()
    }

    private static func exportedBasename(_ item: CloudItem) -> String {
        guard item.Size < 0, let mime = item.MimeType else { return item.Name }
        let extensionName: String?
        switch mime {
        case "application/vnd.google-apps.document": extensionName = "docx"
        case "application/vnd.google-apps.spreadsheet": extensionName = "xlsx"
        case "application/vnd.google-apps.presentation": extensionName = "pptx"
        case "application/vnd.google-apps.drawing": extensionName = "svg"
        default: extensionName = nil
        }
        guard let extensionName else { return item.Name }
        let lower=item.Name.lowercased()
        return lower.hasSuffix("." + extensionName) ? item.Name : item.Name + "." + extensionName
    }

    func cancelAll() {
        stateLock.lock()
        cancellationGeneration &+= 1
        let current = Array(processes.values)
        let downloads = activeDownloads
        stateLock.unlock()
        for id in downloads { TransferCenter.shared.requestCancellation(id) }
        for process in current where process.isRunning { process.terminate() }
    }

    static func decodeListing(_ data: Data, refusePackages: Bool = false) throws -> [CloudItem] {
        let result = try projectListing(data)
        if refusePackages && result.containsPackages { throw CloudBackendError.packageInSyncFolder }
        return result.items
    }

    static func projectListing(_ data: Data) throws -> (items: [CloudItem], containsPackages: Bool) {
        let records: [CatalogRecord]
        do { records = try JSONDecoder().decode([CatalogRecord].self, from: data) }
        catch { throw CloudBackendError.invalidMetadata }
        let items = records.map(\.item)
        try validateEntries(items)
        let packagePaths = Set(records.filter { $0.layout != nil }.map { $0.item.Path })
        guard !packagePaths.isEmpty else { return (items, false) }
        // Drive permits duplicate folder names. A path-only listing cannot
        // assign descendants to the right parent in that case.
        var seen = Set<String>()
        for item in items where packagePaths.contains(item.Path) {
            guard seen.insert(item.Path).inserted else { throw CloudBackendError.duplicateMetadataPath }
        }
        let projected: [CloudItem] = try records.compactMap { record in
            let item = record.item
            var parent = item.Path[...]
            while let slash = parent.lastIndex(of: "/") {
                parent = parent[..<slash]
                if packagePaths.contains(String(parent)) { return nil }
            }
            guard let layout = record.layout else { return item }
            guard let id = item.ID else { throw CloudBackendError.invalidMetadata }
            if item.Name == ".nimbo-upload-" + id { return nil }
            var file = CloudItem(Path: item.Path, Name: item.Name, Size: layout.size, IsDir: false, ModTime: item.ModTime, ID: id, Hashes: ["md5": layout.md5], MimeType: "application/octet-stream")
            file.splitFile = true
            return file
        }
        return (projected, true)
    }

    static func validateRemote(_ name: String) throws {
        guard !name.isEmpty, name.utf8.count <= 128, !name.hasPrefix("-"),
              name != ".", name != "..", name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_.- ".unicodeScalars.contains($0) }) else {
            throw CloudBackendError.invalidRemote
        }
    }

    static func safeBasename(_ name: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw CloudBackendError.unsafePath
        }
        return name
    }

    private static func validateItem(_ item: CloudItem) throws {
        guard !item.Path.isEmpty, item.Path.utf8.count <= 16384, !item.Path.hasPrefix("/"),
              !item.Path.contains("\\"),
              item.Path.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw CloudBackendError.unsafePath
        }
        let parts = item.Path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              item.Name == String(parts.last ?? ""), item.Size >= -1 else {
            throw CloudBackendError.unsafePath
        }
        _ = try safeBasename(item.Name)
    }

    private static func validateEntries(_ entries: [CloudItem]) throws {
        guard entries.count <= 200000 else { throw CloudBackendError.outputLimitExceeded }
        for item in entries {
            guard !item.Path.isEmpty, !item.Name.isEmpty,
                  item.Path.utf8.count <= 16384, item.Name.utf8.count <= 4096,
                  item.Size >= -1 else { throw CloudBackendError.invalidMetadata }
        }
    }

    private func cacheFileURL(remote: String) -> URL {
        let encoded = Data(remote.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return cacheDirectory.appendingPathComponent("remote-" + encoded + ".json.enc")
    }

    private func legacyCacheFileURL(remote: String) -> URL {
        let encoded = Data(remote.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return cacheDirectory.appendingPathComponent("remote-" + encoded + ".json")
    }

    private func cacheAccount(remote: String) -> String {
        "catalog-" + remote
    }

    private func ensurePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: NSNumber(value: 0o700)])
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory else { throw CloudBackendError.cacheUnavailable }
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: url.path)
    }

    private func run(arguments: [String], timeout: TimeInterval, expectedGeneration: UInt64? = nil, transferID: UUID? = nil) throws -> Data {
        let operationID = UUID()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nimbo-" + operationID.uuidString, isDirectory: true)
        do { try ensurePrivateDirectory(temporary) }
        catch { throw CloudBackendError.launchFailed }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let stdoutURL = temporary.appendingPathComponent("stdout")
        let stderrURL = temporary.appendingPathComponent("stderr")
        guard FileManager.default.createFile(atPath: stdoutURL.path, contents: nil, attributes: [.posixPermissions: NSNumber(value: 0o600)]),
              FileManager.default.createFile(atPath: stderrURL.path, contents: nil, attributes: [.posixPermissions: NSNumber(value: 0o600)]) else {
            throw CloudBackendError.launchFailed
        }
        let output: FileHandle
        let errors: FileHandle
        do {
            output = try FileHandle(forWritingTo: stdoutURL)
            errors = try FileHandle(forWritingTo: stderrURL)
        } catch { throw CloudBackendError.launchFailed }
        defer { try? output.close(); try? errors.close() }
        let progress = try transferID.map { _ in try RcloneProgressReader(url: stderrURL) }
        func cancelled(_ generation: UInt64) -> Bool {
            wasCancelled(generation) || transferID.map { TransferCenter.shared.isCancellationRequested($0) } == true
        }
        func pollProgress() throws {
            guard let transferID else { return }
            do { try progress?.poll { TransferCenter.shared.progress(transferID, snapshot: $0) } }
            catch { throw CloudBackendError.outputLimitExceeded }
        }
        let process = Process()
        process.executableURL = binaryURL
        NimboSecureConfig.ensureRuntime(configURL)
        process.arguments = ["--config", configURL.path, "--log-level", "ERROR"] + arguments
        if transferID != nil { process.arguments! += ["--use-json-log", "--stats", "1s", "--stats-log-level", "ERROR"] }
        // Explicit config only: inherited RCLONE_* flags and unrelated credential environment are not forwarded.
        process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": temporary.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        stateLock.lock()
        let generation = expectedGeneration ?? cancellationGeneration
        guard generation == cancellationGeneration, transferID.map({ TransferCenter.shared.isCancellationRequested($0) }) != true else {
            stateLock.unlock()
            throw CloudBackendError.cancelled
        }
        processes[operationID] = process
        do { try process.run() }
        catch {
            processes.removeValue(forKey: operationID)
            stateLock.unlock()
            throw CloudBackendError.launchFailed
        }
        stateLock.unlock()
        defer {
            stateLock.lock()
            processes.removeValue(forKey: operationID)
            stateLock.unlock()
            stop(process)
        }
        let started = ProcessInfo.processInfo.systemUptime
        while process.isRunning {
            try pollProgress()
            if cancelled(generation) { throw CloudBackendError.cancelled }
            if ProcessInfo.processInfo.systemUptime - started > timeout { throw CloudBackendError.timedOut }
            if fileSize(stdoutURL) > metadataByteLimit || fileSize(stderrURL) > stderrByteLimit {
                throw CloudBackendError.outputLimitExceeded
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        try pollProgress()
        if cancelled(generation) { throw CloudBackendError.cancelled }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw CloudBackendError.commandFailed(process.terminationStatus)
        }
        guard fileSize(stdoutURL) <= metadataByteLimit, fileSize(stderrURL) <= stderrByteLimit else {
            throw CloudBackendError.outputLimitExceeded
        }
        do { return try Data(contentsOf: stdoutURL) }
        catch { throw CloudBackendError.invalidMetadata }
    }

    private func currentGeneration() -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancellationGeneration
    }

    private func wasCancelled(_ generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancellationGeneration != generation
    }

    private func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
    }

    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}
