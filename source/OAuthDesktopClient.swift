import Foundation

struct OAuthDesktopClient {
    let id: String
    let secret: String

    enum ImportError: Error, LocalizedError {
        case invalidDesktopFile
        var errorDescription: String? { "Elegí el JSON de un cliente OAuth de tipo App de escritorio descargado de Google Cloud." }
    }

    init(id: String, secret: String) throws {
        guard id.hasSuffix(".apps.googleusercontent.com"), !secret.isEmpty,
              !id.contains(where: { $0.isWhitespace || $0.isNewline }),
              secret == secret.trimmingCharacters(in: .whitespacesAndNewlines),
              !secret.contains(where: { $0.isNewline })
        else { throw ImportError.invalidDesktopFile }
        self.id = id
        self.secret = secret
    }

    static func read(_ url: URL) throws -> OAuthDesktopClient {
        guard url.isFileURL, url.pathExtension.lowercased() == "json",
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        else { throw ImportError.invalidDesktopFile }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try parse(file.read(upToCount: 65_537) ?? Data())
    }

    static func parse(_ data: Data) throws -> OAuthDesktopClient {
        guard data.count <= 65_536,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let installed = root["installed"] as? [String: Any],
              let id = installed["client_id"] as? String,
              let secret = installed["client_secret"] as? String
        else { throw ImportError.invalidDesktopFile }
        return try OAuthDesktopClient(id: id, secret: secret)
    }
}
