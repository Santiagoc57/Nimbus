import Foundation

struct CloudBrowserLocation: Equatable {
    var remote: String?
    var path: String = ""
    var folderID: String?
}

struct CloudBrowserView: Equatable {
    var location = CloudBrowserLocation()
    var query = ""
    var kind = 0
    var dateDays = 0
    var size = 0

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Navigation uses only the metadata already in the catalog. No download,
/// authorization or filesystem operation is performed by browsing a folder.
struct CloudBrowser {
    enum NavigationError: Error { case notFolder, missingFolder, ambiguousFolder }
    private(set) var current = CloudBrowserView()
    private var previous: [CloudBrowserView] = []
    private var next: [CloudBrowserView] = []

    var canGoBack: Bool { !previous.isEmpty }
    var canGoForward: Bool { !next.isEmpty }
    var canGoUp: Bool { current.location.remote != nil }

    mutating func updateFilters(query: String, kind: Int, dateDays: Int, size: Int) {
        current.query = query; current.kind = kind
        current.dateDays = dateDays; current.size = size
    }

    mutating func visit(_ view: CloudBrowserView) {
        guard view != current else { return }
        previous.append(current)
        if previous.count > 100 { previous.removeFirst(previous.count - 100) }
        next.removeAll()
        current = view
    }

    mutating func selectAccount(_ remote: String?) {
        var view = current
        view.location = CloudBrowserLocation(remote: remote)
        visit(view)
    }

    mutating func openFolder(_ entry: RemoteEntry, catalog: [RemoteEntry]) throws {
        guard entry.item.IsDir else { throw NavigationError.notFolder }
        let candidates = catalog.filter { $0.remote == entry.remote && $0.item.Path == entry.item.Path }
        guard !candidates.isEmpty else { throw NavigationError.missingFolder }
        // A path-only recursive catalog cannot distinguish the children of
        // same-named Google Drive folders. Never silently merge those folders.
        guard candidates.count == 1 else { throw NavigationError.ambiguousFolder }
        visit(CloudBrowserView(location: CloudBrowserLocation(remote: entry.remote, path: entry.item.Path, folderID: entry.item.ID.flatMap { $0.isEmpty ? nil : $0 })))
    }

    mutating func goBack() {
        guard let view = previous.popLast() else { return }
        next.append(current); current = view
    }

    mutating func goForward() {
        guard let view = next.popLast() else { return }
        previous.append(current); current = view
    }

    mutating func goHome() { visit(CloudBrowserView()) }

    mutating func goUp() {
        guard let remote = current.location.remote else { return }
        let path = current.location.path
        let location = path.isEmpty ? CloudBrowserLocation() : CloudBrowserLocation(remote: remote, path: Self.parent(of: path))
        visit(CloudBrowserView(location: location))
    }

    /// Reconcile a removed account or moved/deleted folder after a refresh.
    /// A stable Drive ID takes precedence over its old path.
    mutating func reconcile(catalog: [RemoteEntry], remotes: Set<String>) {
        guard let remote = current.location.remote else { return }
        guard remotes.contains(remote) else { current = CloudBrowserView(); return }
        guard !current.location.path.isEmpty else { return }
        let folders = catalog.filter { $0.remote == remote && $0.item.IsDir }
        if let id = current.location.folderID, !id.isEmpty,
           let match = folders.first(where: { $0.item.ID == id }) {
            current.location.path = match.item.Path
            if folders.filter({ $0.item.Path == match.item.Path }).count == 1 { return }
        }
        if current.location.folderID == nil,
           folders.filter({ $0.item.Path == current.location.path }).count == 1,
           let match = folders.first(where: { $0.item.Path == current.location.path }) {
            current.location.folderID = match.item.ID.flatMap { $0.isEmpty ? nil : $0 }
            return
        }
        var path = Self.parent(of: current.location.path)
        while !path.isEmpty {
            if folders.filter({ $0.item.Path == path }).count == 1,
               let parent = folders.first(where: { $0.item.Path == path }) {
                current.location = CloudBrowserLocation(remote: remote, path: path, folderID: parent.item.ID.flatMap { $0.isEmpty ? nil : $0 })
                return
            }
            path = Self.parent(of: path)
        }
        current.location = CloudBrowserLocation(remote: remote)
    }

    func contains(_ entry: RemoteEntry) -> Bool {
        let location = current.location
        if let remote = location.remote, remote != entry.remote { return false }
        if current.isSearching {
            return location.path.isEmpty || entry.item.Path.hasPrefix(location.path + "/")
        }
        return Self.parent(of: entry.item.Path) == location.path
    }

    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }
}
