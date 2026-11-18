import Foundation
import FileProvider
import Darwin

/// Command mode of the signed host. It uses the host's registered provider
/// identity without constructing NSApplication, windows or a menu-bar item.
enum NativeFileCommand {
    struct Request {
        let action: String
        let url: URL
        let isDirectory: Bool
        init(_ arguments: [String], home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
            guard arguments.count == 4, arguments[0] == "--native-file-action",
                  ["status", "sync", "pin", "unsync"].contains(arguments[1]), arguments[2] == "--path",
                  arguments[3].hasPrefix("/") else { throw Failure.usage }
            action = arguments[1]
            url = URL(fileURLWithPath: arguments[3]).standardizedFileURL.resolvingSymlinksInPath()
            let base = home.appendingPathComponent("Library/CloudStorage").standardizedFileURL.resolvingSymlinksInPath()
            guard url.path.hasPrefix(base.path + "/") else { throw Failure.outsideNimbo }
            let components = Array(url.pathComponents.dropFirst(base.pathComponents.count))
            guard components.count >= 2, components[0].hasPrefix("Nimbo-GoogleDrive") else { throw Failure.outsideNimbo }
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            isDirectory = info.st_mode & S_IFMT == S_IFDIR
            guard isDirectory || info.st_mode & S_IFMT == S_IFREG else { throw Failure.fileOnly }
        }
    }
    enum Failure: String, Error {
        case usage = "Uso: Nimbo --native-file-action status|sync|pin|unsync --path /ruta/al/archivo"
        case outsideNimbo = "La ruta debe ser un archivo dentro de Google Drive de Nimbo."
        case fileOnly = "Esta orden admite archivos y carpetas de Nimbo."
        case providerMismatch = "El archivo no pertenece a un dominio de Nimbo reconocido."
        case invalidPage = "El proveedor devolvió una página de estado no válida."
    }
    static func supports(_ domain: String) -> Bool {
        domain == "google-drive" || domain.hasPrefix("google-drive-account-") || domain.hasPrefix("google-drive-shared-")
    }
    static func availability(_ id: String, client: NativeClient) async throws -> NativeAvailabilityCandidate? {
        var after: String?, seen = Set<String>()
        for _ in 0..<1000 {
            let page = try await client.availabilityPage(after: after)
            if let value = page.items.first(where: { $0.id == id }) { return value }
            guard let next = page.next else { return nil }
            guard seen.insert(next).inserted else { throw Failure.invalidPage }
            after = next
        }
        throw Failure.invalidPage
    }
    static func run(_ arguments: [String]) async -> Int32 {
        var phase = "validate-path"
        do {
            let request = try Request(arguments)
            phase = "resolve-domain"
            let resolved = try await NativeClient().identifierForUserVisibleFile(request.url)
            guard supports(resolved.domain) else { throw Failure.providerMismatch }
            let client = NativeClient(identifier: resolved.domain)
            phase = "perform-action"
            switch request.action {
            case "sync": try await client.downloadNow(resolved.id)
            case "pin": try await client.pin(resolved.id, true)
            case "unsync": try await client.evict(resolved.id)
            default: break
            }
            phase = "read-provider-state"
            let availability = request.isDirectory ? nil : try await availability(resolved.id, client: client)
            var info = stat()
            guard lstat(request.url.path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            let dataless = info.st_flags & UInt32(SF_DATALESS) != 0
            let result: [String: Any] = ["result": "OK", "action": request.action, "id": resolved.id,
                "domain": resolved.domain, "kind": request.isDirectory ? "folder" : "file", "dataless": dataless, "logicalBytes": info.st_size,
                "allocatedBytes": Int64(info.st_blocks) * 512,
                "pinned": availability.map { $0.pinned as Any } ?? NSNull(),
                "providerDownloaded": availability.map { ($0.downloadedAt != nil) as Any } ?? NSNull()]
            print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
            return 0
        } catch {
            let e = error as NSError
            let message = (error as? Failure)?.rawValue ?? "No se pudo completar la operación de File Provider."
            let result: [String: Any] = ["result": "ERROR", "message": message, "domain": e.domain, "code": e.code, "phase": phase]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
            return 1
        }
    }
}
