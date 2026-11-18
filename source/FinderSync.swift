import Cocoa
import FinderSync
import FileProvider
import Darwin

enum NimboFinderContextAction: String {
    case sync = "Sincronizar ahora"
    case pin = "Conservar sin conexión"
    case evict = "Desincronizar / liberar espacio"
}

/// Finder Sync contributes the contextual action; the main app performs the
/// File Provider eviction after resolving the selected URL to a stable Drive
/// item identifier. No cloud mutation is performed by this extension.
final class NimboFinderSync: FIFinderSync {
    override init() {
        super.init()
        let home = Self.realHomeDirectory
        // Finder ignores registrations under ~/Library (including
        // ~/Library/CloudStorage), so also register the home folder; Finder
        // then consults this extension for File Provider items below it, and
        // `menu(for:)` / badges stay limited to Nimbo paths via `isNimboPath`.
        let roots = Self.monitoredDirectoryURLs(home: home)
        FIFinderSyncController.default().directoryURLs = roots
        NSLog("NimboFinderSync roots: %@", roots.map(\.path).sorted().joined(separator: ", "))
        guard Self.badgesEnabled else { return }
        let controller = FIFinderSyncController.default()
        controller.setBadgeImage(Self.badge(kind: .cloudFile), label: "Sólo en la nube", forBadgeIdentifier: "nimbo-cloud")
        controller.setBadgeImage(Self.badge(kind: .cloudFolder), label: "Carpeta sólo en la nube", forBadgeIdentifier: "nimbo-cloud-folder")
        controller.setBadgeImage(Self.badge(kind: .localFile), label: "Disponible sin conexión", forBadgeIdentifier: "nimbo-local")
        controller.setBadgeImage(Self.badge(kind: .localFolder), label: "Carpeta disponible sin conexión", forBadgeIdentifier: "nimbo-local-folder")
        // Some macOS releases skip requestBadgeIdentifier for File Provider
        // volumes. Seed the current Nimbo root immediately so Finder can use
        // the same cloud/check decorations even before it asks for a badge.
        DispatchQueue.main.async {
            for root in roots {
                Self.seedBadges(in: root)
            }
        }
    }

    /// Finder rejects CloudStorage registrations, including mounted child roots.
    /// Register one accepted ancestor; menu(for:) still filters every selection.
    /// Persistence after Finder relaunch requires separate runtime acceptance.
    static func monitoredDirectoryURLs(home: URL, fileManager: FileManager = .default) -> Set<URL> {
        [home.standardizedFileURL]
    }

    override func requestBadgeIdentifier(for url: URL) {
        guard Self.badgesEnabled else { return }
        guard Self.isNimboPath(url) else { return }
        setBadge(for: url)
    }

    /// Finder does not consistently call requestBadgeIdentifier for items
    /// inside a File Provider volume.  It does call beginObservingDirectory
    /// when the visible folder changes, so seed the badges for the rows Finder
    /// can see there as well.  This keeps the cloud/check indicators visible
    /// after a Finder restart and after File Provider refreshes the directory.
    override func beginObservingDirectory(at url: URL) {
        // FIFinderSync does not implement this optional callback itself.
        // Calling super sends an unrecognized selector and aborts the helper.
        guard Self.badgesEnabled else { return }
        guard Self.isNimboPath(url) || url.path.contains("/Library/CloudStorage/") else { return }
        NSLog("NimboFinderSync observing: %@", url.path)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries where Self.isNimboPath(entry) {
            setBadge(for: entry)
        }
    }

