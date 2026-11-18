import Foundation

/// The domain comes from the File Provider UI context, never from a current UI account.
struct ProviderWebLinks {
    enum Action: String {
        case copy = "local.nimbo.providerui.copy-link"
        case share = "local.nimbo.providerui.share"
        case revoke = "local.nimbo.providerui.revoke"
        case preview = "local.nimbo.providerui.preview"
    }
    let action: Action
    let domain: String
    let identifiers: [String]

    init(action: String, domain: String?, identifiers: [String]) throws {
        guard let parsed = Action(rawValue: action), let domain,
              domain == "google-drive" || domain.hasPrefix("google-drive-account-") || domain.hasPrefix("google-drive-shared-"),
              !identifiers.isEmpty, identifiers.count <= 100,
              identifiers.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 && !$0.contains("\0") }) else {
            throw NSError(domain: "NimboProviderAction", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "La acción, cuenta o selección de Finder no es válida."])
        }
        self.action = parsed; self.domain = domain
        var seen = Set<String>()
        self.identifiers = identifiers.filter { seen.insert($0).inserted }
    }

    func confirmationURL(identify: (String, String) async throws -> (domain: String, id: String, url: URL)) async throws -> URL {
        guard action == .share || action == .revoke else { throw DriveFailure.invalidResponse }
        var parts = URLComponents()
        parts.scheme = "nimbo"
        parts.host = action == .share ? "share" : "revoke-share"
        var query = [URLQueryItem(name: "domain", value: domain)]
        var seen = Set<String>()
        for opaqueID in identifiers {
            try Task.checkCancellation()
            let item = try await identify(domain, opaqueID)
            guard item.domain == domain, item.url.isFileURL, !item.id.isEmpty else { throw DriveFailure.invalidResponse }
            if seen.insert(item.id).inserted {
                query.append(URLQueryItem(name: "path", value: item.url.path))
                query.append(URLQueryItem(name: "item", value: item.id))
            }
        }
        try Task.checkCancellation()
        parts.queryItems = query
        guard let url = parts.url else { throw DriveFailure.invalidResponse }
        return url
    }

    func resolve(identify: (String, String) async throws -> (domain: String, id: String) = { ($0, $1) },
                 using resolver: (String, String) async throws -> URL) async throws -> [URL] {
        var links: [URL] = []
        for id in identifiers {
            try Task.checkCancellation()
            let identity = try await identify(domain, id)
            guard identity.domain == domain else {
                throw NSError(domain: "NimboProviderAction", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "La selección ya no pertenece a esta cuenta de Nimbo."])
            }
            try Task.checkCancellation()
            let value = try await resolver(identity.domain, identity.id)
            try Task.checkCancellation()
            links.append(try DriveAPI.validatedBrowserURL(value.absoluteString))
        }
        return links
    }
}
