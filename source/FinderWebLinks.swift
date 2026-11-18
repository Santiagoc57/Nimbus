import Foundation

struct FinderWebLinks {
    struct Identity: Sendable { let id: String; let domain: String }
    enum Failure: Error, LocalizedError {
        case outsideNimbo, invalidSelection, unrelatedProvider
        var errorDescription: String? {
            switch self {
            case .outsideNimbo: return "Seleccioná archivos dentro de la carpeta de Nimbo en Finder."
            case .invalidSelection: return "Seleccioná entre 1 y 100 elementos para obtener sus enlaces."
            case .unrelatedProvider: return "El archivo no pertenece a una cuenta de Nimbo."
            }
        }
    }
    let identify: @Sendable (URL) async throws -> Identity
    let resolve: @Sendable (Identity) async throws -> URL
    func links(paths: [String], home: URL) async throws -> [URL] {
        guard !paths.isEmpty, paths.count <= 100 else { throw Failure.invalidSelection }
        let base = home.appendingPathComponent("Library/CloudStorage").standardizedFileURL.path + "/"
        var seen = Set<String>(), result: [URL] = []
        for path in paths {
            try Task.checkCancellation()
            guard path.hasPrefix("/") else { throw Failure.outsideNimbo }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url.path.hasPrefix(base) else { throw Failure.outsideNimbo }
            guard seen.insert(url.path).inserted else { continue }
            let identity = try await identify(url)
            guard identity.domain == "google-drive" || identity.domain.hasPrefix("google-drive-account-") || identity.domain.hasPrefix("google-drive-shared-") else { throw Failure.unrelatedProvider }
            let link = try await resolve(identity)
            try Task.checkCancellation()
            result.append(try DriveAPI.validatedBrowserURL(link.absoluteString))
        }
        return result
    }
}
