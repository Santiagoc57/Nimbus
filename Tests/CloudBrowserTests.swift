#if BROWSER_TESTS
import Foundation

@main
struct CloudBrowserTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ description: String) throws {
        guard value() else { throw NSError(domain: "CloudBrowserTests", code: 1, userInfo: [NSLocalizedDescriptionKey: description]) }
        checks += 1
    }

    static func entry(_ remote: String, _ path: String, folder: Bool = false, id: String? = nil) -> RemoteEntry {
        RemoteEntry(remote: remote, item: CloudItem(Path: path, Name: String(path.split(separator: "/").last!), Size: folder ? 0 : 12, IsDir: folder, ID: id))
    }

    static func main() throws {
        let projects = entry("Personal", "Proyectos", folder: true, id: "projects")
        let child = entry("Personal", "Proyectos/Diseño", folder: true, id: "design")
        let file = entry("Personal", "Proyectos/Diseño/Resumen.pdf", id: "pdf")
        let sibling = entry("Personal", "Proyectos antiguos/Resumen.pdf", id: "old-pdf")
        let empty = entry("Personal", "Vacía", folder: true, id: "empty")
        let other = entry("Trabajo", "Proyectos", folder: true, id: "work-projects")
        let otherFile = entry("Trabajo", "Proyectos/Resumen.pdf", id: "work-pdf")
        let rootFile = entry("Personal", "Inicio.txt", id: "root-file")
        let catalog = [projects, child, file, sibling, empty, other, otherFile, rootFile]
        var browser = CloudBrowser()
        try check(catalog.filter(browser.contains) == [projects, empty, other, rootFile], "Home shows direct children from each account")
        try check(!browser.canGoBack && !browser.canGoForward && !browser.canGoUp, "Home has no false history or parent")
        browser.selectAccount("Personal")
        try check(catalog.filter(browser.contains) == [projects, empty, rootFile], "Account scope excludes other accounts")
        browser.updateFilters(query: "resumen", kind: 1, dateDays: 30, size: 2)
        try check(catalog.filter { browser.contains($0) && matchesQuery(browser.current.query, item: $0.item) } == [file, sibling], "Account search includes descendants")
        let searchState = browser.current
        try browser.openFolder(projects, catalog: catalog)
        try check(catalog.filter(browser.contains) == [child], "Folder shows only its immediate children")
        try check(browser.current.query.isEmpty && browser.current.kind == 0 && browser.current.dateDays == 0 && browser.current.size == 0, "Entering a folder clears filters that could hide its contents")
        browser.goBack()
        try check(browser.current == searchState, "Back restores query, account and all filters")
        browser.goForward()
        try check(browser.current.location.folderID == "projects", "Forward restores folder")
        browser.updateFilters(query: "Resumen", kind: 0, dateDays: 0, size: 0)
        try check(catalog.filter { browser.contains($0) && matchesQuery(browser.current.query, item: $0.item) } == [file], "Folder search respects account and slash boundaries")
        try browser.openFolder(child, catalog: catalog)
        try check(catalog.filter(browser.contains) == [file], "Nested folder lists its content")
        browser.goUp()
        try check(browser.current.location.path == "Proyectos" && browser.current.location.remote == "Personal", "Up goes to parent in the same account")
        browser.reconcile(catalog: catalog, remotes: ["Personal", "Trabajo"])
        try check(browser.current.location.folderID == "projects", "Parent resolves stable identity")
        browser.goUp()
        try check(browser.current.location.path.isEmpty && browser.current.location.remote == "Personal", "Up from top-level folder reaches account root")
        browser.goUp()
        try check(browser.current.location.remote == nil, "Up from account reaches all accounts")
        try browser.openFolder(empty, catalog: catalog)
        try check(catalog.filter(browser.contains).isEmpty, "Empty folder is distinct from catalog-wide results")
        browser.goBack()
        browser.selectAccount("Trabajo")
        try check(!browser.canGoForward, "New navigation clears abandoned forward history")
        let before = browser.current
        do {
            try browser.openFolder(file, catalog: catalog)
            throw NSError(domain: "CloudBrowserTests", code: 2)
        } catch CloudBrowser.NavigationError.notFolder {}
        try check(browser.current == before, "Opening a file as a folder leaves state unchanged")
        let duplicate = entry("Personal", "Proyectos", folder: true, id: "duplicate-projects")
        do {
            try browser.openFolder(projects, catalog: catalog + [duplicate])
            throw NSError(domain: "CloudBrowserTests", code: 3)
        } catch CloudBrowser.NavigationError.ambiguousFolder {}
        try check(browser.current == before, "Same-path folders do not silently merge")
        do {
            try browser.openFolder(empty, catalog: [])
            throw NSError(domain: "CloudBrowserTests", code: 4)
        } catch CloudBrowser.NavigationError.missingFolder {}
        try check(browser.current == before, "Stale folder selection does not navigate")
        try browser.openFolder(child, catalog: catalog)
        let moved = entry("Personal", "Diseños nuevos", folder: true, id: "design")
        browser.reconcile(catalog: catalog.filter { $0 != child } + [moved], remotes: ["Personal", "Trabajo"])
        try check(browser.current.location.path == "Diseños nuevos", "Refresh follows renamed or moved folder by Drive ID")
        browser.reconcile(catalog: catalog.filter { $0 != child }, remotes: ["Personal", "Trabajo"])
        try check(browser.current.location.path.isEmpty && browser.current.location.remote == "Personal", "Deleted top-level folder falls back to its account root")
        try browser.openFolder(child, catalog: catalog)
        browser.reconcile(catalog: catalog.filter { $0 != child }, remotes: ["Personal", "Trabajo"])
        try check(browser.current.location.path == "Proyectos", "Deleted nested folder falls back to surviving parent")
        browser.reconcile(catalog: catalog, remotes: ["Trabajo"])
        try check(browser.current.location.remote == nil, "Removed account returns to all accounts")
        browser.goBack()
        browser.reconcile(catalog: catalog, remotes: ["Trabajo"])
        try check(browser.current.location.remote == nil, "History cannot revive a removed account")
        browser.goHome()
        browser.updateFilters(query: "  \n ", kind: 0, dateDays: 0, size: 0)
        try check(!browser.current.isSearching && !browser.contains(file), "Whitespace-only search keeps direct-child browsing")
        var collisionBrowser = CloudBrowser()
        try collisionBrowser.openFolder(projects, catalog: catalog)
        collisionBrowser.reconcile(catalog: catalog + [duplicate], remotes: ["Personal", "Trabajo"])
        try check(collisionBrowser.current.location.path.isEmpty, "Refresh does not merge a folder that becomes ambiguous")
        let noID = entry("Personal", "Sin ID", folder: true, id: "")
        try collisionBrowser.openFolder(noID, catalog: [noID])
        collisionBrowser.reconcile(catalog: [noID], remotes: ["Personal"])
        try check(collisionBrowser.current.location.path == "Sin ID", "Empty IDs use path fallback instead of losing the current folder")
        collisionBrowser.reconcile(catalog: [noID], remotes: ["Personal"])
        try check(collisionBrowser.current.location.path == "Sin ID", "Repeated refresh with empty IDs keeps the folder open")
        for index in 0..<150 { browser.selectAccount("Account-\(index)") }
        var count = 0
        while browser.canGoBack { browser.goBack(); count += 1 }
        try check(count == 100, "Navigation history is bounded")
        print("PASS: \(checks) browser checks; metadata only; no accounts accessed")
    }
}
#endif