    private func setBadge(for url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return }
        let dataless = (info.st_flags & UInt32(SF_DATALESS)) != 0
        let folder = (info.st_mode & S_IFMT) == S_IFDIR
        let badge = dataless ? (folder ? "nimbo-cloud-folder" : "nimbo-cloud") : (folder ? "nimbo-local-folder" : "nimbo-local")
        FIFinderSyncController.default().setBadgeIdentifier(badge, for: url)
    }

    private static func seedBadges(in directory: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let visible = entries.filter { isNimboPath($0) }
        NSLog("NimboFinderSync seeding %d badges in %@", visible.count, directory.path)
        for entry in visible {
            var info = stat()
            guard lstat(entry.path, &info) == 0 else { continue }
            let dataless = (info.st_flags & UInt32(SF_DATALESS)) != 0
            let folder = (info.st_mode & S_IFMT) == S_IFDIR
            let badge = dataless ? (folder ? "nimbo-cloud-folder" : "nimbo-cloud") : (folder ? "nimbo-local-folder" : "nimbo-local")
            FIFinderSyncController.default().setBadgeIdentifier(badge, for: entry)
        }
    }

    private enum BadgeKind { case cloudFile, cloudFolder, localFile, localFolder }

    /// Draws a compact status badge without copying any provider artwork.
    /// Cloud-only folders retain the blue folder mark; materialized items use
    /// a blue check badge so Finder communicates the completed sync state.
    private static func badge(kind: BadgeKind) -> NSImage {
        let color: NSColor = {
            switch kind {
            case .cloudFile, .cloudFolder, .localFile, .localFolder: return .systemBlue
            }
        }()
        let folder = kind == .cloudFolder
        return NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            color.setFill()
            if kind == .localFile || kind == .localFolder {
                NSBezierPath(ovalIn: NSRect(x: rect.minX + 1, y: rect.minY + 1, width: 14, height: 14)).fill()
                NSColor.white.setStroke()
                let check = NSBezierPath()
                check.lineWidth = 1.7
                check.move(to: NSPoint(x: rect.minX + 4.2, y: rect.midY))
                check.line(to: NSPoint(x: rect.minX + 7.0, y: rect.minY + 4.5))
                check.line(to: NSPoint(x: rect.maxX - 3.2, y: rect.maxY - 4.0))
                check.stroke()
            } else if folder {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: rect.minX + 1, y: rect.minY + 3))
                path.line(to: NSPoint(x: rect.minX + 1, y: rect.maxY - 3))
                path.curve(to: NSPoint(x: rect.minX + 5, y: rect.maxY - 1), controlPoint1: NSPoint(x: rect.minX + 1, y: rect.maxY - 1), controlPoint2: NSPoint(x: rect.minX + 3, y: rect.maxY - 1))
                path.line(to: NSPoint(x: rect.maxX - 2, y: rect.maxY - 1))
                path.curve(to: NSPoint(x: rect.maxX - 1, y: rect.maxY - 3), controlPoint1: NSPoint(x: rect.maxX - 1, y: rect.maxY - 1), controlPoint2: NSPoint(x: rect.maxX - 1, y: rect.maxY - 2))
                path.line(to: NSPoint(x: rect.maxX - 1, y: rect.minY + 3))
                path.curve(to: NSPoint(x: rect.maxX - 3, y: rect.minY + 1), controlPoint1: NSPoint(x: rect.maxX - 1, y: rect.minY + 1), controlPoint2: NSPoint(x: rect.maxX - 2, y: rect.minY + 1))
                path.line(to: NSPoint(x: rect.minX + 7, y: rect.minY + 1))
                path.line(to: NSPoint(x: rect.minX + 5, y: rect.minY + 3))
                path.close()
                path.fill()
            } else {
                let cloud = NSBezierPath()
                cloud.appendOval(in: NSRect(x: rect.minX + 1, y: rect.minY + 3, width: 8, height: 8))
                cloud.appendOval(in: NSRect(x: rect.minX + 5, y: rect.minY + 1, width: 9, height: 11))
                cloud.appendOval(in: NSRect(x: rect.minX + 8, y: rect.minY + 3, width: 7, height: 8))
                cloud.append(NSBezierPath(roundedRect: NSRect(x: rect.minX + 3, y: rect.minY + 2, width: 10, height: 6), xRadius: 3, yRadius: 3))
                cloud.fill()
            }
            return true
        }
    }

    // File Provider's NSFileProviderItemDecorating is the authoritative badge
    // source for CloudStorage volumes. Finder Sync's overlay is disabled to
    // prevent a second badge (or Finder's generic blue cloud arrow) from
    // being composited on top of the native cloud/check decoration.
    static let badgesEnabled = false
    // Keep the odrive-style Finder actions visible in addition to the native
    // File Provider actions. File Provider remains the authoritative source
    // for cloud/check decorations; this menu only dispatches user actions to
    // the host Nimbo app.
    static let extraMenuEnabled = true

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems, Self.extraMenuEnabled else { return nil }
        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        NSLog("NimboFinderSync menu: kind=%ld selected=%ld accepted=%ld", menuKind.rawValue, urls.count, urls.filter(Self.isNimboPath).count)
        guard !urls.isEmpty, urls.allSatisfy({ Self.isNimboPath($0) }) else { return nil }
        let menu = NSMenu(title: "Nimbo")
        // Match the cloud-file workflow: a placeholder offers Sync/Conservar,
        // while a materialized item offers Unsync/Liberar. For a mixed
        // selection, pinning is the safe aggregate action because it leaves
        // already-downloaded items untouched and materializes the rest.
        // Keep the compact cloud workflow familiar to odrive. The blue check
        // badge remains visible in Finder after a successful materialization.
        for (title, action) in [
            ("Sync", #selector(syncSelected)),
            ("Unsync", #selector(evictSelected)),
            ("Refresh", #selector(refreshSelected)),
            ("Share Link", #selector(createShareLink)),
            ("Share Storage", #selector(createShareLink)),
            ("Copy Share Link to Clipboard", #selector(copyDriveLink)),
            ("Open Web Preview", #selector(openDriveLink))
        ] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = Self.menuLinkImage()
        }
        return menu
    }

    /// Draws the same standalone cloud used by the Finder badge, without
    /// Finder's blue app-tile background.
    private static func menuCloudImage() -> NSImage { badge(kind: .localFile) }

    private static func menuLinkImage() -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(paletteColors: [.systemBlue])
        return NSImage(systemSymbolName: "cloud.fill", accessibilityDescription: "Nimbo")?.withSymbolConfiguration(configuration)
    }

    /// Chooses the aggregate action without touching Finder or the network.
    /// A mixed selection uses pinning because it is monotonic: already local
    /// items stay local and placeholders are materialized.
    static func primaryAction(materialized: [Bool]) -> NimboFinderContextAction {
        materialized.isEmpty || !materialized.allSatisfy({ $0 }) ? .pin : .evict
    }

    @objc private func syncSelected(_ sender: Any?) {
        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        openAction("sync", urls: urls)
    }

    @objc private func refreshSelected(_ sender: Any?) {
        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        openAction("refresh", urls: urls)
    }

    @objc private func pinSelected(_ sender: Any?) {
        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        openAction("pin", urls: urls)
    }

    @objc private func openDriveLink(_ sender: Any?) {
        openAction("preview", urls: FIFinderSyncController.default().selectedItemURLs() ?? [])
    }

    @objc private func copyDriveLink(_ sender: Any?) {
        openAction("copy-link", urls: FIFinderSyncController.default().selectedItemURLs() ?? [])
    }

    @objc private func revokeShareLink(_ sender: Any?) {
        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        openAction("revoke-share", urls: urls)
    }

    @objc private func createShareLink(_ sender: Any?) {
        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        openAction("share", urls: urls)
    }

    @objc private func evictSelected(_ sender: Any?) {
        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        openAction("unsync", urls: urls)
    }

    /// Send one action URL for the whole selection. Opening one URL per item
    /// races application activation and can make Finder deliver only the last
    /// path to the host app. URLComponents percent-encodes each path while
    /// retaining repeated `path` query items for the batch operation.
    private func openAction(_ host: String, urls: [URL]) {
        let paths = urls.filter(Self.isNimboPath).map { $0.standardizedFileURL.path }
        guard !paths.isEmpty else { return }
        var components = URLComponents()
        components.scheme = "nimbo"
        components.host = host
        components.queryItems = paths.map { URLQueryItem(name: "path", value: $0) }
        if let target = components.url { NSWorkspace.shared.open(target) }
    }

    /// The user's real home. Inside the sandbox, `homeDirectoryForCurrentUser`
    /// and `NSHomeDirectory()` return the extension container
    /// (`~/Library/Containers/<id>/Data`), which has no `Library/CloudStorage`;
    /// registering that path makes Finder never ask this extension for a menu.
    static var realHomeDirectory: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private static func isNimboPath(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let cloudStorageIndex = components.firstIndex(of: "CloudStorage"),
              cloudStorageIndex + 1 < components.endIndex else { return false }
        let account = String(components[cloudStorageIndex + 1])
        return isNimboAccount(account)
    }

    /// File Provider appends the provider display name with a middle dot to
    /// the visible mount (for example Nimbo-GoogleDrive·GoogleDrive). Keep
    /// accepting the canonical and multi-account forms so Finder menus and
    /// badges survive the system-generated suffix.
    private static func isNimboAccount(_ account: String) -> Bool {
        account == "Nimbo-GoogleDrive" ||
        account.hasPrefix("Nimbo-GoogleDrive-") ||
        account.hasPrefix("Nimbo-GoogleDrive·")
    }

    private static func isDataless(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return true }
        return (info.st_flags & UInt32(SF_DATALESS)) != 0
    }
}
