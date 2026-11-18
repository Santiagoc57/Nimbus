import Foundation
import AppKit
import Darwin

enum NimboCLIError: Error, LocalizedError {
    case usage(String)
    case missingConfiguration(URL)
    var errorDescription: String? {
        switch self {
        case .usage(let message): return message
        case .missingConfiguration(let url): return "No se encontró la configuración de Google Drive en \(url.path). Abrí Nimbo y autorizá la cuenta primero."
        }
    }
}

@main
struct NimboCLI {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            try await run(args)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(2)
        }
    }

    static func run(_ args: [String]) async throws {
        guard let command = args.first else { throw NimboCLIError.usage(usage) }
        // The plaintext runtime is shared with the running Nimbo app. Only
        // remove it when this CLI created it and the app is not running;
        // otherwise every `nimbo doctor` deleted the app's live credentials.
        let supportDirectory = ProcessInfo.processInfo.environment["NIMBO_HOME"].map(URL.init(fileURLWithPath:)) ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Nimbo")
        let runtimeExisted = FileManager.default.fileExists(atPath: NimboSecureConfig.appRuntimeURL(support: supportDirectory).path)
        let paths = try paths()
        defer {
            let appRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "local.nimbo.cloudsearch").isEmpty
            if !runtimeExisted && !appRunning { try? NimboSecureConfig.resealApp(runtime: paths.config, support: paths.support) }
        }
        switch command {
        case "help", "--help", "-h": print(usage)
        case "doctor": try doctor(paths)
        case "autostart": try autostart(Array(args.dropFirst()))
        case "status": try status(paths)
        case "link": try await link(Array(args.dropFirst()), paths: paths)
        case "search": try search(Array(args.dropFirst()), paths: paths)
        case "download": try await download(Array(args.dropFirst()), paths: paths)
        case "unsync": try await nativeAction(Array(args.dropFirst()), action: "unsync", paths: paths)
        case "pin": try await nativeAction(Array(args.dropFirst()), action: "pin", paths: paths)
        case "refresh": try refresh(Array(args.dropFirst()), paths: paths)
        case "spotlight": try spotlight(paths)
        case "sync": try synchronize(Array(args.dropFirst()), paths: paths)
        case "backup": try backup(Array(args.dropFirst()), paths: paths)
        case "trash": try await trash(paths)
        case "trash-delete": try await trashDelete(Array(args.dropFirst()), paths: paths)
        case "trash-restore": try await trashRestore(Array(args.dropFirst()), paths: paths)
        case "share": try await share(Array(args.dropFirst()), paths: paths)
        case "revoke-share": try await revokeShare(Array(args.dropFirst()), paths: paths)
        case "shared-drives": try await sharedDrives(paths)
        default: throw NimboCLIError.usage("Comando desconocido: \(command)\n\n\(usage)")
        }
    }

    private struct Paths {
        let support: URL
        let config: URL
        let binary: URL
        let cache: URL
        let syncRoot: URL
        let offlineRoot: URL
    }

    private static func paths() throws -> Paths {
        let fm = FileManager.default
        let support = ProcessInfo.processInfo.environment["NIMBO_HOME"].map(URL.init(fileURLWithPath:)) ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Nimbo")
        let config = try NimboSecureConfig.prepareApp(support: support)
        guard fm.fileExists(atPath: config.path) else { throw NimboCLIError.missingConfiguration(support.appendingPathComponent("rclone.conf.enc")) }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let candidates = [
            executable.deletingLastPathComponent().appendingPathComponent("rclone"),
            executable.deletingLastPathComponent().appendingPathComponent("Nimbo.app/Contents/Resources/rclone"),
            executable.deletingLastPathComponent().appendingPathComponent("../Nimbo.app/Contents/Resources/rclone").standardizedFileURL,
            fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].deletingLastPathComponent().appendingPathComponent("Applications/Nimbo.app/Contents/Resources/rclone")
        ]
        guard let binary = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) else { throw NimboCLIError.usage("No se encontró el rclone incluido en Nimbo.") }
        let offline = ProcessInfo.processInfo.environment["NIMBO_OFFLINE_ROOT"].map(URL.init(fileURLWithPath:)) ?? fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Nimbo sin conexión")
        return Paths(support: support, config: config, binary: binary, cache: support.appendingPathComponent("Catalogs"), syncRoot: support.appendingPathComponent("Sync"), offlineRoot: offline)
    }

    private static func backend(_ p: Paths) -> CloudBackend { CloudBackend(configURL: p.config, binaryURL: p.binary, cacheDirectory: p.cache) }
    private static func engine(_ p: Paths) throws -> SyncEngine { try SyncEngine(root: p.syncRoot, offlineRoot: p.offlineRoot, config: p.config, binary: p.binary, activityFile: p.support.appendingPathComponent("Activity.json")) }

    private static func status(_ p: Paths) throws {
        let names = try backend(p).listRemotes()
        let sync = try engine(p)
        print("Google Drive: \(names.contains("GoogleDrive") ? "conectado" : "sin conexión gráfica")")
        print("Conexiones: \(names.isEmpty ? "ninguna" : names.joined(separator: ", "))")
        print("Sincronizaciones: \(sync.relations.count)")
        for relation in sync.relations { print("  \(relation.id.uuidString)\t\(relation.name)\t\(relation.paused ? "pausada" : relation.message)") }
    }

    private static func autostart(_ args: [String]) throws {
        guard args.count == 1 else { throw NimboCLIError.usage("Uso: nimbo autostart status|enable|disable") }
        switch args[0].lowercased() {
        case "status": print("Inicio automático: \(LaunchAtLogin.isEnabled() ? "activado" : "desactivado")")
        case "enable":
            try LaunchAtLogin.setEnabled(true, executablePath: applicationExecutablePath())
            print("Inicio automático activado para Nimbo.")
        case "disable":
            try LaunchAtLogin.setEnabled(false)
            print("Inicio automático desactivado.")
        default: throw NimboCLIError.usage("Uso: nimbo autostart status|enable|disable")
        }
    }

    private static func applicationExecutablePath() -> String {
        let command = URL(fileURLWithPath: CommandLine.arguments.first ?? "nimbo").standardizedFileURL
        if command.path.contains("/Nimbo.app/Contents/Resources/") {
            return command.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("MacOS/Nimbo").path
        }
        let homePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Nimbo.app/Contents/MacOS/Nimbo").path
        if FileManager.default.fileExists(atPath: homePath) { return homePath }
        return "/Applications/Nimbo.app/Contents/MacOS/Nimbo"
    }

    private static func doctor(_ p: Paths) throws {
        let fm = FileManager.default
        let names = try backend(p).listRemotes()
        print("Configuración: \(fm.fileExists(atPath: p.config.path) ? "OK" : "faltante")")
        print("Google Drive: \(names.contains("GoogleDrive") ? "conectado" : "no encontrado")")
        print("Conexiones: \(names.isEmpty ? "ninguna" : names.joined(separator: ", "))")
        for name in names {
            do {
                let cache = try backend(p).loadCache(remote: name)
                let detail = cache.map { "\($0.entries.count) entradas · \($0.fetchedAt)" } ?? "sin catálogo"
                print("Catálogo \(name): \(detail)")
            } catch { print("Catálogo \(name): error de lectura") }
        }
        let cloudStorage = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let cloud = (try? fm.contentsOfDirectory(at: cloudStorage, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]))?.first(where: { item in
            let name = item.lastPathComponent
            return (name == "Nimbo-GoogleDrive" || name.hasPrefix("Nimbo-GoogleDrive-") || name.hasPrefix("Nimbo-GoogleDrive·")) &&
                ((try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
        })
        print("Finder: \(cloud != nil ? "carpeta detectada" : "carpeta aún no activada")")
        print("Inicio automático: \(LaunchAtLogin.isEnabled() ? "activado" : "desactivado")")
        print("File Provider: \(fileProviderStatus())")
        print("Finder Sync: \(finderSyncStatus())")
    }

    /// The native provider can be registered while its domain is still
    /// inactive.  `fileproviderctl` is a local, read-only diagnostic and
    /// gives a more useful answer than checking only the visible folder.
    private static func fileProviderStatus() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/fileproviderctl")
        process.arguments = ["dump", "-P", "local.nimbo.cloudsearch.provider/google-drive", "--limit-dump-size", "20000"]
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("nimbo-fileprovider-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else { return "estado no disponible" }
        defer { try? FileManager.default.removeItem(at: outputURL) }
        do {
            let output = try FileHandle(forWritingTo: outputURL)
            defer { try? output.close() }
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                finished.signal()
            }
            guard finished.wait(timeout: .now() + 2) == .success else {
                process.terminate()
                return "estado no disponible (diagnóstico agotó 2 s)"
            }
            try? output.synchronize()
            let text = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
            guard text.contains("local.nimbo.cloudsearch.provider") else { return "no registrado" }
            guard text.contains(" + root:") else { return "registrado sin raíz activa" }
            return text.contains("read-only: 0") ? "activo (lectura/escritura)" : "activo (solo lectura)"
        } catch {
            return "estado no disponible"
        }
    }

    /// PlugInKit is the authoritative local registry for Finder Sync. The
    /// default election is usable; an explicit `-` means the user has
    /// disabled the extension and the contextual menu cannot be shown.
    private static func finderSyncStatus() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-m", "-v", "-p", "com.apple.FinderSync", "-i", "local.nimbo.cloudsearch.finderhelper.findersync"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard text.contains("local.nimbo.cloudsearch.finderhelper.findersync") else { return "no registrada" }
            if text.contains("-    local.nimbo.cloudsearch.finderhelper.findersync") { return "deshabilitada" }
            if text.contains("+    local.nimbo.cloudsearch.finderhelper.findersync") { return "habilitada" }
            return "registrada (elección predeterminada)"
        } catch {
            return "estado no disponible"
        }
    }

    private static func link(_ args: [String], paths: Paths) async throws {
        guard args.count == 1 || args.count == 3, let id = args.first else {
            throw NimboCLIError.usage("Uso: nimbo link DRIVE_ID [--remote GoogleDrive]")
        }
        var remote = "GoogleDrive"
        if args.count == 3 {
            guard args[1] == "--remote", !args[2].isEmpty else { throw NimboCLIError.usage("Uso: nimbo link DRIVE_ID [--remote GoogleDrive]") }
            remote = args[2]
        }
        let item = try await DriveAPI(configuration: paths.config, remoteName: remote).item(id)
        if let link = item.webViewLink { print(link); return }
        print("https://drive.google.com/open?id=\(id)")
    }

    private static func search(_ args: [String], paths: Paths) throws {
        var remote: String?
        var refreshCatalog = false
        var includeID = false
        var terms: [String] = []
        var index = 0
        while index < args.count {
            if args[index] == "--remote" {
                index += 1; guard index < args.count else { throw NimboCLIError.usage("Falta el nombre después de --remote.") }; remote = args[index]
            } else if args[index] == "--refresh" {
                refreshCatalog = true
            } else if args[index] == "--with-id" {
                includeID = true
            } else { terms.append(args[index]) }
            index += 1
        }
        let query = terms.joined(separator: " ")
        let cloud = backend(paths)
        let names = try cloud.listRemotes().filter { remote == nil || $0 == remote }
        guard !names.isEmpty else { print("No hay conexiones para buscar."); return }
        var count = 0; var unavailable:[String] = []
        if refreshCatalog {
            for name in names {
                do { _ = try cloud.list(remote: name) }
                catch { unavailable.append(name) }
            }
        }
        for name in names {
            let cache:RemoteCache?
            do { cache = try backend(paths).loadCache(remote: name) }
            catch { unavailable.append(name); continue }
            guard let cache else { continue }
            for item in cache.entries where matchesQuery(query, item: item) {
                let id = includeID ? "\t\(item.ID ?? "")" : ""
                print("\(name)\t\(item.Path)\t\(item.IsDir ? "carpeta" : "archivo")\(id)")
                count += 1
            }
        }
        if !unavailable.isEmpty { FileHandle.standardError.write(Data(("No se pudo actualizar o leer el catálogo de: " + Array(Set(unavailable)).sorted().joined(separator:", ") + ". Se conserva la copia anterior.\n").utf8)) }
        if count == 0 { FileHandle.standardError.write(Data((refreshCatalog ? "No hay coincidencias en el catálogo actualizado.\n" : "No hay coincidencias en el catálogo local. Usá 'nimbo search --refresh'.\n").utf8)) }
    }

    private static func download(_ args: [String], paths: Paths) async throws {
        var remote = "GoogleDrive"
        var path: String?
        var driveID: String?
        var refreshCatalog = false
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--remote":
                index += 1
                guard index < args.count, !args[index].isEmpty else { throw NimboCLIError.usage("Falta el nombre después de --remote.") }
                remote = args[index]
            case "--path":
                index += 1
                guard index < args.count, !args[index].isEmpty else { throw NimboCLIError.usage("Falta la ruta después de --path.") }
                path = args[index]
            case "--id":
                index += 1
                guard index < args.count, !args[index].isEmpty else { throw NimboCLIError.usage("Falta el ID después de --id.") }
                driveID = args[index]
            case "--refresh": refreshCatalog = true
            default:
                guard path == nil, driveID == nil else { throw NimboCLIError.usage("Uso: nimbo download --path RUTA o --id DRIVE_ID [--remote GoogleDrive] [--refresh]") }
                path = args[index]
            }
            index += 1
        }
        if let driveID {
            guard path == nil else { throw NimboCLIError.usage("Elegí --path o --id, no ambos.") }
            let drive = DriveAPI(configuration: paths.config, remoteName: remote)
            let item = try await drive.item(driveID)
            guard !item.isFolder else { throw CloudBackendError.foldersCannotBeDownloaded }
            guard !item.isGoogleDocument else { throw NimboCLIError.usage("Los documentos nativos se deben exportar desde la interfaz de Nimbo.") }
            if item.capabilities?.canDownload == false { throw DriveFailure.denied }
            let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("Nimbo", isDirectory: true).appendingPathComponent("Nimbo-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let safeName = item.name.replacingOccurrences(of: "/", with: "_").isEmpty ? "archivo" : item.name.replacingOccurrences(of: "/", with: "_")
            let destination = folder.appendingPathComponent(safeName, isDirectory: false)
            try await drive.download(driveID, to: destination, expectedSize: item.size.flatMap(Int64.init))
            print(destination.path)
            return
        }
        guard let path, !path.isEmpty else { throw NimboCLIError.usage("Uso: nimbo download --path RUTA o --id DRIVE_ID [--remote GoogleDrive] [--refresh]") }
        let cloud = backend(paths)
        let cache: RemoteCache
        if refreshCatalog {
            _ = try cloud.list(remote: remote)
        }
        guard let loaded = try cloud.loadCache(remote: remote) else {
            throw NimboCLIError.usage("No hay catálogo para \(remote). Usá --refresh para actualizarlo.")
        }
        cache = loaded
        let matches = cache.entries.filter { $0.Path == path }
        guard matches.count == 1, let item = matches.first else {
            if matches.count > 1 { throw CloudBackendError.duplicateMetadataPath }
            throw NimboCLIError.usage("No se encontró un archivo único en \(remote):\(path)")
        }
        let destination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("Nimbo", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let output = try cloud.download(remote: remote, item: item, destinationDirectory: destination)
        print(output.path)
    }

    private static func refresh(_ args: [String], paths: Paths) throws {
        let names = try backend(paths).listRemotes().filter { args.isEmpty || args.contains($0) }
        guard !names.isEmpty else { throw NimboCLIError.usage("No hay conexiones que actualizar.") }
        let cloud = backend(paths)
        for name in names { print("\(name): \(try cloud.list(remote: name).count) entradas") }
        try spotlight(paths)
    }

    /// Publish the encrypted local catalog to Core Spotlight. Only names,
    /// paths and metadata are indexed; no remote file body is downloaded.
    private static func spotlight(_ p: Paths) throws {
        let cloud = backend(p)
        let remotes = try cloud.listRemotes()
        var entries: [RemoteEntry] = []
        var aliases: [String: String] = [:]
        var unavailable: Set<String> = []
        for remote in remotes {
            aliases[remote] = UserDefaults.standard.string(forKey: "NimboAlias." + remote) ?? remote
            if let cache = try cloud.loadCache(remote: remote) {
                entries += cache.entries.map { RemoteEntry(remote: remote, item: $0) }
            } else { unavailable.insert(remote) }
        }
        let wait = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var outcome: Result<NimboSpotlightReport, Error>?
        SpotlightIndexer.shared.index(entries, aliases: aliases, support: p.support, preservingRemotes: unavailable) { result in
            resultLock.lock(); outcome = result; resultLock.unlock(); wait.signal()
        }
        guard wait.wait(timeout: .now() + 30) == .success else { throw NimboSpotlightFailure.timedOut }
        resultLock.lock(); let result = outcome; resultLock.unlock()
        guard let result else { throw NimboSpotlightFailure.invalidState }
        let report = try result.get()
        print("Spotlight confirmó \(report.indexed) entradas; \(report.removed) obsoletas retiradas; \(report.skipped) sin ID válido.")
        if report.preservedAccounts > 0 {
            print("Se conservaron los resultados anteriores de \(report.preservedAccounts) cuentas sin catálogo disponible.")
        }
    }

    private static func nativeAction(_ args: [String], action: String, paths: Paths) async throws {
        let verb = action == "pin" ? "pin" : "unsync"
        var filePaths: [String] = []
        var limitToken: String?
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--path":
                index += 1
                guard index < args.count, !args[index].isEmpty else {
                    throw NimboCLIError.usage("Uso: nimbo \(verb) --path RUTA")
                }
                filePaths.append(args[index])
            case "--limit":
                guard action == "pin" else { throw NimboCLIError.usage("Uso: nimbo unsync --path RUTA [--path RUTA…]") }
                index += 1
                guard index < args.count, !args[index].isEmpty, limitToken == nil else {
                    throw NimboCLIError.usage("Uso: nimbo pin --path RUTA [--path RUTA…] [--limit none|100m|500m|1g|2g]")
                }
                let candidate = args[index].lowercased()
                guard ["none", "100m", "500m", "1g", "2g"].contains(candidate) else {
                    throw NimboCLIError.usage("Límite inválido. Usá none, 100m, 500m, 1g o 2g.")
                }
                limitToken = candidate
            default:
                throw NimboCLIError.usage(action == "pin" ? "Uso: nimbo pin --path RUTA [--path RUTA…] [--limit none|100m|500m|1g|2g]" : "Uso: nimbo unsync --path RUTA [--path RUTA…]")
            }
            index += 1
        }
        guard !filePaths.isEmpty else {
            throw NimboCLIError.usage(action == "pin" ? "Uso: nimbo pin --path RUTA [--path RUTA…] [--limit none|100m|500m|1g|2g]" : "Uso: nimbo unsync --path RUTA [--path RUTA…]")
        }
        let standardized = filePaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cloudRoot = home + "/Library/CloudStorage/"
        for path in standardized {
            let relative = String(path.dropFirst(cloudRoot.count))
            let account = relative.split(separator: "/", maxSplits: 1).first.map(String.init)
            guard path.hasPrefix(cloudRoot),
                  (account == "Nimbo-GoogleDrive" || account?.hasPrefix("Nimbo-GoogleDrive-") == true || account?.hasPrefix("Nimbo-GoogleDrive·") == true),
                  FileManager.default.fileExists(atPath: path) else {
                throw NimboCLIError.usage("La ruta debe existir dentro de un volumen Google Drive de Nimbo: \(path)")
            }
        }
        var components = URLComponents()
        components.scheme = "nimbo"
        components.host = verb
        components.queryItems = standardized.map { URLQueryItem(name: "path", value: $0) }
        if let limitToken { components.queryItems?.append(URLQueryItem(name: "limit", value: limitToken)) }
        guard let target = components.url else {
            throw NimboCLIError.usage("La ruta no se pudo codificar.")
        }
        guard NSWorkspace.shared.open(target) else { throw NimboCLIError.usage("No se pudo enviar la orden a Nimbo.") }
        let verbText = action == "pin" ? "conservar sin conexión" : "liberar la copia local"
        print("Orden enviada: \(verbText) en \(standardized.count) elemento\(standardized.count == 1 ? "" : "s")")
    }

    private static func synchronize(_ args: [String], paths: Paths) throws {
        guard let text = args.first, let id = UUID(uuidString: text) else { throw NimboCLIError.usage("Uso: nimbo sync UUID") }
        let sync = try engine(paths); try sync.synchronize(id); print("Sincronización completada: \(id.uuidString)")
    }

    private static func backup(_ args: [String], paths: Paths) throws {
        let help = "Uso: nimbo backup UUID | nimbo backup list UUID | nimbo backup restore UUID RESPALDO CARPETA_NUEVA"
        let sync = try engine(paths)
        if args.count == 1, let id = UUID(uuidString: args[0]) {
            try sync.runBackup(id)
            print("Backup completado: " + id.uuidString)
        } else if args.count == 2, args[0] == "list", let id = UUID(uuidString: args[1]) {
            for name in try sync.remoteBackups(id) { print(name) }
        } else if args.count == 4, args[0] == "restore", let id = UUID(uuidString: args[1]) {
            let output = URL(fileURLWithPath: args[3])
            try sync.restoreRemoteBackup(id, snapshot: args[2], destination: output)
            print("Respaldo restaurado en " + output.path)
        } else { throw NimboCLIError.usage(help) }
    }

    private static func sharedDrives(_ p: Paths) async throws {
        let values = try await DriveAPI(configuration: p.config).allSharedDrives(limit: 500)
        if values.isEmpty {
            print("No hay Unidades compartidas visibles para la cuenta conectada.")
            return
        }
        for item in values { print("\(item.id)\t\(item.name)\t\(item.createdTime ?? "")") }
    }

    private static func trash(_ p: Paths) async throws {
        let drive = DriveAPI(configuration: p.config)
        var page: String?, seen = Set<String>(), count = 0
        repeat {
            let result = try await drive.trashPage(page: page)
            for item in result.files { print("\(item.id)\t\(item.name)\t\(item.modifiedTime ?? "")"); count += 1 }
            guard count <= 2000, let next = result.nextPageToken, seen.insert(next).inserted else { break }
            page = next
        } while page != nil
    }

    private static func trashDelete(_ args: [String], paths: Paths) async throws {
        guard args.count == 2, args[1] == "--confirm" else {
            throw NimboCLIError.usage("Uso: nimbo trash-delete DRIVE_ID --confirm\nLa acción elimina permanentemente un solo elemento ya presente en la papelera.")
        }
        let drive = DriveAPI(configuration: paths.config)
        guard try await drive.permitsWrites() else { throw DriveFailure.denied }
        try await drive.permanentlyDeleteFromTrash(args[0])
        print("Elemento eliminado permanentemente: \(args[0])")
    }

    private static func trashRestore(_ args: [String], paths: Paths) async throws {
        let (id, remote) = try shareArguments(args, command: "trash-restore")
        let drive = DriveAPI(configuration: paths.config, remoteName: remote)
        guard try await drive.permitsWrites() else { throw DriveFailure.denied }
        let restored = try await drive.restoreFromTrash(id)
        print("Elemento restaurado: \(restored.name)")
    }

    private static func share(_ args: [String], paths: Paths) async throws {
        let (id, remote) = try shareArguments(args, command: "share")
        let drive = DriveAPI(configuration: paths.config, remoteName: remote)
        guard try await drive.permitsWrites() else { throw DriveFailure.denied }
        print(try await drive.createPublicLink(id))
    }

    private static func revokeShare(_ args: [String], paths: Paths) async throws {
        let (id, remote) = try shareArguments(args, command: "revoke-share")
        let drive = DriveAPI(configuration: paths.config, remoteName: remote)
        guard try await drive.permitsWrites() else { throw DriveFailure.denied }
        let removed = try await drive.revokePublicLinks(id)
        print("Enlaces públicos revocados: \(removed)")
    }

    private static func shareArguments(_ args: [String], command: String) throws -> (String, String) {
        var id: String?
        var remote = "GoogleDrive"
        var confirmed = false
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--confirm": confirmed = true
            case "--remote":
                index += 1
                guard index < args.count, !args[index].isEmpty else { throw NimboCLIError.usage("Falta el nombre después de --remote.") }
                remote = args[index]
            default:
                guard id == nil else { throw NimboCLIError.usage("Uso: nimbo \(command) DRIVE_ID --confirm [--remote GoogleDrive]") }
                id = args[index]
            }
            index += 1
        }
        guard let id, !id.isEmpty, confirmed else {
            throw NimboCLIError.usage("Uso: nimbo \(command) DRIVE_ID --confirm [--remote GoogleDrive]")
        }
        return (id, remote)
    }

    private static let usage = """
    nimbo — automatización local de Google Drive de Nimbo

    nimbo doctor
    nimbo autostart status|enable|disable
    nimbo link DRIVE_ID [--remote GoogleDrive]
    nimbo status
    nimbo search [--refresh] [--with-id] [--remote GoogleDrive] [términos]
    nimbo download --path RUTA o --id DRIVE_ID [--remote GoogleDrive] [--refresh]
    nimbo unsync --path RUTA [--path RUTA…]
    nimbo pin --path RUTA [--path RUTA…] [--limit none|100m|500m|1g|2g]
    nimbo refresh [remotes...]
    nimbo spotlight
    nimbo sync UUID
    nimbo backup UUID
    nimbo backup list UUID
    nimbo backup restore UUID RESPALDO CARPETA_NUEVA
    nimbo trash
    nimbo trash-delete DRIVE_ID --confirm
    nimbo trash-restore DRIVE_ID --confirm [--remote GoogleDrive]
    nimbo share DRIVE_ID --confirm [--remote GoogleDrive]
    nimbo revoke-share DRIVE_ID --confirm [--remote GoogleDrive]
    nimbo shared-drives

    search usa el catálogo local y no descarga contenido; --refresh actualiza los nombres y rutas antes de buscar y --with-id agrega el ID estable como cuarta columna. download acepta una ruta exacta o un ID estable y copia un único archivo a Descargas/Nimbo sin reemplazar archivos existentes. pin y unsync delegan al host Nimbo la conservación o liberación de una copia local, sin modificar Google Drive, y respetan la seguridad de File Provider. trash-restore, share y revoke-share modifican sólo el elemento indicado y exigen --confirm.
    """
}
