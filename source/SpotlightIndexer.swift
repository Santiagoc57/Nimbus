import Foundation
import CoreSpotlight
import UniformTypeIdentifiers
import AppKit

/// Publishes catalog metadata and previews already cached while browsing.
/// The indexer itself makes no cloud-content or thumbnail network requests.
final class SpotlightIndexer {
    static let shared = SpotlightIndexer()
    private let queue = DispatchQueue(label: "local.nimbo.spotlight", qos: .utility)
    private var tail: Task<Void, Never>?

    func index(_ entries: [RemoteEntry], aliases: [String: String], support: URL,
               preservingRemotes: Set<String> = [],
               completion: ((Result<NimboSpotlightReport, Error>) -> Void)? = nil) {
        queue.async {
            let previous = self.tail
            self.tail = Task {
                await previous?.value
                do {
                    let reconciler = SpotlightReconciler(support: support, sink: SystemSpotlightSink(support: support))
                    let report = try await reconciler.reconcile(entries, aliases: aliases, preservingRemotes: preservingRemotes)
                    completion?(.success(report))
                } catch { completion?(.failure(error)) }
            }
        }
    }
    func enrich(_ entry: RemoteEntry, alias: String, support: URL) {
        queue.async {
            let previous = self.tail
            self.tail = Task {
                await previous?.value
                let reconciler = SpotlightReconciler(support: support, sink: SystemSpotlightSink(support: support))
                // A later catalog refresh retries cached previews if Spotlight
                // is busy/unavailable; the browser still displays its preview.
                _ = try? await reconciler.enrich(entry, alias: alias)
            }
        }
    }
}

private final class SystemSpotlightSink: NimboSpotlightSink {
    private let index = CSSearchableIndex(name: "NimboCatalogV2")
    private var icons: [String: Data] = [:]
    private let thumbnails: ThumbnailCache
    init(support: URL) { thumbnails = ThumbnailCache(support: support) }

    func publish(_ entries: [RemoteEntry], aliases: [String: String]) async throws {
        var items: [CSSearchableItem] = []
        for entry in entries {
            guard let unique = SpotlightReconciler.identifier(entry), let id = entry.item.ID else { continue }
            let type = contentType(for: entry.item)
            let attrs = CSSearchableItemAttributeSet(contentType: type)
            attrs.title = entry.item.Name
            attrs.displayName = entry.item.Name
            attrs.contentDescription = "\(aliases[entry.remote] ?? entry.remote):/\(entry.item.Path)"
            attrs.path = entry.item.Path
            attrs.keywords = [entry.item.Name, entry.item.Path, aliases[entry.remote] ?? entry.remote]
            var link = URLComponents()
            link.scheme = "nimbo"; link.host = "open"
            link.queryItems = [URLQueryItem(name: "remote", value: entry.remote), URLQueryItem(name: "id", value: id)]
            attrs.contentURL = link.url
            attrs.fileSize = entry.item.Size >= 0 ? NSNumber(value: entry.item.Size) : nil
            attrs.contentModificationDate = date(entry.item.ModTime)
            if icons[type.identifier] == nil {
                let icon = NSWorkspace.shared.icon(forFileType: type.identifier)
                if let tiff = icon.tiffRepresentation {
                    icons[type.identifier] = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                }
            }
            attrs.thumbnailData = await thumbnails.read(entry)?.data ?? icons[type.identifier]
            items.append(CSSearchableItem(uniqueIdentifier: unique, domainIdentifier: "local.nimbo.catalog.v2", attributeSet: attrs))
        }
        try await index.indexSearchableItems(items)
    }

    func remove(_ identifiers: [String]) async throws {
        try await index.deleteSearchableItems(withIdentifiers: identifiers)
    }

    func removeLegacyIndex() async throws {
        try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: ["local.nimbo.cloud"])
    }

    private func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private func contentType(for item: CloudItem) -> UTType {
        if item.IsDir { return .folder }
        if let mime = item.MimeType, let type = UTType(mimeType: mime) { return type }
        return UTType(filenameExtension: URL(fileURLWithPath: item.Name).pathExtension) ?? .data
    }
}
