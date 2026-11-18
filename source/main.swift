import AppKit
import CoreSpotlight

private final class NimboSidebarStack: NSStackView {
    override var isFlipped: Bool { true }
}

final class NimboGridItem: NSCollectionViewItem {
    let icon = NSImageView()
    let nameLabel = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    var thumbnailTask: Task<Void, Never>?
    var thumbnailKey: String?
    override var isSelected: Bool {
        didSet {
            view.layer?.borderColor = (isSelected ? NSColor.systemBlue : NSColor.separatorColor).cgColor
            view.layer?.borderWidth = isSelected ? 2 : 1
            view.layer?.backgroundColor = isSelected ? NSColor.systemBlue.withAlphaComponent(0.16).cgColor : nil
        }
    }
    override func prepareForReuse() {
        super.prepareForReuse(); thumbnailTask?.cancel(); thumbnailTask = nil; thumbnailKey = nil
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 9
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.lineBreakMode = .byTruncatingMiddle
        for view in [icon, nameLabel, subtitle] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: root.topAnchor, constant: 12), icon.centerXAnchor.constraint(equalTo: root.centerXAnchor), icon.widthAnchor.constraint(equalToConstant: 42), icon.heightAnchor.constraint(equalToConstant: 42),
            nameLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8), nameLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8), nameLabel.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 7),
            subtitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8), subtitle.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8), subtitle.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3), subtitle.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -8)
        ])
        view = root
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}

private struct NimboPendingDownload: Codable, Equatable {
    let remote: String
    let item: CloudItem
    let due: Date
}

final class App: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {
    var window: NSWindow!
    let search = NSSearchField()
    let table = NSTableView()
    let grid = NSCollectionView()
    let viewMode = NSSegmentedControl(labels: ["Lista", "Iconos", "Galería"], trackingMode: .selectOne, target: nil, action: nil)
    let breadcrumb = NSTextField(labelWithString: "Nube")
    private var cloudBrowser = CloudBrowser()
    private let browserTitle = NSTextField(labelWithString: "Tus archivos")
    private let browserSubtitle = NSTextField(labelWithString: "Explorá Google Drive sin descargar su contenido")
    private let accountSidebar = NimboSidebarStack()
    private var sidebarAccounts: [String: NSButton] = [:]
    private var dashboardVisible = true
    private var dashboard: NSStackView?
    private var dashboardScroll: NSScrollView?
    private var accountHeaderActions: [NSView] = []
    private var oauthAdvanced: NSStackView?
    private var oauthAdvancedToggle: NSButton?
    private var browserSections: [NSView] = []
    private var homeButton: NSButton?
    private var sidebarFooterTitle = NSTextField(labelWithString: "")
    private var sidebarFooterDetail = NSTextField(labelWithString: "")
    private let sidebarFooterBar = NimboSegmentBar()
    private var sidebarDots: [String: NimboDot] = [:]
    private var sidebarBars: [String: NimboUsageBar] = [:]
    private var settingsWindow: NSWindow?
    private var statusSymbol = "cloud"
    private var lastLimitCheck: Date?
    private var pauseMenuItem: NSMenuItem?
    private var resumeMenuItem: NSMenuItem?
    private var limitRunning = false
    private let pageHost = NSView()
    private weak var mainColumn: NSView?
    private var toolButtonsByKey: [String: NSButton] = [:]
    private var localFootprints: [String: NimboLocalFootprint] = [:]
    private var accountConflicts: [String: [NativeConflict]] = [:]
    private var footprintLoading = Set<String>()
    private var lastConnected: [String: Bool] = [:]
    private var overviewRemote: String?
    private let accountUsageBar = NSProgressIndicator()
    private var overviews: [String: DriveAccountOverview] = [:]
    private var overviewErrors: [String: String] = [:]
    private var overviewLoading = false
    var overviewLoadedAt: Date?
    private var overviewTask: Task<Void, Never>?
    private var galleryPreview = NSImageView()
    private let galleryCaption = NSTextField(labelWithString: "Seleccioná un archivo para ver su miniatura")
    private var galleryCanvasHeight: NSLayoutConstraint!
    private var galleryStripHeight: NSLayoutConstraint!
    private var galleryBox: NSView?
    private var galleryTask: Task<Void,Never>?
    private var galleryKey: String?


    private let browserBack = NSButton(title: "", target: nil, action: nil)
    private let browserForward = NSButton(title: "", target: nil, action: nil)
    private let browserUp = NSButton(title: "", target: nil, action: nil)
    private let browserHome = NSButton(title: "Todas las cuentas", target: nil, action: nil)
    var tableScroll: NSScrollView!
    var gridScroll: NSScrollView!
    let status = NSTextField(labelWithString: "Conectá Google Drive para crear tu catálogo de la nube.")
    let summary = NSTextField(labelWithString: "Sin cuenta conectada")
    let detail = NSTextField(wrappingLabelWithString: "Buscá archivos sin descargarlos. Sólo se guarda un catálogo de nombres y rutas en tu Mac.")
    let cloud = NSPopUpButton()
    let filter = NSSegmentedControl(labels: ["Todo", "Archivos", "Carpetas"], trackingMode: .selectOne, target: nil, action: nil)
    let dateFilter = NSPopUpButton(frame: .zero, pullsDown: false)
    let sizeFilter = NSPopUpButton(frame: .zero, pullsDown: false)
    let refresh = NSButton(title: "Actualizar catálogo", target: nil, action: nil)
    let download = NSButton(title: "Descargar archivo", target: nil, action: nil)
    let web = NSButton(title: "Ver en Google Drive", target: nil, action: nil)
    let connect = NSButton(title: "Conectar Google Drive", target: nil, action: nil)
    let cancel = NSButton(title: "Cancelar", target: nil, action: nil)
    let finderDrive = NSButton(title: "Conectar en Finder", target: nil, action: nil)
    let finderDisconnect = NSButton(title: "Desconectar", target: nil, action: nil)
    let finderSettings = NSButton(title: "Ajustes de Finder", target: nil, action: nil)
    let finderStatus = NSTextField(labelWithString: "Google Drive en Finder")
    let finderBridge = FinderController()
    var syncController: SyncController?
    var nativeController: NativeController?
    var accountNativeControllers: [String: NativeController] = [:]
    var sharedNativeControllers: [String: NativeController] = [:]
    var trashControllers: [String: TrashController] = [:]
    var sharedDriveControllers: [String: SharedDriveController] = [:]
    var activityController: ActivityController?
    var transferController: TransferController?
    var sendController: SendController?
    private var openingWeb = false
    private var finderWebTask: Task<Void, Never>?
    private var finderWebGeneration = UUID()
    let syncFolder = NSButton(title:"Sincronizar carpeta",target:nil,action:nil)
    let writeAccess = NSButton(checkboxWithTitle:"Permitir sincronización: crear, modificar y borrar archivos en Drive",target:nil,action:nil)
    var statusItem: NSStatusItem?
    var connectionStateItem: NSMenuItem?
    var reconnectMenuItem: NSMenuItem?
    var accountsAnchorItem: NSMenuItem?
    var accountMenuItems: [NSMenuItem] = []
    private var pendingSendFiles: [URL]?
    private var launchReady = false
    private var pendingSpotlightRoute: (remote: String, id: String)?
    var terminationPending = false
    let spinner = NSProgressIndicator()
    var backend: CloudBackend!
    private var thumbnails: CloudThumbnails?
    var entries: [RemoteEntry] = []
    var visible: [RemoteEntry] = []
    var dates: [String: Date] = [:]
    var busy = false
    var generation = 0
    var oauth: Process?
    var oauthTimer: DispatchWorkItem?
    var support: URL!
    var config: URL!
    var setup: NSWindow?
    let clientID = NSTextField()
    let secret = NSSecureTextField()
    let accountName = NSTextField()
    let accountAlias = NSTextField()
    let providerPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    let providerHint = NSTextField(wrappingLabelWithString: "")
    var oauthButton: NSButton?
    private var connectionList: NSStackView?
    var downloaded: URL?
    private var pendingDownloads: [NimboPendingDownload] = []
    private var policyTimer: Timer?
    private var lastTrashPolicyRun: Date?
    private var bandwidthMenu: NSMenu?
    var refreshMarker: URL { support.appendingPathComponent("needs-refresh") }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        let fm = FileManager.default
        let test = ProcessInfo.processInfo.environment["NIMBO_TEST_ROOT"]
        support = test.map { URL(fileURLWithPath: $0) } ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Nimbo")
        do {
            try fm.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            config = try NimboSecureConfig.prepareApp(support: support)
            backend = CloudBackend(configURL: config, binaryURL: Bundle.main.resourceURL!.appendingPathComponent("rclone"), cacheDirectory: support.appendingPathComponent("Catalogs"))
            TransferCenter.shared.configure(support: support)
            thumbnails = CloudThumbnails(configuration: config, support: support)
        } catch { NSApp.terminate(nil); return }
        // Login and manual launches share one menu-bar application. Build the
        // dashboard only when requested, after the controllers are ready.
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        LaunchAtLogin.refreshExecutablePathIfEnabled()
        loadAccounts()
        do {
            let offline = test == nil ? fm.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("Nimbo sin conexión") : support.appendingPathComponent("Offline")
            let engine = try SyncEngine(root:support.appendingPathComponent("Sync"),offlineRoot:offline,config:config,binary:backend.binaryURL,testing:test != nil,activityFile:support.appendingPathComponent("Activity.json"))
            syncController = SyncController(engine:engine)
            syncController?.bandwidthDidChange = { [weak self] in
                guard let self else { return }
                self.refreshBandwidthChecks()
                for controller in Array(self.accountNativeControllers.values) + Array(self.sharedNativeControllers.values) {
                    Task { @MainActor in controller.refreshTransferLimits() }
                }
            }
            syncController?.needsAuthorization = { [weak self] in self?.showConnect(); self?.writeAccess.state = .on }
        } catch { showError("No se pudo cargar la sincronización: " + error.localizedDescription) }
        nativeController = NativeController(config:config, client:NativeClient(name: displayName(for: "GoogleDrive")))
        if let nativeController { accountNativeControllers["GoogleDrive"] = nativeController }
        activityController = ActivityController(file: support.appendingPathComponent("Activity.json"))
        activityController?.transfersView = { [weak self] in
            let remotes = self?.configuredRemotes() ?? []
            if self?.transferController == nil { self?.transferController = TransferController() }
            return self?.transferController?.embeddedView(aliases: Dictionary(uniqueKeysWithValues: remotes.map { ($0, self?.displayName(for: $0) ?? $0) })) ?? NSView()
        }
        activityController?.openDownloads = { [weak self] in self?.showDownloads() }
        loadPendingDownloads()
        policyTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.runPolicies()
        }
        configureNativeSelection(nativeController, remote: "GoogleDrive")
        configureFinder()
        nativeController?.restore()
        startStatusWatcher()
        // Every additional Google account gets its own Finder location back.
        let extra = configuredRemotes().filter { $0 != "GoogleDrive" }
        NSLog("Nimbo extra accounts: %@ (config %@)", extra.joined(separator: ","), config?.path ?? "nil")
        for remote in extra { nativeController(for: remote)?.restore() }
        launchReady = true
        if let files = pendingSendFiles {
            pendingSendFiles = nil
            do { try presentSend(files: files) }
            catch { NSAlert(error: error).runModal() }
        }
        if let route = pendingSpotlightRoute {
            pendingSpotlightRoute = nil
            revealSpotlightItem(remote: route.remote, id: route.id)
        }

    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard launchReady, pendingSendFiles == nil else { return false }
        if sendController?.raiseIfVisible() != true { showMainWindow() }
        return false
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "nimbo" {
            let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if url.host == "open", let id = queryItems.first(where: { $0.name == "id" })?.value,
               let remote = queryItems.first(where: { $0.name == "remote" })?.value,
               let route = SpotlightReconciler.route("nimbo-v2:" + remote + ":" + id) {
                revealSpotlightItem(remote: route.remote, id: route.id)
                continue
            }
            let paths = queryItems.filter { $0.name == "path" }.compactMap { $0.value }
            let limit = queryItems.first(where: { $0.name == "limit" })?.value.flatMap { token -> Int64? in
                switch token.lowercased() {
                case "none": return nil
                case "100m": return 100 * 1024 * 1024
                case "500m": return 500 * 1024 * 1024
                case "1g": return 1024 * 1024 * 1024
                case "2g": return 2 * 1024 * 1024 * 1024
                default: return nil
                }
            }
            guard !paths.isEmpty else { continue }
            if url.host == "unsync" { handleFinderUnsync(paths) }
            if url.host == "sync" { handleFinderSync(paths) }
            if url.host == "pin" { handleFinderPin(paths, limit: limit) }
            if url.host == "refresh" { handleFinderRefresh(paths) }
            if url.host == "preview" || url.host == "copy-link" { handleFinderWebLinks(paths, copy: url.host == "copy-link") }
            if url.host == "share" || url.host == "revoke-share" {
                let ids = queryItems.filter { $0.name == "item" }.compactMap { $0.value }
                let domain = queryItems.first { $0.name == "domain" }?.value
                guard paths.count <= 100, (domain == nil && ids.isEmpty) || (domain != nil && ids.count == paths.count) else { continue }
                if url.host == "share" { handleFinderShare(paths, domain: domain, ids: ids) }
                else { handleFinderRevokeShare(paths, domain: domain, ids: ids) }
            }
        }
    }
    func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let route = SpotlightReconciler.route(identifier) else { return false }
        revealSpotlightItem(remote: route.remote, id: route.id)
        return true
    }
    private func revealSpotlightItem(remote: String, id: String) {
        guard launchReady else { pendingSpotlightRoute = (remote, id); return }
        showMainWindow()
        dashboardVisible = false
        updateDashboardVisibility()
        guard configuredRemotes().contains(remote) else {
            showError("La cuenta de este resultado ya no está conectada. Actualizá Spotlight desde una cuenta disponible.")
            return
        }
        guard let entry = entries.filter({ $0.remote == remote && $0.item.ID == id }).sorted(by: { $0.item.Path < $1.item.Path }).first else {
            cloudBrowser.visit(CloudBrowserView(location: CloudBrowserLocation(remote: remote)))
            restoreBrowserView()
            showError("El resultado no está en el catálogo actual de esta cuenta. Pulsá «Actualizar catálogo» para comprobarlo.")
            return
        }
        cloudBrowser.visit(CloudBrowserView(location: CloudBrowserLocation(remote: remote), query: entry.item.Name))
        restoreBrowserView()
        guard let row = visible.firstIndex(where: { $0.remote == remote && $0.item.ID == id }) else { return }
        if viewMode.selectedSegment != 0 {
            let path = IndexPath(item: row, section: 0)
            grid.selectionIndexPaths = [path]
            grid.scrollToItems(at: [path], scrollPosition: viewMode.selectedSegment == 2 ? .nearestHorizontalEdge : .nearestVerticalEdge)
        } else {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        updateGalleryPreview()
        updateActions()
    }

    private func handleFinderUnsync(_ paths: [String], attempt: Int = 0) {
        guard backend != nil, nativeController != nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.handleFinderUnsync(paths, attempt: attempt + 1) }
            return
        }
        let remotes = (try? backend.listRemotes()) ?? ["GoogleDrive"]
        for remote in remotes { _ = nativeController(for: remote) }
        var controllers: [NativeController] = []
        if let primary = nativeController { controllers.append(primary) }
        for controller in accountNativeControllers.values where !controllers.contains(where: { $0 === controller }) {
            controllers.append(controller)
        }
        Task { @MainActor in
            var released = 0, issues: [String] = []
            for path in paths {
                var done = false
                var lastError: String?
                for controller in controllers {
                    do {
                        if try await controller.evictPath(path) { done = true; released += 1; break }
                    } catch {
                        lastError = controller.readable(error)
                    }
                }
                if !done {
                    let name = URL(fileURLWithPath: path).lastPathComponent
                    issues.append(lastError.map { "\(name): \($0)" } ?? "\(name): no hay una copia local materializada")
                }
            }
            if !issues.isEmpty && released == 0 && attempt < 3 {
                // A freshly launched app may have its File Provider service
                // registered while the extension is still becoming ready.
                // Retry the same user action briefly instead of reporting a
                // false failure from the first URL activation.
                self.status.stringValue = "Esperando a que Finder habilite Nimbo…"
                self.status.textColor = .secondaryLabelColor
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.handleFinderUnsync(paths, attempt: attempt + 1)
                }
                return
            }
            if issues.isEmpty {
                status.stringValue = released == 1 ? "Nimbo liberó la copia local. El archivo sigue en Google Drive." : "Nimbo liberó \(released) copias locales. Los archivos siguen en Google Drive."
                status.textColor = .secondaryLabelColor
                self.activityController?.record(operation: "Desincronizar desde Finder", detail: "Se liberaron \(released) copias locales; Google Drive no se modificó.", success: true)
            } else {
                status.stringValue = "Nimbo liberó \(released) copias. No pudo completar: \(issues.prefix(3).joined(separator: " · "))"
                status.textColor = .systemOrange
                self.activityController?.record(operation: "Desincronizar desde Finder", detail: "Se liberaron \(released) copias. Pendientes: \(issues.prefix(3).joined(separator: " · "))", success: false)
                let alert = NSAlert()
                alert.messageText = "Nimbo no pudo liberar todas las copias"
                alert.informativeText = issues.prefix(8).joined(separator: "\n")
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Cerrar")
                alert.runModal()
            }
        }
    }
    private func handleFinderSync(_ paths: [String], attempt: Int = 0) {
        guard backend != nil, nativeController != nil else {
            guard attempt < 5 else {
                status.stringValue = "Nimbo todavía no está listo para sincronizar este archivo."
                status.textColor = .systemOrange
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.handleFinderSync(paths, attempt: attempt + 1) }
            return
        }
        let remotes = (try? backend.listRemotes()) ?? ["GoogleDrive"]
        for remote in remotes { _ = nativeController(for: remote) }
        var controllers: [NativeController] = []
        if let primary = nativeController { controllers.append(primary) }
        for controller in accountNativeControllers.values where !controllers.contains(where: { $0 === controller }) {
            controllers.append(controller)
        }
        Task { @MainActor in
            var synced = 0, issues: [String] = []
            for path in paths {
                var done = false
                var lastError: String?
                for controller in controllers {
                    do {
                        if try await controller.syncPath(path) { done = true; synced += 1; break }
                    } catch { lastError = controller.readable(error) }
                }
                if !done {
                    let name = URL(fileURLWithPath: path).lastPathComponent
                    issues.append(lastError.map { "\(name): \($0)" } ?? "\(name): no se pudo descargar")
                }
            }
            if !issues.isEmpty && synced == 0 && attempt < 3 {
                status.stringValue = "Esperando a que Finder habilite Nimbo…"
                status.textColor = .secondaryLabelColor
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.handleFinderSync(paths, attempt: attempt + 1) }
                return
            }
            if issues.isEmpty {
                status.stringValue = synced == 1 ? "Nimbo sincronizó el archivo. Podés liberarlo después para recuperar espacio." : "Nimbo sincronizó \(synced) archivos. Podés liberarlos después para recuperar espacio."
                status.textColor = .secondaryLabelColor
                self.activityController?.record(operation: "Sincronizar desde Finder", detail: "Se descargaron \(synced) copias sin fijarlas sin conexión.", success: true)
            } else {
                status.stringValue = "Nimbo sincronizó \(synced) archivos. No pudo completar: " + issues.prefix(3).joined(separator: " · ")
                status.textColor = .systemOrange
                self.activityController?.record(operation: "Sincronizar desde Finder", detail: "Se descargaron \(synced) copias. Pendientes: " + issues.prefix(3).joined(separator: " · "), success: false)
            }
        }
    }

    /// Refresh metadata for the selected Nimbo items without downloading
    /// their bodies. File Provider receives a change signal and the host
    /// revalidates each configured Google account; this is intentionally
    /// separate from `sync`, which materializes content.
    private func handleFinderRefresh(_ paths: [String]) {
        guard backend != nil, nativeController != nil else { return }
        let remotes = (try? backend.listRemotes()) ?? ["GoogleDrive"]
        for remote in remotes { _ = nativeController(for: remote) }
        var controllers: [NativeController] = []
        if let primary = nativeController { controllers.append(primary) }
        for controller in accountNativeControllers.values where !controllers.contains(where: { $0 === controller }) {
            controllers.append(controller)
        }
        for controller in controllers {
            controller.client.signalChanges()
            controller.revalidate()
        }
        status.stringValue = paths.count == 1 ? "Metadatos actualizados. El archivo no se descargó." : "Metadatos actualizados para \(paths.count) elementos. No se descargaron archivos."
        status.textColor = .secondaryLabelColor
        activityController?.record(operation: "Refresh desde Finder", detail: "Se solicitó actualización de metadatos para \(paths.count) elementos.", success: true)
    }

    private func handleFinderPin(_ paths: [String], limit: Int64? = nil, attempt: Int = 0) {
        guard backend != nil, nativeController != nil else {
            guard attempt < 5 else {
                status.stringValue = "Nimbo todavía no está listo para conservar archivos sin conexión."
                status.textColor = .systemOrange
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.handleFinderPin(paths, limit: limit, attempt: attempt + 1) }
            return
        }
        let remotes = (try? backend.listRemotes()) ?? ["GoogleDrive"]
        for remote in remotes { _ = nativeController(for: remote) }
        var controllers: [NativeController] = []
        if let primary = nativeController { controllers.append(primary) }
        for controller in accountNativeControllers.values where !controllers.contains(where: { $0 === controller }) {
            controllers.append(controller)
        }
        Task { @MainActor in
            var pinned = 0, issues: [String] = []
            for path in paths {
                var done = false
                var lastError: String?
                for controller in controllers {
                    do {
                        if try await controller.pinPath(path, limit: limit) { done = true; pinned += 1; break }
                    } catch {
                        lastError = controller.readable(error)
                    }
                }
                if !done {
                    let name = URL(fileURLWithPath: path).lastPathComponent
                    issues.append(lastError.map { "\(name): \($0)" } ?? "\(name): no se pudo marcar sin conexión")
                }
            }
            if !issues.isEmpty && pinned == 0 && attempt < 3 {
                self.status.stringValue = "Esperando a que Finder habilite Nimbo…"
                self.status.textColor = .secondaryLabelColor
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.handleFinderPin(paths, limit: limit, attempt: attempt + 1)
                }
                return
            }
            if issues.isEmpty {
                status.stringValue = pinned == 1 ? "Nimbo conservará el archivo sin conexión." : "Nimbo conservará " + String(pinned) + " archivos sin conexión."
                status.textColor = .secondaryLabelColor
                self.activityController?.record(operation: "Conservar desde Finder", detail: "Se marcaron \(pinned) elementos para uso sin conexión.", success: true)
            } else {
                status.stringValue = "Nimbo conservó " + String(pinned) + " archivos. No pudo completar: " + issues.prefix(3).joined(separator: " · ")
                status.textColor = .systemOrange
                self.activityController?.record(operation: "Conservar desde Finder", detail: "Se marcaron \(pinned) elementos. Pendientes: " + issues.prefix(3).joined(separator: " · "), success: false)
            }
        }
    }
    private func handleFinderWebLinks(_ paths: [String], copy: Bool) {
        finderWebTask?.cancel()
        let generation = UUID(); finderWebGeneration = generation
        finderWebTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if finderWebGeneration == generation { finderWebTask = nil } }
            do {
                let resolver = FinderWebLinks(identify: { url in
                    let value = try await NativeClient().identifierForUserVisibleFile(url)
                    return FinderWebLinks.Identity(id: value.id, domain: value.domain)
                }, resolve: { identity in
                    try await NativeClient(identifier: identity.domain).browserLink(identity.id)
                })
                let links = try await resolver.links(paths: paths, home: FileManager.default.homeDirectoryForCurrentUser)
                try Task.checkCancellation()
                if copy {
                    let board = NSPasteboard.general
                    board.clearContents(); board.setString(links.map(\.absoluteString).joined(separator: "\n"), forType: .string)
                } else {
                    for link in links { guard NSWorkspace.shared.open(link) else { throw DriveFailure.unavailable } }
                }
                status.stringValue = copy ? "\(links.count) enlace(s) copiado(s). Los permisos de Drive no cambiaron." : "Vista previa abierta. La sesión del navegador es independiente de Nimbo."
                status.textColor = .secondaryLabelColor
            } catch is CancellationError { }
            catch {
                guard finderWebGeneration == generation else { return }
                let alert = NSAlert(); alert.messageText = "No se pudo obtener el enlace de Finder"
                alert.informativeText = error.localizedDescription + (copy ? " El portapapeles no se modificó." : "")
                alert.addButton(withTitle: "Cerrar"); alert.runModal()
            }
        }
    }
    private func handleFinderShare(_ paths: [String], domain: String? = nil, ids: [String] = []) {
        guard backend != nil, nativeController != nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.handleFinderShare(paths, domain: domain, ids: ids) }
            return
        }
        let alert=NSAlert()
        alert.messageText = paths.count == 1 ? "Crear enlace compartido" : "Crear enlaces compartidos"
        let subject = paths.count == 1 ? "este archivo" : "estos archivos"
        alert.informativeText = "Cualquier persona con el enlace podrá acceder a " + subject + ". Si no hay acceso público, se creará un permiso de lectura. Si ya permite comentar o editar, ese permiso se conserva. Las carpetas comparten también su contenido. Podés revisar o revocar el acceso desde Google Drive."
        alert.addButton(withTitle:"Crear y copiar enlace")
        alert.addButton(withTitle:"Cancelar")
        alert.informativeText += "\n\n" + paths.prefix(3).map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: "\n") + (paths.count > 3 ? "\n… y \(paths.count - 3) más" : "")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let remotes = (try? backend.listRemotes()) ?? ["GoogleDrive"]
        for remote in remotes { _ = nativeController(for: remote) }
        var controllers: [NativeController] = []
        if let primary = nativeController { controllers.append(primary) }
        for controller in Array(accountNativeControllers.values) + Array(sharedNativeControllers.values) where !controllers.contains(where: { $0 === controller }) { controllers.append(controller) }
        Task { @MainActor in
            var links:[String]=[], issues:[String]=[]
            for (index, path) in paths.enumerated() {
                var done=false, lastError:String?
                for controller in controllers {
                    do {
                        if let link=try await controller.shareLinkPath(path, expectedDomain: domain, expectedID: ids.isEmpty ? nil : ids[index]) { links.append(link); done=true; break }
                    } catch { lastError=controller.readable(error) }
                }
                if !done { issues.append(URL(fileURLWithPath:path).lastPathComponent + ": " + (lastError ?? "no se encontró el elemento en Google Drive")) }
            }
            if !links.isEmpty {
                let text=links.joined(separator:"\n")
                let pasteboard=NSPasteboard.general; pasteboard.clearContents(); pasteboard.setString(text,forType:.string)
                if let first=URL(string:links[0]) { NSWorkspace.shared.open(first) }
            }
            if issues.isEmpty {
                status.stringValue = links.count == 1 ? "Enlace compartido creado y copiado al portapapeles." : String(links.count) + " enlaces compartidos creados y copiados al portapapeles."
                status.textColor = .secondaryLabelColor
            } else {
                status.stringValue = "Se crearon " + String(links.count) + " enlaces. No se pudo completar: " + issues.prefix(3).joined(separator:" · ")
                status.textColor = .systemOrange
            }
        }
    }
    private func handleFinderRevokeShare(_ paths: [String], domain: String? = nil, ids: [String] = []) {
        guard backend != nil, nativeController != nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.handleFinderRevokeShare(paths, domain: domain, ids: ids) }
            return
        }
        let alert=NSAlert()
        alert.messageText = paths.count == 1 ? "Revocar enlace compartido" : "Revocar enlaces compartidos"
        let subject = paths.count == 1 ? "este archivo" : "estos archivos"
        alert.informativeText = "Se quitarán los permisos públicos directos de " + subject + ". Los permisos de usuarios, grupos y organizaciones se conservan. Si el acceso público viene de una carpeta, deberás cambiarlo allí; Nimbo no cambiará la carpeta de origen."
        alert.addButton(withTitle:"Revocar enlace")
        alert.addButton(withTitle:"Cancelar")
        alert.informativeText += "\n\n" + paths.prefix(3).map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: "\n") + (paths.count > 3 ? "\n… y \(paths.count - 3) más" : "")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let remotes = (try? backend.listRemotes()) ?? ["GoogleDrive"]
        for remote in remotes { _ = nativeController(for: remote) }
        var controllers: [NativeController] = []
        if let primary = nativeController { controllers.append(primary) }
        for controller in Array(accountNativeControllers.values) + Array(sharedNativeControllers.values) where !controllers.contains(where: { $0 === controller }) { controllers.append(controller) }
        Task { @MainActor in
            var revoked=0, issues:[String]=[]
            for (index, path) in paths.enumerated() {
                var done=false, lastError:String?
                for controller in controllers {
                    do {
                        if let count=try await controller.revokeSharePath(path, expectedDomain: domain, expectedID: ids.isEmpty ? nil : ids[index]) { revoked += count; done=true; break }
                    } catch {
                        if let partial = error as? DrivePublicRevocationFailure { revoked += partial.removed }
                        lastError=controller.readable(error)
                    }
                }
                if !done { issues.append(URL(fileURLWithPath:path).lastPathComponent + ": " + (lastError ?? "no se encontró el elemento en Google Drive")) }
            }
            if issues.isEmpty {
                status.stringValue = revoked == 0 ? "No había un enlace público para revocar." : "Se quitaron " + String(revoked) + " permisos públicos directos. Los demás accesos se conservan."
                status.textColor = .secondaryLabelColor
            } else {
                status.stringValue = "Se revocaron " + String(revoked) + " enlaces. No se pudo completar: " + issues.prefix(3).joined(separator:" · ")
                status.textColor = .systemOrange
            }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        let disconnect = { self.finderBridge.stop { [weak self] success in
            DispatchQueue.main.async {
                self?.terminationPending = false
                if !success { self?.syncController?.resumeAfterCancelledQuit(); self?.showMainWindow() }
                sender.reply(toApplicationShouldTerminate:success)
            }
        } }
        if let syncController { syncController.shutdown(disconnect) } else { disconnect() }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        finderWebTask?.cancel()
        sendController?.stop()
        backend?.cancelAll(); oauth?.terminate(); oauthTimer?.cancel()
        if let config, let support { try? NimboSecureConfig.resealApp(runtime: config, support: support) }
        LaunchAtLogin.unregisterForExit()
    }

    func label(_ text: String, size: CGFloat = 13, bold: Bool = false) -> NSTextField {
        let x = NSTextField(labelWithString: text)
        x.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        return x
    }
    func stack(_ views: [NSView], vertical: Bool = false, spacing: CGFloat = 12) -> NSStackView {
        let s = NSStackView(views: views); s.orientation = vertical ? .vertical : .horizontal
        // Vertical dashboard stacks should stretch cards and tables to the
        // available window width; horizontal rows keep their native controls.
        s.alignment = vertical ? .width : .centerY; s.spacing = spacing
        return s
    }
    func bind(_ b: NSButton, _ action: Selector) { b.target = self; b.action = action; b.bezelStyle = .rounded }
    /// A restrained native card used for the dashboard sections. It keeps the
    /// visual hierarchy from the design reference while retaining AppKit
    /// controls, keyboard navigation and the real actions behind each section.
    func card(_ content: NSView, padding: CGFloat = 16) -> NSView {
        NimboGlassCard(content, padding: padding)
    }
    func buildWindow(testing: Bool) {
        guard window == nil else { return }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800), styleMask: [.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView], backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.title = "Nimbo · Tu nube, a mano"
        window.minSize = NSSize(width: 1020, height: 640); window.center()
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(srgbRed: 0.07, green: 0.10, blue: 0.23, alpha: 1)
        window.contentView = NimboGradientView()
        let menu = NSMenu(); let appMenu = NSMenu(); let item = NSMenuItem(); menu.addItem(item); item.submenu = appMenu
        appMenu.addItem(withTitle: "Acerca de Nimbo", action: #selector(about), keyEquivalent: "") .target = self
        appMenu.addItem(.separator()); appMenu.addItem(withTitle: "Salir de Nimbo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileItem = NSMenuItem(); fileItem.title = "Archivo"; menu.addItem(fileItem)
        let fileMenu = NSMenu(title: "Archivo"); fileItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "Cerrar ventana", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let editItem = NSMenuItem(); editItem.title = "Edición"; menu.addItem(editItem)
        let edit = NSMenu(title: "Edición"); editItem.submenu = edit
        for (title, sel, key) in [("Copiar", "copy:", "c"), ("Pegar", "paste:", "v"), ("Seleccionar todo", "selectAll:", "a")] { edit.addItem(withTitle: title, action: Selector(sel), keyEquivalent: key) }
        edit.addItem(withTitle: "Buscar", action: #selector(focusSearch), keyEquivalent: "f").target = self
        NSApp.mainMenu = menu

        // Native, account-first browser inspired by Nimbus. Browsing remains
        // metadata-only and closing this window leaves the menu-bar app alive.
        browserTitle.font = .systemFont(ofSize: 26, weight: .bold)
        browserSubtitle.font = .systemFont(ofSize: 12)
        browserSubtitle.textColor = .secondaryLabelColor
        browserSubtitle.lineBreakMode = .byTruncatingTail
        let headings = stack([browserTitle, browserSubtitle], vertical: true, spacing: 5)
        headings.alignment = .leading
        bind(connect, #selector(showConnect))
        bind(finderDrive, #selector(openBrowserFinder))
        finderDrive.title = "Abrir en Finder"
        finderDrive.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        finderDrive.imagePosition = .imageLeading
        let nativeButton = NSButton(title: "Bajo demanda", target: self, action: #selector(showNative))
        nativeButton.bezelStyle = .rounded
        nativeButton.image = NSImage(systemSymbolName: "cloud", accessibilityDescription: nil)
        nativeButton.imagePosition = .imageLeading
        accountHeaderActions = [finderDrive, nativeButton]
        let head = stack([NimboWindowStyle.driveTile(size: 46), headings, NSView(), finderDrive, nativeButton], spacing: 12)
        let hero = NimboGradientView(); hero.bright = true; hero.wantsLayer = true
        hero.layer?.cornerRadius = 16; hero.layer?.masksToBounds = true
        accountUsageBar.style = .bar
        accountUsageBar.isIndeterminate = false
        accountUsageBar.minValue = 0
        accountUsageBar.maxValue = 1
        accountUsageBar.controlSize = .small
        accountUsageBar.isHidden = true
        accountUsageBar.setAccessibilityLabel("Espacio utilizado en la cuenta")
        let heroContent = stack([head, accountUsageBar], vertical: true, spacing: 7)
        heroContent.alignment = .leading
        hero.addSubview(heroContent)
        heroContent.translatesAutoresizingMaskIntoConstraints = false
        head.widthAnchor.constraint(equalTo: heroContent.widthAnchor).isActive = true
        accountUsageBar.widthAnchor.constraint(equalTo: heroContent.widthAnchor).isActive = true
        NSLayoutConstraint.activate([heroContent.leadingAnchor.constraint(equalTo: hero.leadingAnchor, constant: 18), heroContent.trailingAnchor.constraint(equalTo: hero.trailingAnchor, constant: -18), heroContent.topAnchor.constraint(equalTo: hero.topAnchor, constant: 16), heroContent.bottomAnchor.constraint(equalTo: hero.bottomAnchor, constant: -16)])
        search.placeholderString = "Buscar por nombre o ruta en la nube…"; search.delegate = self
        search.controlSize = .large; search.font = .systemFont(ofSize: 14)
        search.sendsSearchStringImmediately = true
        search.heightAnchor.constraint(equalToConstant: 34).isActive = true
        bind(refresh, #selector(refreshCatalog)); bind(cancel, #selector(cancelWork)); cancel.isHidden = true
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        let tools = stack([search, refresh, spinner, cancel])
        cloud.target = self; cloud.action = #selector(changeBrowserAccount)
        cloud.widthAnchor.constraint(equalToConstant: 220).isActive = true
        filter.selectedSegment = 0; filter.target = self; filter.action = #selector(applyFilter)
        dateFilter.addItems(withTitles: ["Cualquier fecha", "Últimos 7 días", "Últimos 30 días", "Último año"])
        for (item, tag) in zip(dateFilter.itemArray, [0, 7, 30, 365]) { item.tag = tag }
        dateFilter.selectItem(withTag: 0); dateFilter.target = self; dateFilter.action = #selector(applyFilter)
        sizeFilter.addItems(withTitles: ["Cualquier tamaño", "Menos de 10 MB", "10–100 MB", "Más de 100 MB"])
        for (item, tag) in zip(sizeFilter.itemArray, [0, 1, 2, 3]) { item.tag = tag }
        sizeFilter.selectItem(withTag: 0); sizeFilter.target = self; sizeFilter.action = #selector(applyFilter)
        summary.textColor = .secondaryLabelColor
        let options = stack([filter, dateFilter, sizeFilter, NSView(), summary], spacing: 8)
        table.delegate = self; table.dataSource = self; table.rowHeight = 36; table.usesAlternatingRowBackgroundColors = true; table.allowsMultipleSelection = true
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.style = .fullWidth; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (id,title,width) in [("name","Nombre",310.0),("path","Ubicación",240.0),("kind","Tipo",90.0),("size","Tamaño",90.0)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); c.title = title; c.width = width; c.minWidth = 70; c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true); table.addTableColumn(c)
        }
        table.target = self; table.doubleAction = #selector(openBrowserSelection)
        tableScroll = NSScrollView(); tableScroll.documentView = table; tableScroll.hasVerticalScroller = true; tableScroll.borderType = .noBorder; tableScroll.drawsBackground = false
        tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        let gridLayout = NSCollectionViewFlowLayout(); gridLayout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12); gridLayout.minimumInteritemSpacing = 10; gridLayout.minimumLineSpacing = 10; grid.collectionViewLayout = gridLayout
        grid.isSelectable = true; grid.allowsMultipleSelection = true
        grid.register(NimboGridItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("NimboGridItem"))
        grid.dataSource = self; grid.delegate = self
        grid.backgroundColors = [.clear]
        let gridDoubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleGridDoubleClick(_:)))
        gridDoubleClick.numberOfClicksRequired = 2
        gridDoubleClick.delaysPrimaryMouseButtonEvents = true
        grid.addGestureRecognizer(gridDoubleClick)
        gridScroll = NSScrollView(); gridScroll.documentView = grid; gridScroll.hasVerticalScroller = true; gridScroll.borderType = .noBorder; gridScroll.drawsBackground = false; gridScroll.isHidden = true
        galleryPreview.imageScaling = .scaleProportionallyUpOrDown
        galleryPreview.setContentHuggingPriority(.defaultLow, for: .vertical)
        galleryPreview.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        galleryPreview.setAccessibilityLabel("Vista previa")
        galleryPreview.wantsLayer = true
        galleryPreview.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.17).cgColor
        galleryPreview.layer?.cornerRadius = 10
        galleryPreview.layer?.masksToBounds = true
        galleryCaption.alignment = .center; galleryCaption.textColor = .secondaryLabelColor
        galleryCaption.lineBreakMode = .byTruncatingMiddle
        let previewContent = stack([galleryPreview, galleryCaption], vertical: true, spacing: 6)
        for child in previewContent.arrangedSubviews { child.widthAnchor.constraint(equalTo: previewContent.widthAnchor).isActive = true }
        galleryBox = previewContent; previewContent.isHidden = true
        let browser = stack([previewContent, tableScroll, gridScroll], vertical: true, spacing: 10)
        for child in browser.arrangedSubviews { child.widthAnchor.constraint(equalTo: browser.widthAnchor).isActive = true }
        gridScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        galleryStripHeight = gridScroll.heightAnchor.constraint(equalToConstant: 120)
        browser.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        viewMode.selectedSegment = 0; viewMode.target = self; viewMode.action = #selector(changeViewMode(_:)); viewMode.segmentStyle = .texturedRounded
        breadcrumb.textColor = .secondaryLabelColor; breadcrumb.font = .systemFont(ofSize: 12)
        breadcrumb.lineBreakMode = .byTruncatingMiddle
        for (button, symbol, title, action) in [
            (browserBack, "chevron.left", "Atrás", #selector(browserGoBack)),
            (browserForward, "chevron.right", "Adelante", #selector(browserGoForward)),
            (browserUp, "arrow.up", "Carpeta superior", #selector(browserGoUp))
        ] {
            bind(button, action)
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            button.toolTip = title
            button.setAccessibilityLabel(title)
            button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        }
        bind(browserHome, #selector(browserGoHome))
        detail.textColor = .secondaryLabelColor; detail.font = .systemFont(ofSize: 13)
        detail.maximumNumberOfLines = 2
        bind(download, #selector(downloadSelected)); bind(web, #selector(openWeb))
        bind(syncFolder,#selector(syncSelected))
        let actions = stack([download, web, syncFolder, NSView()], spacing: 8)
        for (button, symbol) in [(download, "arrow.down.circle"), (web, "arrow.up.right.square"), (syncFolder, "arrow.triangle.2.circlepath")] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
        }
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        let navigationRow = stack([browserBack, browserForward, browserUp, breadcrumb, NSView(), viewMode], spacing: 7)
        breadcrumb.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let resultsContent = stack([navigationRow, browser, detail, actions], vertical: true, spacing: 10)
        let resultsCard = card(resultsContent, padding: 12)
        let home = NimboSidebarStack(); home.orientation = .vertical; home.alignment = .width; home.spacing = 16
        dashboard = home
        let homeScroll = NSScrollView(); homeScroll.drawsBackground = false; homeScroll.hasVerticalScroller = true; homeScroll.scrollerStyle = .overlay; homeScroll.autohidesScrollers = true
        homeScroll.documentView = home; home.translatesAutoresizingMaskIntoConstraints = false
        home.widthAnchor.constraint(equalTo:homeScroll.contentView.widthAnchor, constant: -18).isActive = true
        home.topAnchor.constraint(equalTo:homeScroll.contentView.topAnchor).isActive = true
        dashboardScroll = homeScroll
        browserSections = [hero, tools, options, resultsCard]
        let main = stack([hero, homeScroll, tools, options, resultsCard, status], vertical: true, spacing: 16)
        main.translatesAutoresizingMaskIntoConstraints = false

        let sidebar = NimboGradientView(); sidebar.sidebar = true; sidebar.wantsLayer = true
        sidebar.layer?.masksToBounds = true
        sidebar.layer?.cornerRadius = NimboMetrics.panel
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        let brand = NSImageView(image: NimboUI.driveTileImage(size: 30))
        brand.widthAnchor.constraint(equalToConstant: 30).isActive = true
        brand.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let brandName = NimboUI.title("Nimbo", size: 17)
        let branding = stack([brand, brandName, NSView()], spacing: 10)
        accountSidebar.orientation = .vertical; accountSidebar.alignment = .width; accountSidebar.spacing = 2
        var toolButtons: [NSView] = [
            keyed("sync", sidebarTool("Sincronizaciones", symbol: "arrow.triangle.2.circlepath", color: NimboPalette.rgb(0x10A877), action: #selector(showSync))),
            keyed("activity", sidebarTool("Actividad", symbol: "clock.fill", color: NimboPalette.rgb(0x6D4DFF), action: #selector(showActivity))),
            keyed("trash", sidebarTool("Papelera", symbol: "trash.fill", color: NimboPalette.rgb(0x5B6478), action: #selector(showTrash)))
        ]
        if UserDefaults.standard.bool(forKey: "NimboShowSend") {
            toolButtons.append(sidebarTool("Enviar a Drive", symbol: "paperplane.fill", color: NimboPalette.rgb(0x0891B2), action: #selector(showSend)))
        }
        if UserDefaults.standard.bool(forKey: "NimboShowSharedDrives") {
            toolButtons.append(keyed("shared", sidebarTool("Unidades compartidas", symbol: "person.2.fill", color: NimboPalette.rgb(0xD97706), action: #selector(showSharedDrives))))
        }
        let sections = stack(toolButtons, vertical: true, spacing: 2)
        let homeNavigation = sidebarTool("Inicio", symbol: "house.fill", color: NimboPalette.driveDeep, action: #selector(showDashboard))
        homeButton = homeNavigation
        let addAccount = sidebarButton("Agregar cuenta…", symbol: "plus", action: #selector(addAccountSimple))
        addAccount.toolTip = "Conectá otra cuenta de Google. Aparece en Finder con su propia carpeta y no se mezcla con las demás."
        addAccount.contentTintColor = NimboPalette.textSecondary
        addAccount.title = "   Agregar cuenta…"
        // Free space across accounts, like a fuel gauge at the foot of the sidebar.
        sidebarFooterTitle.font = .systemFont(ofSize: 13, weight: .semibold); sidebarFooterTitle.textColor = .white
        sidebarFooterDetail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); sidebarFooterDetail.textColor = NimboPalette.textSecondary
        let footerBody = NimboUI.vstack([NimboUI.hstack([sidebarFooterTitle, NSView(), sidebarFooterDetail]), sidebarFooterBar], spacing: 8)
        let footer = NimboGlassCard(footerBody, padding: 12, tone: .raised, radius: 12)
        footer.toolTip = "Espacio libre sumando todas tus cuentas, según lo que informa Google."
        let settingsButton = keyed("settings", sidebarTool("Configuración", symbol: "gearshape.fill", color: NimboPalette.rgb(0x5B6478), action: #selector(showSettings)))
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .vertical)
        let sidebarContent = stack([branding, homeNavigation, sidebarSection("Cuentas"), accountSidebar, addAccount,
            sidebarSection("Herramientas"), sections, spacer, settingsButton, footer
        ], vertical: true, spacing: 6)
        sidebarContent.setCustomSpacing(20, after: branding)
        sidebarContent.setCustomSpacing(14, after: homeNavigation)
        sidebarContent.setCustomSpacing(14, after: addAccount)
        sidebarContent.setCustomSpacing(10, after: settingsButton)
        sidebarContent.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarContent)
        let divider = NSView(); divider.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        // The window height is independent of the selected thumbnail's natural size.
        galleryCanvasHeight = galleryPreview.heightAnchor.constraint(equalTo: content.heightAnchor, constant: -550)
        galleryCanvasHeight.priority = .init(700)
        content.addSubview(sidebar); content.addSubview(divider); content.addSubview(main)
        mainColumn = main
        pageHost.translatesAutoresizingMaskIntoConstraints = false; pageHost.isHidden = true
        content.addSubview(pageHost)
        NSLayoutConstraint.activate([pageHost.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 4), pageHost.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),
                                     pageHost.topAnchor.constraint(equalTo: content.topAnchor, constant: 18), pageHost.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        NimboEmbedding.host = { [weak self] view, key in self?.hostPage(view, key: key) ?? false }
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10), sidebar.topAnchor.constraint(equalTo: content.topAnchor, constant: 38), sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10), sidebar.widthAnchor.constraint(equalToConstant: 244),
            sidebarContent.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12), sidebarContent.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12), sidebarContent.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 16), sidebarContent.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -12),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor), divider.widthAnchor.constraint(equalToConstant: 1), divider.topAnchor.constraint(equalTo: content.topAnchor), divider.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            main.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 28), main.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28), main.topAnchor.constraint(equalTo: content.topAnchor, constant: 40), main.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
        for view in [head, tools, options, resultsCard, browser, detail, actions, status] { view.setContentHuggingPriority(.defaultLow, for: .horizontal) }
        headings.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        browser.setContentHuggingPriority(.defaultLow, for: .vertical)
        // NSStackView does not force arranged views to fill its cross-axis.
        // Pin widths explicitly so every row shares the same leading edge.
        for column in [main, resultsContent, sidebarContent, sections] {
            for child in column.arrangedSubviews { child.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        }
        rebuildAccountSidebar()
        renderDashboard()
        updateDashboardVisibility()
        refreshOverview()
        updateActions()
    }
    private func sidebarSection(_ title: String) -> NSTextField {
        // Sentence case, quiet: a label, not a shout.
        let field = NimboUI.muted(title, size: 11)
        field.font = .systemFont(ofSize: 11, weight: .medium)
        return field
    }
    private func sidebarButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false; button.alignment = .left
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading; button.imageHugsTitle = true
        button.contentTintColor = .white
        button.wantsLayer = true; button.layer?.cornerRadius = NimboMetrics.row; button.layer?.cornerCurve = .continuous
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        button.setAccessibilityLabel(title)
        button.toolTip = title
        return button
    }
    /// Sidebar row with a coloured tile, like System Settings.
    private func sidebarTool(_ title: String, symbol: String, color: NSColor, action: Selector) -> NSButton {
        let button = sidebarButton("  " + title, symbol: symbol, action: action)
        // 8 pt inside the row so the selection never clips the tile.
        let tile = NimboUI.toolTile(symbol, color: color, size: 22)
        button.image = NSImage(size: NSSize(width: 30, height: 22), flipped: false) { _ in tile.draw(in: NSRect(x: 8, y: 0, width: 22, height: 22)); return true }
        button.setAccessibilityLabel(title)
        return button
    }
    private func keyed(_ key: String, _ button: NSButton) -> NSButton {
        toolButtonsByKey[key] = button
        button.toolTip = [
            "sync": "Sincronizaciones: vinculá una carpeta de tu Mac con una de Drive para que estén siempre iguales, aun sin internet. También se programan copias de seguridad.",
            "activity": "Actividad: lo que hizo Nimbo, lo que se está subiendo o bajando ahora y tu carpeta de descargas.",
            "trash": "Papelera: recuperá archivos que borraste en Google Drive.",
            "shared": "Unidades compartidas: carpetas de equipo de Google Workspace que no son de tu Drive personal.",
            "settings": "Configuración: liberar espacio, velocidad, avisos y opciones avanzadas."
        ][key] ?? button.toolTip
        return button
    }
    /// Shows a tool screen inside the main window, next to the sidebar.
    private func hostPage(_ view: NSView, key: String) -> Bool {
        if window == nil { showMainWindow() }
        guard window != nil else { return false }
        pageHost.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        pageHost.addSubview(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: pageHost.leadingAnchor), view.trailingAnchor.constraint(equalTo: pageHost.trailingAnchor),
                                     view.topAnchor.constraint(equalTo: pageHost.topAnchor), view.bottomAnchor.constraint(equalTo: pageHost.bottomAnchor)])
        pageHost.isHidden = false; mainColumn?.isHidden = true
        dashboardVisible = false
        markSidebarSelection(homeButton, selected: false)
        for (_, button) in sidebarAccounts { markSidebarSelection(button, selected: false) }
        for (name, button) in toolButtonsByKey { markSidebarSelection(button, selected: name == key) }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        return true
    }
    /// Back to Inicio or the browser.
    private func closePage() {
        guard !pageHost.isHidden else { return }
        pageHost.isHidden = true; mainColumn?.isHidden = false
        NimboEmbedding.dismissed()
        for (_, button) in toolButtonsByKey { markSidebarSelection(button, selected: false) }
    }
    private func markSidebarSelection(_ button: NSButton?, selected: Bool) {
        button?.layer?.backgroundColor = (selected ? NSColor.white.withAlphaComponent(0.12) : NSColor.clear).cgColor
        button?.layer?.borderWidth = selected ? 1 : 0
        button?.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
    }
    /// One wording for an account's state, used by the sidebar, cards and menu.
    private func accountStatus(_ remote: String) -> (status: NimboStatus, text: String, needsSignIn: Bool) {
        let active = TransferCenter.shared.recent(limit: 50).filter { $0.remote == remote && ($0.state == .running || $0.state == .queued) }
        if !active.isEmpty {
            let uploads = active.filter { $0.operation != "Descarga" }.count
            return (.busy, uploads > 0 ? "Subiendo \(active.count) " + (active.count == 1 ? "elemento" : "elementos") : "Descargando \(active.count) " + (active.count == 1 ? "elemento" : "elementos"), false)
        }
        if let error = overviewErrors[remote] {
            let lower = error.lowercased()
            if lower.contains("autoriz") || lower.contains("invalid_grant") || lower.contains("token") || lower.contains("iniciar sesión") {
                return (.warning, "Necesita iniciar sesión", true)
            }
            return (.error, "Sin conexión con Google", false)
        }
        if overviews[remote] != nil { return (.ok, remoteAllowsWrites(remote) ? "Lista" : "Lista · solo lectura", false) }
        return (.muted, overviewLoading ? "Comprobando…" : "Sin comprobar", false)
    }
    private func updateSidebarFooter() {
        let remotes = cloud.itemArray.compactMap { $0.representedObject as? String }
        let quotas = remotes.compactMap { overviews[$0]?.storageQuota }.filter { $0.limitBytes != nil }
        let limit = quotas.reduce(Int64(0)) { $0 + ($1.limitBytes ?? 0) }
        let used = quotas.reduce(Int64(0)) { $0 + ($1.usageBytes ?? 0) }
        guard limit > 0 else {
            sidebarFooterTitle.stringValue = remotes.isEmpty ? "Sin cuentas" : "Espacio sin datos"
            sidebarFooterDetail.stringValue = ""; sidebarFooterBar.segments = []; return
        }
        sidebarFooterTitle.stringValue = NimboUI.bytes(max(0, limit - used)) + " libres"
        sidebarFooterDetail.stringValue = "\(Int((Double(used) / Double(limit) * 100).rounded())) % usado"
        sidebarFooterBar.segments = quotas.map { Double($0.usageBytes ?? 0) / Double(limit) }
    }
    private func rebuildAccountSidebar() {
        guard window != nil else { return }
        for view in accountSidebar.arrangedSubviews { accountSidebar.removeArrangedSubview(view); view.removeFromSuperview() }
        sidebarAccounts.removeAll()
        sidebarDots.removeAll(); sidebarBars.removeAll()
        let remotesInSidebar = cloud.itemArray.compactMap { $0.representedObject as? String }
        if remotesInSidebar.count > 1 {
            let all = sidebarButton("  Todas las cuentas", symbol: "square.grid.2x2", action: #selector(selectSidebarAccount(_:)))
            all.toolTip = "Buscá y explorá los archivos de todas tus cuentas juntas, sin descargarlos."
            let allTile = NimboUI.toolTile("square.grid.2x2.fill", color: NimboPalette.rgb(0x334155), size: 22)
            all.image = NSImage(size: NSSize(width: 30, height: 22), flipped: false) { _ in allTile.draw(in: NSRect(x: 8, y: 0, width: 22, height: 22)); return true }
            all.identifier = NSUserInterfaceItemIdentifier("")
            sidebarAccounts[""] = all; accountSidebar.addArrangedSubview(all)
        }
        for remote in remotesInSidebar {
            let button = sidebarButton("  " + displayName(for: remote), symbol: "cloud.fill", action: #selector(selectSidebarAccount(_:)))
            // Tile drawn 10 pt higher so it lines up with the lifted title.
            let tile = NimboUI.accountTileImage(remote, size: 22)
            button.image = NSImage(size: NSSize(width: 30, height: 32), flipped: false) { _ in tile.draw(in: NSRect(x: 8, y: 10, width: 22, height: 22)); return true }
            button.identifier = NSUserInterfaceItemIdentifier(remote)
            button.toolTip = displayName(for: remote) + " · " + (dates[remote] == nil ? "catálogo por actualizar" : "\(entries.lazy.filter { $0.remote == remote }.count) elementos en catálogo")
            sidebarAccounts[remote] = button
            let dot = NimboDot(accountStatus(remote).status, size: 8)
            dot.toolTip = accountStatus(remote).text
            sidebarDots[remote] = dot
            dot.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(dot)
            dot.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -10).isActive = true
            // Usage bar inside the row, under the name, so the selection wraps it.
            let bar = NimboUsageBar(); bar.height = 3
            bar.fraction = overviews[remote]?.storageQuota?.fraction
            sidebarBars[remote] = bar
            bar.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(bar)
            button.imagePosition = .imageLeading
            NSLayoutConstraint.activate([bar.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 46), bar.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -26),
                                         bar.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -6), bar.heightAnchor.constraint(equalToConstant: 3)])
            for constraint in button.constraints where constraint.firstAttribute == .height && constraint.secondItem == nil { constraint.constant = 44 }
            // Lift the title a little so it sits above the bar.
            button.alignment = .left
            let style = NSMutableParagraphStyle(); style.alignment = .left
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white, .baselineOffset: 5, .paragraphStyle: style])
            NSLayoutConstraint.deactivate(button.constraints.filter { ($0.firstItem as? NimboDot) != nil && $0.firstAttribute == .centerY })
            dot.centerYAnchor.constraint(equalTo: button.centerYAnchor, constant: -5).isActive = true
            accountSidebar.addArrangedSubview(button)
        }
        for child in accountSidebar.arrangedSubviews { child.widthAnchor.constraint(equalTo: accountSidebar.widthAnchor).isActive = true }
        updateBrowserHeading()
    }
    private func updateBrowserHeading() {
        let location = cloudBrowser.current.location
        let account = location.remote.map { displayName(for: $0) } ?? "Todas las cuentas"
        browserTitle.stringValue = dashboardVisible ? "Tu nube, a mano" : location.path.isEmpty ? account : (location.path as NSString).lastPathComponent
        browserTitle.lineBreakMode = .byTruncatingMiddle
        browserSubtitle.stringValue = dashboardVisible ? "Google Drive · Resumen de tus cuentas" : location.remote == nil ? "Tus cuentas de Google Drive, en un mismo lugar" : "Google Drive · Exploración sin descargar archivos"
        let quota = location.remote.flatMap { overviews[$0]?.storageQuota }
        accountUsageBar.isHidden = dashboardVisible || quota?.fraction == nil
        accountUsageBar.doubleValue = quota?.fraction ?? 0
        if !dashboardVisible, let quota, let used = quota.usageBytes {
            let usage = ByteCountFormatter.string(fromByteCount: used, countStyle: .decimal) + " usados"
            let capacity = quota.freeBytes.map { usage + " · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .decimal) + " libres" } ?? usage
            browserSubtitle.stringValue = account + " · " + capacity
            accountUsageBar.toolTip = capacity
        }
        browserSubtitle.toolTip = location.path.isEmpty ? account : account + "/" + location.path
        finderDrive.title = "Abrir en Finder"
        finderDrive.isEnabled = cloud.numberOfItems > 1
        for (key, button) in sidebarAccounts {
            let selected = !dashboardVisible && key == (location.remote ?? "")
            button.state = selected ? .on : .off
            button.contentTintColor = .white
            markSidebarSelection(button, selected: selected)
        }
    }
    @objc private func selectSidebarAccount(_ sender: NSButton) {
        closePage()
        dashboardVisible = false; updateDashboardVisibility()
        let remote = sender.identifier?.rawValue ?? ""
        cloudBrowser.selectAccount(remote.isEmpty ? nil : remote)
        restoreBrowserView()
    }
    @objc private func openBrowserFinder() {
        let remote = selectedRemote() ?? selection()?.remote ?? "GoogleDrive"
        nativeController(for: remote)?.openRoot()
    }
    @objc private func showDashboard() {
        closePage()
        dashboardVisible = true
        if window == nil { showMainWindow() }
        updateDashboardVisibility(); renderDashboard(); refreshOverview()
    }
    private func updateDashboardVisibility() {
        guard window != nil else { return }
        dashboardScroll?.isHidden = !dashboardVisible
        accountHeaderActions.forEach { $0.isHidden = dashboardVisible }
        browserSections.forEach { $0.isHidden = dashboardVisible }
        markSidebarSelection(homeButton, selected: dashboardVisible)
        updateBrowserHeading()
    }
    @objc private func reloadOverview() { overviewLoadedAt = nil; refreshOverview() }
    private func refreshOverview() {
        guard !overviewLoading, overviewLoadedAt.map({ Date().timeIntervalSince($0) > 300 }) ?? true else { return }
        let remotes = cloud.itemArray.compactMap { $0.representedObject as? String }
        guard !remotes.isEmpty else { return }
        overviewLoading = true; renderDashboard()
        let configuration = config!
        overviewTask = Task { [weak self] in
            var values: [String: DriveAccountOverview] = [:]
            var failures: [String: String] = [:]
            for remote in remotes {
                guard !Task.isCancelled else { return }
                do { values[remote] = try await DriveAPI(configuration: configuration, remoteName: remote).accountOverview() }
                catch { failures[remote] = error.localizedDescription }
            }
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.overviews = values; self.overviewErrors = failures
                self.overviewLoading = false; self.overviewLoadedAt = Date()
                self.renderDashboard()
                self.updateBrowserHeading()
            }
        }
    }
    @objc private func selectOverviewAccount(_ sender: NSPopUpButton) {
        overviewRemote = sender.selectedItem?.representedObject as? String
        renderDashboard()
    }
    private func quotaDescription(_ quota: DriveStorageQuota?) -> String {
        guard let quota, let used = quota.usageBytes else { return "Espacio no disponible" }
        let usedText = ByteCountFormatter.string(fromByteCount: used, countStyle: .decimal)
        if let limit = quota.limitBytes { return usedText + " de " + ByteCountFormatter.string(fromByteCount: limit, countStyle: .decimal) }
        return usedText + " usados · sin límite informado"
    }
    private func renderDashboard() {
        guard let dashboard, let support else { return }
        for view in dashboard.arrangedSubviews { dashboard.removeArrangedSubview(view); view.removeFromSuperview() }
        let remotes = cloud.itemArray.compactMap { $0.representedObject as? String }
        updateSidebarFooter()
        for remote in remotes {
            sidebarDots[remote]?.status = accountStatus(remote).status
            sidebarDots[remote]?.toolTip = accountStatus(remote).text
            sidebarBars[remote]?.fraction = overviews[remote]?.storageQuota?.fraction
        }
        dashboard.spacing = 24

        // 1. Page heading: what this screen is, one secondary action.
        let refreshButton = NimboUI.button(overviewLoading ? "Consultando…" : "Actualizar", target: self, action: #selector(reloadOverview))
        refreshButton.isEnabled = !overviewLoading
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil); refreshButton.imagePosition = .imageLeading
        let heading = NimboUI.hstack([NimboUI.title("Inicio", size: 28), NSView(), refreshButton], spacing: 12)
        dashboard.addArrangedSubview(heading)

        // 2. Accounts that need the user: one clear notice and one button each.
        for remote in remotes where accountStatus(remote).needsSignIn {
            let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Aviso")!)
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 26, weight: .regular)
            icon.contentTintColor = NimboPalette.warning
            let title = NimboUI.text("«\(displayName(for: remote))» necesita que vuelvas a iniciar sesión", size: 14, weight: .semibold)
            let body = NimboUI.wrapping("Google cerró la sesión. Lo que ya está en este Mac sigue a salvo; los cambios nuevos esperan hasta que vuelvas a entrar.")
            let text = NimboUI.vstack([title, body], spacing: 4)
            let action = NimboUI.button("Iniciar sesión en Google", primary: true, target: self, action: #selector(reconnectFromDashboard(_:)))
            action.identifier = NSUserInterfaceItemIdentifier(remote)
            action.controlSize = .large
            let row = NimboUI.hstack([icon, text, action], spacing: 16)
            text.setContentHuggingPriority(.defaultLow, for: .horizontal)
            dashboard.addArrangedSubview(NimboGlassCard(row, padding: 16, tone: .warning, radius: 16))
        }

        // 3. The one big number: free space across accounts.
        let quotas = remotes.compactMap { r in overviews[r]?.storageQuota.map { (r, $0) } }.filter { $0.1.limitBytes != nil }
        let limit = quotas.reduce(Int64(0)) { $0 + ($1.1.limitBytes ?? 0) }
        let used = quotas.reduce(Int64(0)) { $0 + ($1.1.usageBytes ?? 0) }
        if remotes.isEmpty {
            let add = NimboUI.button("Agregar una cuenta de Google", primary: true, target: self, action: #selector(addAccountSimple))
            add.controlSize = .large
            let body = NimboUI.vstack([NimboUI.title("Conectá Google Drive", size: 22),
                                       NimboUI.wrapping("Tus archivos aparecen en Finder sin ocupar espacio. Descargás lo que usás y liberás lo que no."),
                                       NimboUI.hstack([add, NSView()])], spacing: 12)
            dashboard.addArrangedSubview(NimboGlassCard(body, padding: 24, tone: .raised, radius: 20))
        } else {
            let big = NimboUI.title(limit > 0 ? NimboUI.bytes(max(0, limit - used)) + " libres" : (overviewLoading ? "Consultando espacio…" : "Espacio sin datos"), size: 44)
            let sub = NimboUI.secondary(limit > 0 ? "de \(NimboUI.bytes(limit)) en \(quotas.count) " + (quotas.count == 1 ? "cuenta" : "cuentas") + " · \(Int((Double(used) / Double(max(limit, 1)) * 100).rounded())) % usado"
                                        : "Google todavía no informó el espacio de tus cuentas", size: 14)
            var heroViews: [NSView] = [big, sub]
            if limit > 0 {
                let bar = NimboSegmentBar(); bar.segments = quotas.map { Double($0.1.usageBytes ?? 0) / Double(limit) }
                bar.heightAnchor.constraint(equalToConstant: 10).isActive = true
                heroViews.append(bar)
                let legend = NimboUI.hstack(quotas.map { item in
                    NimboUI.hstack([NimboUI.muted(displayName(for: item.0), size: 12), NimboUI.text(NimboUI.bytes(item.1.usageBytes ?? 0), size: 12, weight: .medium, color: NimboPalette.textSecondary)], spacing: 6)
                } + [NSView()], spacing: 20)
                heroViews.append(legend)
            }
            let hero = NimboUI.vstack(heroViews, spacing: 10)
            dashboard.addArrangedSubview(hero)
            let disclaimer = NimboUI.muted("Espacio informado por Google; puede incluir Gmail, Fotos o el almacenamiento compartido de tu organización", size: 11)
            dashboard.addArrangedSubview(disclaimer)
            dashboard.setCustomSpacing(12, after: hero)

            // 4. One card per account.
            dashboard.addArrangedSubview(NimboUI.title("Tus cuentas", size: 17))
            let columns = min(3, max(1, remotes.count))
            for start in stride(from: 0, to: remotes.count, by: columns) {
                let row = NSStackView(); row.orientation = .horizontal; row.alignment = .top; row.spacing = 16; row.distribution = .fillEqually
                for remote in remotes[start..<min(start + columns, remotes.count)] { row.addArrangedSubview(accountCard(remote)) }
                for _ in row.arrangedSubviews.count..<columns { row.addArrangedSubview(NSView()) }
                dashboard.addArrangedSubview(row)
            }

            // 5. Folders kept offline: the things the user always wants at hand.
            let kept = remotes.flatMap { remote in (localFootprints[remote]?.keptOffline ?? []).map { (remote, $0.name, $0.url) } }
            let keptTitle = NimboUI.text("Siempre disponibles", size: 14, weight: .semibold)
            keptTitle.toolTip = "Carpetas que marcaste para tener siempre en este Mac, aun sin internet. Nimbo no las libera nunca."
            var keptRows: [NSView] = [keptTitle]
            if kept.isEmpty {
                keptRows.append(NimboUI.wrapping("Para tener una carpeta siempre a mano sin conexión, hacé clic derecho sobre ella en Finder y elegí «Conservar sin conexión con Nimbo»."))
            }
            for (remote, name, url) in kept.prefix(8) {
                let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: url.path)); icon.widthAnchor.constraint(equalToConstant: 20).isActive = true; icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
                let open = NimboUI.button("Abrir", target: self, action: #selector(openKeptFolder(_:))); open.controlSize = .small
                open.identifier = NSUserInterfaceItemIdentifier(url.path)
                keptRows.append(NimboUI.hstack([icon, NimboUI.text(name, size: 13), NimboUI.muted(displayName(for: remote), size: 12), NSView(), NimboUI.chip("Sin conexión"), open], spacing: 10))
            }
            dashboard.addArrangedSubview(NimboGlassCard(NimboUI.vstack(keptRows, spacing: 10), padding: 18))
        }

        // 6. Recent activity (2/3) and things worth a look (1/3).
        let events = ActivityLog(file: support.appendingPathComponent("Activity.json")).events()
            .filter { !NimboPresentation.isRoutineActivity(operation: $0.operation, detail: $0.detail) }.prefix(5)
        var activityRows: [NSView] = [NimboUI.hstack([NimboUI.text("Actividad reciente", size: 14, weight: .semibold), NSView(),
                                                      NimboUI.button("Ver todo", target: self, action: #selector(showActivity))])]
        if events.isEmpty { activityRows.append(NimboUI.secondary("Todavía no hay operaciones")) }
        for event in events {
            let symbol = event.success ? "checkmark" : "exclamationmark.triangle"
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
            icon.contentTintColor = event.success ? NimboPalette.ok : NimboPalette.warning
            icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
            let line = NimboUI.text(event.operation + " · " + event.detail, size: 13, color: NSColor.white.withAlphaComponent(0.88))
            line.toolTip = event.detail
            line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let when = NimboUI.muted(NimboUI.relative(event.date), size: 12)
            when.setContentCompressionResistancePriority(.required, for: .horizontal)
            activityRows.append(NimboUI.hstack([icon, line, NSView(), when], spacing: 10))
        }
        let activityCard = NimboGlassCard(NimboUI.vstack(activityRows, spacing: 12), padding: 18)
        let reviewCard = NimboGlassCard(NimboUI.vstack(reviewItems(remotes), spacing: 12), padding: 18, tone: .raised)
        let bottom = NSStackView(views: [activityCard, reviewCard]); bottom.orientation = .horizontal; bottom.alignment = .top; bottom.spacing = 16; bottom.distribution = .fill
        reviewCard.setContentHuggingPriority(.required, for: .vertical); activityCard.setContentHuggingPriority(.required, for: .vertical)
        activityCard.setContentHuggingPriority(.init(1), for: .horizontal)
        reviewCard.widthAnchor.constraint(equalTo: activityCard.widthAnchor, multiplier: 0.5).isActive = true
        dashboard.addArrangedSubview(bottom)

        for child in dashboard.arrangedSubviews { child.widthAnchor.constraint(equalTo: dashboard.widthAnchor).isActive = true }
        loadFootprintsIfNeeded(remotes)
    }
    private func accountCard(_ remote: String) -> NSView {
        let state = accountStatus(remote)
        let tile = NSImageView(image: NimboUI.accountTileImage(remote, size: 40))
        tile.widthAnchor.constraint(equalToConstant: 40).isActive = true; tile.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let name = NimboUI.text(displayName(for: remote), size: 15, weight: .semibold)
        let titles = NimboUI.vstack([name, NimboUI.status(state.text, state.status)], spacing: 4, fill: false)
        var header: [NSView] = [tile, titles, NSView()]
        if nativeController(for: remote)?.connected == true {
            let chip = NimboUI.chip("En Finder")
            chip.toolTip = "Esta cuenta ya aparece en la barra lateral de Finder. Sus archivos se ven ahí sin ocupar espacio hasta que los abrís."
            header.append(chip)
        }
        let quota = overviews[remote]?.storageQuota
        let bar = NimboUsageBar(); bar.fraction = quota?.fraction
        bar.toolTip = "Espacio usado en Google. Puede incluir Gmail, Fotos o el almacenamiento compartido de tu organización."
        let capacity = NimboUI.secondary(quotaDescription(quota), size: 12)
        capacity.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let hairline = NSBox(); hairline.boxType = .custom; hairline.borderWidth = 0; hairline.fillColor = NSColor.white.withAlphaComponent(0.08)
        hairline.heightAnchor.constraint(equalToConstant: 1).isActive = true
        var local: [NSView] = []
        if let footprint = localFootprints[remote] {
            local.append(NimboUI.secondary(footprint.downloadedBytes == 0 ? "Nada descargado en este Mac" : "En este Mac: " + NimboUI.bytes(footprint.downloadedBytes), size: 12))
            if footprint.unusedCount > 0 {
                let release = NimboUI.button("Liberar " + NimboUI.bytes(footprint.unusedBytes) + " sin usar en 30 días", target: self, action: #selector(releaseUnusedFromDashboard(_:)))
                release.identifier = NSUserInterfaceItemIdentifier(remote); release.controlSize = .small
                release.toolTip = "Vuelve a dejar sólo en la nube los archivos descargados que no abriste en 30 días. Siguen visibles en Finder y se bajan de nuevo al abrirlos. No toca lo que conservás sin conexión."
                local.append(NimboUI.hstack([release, NSView()]))
            } else {
                local.append(NimboUI.muted("Nada sin usar para liberar", size: 12))
            }
        } else {
            local.append(NimboUI.muted(footprintLoading.contains(remote) ? "Midiendo lo descargado…" : state.needsSignIn ? "Iniciá sesión para ver lo descargado" : "Mostrala en Finder para ver lo descargado", size: 12))
        }
        let finder = NimboUI.button("Abrir en Finder", primary: true, target: self, action: #selector(openDashboardFinder(_:)))
        finder.identifier = NSUserInterfaceItemIdentifier(remote)
        finder.toolTip = "Abre la carpeta de esta cuenta en Finder. Ahí sincronizás o liberás con clic derecho."
        let browse = NimboUI.button("Explorar", target: self, action: #selector(selectSidebarAccount(_:)))
        browse.identifier = NSUserInterfaceItemIdentifier(remote)
        let iconButton = NimboUI.button("Ícono…", target: self, action: #selector(chooseAccountIcon(_:)))
        iconButton.identifier = NSUserInterfaceItemIdentifier(remote)
        iconButton.toolTip = "Elegí el símbolo y el color de esta cuenta: se usan en Finder, en la barra lateral y en Nimbo."
        browse.toolTip = "Buscá y mirá los archivos de esta cuenta dentro de Nimbo, sin descargarlos."
        let body = NimboUI.vstack([NimboUI.hstack(header, spacing: 12), bar, capacity, hairline] + local + [NimboUI.hstack([finder, browse, NSView(), iconButton])], spacing: 10)
        body.setCustomSpacing(16, after: body.arrangedSubviews[0])
        body.setCustomSpacing(14, after: hairline)
        return NimboGlassCard(body, padding: 18, tone: state.needsSignIn ? .normal : .raised)
    }
    /// Real suggestions only: each one comes from the account state, no filler.
    private func reviewItems(_ remotes: [String]) -> [NSView] {
        var rows: [NSView] = [NimboUI.text("Para revisar", size: 14, weight: .semibold)]
        func item(_ title: String, _ detail: String, _ button: String, _ action: Selector, _ remote: String) {
            let b = NimboUI.button(button, target: self, action: action); b.identifier = NSUserInterfaceItemIdentifier(remote)
            let block = NimboUI.vstack([NimboUI.text(title, size: 13, weight: .medium), NimboUI.wrapping(detail, size: 12), NimboUI.hstack([b, NSView()])], spacing: 6)
            block.setCustomSpacing(10, after: block.arrangedSubviews[1])
            rows.append(block)
        }
        for remote in remotes where overviews[remote] != nil && !remoteAllowsWrites(remote) {
            item("«\(displayName(for: remote))» es de solo lectura", "Ves sus archivos en Finder, pero lo que cambies ahí no se sube a Drive.", "Permitir cambios", #selector(allowWritesFromDashboard(_:)), remote)
        }
        for remote in remotes where nativeController(for: remote)?.connected != true && !accountStatus(remote).needsSignIn {
            item("«\(displayName(for: remote))» no está en Finder", "Mostrala en Finder para navegar sus archivos sin descargarlos.", "Mostrar en Finder", #selector(showInFinderFromDashboard(_:)), remote)
        }
        let conflictCount = accountConflicts.values.reduce(0) { $0 + $1.count }
        if conflictCount > 0 {
            item(conflictCount == 1 ? "1 archivo con dos versiones" : "\(conflictCount) archivos con dos versiones",
                 "Se editaron en el Mac y en Drive a la vez. Elegí cuál queda; nada se pierde.", "Resolver", #selector(showConflicts), "")
        }
        if rows.count == 1 { rows.append(NimboUI.status("Todo en orden", .ok)) }
        return rows
    }
    private func loadFootprintsIfNeeded(_ remotes: [String]) {
        for remote in remotes where localFootprints[remote] == nil && !footprintLoading.contains(remote) {
            guard let controller = nativeController(for: remote), controller.connected else { continue }
            footprintLoading.insert(remote)
            Task { [weak self] in
                let footprint = await controller.client.localFootprint()
                let conflicts = (try? await controller.client.conflicts()) ?? []
                await MainActor.run {
                    guard let self else { return }
                    let previous = self.accountConflicts[remote]?.count ?? 0
                    self.accountConflicts[remote] = conflicts
                    if conflicts.count > previous {
                        NimboNotifier.shared.post("conflicts-" + remote, title: "Hay archivos con dos versiones",
                                                  body: "«\(self.displayName(for: remote))»: \(conflicts.count) para revisar. Abrí Nimbo para elegir cuál queda.")
                    }
                    self.footprintLoading.remove(remote); self.localFootprints[remote] = footprint
                    if self.dashboardVisible { self.renderDashboard() }
                }
            }
        }
    }
    @objc func chooseAccountIcon(_ sender: NSButton) {
        guard let remote = sender.identifier?.rawValue else { return }
        let current = NimboFinderIcon.style(for: remote)
        let symbols = NSPopUpButton(frame: NSRect(x: 0, y: 34, width: 260, height: 26), pullsDown: false)
        for (name, symbol) in NimboFinderIcon.symbols {
            symbols.addItem(withTitle: name)
            symbols.lastItem?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            symbols.lastItem?.representedObject = symbol
            if symbol == current.symbol { symbols.select(symbols.lastItem) }
        }
        let colors = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        for (name, hex) in NimboFinderIcon.colors {
            colors.addItem(withTitle: name)
            colors.lastItem?.image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in NimboPalette.rgb(hex).setFill(); NSBezierPath(ovalIn: r).fill(); return true }
            colors.lastItem?.tag = Int(hex)
            if hex == current.color { colors.select(colors.lastItem) }
        }
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 60)); box.addSubview(symbols); box.addSubview(colors)
        let alert = NSAlert()
        alert.messageText = "Ícono de «\(displayName(for: remote))»"
        alert.informativeText = "Se usa en la carpeta de Finder, en la barra lateral y en Nimbo."
        alert.accessoryView = box
        alert.addButton(withTitle: "Guardar"); alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn, let symbol = symbols.selectedItem?.representedObject as? String,
              let hex = colors.selectedItem.map({ UInt32($0.tag) }) else { return }
        NimboFinderIcon.setStyle(symbol, hex, for: remote)
        if let controller = nativeController(for: remote) {
            Task { if let url = try? await controller.client.location() { await MainActor.run {
                NimboFinderIcon.apply(to: url, remote: remote, force: true)
                NimboFinderIcon.addToSidebar(url, name: self.displayName(for: remote), remote: remote, force: true)
            } } }
        }
        rebuildAccountSidebar(); renderDashboard(); updateBrowserHeading()
    }
    @objc func showConflicts() {
        let page = NimboGradientView(); page.transparent = true
        var rows: [NSView] = [NimboWindowStyle.header("Conflictos", subtitle: "Archivos que se editaron en el Mac y en Google Drive al mismo tiempo. Nimbo guardó las dos versiones; elegí cuál queda.")]
        let all = accountConflicts.flatMap { remote, list in list.map { (remote, $0) } }
        if all.isEmpty { rows.append(NimboUI.status("No hay conflictos para resolver", .ok)) }
        for (remote, conflict) in all.prefix(50) {
            let kind: String
            switch conflict.kind {
            case "content": kind = "Se editó en los dos lados"
            case "rename": kind = "Se renombró en los dos lados"
            case "move": kind = "Se movió en los dos lados"
            case "delete": kind = "Se borró en un lado y se editó en el otro"
            default: kind = "Cambio en los dos lados"
            }
            let title = NimboUI.text(conflict.name, size: 14, weight: .semibold)
            let detail = NimboUI.wrapping(kind + " · " + displayName(for: remote) + (conflict.detail.map { " · " + $0 } ?? ""), size: 12)
            var buttons: [NSView] = []
            if conflict.remoteID != nil {
                let mac = NimboUI.button("Usar la del Mac", primary: true, target: self, action: #selector(resolveConflictPressed(_:)))
                mac.identifier = NSUserInterfaceItemIdentifier("retryLocal|" + remote + "|" + conflict.id)
                mac.toolTip = "Tu versión del Mac reemplaza a la de Drive, en el mismo archivo. La copia separada queda como respaldo."
                buttons.append(mac)
            }
            let drive = NimboUI.button(conflict.remoteID != nil ? "Dejar la de Drive" : "Marcar como revisado", target: self, action: #selector(resolveConflictPressed(_:)))
            drive.identifier = NSUserInterfaceItemIdentifier("keepRemote|" + remote + "|" + conflict.id)
            drive.toolTip = "Drive queda como está. Tu versión del Mac sigue como un archivo aparte, así no perdés nada."
            buttons.append(drive)
            let finder = NimboUI.button("Ver en Finder", target: self, action: #selector(revealConflictPressed(_:)))
            finder.identifier = NSUserInterfaceItemIdentifier(remote + "|" + conflict.id)
            buttons.append(finder)
            rows.append(NimboGlassCard(NimboUI.vstack([title, detail, NimboUI.hstack(buttons + [NSView()])], spacing: 8), padding: 16))
        }
        let column = NimboUI.vstack(rows, spacing: 14)
        let document = NSView(); column.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(column)
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false; document.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: page.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: page.topAnchor), scroll.bottomAnchor.constraint(equalTo: page.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            column.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24), column.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            column.topAnchor.constraint(equalTo: document.topAnchor, constant: 22), column.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24)])
        _ = hostPage(page, key: "conflicts")
    }
    @objc private func resolveConflictPressed(_ sender: NSButton) {
        let parts = (sender.identifier?.rawValue ?? "").components(separatedBy: "|")
        guard parts.count == 3, let controller = nativeController(for: parts[1]) else { return }
        sender.isEnabled = false
        Task { [weak self] in
            var failure: String?
            do { try await controller.client.resolveConflict(parts[2], action: parts[0]); controller.client.signalChanges() }
            catch { failure = error.localizedDescription }
            let remaining = (try? await controller.client.conflicts()) ?? []
            await MainActor.run {
                guard let self else { return }
                self.accountConflicts[parts[1]] = remaining
                if let failure { self.showError("No se pudo resolver: " + failure) }
                self.activityController?.record(operation: "Conflicto", detail: parts[0] == "retryLocal" ? "Se usó la versión del Mac." : "Se dejó la versión de Drive.", success: failure == nil)
                self.showConflicts()
            }
        }
    }
    @objc private func revealConflictPressed(_ sender: NSButton) {
        let parts = (sender.identifier?.rawValue ?? "").components(separatedBy: "|")
        guard parts.count == 2, let controller = nativeController(for: parts[0]) else { return }
        Task { if let url = try? await controller.client.location(parts[1]) { await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) } } }
    }
    @objc private func reconnectFromDashboard(_ sender: NSButton) {
        guard let remote = sender.identifier?.rawValue else { return }
        reconnectRemote(remote, write: remoteAllowsWrites(remote))
    }
    @objc private func allowWritesFromDashboard(_ sender: NSButton) {
        guard let remote = sender.identifier?.rawValue else { return }
        let alert = NSAlert(); alert.messageText = "Permitir cambios en «\(displayName(for: remote))»"
        alert.informativeText = "Google te va a pedir permiso para que Nimbo suba a Drive lo que cambies en Finder. Podés volver a solo lectura cuando quieras."
        alert.addButton(withTitle: "Continuar en Google"); alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        reconnectRemote(remote, write: true)
    }
    @objc private func showInFinderFromDashboard(_ sender: NSButton) {
        guard let remote = sender.identifier?.rawValue, let controller = nativeController(for: remote) else { return }
        controller.onConnected = { [weak self, weak controller] in
            controller?.onConnected = nil
            self?.localFootprints[remote] = nil
            controller?.openRoot(); self?.renderDashboard()
        }
        controller.connect(reimport: false)
    }
    @objc private func openKeptFolder(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
    @objc private func releaseUnusedFromDashboard(_ sender: NSButton) {
        guard let remote = sender.identifier?.rawValue, let controller = nativeController(for: remote) else { return }
        sender.isEnabled = false; sender.title = "Liberando…"
        Task { [weak self] in
            let result = await controller.client.releaseUnused(days: 30)
            await MainActor.run {
                guard let self else { return }
                self.activityController?.record(operation: "Liberar espacio", detail: "\(self.displayName(for: remote)): \(result.released) archivos, \(NimboUI.bytes(result.bytes)) liberados.", success: true)
                self.localFootprints[remote] = nil
                self.renderDashboard()
            }
        }
    }
    /// Straight to Google for one account: no detour through account settings.
    func reconnectRemote(_ remote: String, write: Bool) {
        accountName.stringValue = remote
        accountAlias.stringValue = alias(for: remote)
        clientID.stringValue = ""; secret.stringValue = ""
        writeAccess.state = write ? .on : .off
        authorize()
    }
    @objc private func openDashboardFinder(_ sender: NSButton) {
        guard let remote = sender.identifier?.rawValue, !remote.isEmpty else { return }
        nativeController(for:remote)?.openRoot()
    }
    private func updateGalleryPreview() {
        galleryTask?.cancel(); galleryKey = nil
        guard viewMode.selectedSegment == 2, let entry = selection() else {
            galleryPreview.image = nil; galleryCaption.stringValue = "Seleccioná un archivo para ver su miniatura"; return
        }
        let kind = entry.item.IsDir ? "Carpeta" : entry.item.Size < 0 ? "Documento de Google" : ByteCountFormatter.string(fromByteCount: entry.item.Size, countStyle: .file)
        galleryCaption.stringValue = entry.item.Name + " · " + kind
        galleryPreview.image = NSWorkspace.shared.icon(forFileType: entry.item.IsDir ? "public.folder" : URL(fileURLWithPath:entry.item.Name).pathExtension)
        guard !entry.item.IsDir, let thumbnails else { return }
        let key = ThumbnailCache.key(entry); galleryKey = key
        galleryTask = Task { [weak self] in
            let data = await thumbnails.thumbnail(entry)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.galleryKey == key else { return }
                if let data, let image = NSImage(data:data) { self.galleryPreview.image = image }
                else { self.galleryCaption.stringValue = entry.item.Name + " · Sin miniatura disponible" }
            }
        }
    }
    @objc func about() {
        let a = NSAlert(); a.messageText = "Nimbo \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · Google Drive"
        a.informativeText = "Google Drive en Finder con archivos bajo demanda. Con permiso de sincronización, podés crear, editar, renombrar, mover y borrar archivos; los borrados se envían a la papelera de Drive. La Papelera de Google Drive permite restaurar un elemento remoto por vez. Unidades compartidas descubre las raíces de equipo y las abre en Google Drive web o en dominios separados de Finder. Las carpetas de Sincronizaciones admiten sincronización programada, backups unidireccionales con retención configurable y transferencias detalladas. Los conflictos de contenido conservan ambas versiones. Podés conservar y liberar archivos o carpetas. La liberación automática opcional admite plazos de 1, 7 y 30 días y respeta los archivos conservados sin conexión. Las carpetas de Sincronizaciones siguen disponibles como copias locales editables. El navegador de Nimbo permite buscar por cuenta, alias, ruta, fecha y tamaño sin descargar el contenido. Usa rclone 1.76.0 (MIT)."
        a.runModal()
    }
    @objc func openFinderSettings() {
        // Launch Settings directly. The deep-link URL is not registered on
        // every supported macOS release and can fall back to the wrong app.
        let settings = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        NSWorkspace.shared.openApplication(at: settings, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
    /// Finder Services fallback for Macs where the optional Finder Sync
    /// extension is still disabled by PlugInKit. The service receives only
    /// file URLs; the existing path guards and native controller perform the
    /// actual local File Provider operation.
    @objc @MainActor func composeCloudSend(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard pendingSendFiles == nil, sendController?.isRunning != true else {
            error.pointee = "Nimbo está ocupada. Volvé a elegir Enviar a Nimbo cuando termine." as NSString
            return
        }
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else {
            error.pointee = "Elegí uno o más archivos en Finder." as NSString
            return
        }
        guard launchReady else { pendingSendFiles = urls; return }
        do { try presentSend(files: urls) }
        catch let failure { error.pointee = failure.localizedDescription as NSString }
    }
    @objc func unsyncFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let paths = servicePaths(from: pasteboard), !paths.isEmpty else {
            error.pointee = "Seleccioná archivos dentro de Google Drive de Nimbo." as NSString
            return
        }
        handleFinderUnsync(paths)
    }
    @objc func syncFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let paths = servicePaths(from: pasteboard), !paths.isEmpty else {
            error.pointee = "Seleccioná archivos dentro de Google Drive de Nimbo." as NSString
            return
        }
        handleFinderSync(paths)
    }
    @objc func pinFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let paths = servicePaths(from: pasteboard), !paths.isEmpty else {
            error.pointee = "Seleccioná archivos dentro de Google Drive de Nimbo." as NSString
            return
        }
        handleFinderPin(paths, limit: nil)
    }
    private func servicePaths(from pasteboard: NSPasteboard) -> [String]? {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        let paths = objects?.map(\.standardizedFileURL.path).filter { path in
            let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage", isDirectory: true).path + "/"
            guard path.hasPrefix(root) else { return false }
            let account = String(path.dropFirst(root.count)).split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            return account == "Nimbo-GoogleDrive" || account.hasPrefix("Nimbo-GoogleDrive-") || account.hasPrefix("Nimbo-GoogleDrive·")
        }
        return paths
    }
    @objc func focusSearch() { showSearchWindow() }
    private func configureNativeSelection(_ controller: NativeController?, remote: String) {
        controller?.selection = { [weak self] in
            guard let item=self?.selection(), item.remote==remote, let id=item.item.ID, !id.isEmpty else{return nil}
            return (id:id,name:item.item.Name,isFolder:item.item.IsDir)
        }
        controller?.onAutoReport = { [weak self] report in
            // A disabled timer is a setting, not a repeated failed operation.
            guard !report.disabled, !report.busy else { return }
            let success = report.deferred == 0
            self?.activityController?.record(operation: "Auto Unsync", detail: report.message, success: success)
        }
    }
    private func nativeController(for remote: String) -> NativeController? {
        if let existing=accountNativeControllers[remote] { return existing }
        guard remote != "GoogleDrive" else { return nativeController }
        let safe=remote.replacingOccurrences(of:" ",with:"-")
        let client=NativeClient(identifier:"google-drive-account-"+safe,name: displayName(for: remote),remoteName:remote)
        let controller=NativeController(config:config,client:client)
        configureNativeSelection(controller,remote:remote)
        accountNativeControllers[remote]=controller
        return controller
    }
    @objc func showNative() {
        let remote=selection()?.remote ?? selectedRemote() ?? "GoogleDrive"
        nativeController(for: remote)?.show()
    }
    @objc func showUsageGuide() {
        if let url = URL(string: "https://docs.odrive.com/Features/sync/") { NSWorkspace.shared.open(url) }
    }
    @objc func showAnnouncements() {
        let alert = NSAlert(); alert.messageText = "Nimbo"
        alert.informativeText = "Nimbo mantiene Google Drive bajo demanda en Finder. Las novedades y los estados de sincronización aparecen en Actividad."
        alert.addButton(withTitle: "OK"); alert.runModal()
    }
    @objc func showDetailedStatus() { showActivity() }
    @objc func sendDiagnostics() { showActivity() }
    @objc func showAuthorizedUser() { showConnect() }
    @objc func syncToDriveFromMenu() { showSync() }
    @objc func backupToDriveFromMenu() { showSync() }
    @objc func setAutoDownloadPreset(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: "NimboAutoDownloadPreset")
        if sender.tag < 0 {
            pendingDownloads.removeAll(); savePendingDownloads()
            status.stringValue = "Descarga automática desactivada. Las descargas manuales siguen disponibles."
        } else if sender.tag == 0 {
            status.stringValue = "Descarga automática: inmediata para las descargas elegidas."
            runPolicies()
        } else {
            status.stringValue = "Descarga automática: las descargas elegidas se programarán después de \(sender.title.lowercased().replacingOccurrences(of: "después de ", with: ""))."
        }
        status.textColor = .secondaryLabelColor
    }
    @objc func setAutoUnsyncPreset(_ sender: NSMenuItem) {
        let days: Int? = sender.tag == 0 ? nil : sender.tag
        UserDefaults.standard.set(sender.tag, forKey: "NimboAutoUnsyncPreset")
        nativeController?.configureAutomaticUnsync(days: days)
        status.stringValue = days.map { "Liberación automática: después de \($0) días sin uso." } ?? "Liberación automática desactivada."
        status.textColor = .secondaryLabelColor
    }
    @objc func setBandwidthPreset(_ sender: NSMenuItem) {
        guard let syncController, let raw = sender.representedObject as? String, let direction = TransferDirection(rawValue: raw) else { return }
        do { try syncController.setBandwidthLimit(sender.tag, for: direction) }
        catch { showError(error.localizedDescription) }
    }
    @objc func setFinderSegments(_ sender: NSMenuItem) {
        guard let syncController else { return }
        do {
            try syncController.engine.setFinderSegmentSize(sender.tag)
            syncController.bandwidthDidChange?()
            sender.menu?.items.forEach { $0.state = $0.tag == sender.tag ? .on : .off }
        } catch { showError(error.localizedDescription) }
    }
    @objc func setLinkedSegments(_ sender: NSMenuItem) {
        guard let syncController else { return }
        do {
            try syncController.engine.setLinkedSegmentSize(sender.tag)
            sender.menu?.items.forEach { $0.state = $0.tag == sender.tag ? .on : .off }
        } catch { showError(error.localizedDescription) }
    }
    @objc func setBackupSegments(_ sender: NSMenuItem) {
        guard let syncController else { return }
        do {
            try syncController.engine.setBackupSegmentSize(sender.tag)
            sender.menu?.items.forEach { $0.state = $0.tag == sender.tag ? .on : .off }
        } catch { showError(error.localizedDescription) }
    }
    @objc func setSplitLargeFiles(_ sender: NSMenuItem) {
        sender.state = sender.state == .on ? .off : .on
        let enabled = sender.state == .on
        UserDefaults.standard.set(enabled, forKey: "NimboSplitLargeFiles")
        syncController?.setSplitLargeFiles(enabled)
        status.stringValue = sender.state == .on ? "Subida por bloques de 64 MiB activada." : "Subida por bloques de 64 MiB desactivada."
        status.textColor = .secondaryLabelColor
    }
    @objc func setAutoEmptyTrash(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: "NimboAutoEmptyTrashDays")
        status.stringValue = sender.tag == 0 ? "Vaciado automático de papelera desactivado." : "Vaciado automático de papelera: después de \(sender.tag) días."
        status.textColor = .secondaryLabelColor
        if sender.tag > 0 { runAutomaticTrashPolicy() }
    }
    @objc func showSync() { syncController?.show() }
    @MainActor private func panelAccount(_ title: String) -> String? {
        let remotes = Array(Set(cloud.itemArray.compactMap { $0.representedObject as? String })).sorted()
        guard !remotes.isEmpty else { showConnect(); return nil }
        if remotes.count == 1 { return remotes[0] }
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 28), pullsDown: false)
        for remote in remotes { picker.addItem(withTitle: alias(for: remote) + " · " + remote); picker.lastItem?.representedObject = remote }
        if let selected = selectedRemote(), let item = picker.itemArray.first(where: { $0.representedObject as? String == selected }) { picker.select(item) }
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = "Elegí la cuenta de Google Drive. Cada ventana conserva su cuenta y sus permisos."; alert.accessoryView = picker
        alert.addButton(withTitle: "Abrir"); alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return picker.selectedItem?.representedObject as? String
    }
    @objc @MainActor func showTrash() {
        guard let remote = panelAccount("Papelera") else { return }
        let controller = trashControllers[remote] ?? TrashController(config: config, remote: remote)
        trashControllers[remote] = controller
        controller.show(alias: alias(for: remote))
    }
    @objc @MainActor func showSharedDrives() {
        guard let remote = panelAccount("Unidades compartidas") else { return }
        let controller = sharedDriveControllers[remote] ?? SharedDriveController(config: config, remote: remote) { [weak self] drive in self?.showSharedDriveInFinder(drive, remote: remote) }
        sharedDriveControllers[remote] = controller
        controller.show(alias: alias(for: remote))
    }
    func showSharedDriveInFinder(_ drive: SharedDriveInfo, remote: String) {
        let key = CloudAccountScope.sharedDomainIdentifier(remote: remote, driveID: drive.id)
        let controller: NativeController
        if let existing = sharedNativeControllers[key] { controller = existing }
        else {
            let client = NativeClient(identifier: key, name: "Google Drive · " + alias(for: remote) + " · " + drive.name, rootID: drive.id, remoteName: remote)
            controller = NativeController(config: config, client: client)
            sharedNativeControllers[key] = controller
        }
        controller.show()
    }
    @objc func showActivity() { activityController?.show() }
    @objc func showTransfers() {
        activityController?.showTransfers()
    }
    @objc @MainActor func showSend() {
        do { try presentSend(files: nil) }
        catch { NSAlert(error: error).runModal() }
    }
    @MainActor private func presentSend(files: [URL]?) throws {
        if sendController == nil {
            let controller=SendController(config:config,root:support.appendingPathComponent("SendQueue"))
            controller.onTransfers={ [weak self] in self?.showTransfers() }
            controller.onCompleted={ [weak self] remote in
                self?.nativeController(for:remote)?.client.signalChanges()
                self?.activityController?.record(operation:"Envío",detail:"Archivo enviado y comprobado en " + (self?.alias(for:remote) ?? remote),success:true)
            }
            sendController=controller
        }
        if let files { try sendController?.useSelection(files) }
        let accounts=Set(cloud.itemArray.compactMap{$0.representedObject as? String})
        sendController?.show(accounts:Dictionary(uniqueKeysWithValues:accounts.map{($0,alias(for:$0))}),entries:entries,selected:selectedRemote())
    }
    @objc func syncSelected() { if let entry = selection(), entry.item.IsDir { syncController?.add(entry) } }
    /// Menu status reflects the last real Google Drive query, never just the
    /// presence of a configuration file.
    func connectionStateTitle() -> String {
        if pausedUntil != nil { return "⏸ Sincronización en pausa" }
        let active = TransferCenter.shared.recent(limit: 50).filter { $0.state == .running || $0.state == .queued }
        if !active.isEmpty {
            let uploads = active.filter { $0.operation != "Descarga" }.count
            return (uploads > 0 ? "↑ Subiendo " : "↓ Descargando ") + "\(active.count) " + (active.count == 1 ? "archivo…" : "archivos…")
        }
        if let remote = remoteNeedingSignIn() { return "⚠︎ «\(displayName(for: remote))» necesita iniciar sesión" }
        guard let native = nativeController else { return "○ Ninguna cuenta conectada" }
        if native.connected { return "✓ Google Drive al día" }
        if native.lastConnectionError != nil { return "⚠︎ Sin conexión con Google Drive" }
        return FileManager.default.fileExists(atPath: support.appendingPathComponent("rclone.conf.enc").path) ? "… Conectando con Google Drive" : "○ Ninguna cuenta conectada"
    }
    @objc func refreshConnectionFromMenu() { nativeController?.revalidate() }
    /// The account whose Google session ended, if any (main account first).
    func remoteNeedingSignIn() -> String? {
        let remotes = configuredRemotes()
        for remote in (remotes.contains("GoogleDrive") ? ["GoogleDrive"] : []) + remotes.filter({ $0 != "GoogleDrive" }) {
            if accountStatus(remote).needsSignIn { return remote }
            if remote == "GoogleDrive", let error = nativeController?.lastConnectionError, nativeController?.connected != true,
               error.lowercased().contains("autoriz") { return remote }
        }
        return nil
    }
    @objc func reconnectFromMenu() {
        guard let remote = remoteNeedingSignIn() else { nativeController?.revalidate(); return }
        reconnectRemote(remote, write: remoteAllowsWrites(remote))
    }
    func configureFinder() {
        ensureFinderSyncElection()
        // PlugInKit may finish discovering a freshly replaced extension just
        // after application launch. Retry once after that registration window
        // so the first Finder right-click sees the extension as enabled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.ensureFinderSyncElection()
        }
        statusItem = NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        statusItem?.isVisible = true
        statusItem?.button?.toolTip = "Nimbo · Google Drive"
        statusItem?.button?.setAccessibilityLabel("Nimbo · Google Drive")
        // Keep the menu-bar affordance deliberately simple: the branded
        // header asset includes a decorative dot, while the status item
        // should read as a single cloud like odrive's compact indicator.
        if let icon = NSImage(systemSymbolName: "cloud", accessibilityDescription: "Nimbo") {
            icon.isTemplate = true
            icon.size = NSSize(width: 16, height: 16)
            statusItem?.button?.image = icon
        }
        // Menú corto: abrir Nimbo, estado en palabras, una fila por cuenta,
        // agregar cuenta y Configuración. Todo lo demás vive en la ventana.
        let menu = NSMenu()
        let open = NSMenuItem(title: "Abrir Nimbo", action: #selector(showDashboard), keyEquivalent: "")
        open.target = self
        open.image = NSImage(systemSymbolName: "house", accessibilityDescription: nil)
        menu.addItem(open)
        menu.addItem(.separator())
        let state = NSMenuItem(title: connectionStateTitle(), action: nil, keyEquivalent: "")
        state.isEnabled = false
        connectionStateItem = state
        menu.addItem(state)
        let reconnect = NSMenuItem(title: "Volver a iniciar sesión en Google…", action: #selector(reconnectFromMenu), keyEquivalent: "")
        reconnect.target = self; reconnect.isHidden = true
        reconnectMenuItem = reconnect
        menu.addItem(reconnect)
        menu.addItem(.separator())
        accountsAnchorItem = NSMenuItem.separator()
        menu.addItem(accountsAnchorItem!)
        menu.addItem(withTitle:"Agregar una cuenta de Google…", action:#selector(addAccountSimple), keyEquivalent:"").target = self
        menu.addItem(.separator())
        let pause = NSMenuItem(title: "Pausar sincronización", action: nil, keyEquivalent: "")
        let pauseMenu = NSMenu(title: "Pausar sincronización")
        for (title, minutes) in [("Durante 1 hora", 60), ("Durante 3 horas", 180), ("Hasta mañana", -1)] {
            let option = NSMenuItem(title: title, action: #selector(pauseSyncFromMenu(_:)), keyEquivalent: ""); option.target = self; option.tag = minutes
            pauseMenu.addItem(option)
        }
        pause.submenu = pauseMenu
        pauseMenuItem = pause; menu.addItem(pause)
        let resume = NSMenuItem(title: "Reanudar sincronización", action: #selector(resumeSyncFromMenu), keyEquivalent: "")
        resume.target = self; resume.isHidden = true
        resumeMenuItem = resume; menu.addItem(resume)
        menu.addItem(.separator())
        let searchItem = NSMenuItem(title: "Buscar en Google Drive…  " + NimboHotKey.display, action: #selector(showSearchWindow), keyEquivalent: "")
        searchItem.target = self; menu.addItem(searchItem)
        menu.addItem(withTitle: "Actividad", action: #selector(showActivity), keyEquivalent: "").target = self
        let settings = NSMenuItem(title: "Configuración…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self; menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(withTitle:"Salir de Nimbo", action:#selector(NSApplication.terminate(_:)), keyEquivalent:"q").target = NSApp
        rebuildAccountItems(in: menu)
        statusItem?.menu = menu
        menu.delegate = self
        finderBridge.onChange = { [weak self] state,message in
            guard let self else { return }
            self.finderDrive.title = state == .connected ? "Abrir Google Drive en Finder" : "Conectar en Finder"
            self.finderDrive.isEnabled = state != .connecting
            self.finderDisconnect.isEnabled = state == .connected
            self.finderStatus.stringValue = message.isEmpty ? "Drive desconectado de Finder" : message
            self.finderStatus.textColor = state == .failed ? .systemOrange : .secondaryLabelColor
        }
        finderDisconnect.isEnabled = false
        if FileManager.default.fileExists(atPath:config.path) {
            if FileManager.default.fileExists(atPath:nativeFinderRoot().path) {
                finderDrive.title = "Abrir Google Drive en Finder"
                finderDrive.isEnabled = true
                finderStatus.stringValue = "Google Drive nativo disponible · conservar/liberar en Finder"
            } else {
                // First run on this Mac: turn on the File Provider location
                // (on-demand files, states and right-click), never the old
                // read-only network volume.
                UserDefaults.standard.set(true, forKey: "NimboNativeEnabled.google-drive")
            }
        }
    }

    /// Enable the Finder Sync extension once per app version. The extension
    /// lives in `Contents/Library/LoginItems/NimboFinderHelper.app` because
    /// Finder opts out (election `ignore`) any Finder Sync extension whose
    /// containing app also contains an enabled File Provider extension.
    /// No unregister/re-register loop: a single `use` election is enough, and
    /// the version marker respects a later manual disable until the next update.
    private func ensureFinderSyncElection() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let pluginURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LoginItems/NimboFinderHelper.app/Contents/PlugIns/NimboFinderSync.appex")
        guard FileManager.default.fileExists(atPath: pluginURL.path) else { return }
        let identifier = bundleID + ".finderhelper.findersync"
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "unknown"
        let marker = "finderHelperElectionVersion"
        if UserDefaults.standard.string(forKey: marker) == version { return }

        func run(_ arguments: [String]) -> String? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            } catch {
                return nil
            }
        }

        let current = run(["-m", "-v", "-i", identifier]) ?? ""
        if current.contains("+    \(identifier)") {
            UserDefaults.standard.set(version, forKey: marker)
            return
        }

        _ = run(["-a", pluginURL.path])
        var refreshed = ""
        for _ in 0..<10 {
            refreshed = run(["-m", "-v", "-i", identifier]) ?? ""
            if refreshed.contains(identifier) { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        if !refreshed.contains("+    \(identifier)") {
            _ = run(["-e", "use", "-i", identifier])
        }
        var finalState = ""
        for _ in 0..<10 {
            finalState = run(["-m", "-v", "-i", identifier]) ?? ""
            if finalState.contains("+    \(identifier)") { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        if finalState.contains("+    \(identifier)") {
            UserDefaults.standard.set(version, forKey: marker)
        }
    }
    func startFinder() {
        guard !busy else { return }
        guard FileManager.default.fileExists(atPath:config.path) else {
            finderStatus.stringValue = "Primero conectá tu cuenta de Google Drive."; return
        }
        let environment = ProcessInfo.processInfo.environment
        let testSource = environment["NIMBO_TEST_ROOT"] == nil ? nil : environment["NIMBO_FINDER_TEST_SOURCE"]
        finderBridge.start(config:config,binary:backend.binaryURL,testSource:testSource)
    }
    @objc func showMainWindow() {
        // While the window is open Nimbo shows in the Dock, so it never gets
        // lost behind other windows. Closing it returns to the menu-bar cloud.
        NSApp.setActivationPolicy(.regular)
        // Use the bundled icon directly so the Dock never shows a cached older one.
        if let icon = Bundle.main.image(forResource: "Nimbo") { NSApp.applicationIconImage = icon }
        if window == nil {
            buildWindow(testing: ProcessInfo.processInfo.environment["NIMBO_TEST_ROOT"] != nil)
            restoreBrowserView()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.viewMode.selectedSegment != 0 else { return }
            for item in self.grid.visibleItems() {
                if let path = self.grid.indexPath(for: item) {
                    self.collectionView(self.grid, willDisplay: item, forRepresentedObjectAt: path)
                }
            }
        }
    }
    @objc func showSearchWindow() {
        closePage()
        dashboardVisible = false
        showMainWindow()
        updateDashboardVisibility()
        DispatchQueue.main.async { [weak self] in
            self?.window.makeFirstResponder(self?.search)
        }
    }
    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let enable = sender.state != .on
        do {
            try LaunchAtLogin.setEnabled(enable)
            sender.state = enable ? .on : .off
            status.stringValue = enable
                ? "Nimbo se iniciará al entrar en tu sesión y continuará las sincronizaciones programadas."
                : "Nimbo ya no se iniciará automáticamente al entrar en tu sesión."
            status.textColor = .secondaryLabelColor
        } catch {
            status.stringValue = "No se pudo cambiar el inicio automático: \(error.localizedDescription)"
            status.textColor = .systemOrange
        }
    }
    @objc private func toggleKeychainLock(_ sender: NSMenuItem) {
        let enable = sender.state != .on
        do {
            try NimboSecureConfig.setKeychainLock(enable, support: support)
            sender.state = enable ? .on : .off
            status.stringValue = enable ? "Credenciales protegidas con Keychain." : "Credenciales guardadas con la protección local de Nimbo."
            status.textColor = .secondaryLabelColor
        } catch {
            status.stringValue = "No se pudo cambiar el bloqueo de Keychain: \(error.localizedDescription)"
            status.textColor = .systemOrange
        }
    }
    private func nativeFinderRoot() -> URL {
        let cloudStorage = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage", isDirectory: true)
        if let entries = try? FileManager.default.contentsOfDirectory(at: cloudStorage, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]),
           let root = entries.first(where: { item in
               let name = item.lastPathComponent
               return (name == "Nimbo-GoogleDrive" || name.hasPrefix("Nimbo-GoogleDrive-") || name.hasPrefix("Nimbo-GoogleDrive·")) &&
                   ((try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
           }) {
            return root
        }
        return cloudStorage.appendingPathComponent("Nimbo-GoogleDrive", isDirectory: true)
    }
    @objc func openFinderDrive() {
        // Prefer the native File Provider root: Finder Sync contextual actions
        // (conservar, abrir/copiar enlace y desincronizar) are attached there.
        // Keep the read-only WebDAV volume as a compatibility fallback.
        let native = nativeFinderRoot()
        if FileManager.default.fileExists(atPath: native.path) {
            NSWorkspace.shared.open(native)
            return
        }
        // Not in Finder yet: connect the native location and open it when ready.
        guard let controller = nativeController else { return }
        controller.onConnected = { [weak controller] in
            controller?.onConnected = nil
            Task { if let url = try? await controller?.client.location() { await MainActor.run { _ = NSWorkspace.shared.open(url) } } }
        }
        controller.connect(reimport: false)
    }
    @objc func disconnectFinder() {
        finderDisconnect.isEnabled = false
        finderBridge.stop { [weak self] success in
            self?.finderDisconnect.isEnabled = !success
        }
    }
    func loadAccounts() {
        do {
            let remotes = try backend.listRemotes()
            if let thumbnails { Task { await thumbnails.setAccounts(Set(remotes)) } }
            cloud.setDriveAccounts(remotes.map { ($0, displayName(for: $0)) }, allTitle: "Todas las cuentas")
            entries = []; dates = [:]
            var cacheErrors:[String] = []
            // A failed refresh must not hide the last valid catalog. The
            // marker only changes the status message; each remote cache is
            // still loaded so search remains useful while offline.
            for remote in remotes {
                do {
                    if let cache = try backend.loadCache(remote: remote) {
                        entries += cache.entries.map { RemoteEntry(remote: remote, item: $0) }; dates[remote] = cache.fetchedAt
                    }
                } catch { cacheErrors.append(remote) }
            }
            let pendingRefresh=FileManager.default.fileExists(atPath: refreshMarker.path)
            if remotes.isEmpty { status.stringValue = "Conectá Google Drive para empezar." }
            else if !cacheErrors.isEmpty {
                let readable=dates.isEmpty ? "No se pudo leer ningún catálogo local." : "Catálogo parcial disponible."
                status.stringValue = readable + " Actualizá estas conexiones: " + cacheErrors.joined(separator:", ") + "."
            } else if dates.isEmpty || pendingRefresh {
                status.stringValue = dates.isEmpty ? "Cuenta configurada. Actualizá el catálogo para consultar sus archivos." : "Catálogo local guardado. Actualizá el catálogo para comprobar la conexión de Google Drive."
            } else { status.stringValue = catalogStatus(remotes: remotes) }
            refresh.isEnabled = !remotes.isEmpty && !busy
            connect.title = remotes.isEmpty ? "Conectar Google Drive" : "Cuenta de Google Drive"
            rebuildAccountSidebar()
            renderDashboard()
            restoreBrowserView()
            let unavailableCatalogs = Set(remotes.filter { dates[$0] == nil })
            SpotlightIndexer.shared.index(entries, aliases: Dictionary(uniqueKeysWithValues: remotes.map { ($0, alias(for: $0)) }), support: support, preservingRemotes: unavailableCatalogs) { [weak self] result in
                if case .failure(let error) = result {
                    DispatchQueue.main.async { self?.showError("No se pudo actualizar Spotlight: " + error.localizedDescription) }
                }
            }
        } catch { showError(error.localizedDescription) }
    }
    func catalogStatus(remotes: [String]) -> String {
        let formatter = DateFormatter(); formatter.dateStyle = .short; formatter.timeStyle = .short
        let values = remotes.compactMap { remote -> String? in
            guard let date = dates[remote] else { return nil }
            return "\(displayName(for: remote)): \(formatter.string(from: date))"
        }
        guard !values.isEmpty else { return "Cuenta configurada. Actualizá el catálogo para consultar sus archivos." }
        let suffix = values.joined(separator: " · ")
        return "Catálogo local guardado · última lectura: \(suffix) · Actualizalo para consultar cambios en la nube."
    }
    private func selectedRemote() -> String? {
        guard cloud.indexOfSelectedItem > 0 else { return nil }
        return cloud.selectedItem?.representedObject as? String ?? cloud.titleOfSelectedItem
    }
    private func catalogDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    private func restoreBrowserView() {
        let remotes = Set(cloud.itemArray.compactMap { $0.representedObject as? String })
        cloudBrowser.reconcile(catalog: entries, remotes: remotes)
        let state = cloudBrowser.current
        if let remote = state.location.remote,
           let index = cloud.itemArray.firstIndex(where: { ($0.representedObject as? String) == remote }) {
            cloud.selectItem(at: index)
        } else { cloud.selectItem(at: 0) }
        guard window != nil else { return }
        search.stringValue = state.query
        filter.selectedSegment = state.kind
        dateFilter.selectItem(withTag: state.dateDays)
        sizeFilter.selectItem(withTag: state.size)
        applyFilter()
    }
    @objc private func changeBrowserAccount() {
        cloudBrowser.selectAccount(selectedRemote()); restoreBrowserView()
    }
    @objc private func browserGoBack() { cloudBrowser.goBack(); restoreBrowserView() }
    @objc private func browserGoForward() { cloudBrowser.goForward(); restoreBrowserView() }
    @objc private func browserGoUp() { cloudBrowser.goUp(); restoreBrowserView() }
    @objc private func browserGoHome() { cloudBrowser.goHome(); restoreBrowserView() }

    @objc private func openBrowserSelection() {
        guard let entry = selection() else { return }
        guard entry.item.IsDir else { openWeb(); return }
        do {
            try cloudBrowser.openFolder(entry, catalog: entries)
            restoreBrowserView()
        } catch CloudBrowser.NavigationError.ambiguousFolder {
            showError("Hay carpetas con la misma ruta. Usá «Ver en Google Drive» para distinguirlas.")
        } catch { showError("La carpeta ya no está en el catálogo. Actualizá el catálogo y volvé a intentarlo.") }
    }

    @objc func applyFilter() {
        guard window != nil else { return }
        cloudBrowser.updateFilters(query: search.stringValue, kind: filter.selectedSegment, dateDays: dateFilter.selectedTag(), size: sizeFilter.selectedTag())
        let dateDays = dateFilter.selectedTag()
        let sizeTag = sizeFilter.selectedTag()
        let cutoff = dateDays > 0 ? Date().addingTimeInterval(-TimeInterval(dateDays) * 86400) : nil
        visible = entries.filter { e in
            let sizeOK: Bool
            if e.item.IsDir || sizeTag == 0 { sizeOK = true }
            else if sizeTag == 1 { sizeOK = e.item.Size >= 0 && e.item.Size < 10 * 1024 * 1024 }
            else if sizeTag == 2 { sizeOK = e.item.Size >= 10 * 1024 * 1024 && e.item.Size <= 100 * 1024 * 1024 }
            else { sizeOK = e.item.Size > 100 * 1024 * 1024 }
            let dateOK = cutoff == nil || (catalogDate(e.item.ModTime).map { $0 >= cutoff! } ?? false)
            return cloudBrowser.contains(e) && matchesQuery(search.stringValue, item: e.item) && (filter.selectedSegment == 0 || (filter.selectedSegment == 2) == e.item.IsDir) && sizeOK && dateOK
        }.sorted { a,b in
            if a.item.IsDir != b.item.IsDir { return a.item.IsDir }
            return a.item.Path.localizedStandardCompare(b.item.Path) == .orderedAscending
        }
        browserBack.isEnabled = cloudBrowser.canGoBack
        browserForward.isEnabled = cloudBrowser.canGoForward
        browserUp.isEnabled = cloudBrowser.canGoUp
        let location = cloudBrowser.current.location
        let account = location.remote.map { displayName(for: $0) } ?? "Todas las cuentas"
        updateBrowserHeading()
        breadcrumb.stringValue = location.path.isEmpty ? account : account + " / " + location.path
        breadcrumb.toolTip = breadcrumb.stringValue
        search.placeholderString = location.path.isEmpty ? "Buscar en \(account)…" : "Buscar en esta carpeta y sus subcarpetas…"
        table.deselectAll(nil); grid.deselectAll(nil)
        updateGalleryPreview()
        table.reloadData(); grid.reloadData(); summary.stringValue = "\(visible.count) de \(entries.count) entradas"
        if entries.isEmpty { detail.stringValue = cloud.numberOfItems > 1 ? "Actualizá el catálogo para leer los nombres y carpetas de tu cuenta. No se descargan los archivos." : "Conectá Google Drive. Después podrás buscar también en carpetas que nunca abriste en este Mac." }
        else if visible.isEmpty {
            let hasFilters = cloudBrowser.current.isSearching || filter.selectedSegment != 0 || dateDays != 0 || sizeTag != 0
            detail.stringValue = hasFilters ? "No hay coincidencias en esta ubicación. Cambiá los filtros o elegí «Todas las cuentas» para ampliar la búsqueda." : "Esta carpeta no contiene elementos en el catálogo guardado. Actualizá el catálogo para comprobar cambios en Drive."
        } else {
            detail.stringValue = cloudBrowser.current.isSearching ? "\(visible.count) resultados en esta ubicación y sus subcarpetas. Los archivos permanecen en la nube." : "\(visible.count) elementos. Doble clic en una carpeta para explorarla; en un archivo para abrirlo en Google Drive."
        }
        updateActions()
    }
    func controlTextDidChange(_ obj: Notification) { applyFilter() }
    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < visible.count else { return nil }; let e = visible[row]; let id = tableColumn!.identifier.rawValue
        let text: String
        switch id {
        case "name": text = e.item.Name
        case "path": text = alias(for: e.remote) + ":/" + e.item.Path
        case "kind": text = e.item.IsDir ? "Carpeta" : "Archivo"
        default: text = e.item.IsDir ? "—" : e.item.Size < 0 ? "Al exportar" : ByteCountFormatter.string(fromByteCount: e.item.Size, countStyle: .file)
        }
        let cell = NSTableCellView(); let l = label(text, size: 13, bold: id == "name"); l.lineBreakMode = .byTruncatingMiddle
        l.textColor = id == "name" ? .labelColor : .secondaryLabelColor; l.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(l); cell.textField = l; cell.toolTip = text
        if id == "name" {
            let icon = NSImageView(image: NSImage(systemSymbolName: e.item.IsDir ? "folder.fill" : "doc", accessibilityDescription: e.item.IsDir ? "Carpeta" : "Archivo")!)
            icon.contentTintColor = e.item.IsDir ? .systemBlue : .secondaryLabelColor
            icon.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(icon)
            NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), icon.widthAnchor.constraint(equalToConstant: 19), icon.heightAnchor.constraint(equalToConstant: 19), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor), l.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9)])
        } else { l.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8).isActive = true }
        NSLayoutConstraint.activate([l.trailingAnchor.constraint(equalTo: cell.trailingAnchor,constant:-8),l.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if let e = selection() {
            detail.stringValue = e.remote + ":/" + e.item.Path + (e.item.IsDir ? "\nCarpeta remota · los archivos se descargan individualmente." : "\nSólo en el catálogo · Descargar guarda una copia en Descargas/Nimbo.")
        }
        updateActions()
    }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first else { return }
        let ascending = descriptor.ascending
        visible.sort {
            let left: String
            let right: String
            switch descriptor.key ?? "name" {
            case "path": left = $0.item.Path; right = $1.item.Path
            case "kind": left = $0.item.IsDir ? "Carpeta" : "Archivo"; right = $1.item.IsDir ? "Carpeta" : "Archivo"
            case "size": left = String($0.item.Size); right = String($1.item.Size)
            default: left = $0.item.Name; right = $1.item.Name
            }
            let result = left.localizedStandardCompare(right)
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
        table.reloadData(); grid.reloadData()
    }
    func selection() -> RemoteEntry? {
        if viewMode.selectedSegment != 0 {
            guard let index = grid.selectionIndexPaths.map({ $0.item }).min(), visible.indices.contains(index) else { return nil }
            return visible[index]
        }
        return table.selectedRow >= 0 && table.selectedRow < visible.count ? visible[table.selectedRow] : nil
    }

    @objc func changeViewMode(_ sender: NSSegmentedControl) {
        let previous = tableScroll.isHidden ? grid.selectionIndexPaths.map(\.item).sorted() : Array(table.selectedRowIndexes)
        let icons = sender.selectedSegment != 0
        let gallery = sender.selectedSegment == 2
        cancelVisibleThumbnails()
        tableScroll.isHidden = icons
        gridScroll.isHidden = !icons
        galleryBox?.isHidden = !gallery
        galleryCanvasHeight.isActive = gallery
        galleryStripHeight.isActive = gallery
        gridScroll.hasVerticalScroller = !gallery
        gridScroll.hasHorizontalScroller = gallery
        if let layout = grid.collectionViewLayout as? NSCollectionViewFlowLayout {
            layout.scrollDirection = gallery ? .horizontal : .vertical
            layout.sectionInset = gallery ? NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4) : NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
            layout.invalidateLayout()
        }
        var indices = previous.filter { visible.indices.contains($0) }
        if gallery, indices.isEmpty, !visible.isEmpty { indices = [0] }
        if icons {
            grid.reloadData()
            let paths = Set(indices.map { IndexPath(item: $0, section: 0) })
            grid.selectionIndexPaths = paths
            if let first = indices.first {
                grid.scrollToItems(at: [IndexPath(item: first, section: 0)], scrollPosition: gallery ? .nearestHorizontalEdge : .nearestVerticalEdge)
            }
        } else {
            table.reloadData()
            table.selectRowIndexes(IndexSet(indices), byExtendingSelection: false)
            if let first = indices.first { table.scrollRowToVisible(first) }
        }
        updateGalleryPreview()
        updateActions()
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { visible.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("NimboGridItem"), for: indexPath) as! NimboGridItem
        let entry = visible[indexPath.item]
        item.thumbnailTask?.cancel(); item.thumbnailTask = nil
        item.thumbnailKey = ThumbnailCache.key(entry)
        item.nameLabel.stringValue = entry.item.Name
        item.subtitle.isHidden = viewMode.selectedSegment == 2
        item.subtitle.stringValue = entry.item.IsDir ? "Carpeta" : (entry.item.Size < 0 ? "Documento Google" : ByteCountFormatter.string(fromByteCount: entry.item.Size, countStyle: .file))
        item.icon.image = NSWorkspace.shared.icon(forFileType: entry.item.IsDir ? "public.folder" : (entry.item.MimeType ?? URL(fileURLWithPath: entry.item.Name).pathExtension))
        item.icon.imageScaling = .scaleProportionallyUpOrDown
        return item
    }
    func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        guard window?.isVisible == true, viewMode.selectedSegment != 0, let item = item as? NimboGridItem,
              let entry = visible[safe: indexPath.item], !entry.item.IsDir, let thumbnails else { return }
        let key = ThumbnailCache.key(entry)
        item.thumbnailTask?.cancel()
        item.thumbnailTask = Task { [weak self, weak item] in
            guard let data = await thumbnails.thumbnail(entry), !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, let item, item.thumbnailKey == key,
                      self.entries.contains(entry), let image = NSImage(data: data) else { return }
                item.icon.image = image
                SpotlightIndexer.shared.enrich(entry, alias: self.alias(for: entry.remote), support: self.support)
            }
        }
    }
    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        (item as? NimboGridItem)?.thumbnailTask?.cancel()
    }
    private func cancelVisibleThumbnails() {
        grid.visibleItems().forEach { ($0 as? NimboGridItem)?.thumbnailTask?.cancel() }
    }
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === window {
            cancelVisibleThumbnails(); galleryTask?.cancel()
            DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
        }
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let index = indexPaths.first?.item else { return }
        if let entry = visible[safe: index] {
            detail.stringValue = entry.remote + ":/" + entry.item.Path + (entry.item.IsDir ? "\nCarpeta remota · los archivos se descargan individualmente." : "\nSólo en el catálogo · Descargar guarda una copia en Descargas/Nimbo.")
        }
        updateGalleryPreview()
        updateActions()
    }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        updateGalleryPreview()
        updateActions()
    }
    @objc private func handleGridDoubleClick(_ gesture: NSClickGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let point = gesture.location(in: grid)
        guard let indexPath = grid.indexPathForItem(at: point), visible.indices.contains(indexPath.item) else { return }
        grid.selectionIndexPaths = [indexPath]
        openBrowserSelection()
    }
    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize { viewMode.selectedSegment == 2 ? NSSize(width: 104, height: 94) : NSSize(width: 150, height: 120) }
    func updateActions() {
        accountNativeControllers.values.forEach { $0.update() }
        let selected=selection()
        download.title = selected?.item.Size ?? 0 < 0 ? "Exportar documento" : "Descargar archivo"
        download.isEnabled = !busy && selected?.item.IsDir == false
        syncFolder.isEnabled = !busy && selected?.item.IsDir == true
        web.isEnabled = !busy && !openingWeb && selected?.item.ID?.isEmpty == false && ProcessInfo.processInfo.environment["NIMBO_TEST_ROOT"] == nil
    }
    func setBusy(_ flag: Bool, text: String? = nil) {
        busy = flag; refresh.isEnabled = !flag && cloud.numberOfItems > 1; connect.isEnabled = !flag
        status.textColor = .secondaryLabelColor
        cancel.isHidden = !flag; flag ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        if let text { status.stringValue = text }; updateActions()
    }
    @objc func refreshCatalog() {
        guard !busy else { return }; generation += 1; let run = generation
        let remotes = cloud.itemArray.dropFirst().compactMap { $0.representedObject as? String }
        setBusy(true, text: "Leyendo nombres y carpetas de Google Drive… Los archivos permanecen en la nube.")
        DispatchQueue.global(qos: .userInitiated).async {
            var results: [RemoteEntry] = []; var errors: [String] = []
            for remote in remotes {
                do { let items = try self.backend.list(remote: remote); results += items.map { RemoteEntry(remote: remote, item: $0) } }
                catch {
                    errors.append(remote + ": " + error.localizedDescription)
                    if (error as? CloudBackendError) == .cancelled { break }
                }
            }
            DispatchQueue.main.async {
                guard run == self.generation else { return }
                // Reload committed caches, preserving a previous catalogue on network failures.
                if errors.isEmpty { try? FileManager.default.removeItem(at: self.refreshMarker) }
                self.setBusy(false); self.loadAccounts()
                if errors.isEmpty {
                    let fmt = DateFormatter(); fmt.dateStyle = .short; fmt.timeStyle = .short
                    self.status.stringValue = "Catálogo actualizado: \(fmt.string(from: Date())) · \(results.count) entradas remotas."
                } else { self.showError("No se pudo actualizar todo. Se conserva el catálogo anterior. " + errors.joined(separator: " · ")) }
            }
        }
    }
    @objc func cancelWork() {
        generation += 1; backend.cancelAll(); oauth?.terminate(); oauth = nil; oauthTimer?.cancel()
        syncController?.suspended = false
        setBusy(false, text: "Operación cancelada. El catálogo guardado se conserva.")
    }
    private var pendingDownloadFile: URL { support.appendingPathComponent("pending-downloads.json") }
    private func loadPendingDownloads() {
        guard let data = try? Data(contentsOf: pendingDownloadFile), data.count < 8 * 1024 * 1024,
              let values = try? JSONDecoder().decode([NimboPendingDownload].self, from: data) else { return }
        pendingDownloads = values
    }
    private func savePendingDownloads() {
        guard let data = try? JSONEncoder().encode(pendingDownloads) else { return }
        try? data.write(to: pendingDownloadFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pendingDownloadFile.path)
    }
    private func runPolicies() {
        processPendingDownloads()
        runAutomaticTrashPolicy()
    }
    private func processPendingDownloads() {
        guard !busy, !pendingDownloads.isEmpty else { return }
        let now = Date(); let due = pendingDownloads.filter { $0.due <= now }
        guard !due.isEmpty else { return }
        pendingDownloads.removeAll { $0.due <= now }; savePendingDownloads()
        let destination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("Nimbo")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            var completed = 0
            for task in due where !task.item.IsDir {
                do { _ = try self.backend.download(remote: task.remote, item: task.item, destinationDirectory: destination); completed += 1 }
                catch { self.activityController?.record(operation: "Descarga automática", detail: "\(task.item.Name): \(error.localizedDescription)", success: false) }
            }
            DispatchQueue.main.async {
                if completed > 0 { self.status.stringValue = "Descarga automática completada: \(completed) archivo\(completed == 1 ? "" : "s")." }
                self.activityController?.record(operation: "Descarga automática", detail: "Completadas: \(completed) de \(due.count).", success: completed == due.count)
            }
        }
    }
    private func runAutomaticTrashPolicy() {
        let days = UserDefaults.standard.integer(forKey: "NimboAutoEmptyTrashDays")
        guard days > 0, config != nil else { return }
        if let lastTrashPolicyRun, Date().timeIntervalSince(lastTrashPolicyRun) < 600 { return }
        lastTrashPolicyRun = Date()
        let cutoff = Date().addingTimeInterval(-TimeInterval(days) * 86400)
        Task { [weak self] in
            guard let self else { return }
            do {
                let drive = DriveAPI(configuration: self.config)
                guard try await drive.permitsWrites() else { return }
                let rows = try await drive.allTrash(limit: 2000)
                let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let fallback = ISO8601DateFormatter()
                var removed = 0
                for row in rows {
                    guard removed < 100, let stamp = row.modifiedTime,
                          let date = formatter.date(from: stamp) ?? fallback.date(from: stamp), date <= cutoff else { continue }
                    do { try await drive.permanentlyDeleteFromTrash(row.id); removed += 1 }
                    catch { self.activityController?.record(operation: "Papelera automática", detail: "\(row.name): \(error.localizedDescription)", success: false) }
                }
                if removed > 0 {
                    let count = removed
                    self.activityController?.record(operation: "Papelera automática", detail: "Se eliminaron \(count) elementos con más de \(days) días.", success: true)
                    await MainActor.run { self.status.stringValue = "Papelera automática: \(count) elemento\(count == 1 ? "" : "s") eliminado\(count == 1 ? "" : "s")." }
                }
            } catch { self.activityController?.record(operation: "Papelera automática", detail: error.localizedDescription, success: false) }
        }
    }
    @objc func downloadSelected() {
        guard !busy, let e = selection(), !e.item.IsDir else { return }
        // Same-path cloud duplicates cannot be safely selected by path.
        guard entries.filter({ $0.remote == e.remote && $0.item.Path == e.item.Path }).count == 1 else { showError("Hay varios archivos con la misma ruta. Abrilo en Google Drive para elegir el correcto."); return }
        let preset = UserDefaults.standard.object(forKey: "NimboAutoDownloadPreset") as? Int ?? -1
        if preset > 0 {
            let due = Date().addingTimeInterval(TimeInterval(preset) * 60)
            pendingDownloads.append(NimboPendingDownload(remote: e.remote, item: e.item, due: due)); savePendingDownloads()
            let formatter = DateFormatter(); formatter.dateStyle = .none; formatter.timeStyle = .short
            setBusy(false, text: "Descarga programada para las \(formatter.string(from: due)).")
            return
        }
        generation += 1; let run = generation
        let destination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("Nimbo")
        setBusy(true, text: "Descargando \(e.item.Name)…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let url = try self.backend.download(remote: e.remote, item: e.item, destinationDirectory: destination)
                DispatchQueue.main.async {
                    guard run == self.generation else { return }; self.downloaded = url
                    self.setBusy(false, text: "Descarga completa: \(url.path)")
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch { DispatchQueue.main.async { guard run == self.generation else { return }; self.setBusy(false); self.showError(error.localizedDescription) } }
        }
    }
    @objc func showDownloads() {
        if let downloaded { NSWorkspace.shared.activateFileViewerSelecting([downloaded]); return }
        let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("Nimbo")
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); NSWorkspace.shared.open(url) } catch { showError(error.localizedDescription) }
    }
    @objc func openWeb() {
        guard web.isEnabled, !openingWeb, let entry = selection(), let id = entry.item.ID else { return }
        openingWeb = true; updateActions()
        let progressMessage = "Consultando el enlace de " + alias(for: entry.remote) + "…"
        status.stringValue = progressMessage
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                openingWeb = false; updateActions()
                if status.stringValue == progressMessage { status.stringValue = "Consulta terminada. Podés abrir el enlace de la selección actual." }
            }
            do {
                let link = try await DriveAPI(configuration: config, remoteName: entry.remote).browserLink(id)
                guard selection()?.remote == entry.remote, selection()?.item.ID == id, window?.isVisible == true else { return }
                guard NSWorkspace.shared.open(link) else { throw DriveFailure.unavailable }
                status.stringValue = "Enlace de " + alias(for: entry.remote) + ": abierto en el navegador. Si Google pide acceso, comprobá la cuenta del navegador."
                status.textColor = .secondaryLabelColor
            } catch {
                guard selection()?.remote == entry.remote, selection()?.item.ID == id else { return }
                showError("No se pudo abrir el enlace de " + alias(for: entry.remote) + ": " + error.localizedDescription)
            }
        }
    }
    func showError(_ message: String) { status.stringValue = message; status.textColor = .systemOrange }

    @objc func showConnect() {
        if setup != nil { setup?.makeKeyAndOrderFront(nil); return }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 680), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.title = "Nimbo · Conectar Google Drive"; panel.appearance = NSAppearance(named: .darkAqua); panel.contentView = NimboGradientView(); setup = panel
        let heading = label("Tus conexiones", size: 24, bold: true)
        let explanation = NSTextField(wrappingLabelWithString: "Cada cuenta funciona como un marcador independiente, con su propio alias, catálogo y acceso en Finder. Elegí una conexión existente para reconectarla o agregá otra cuenta sin tocar las demás.")
        explanation.textColor = .secondaryLabelColor
        let list = NSStackView(); list.orientation = .vertical; list.alignment = .leading; list.spacing = 8; list.translatesAutoresizingMaskIntoConstraints = false
        connectionList = list
        let add = NSButton(title: "＋ Agregar otra cuenta de Google Drive", target: self, action: #selector(startAddingAccount)); add.bezelStyle = .rounded
        let editorTitle = label("Conectar otra cuenta", size: 18, bold: true)
        providerPicker.removeAllItems()
        providerPicker.addItems(withTitles: ["Google Drive"])
        providerPicker.target = self; providerPicker.action = #selector(providerChanged(_:)); providerPicker.selectItem(at: 0)
        let providerLabel = label("Proveedor", size: 12, bold: true)
        accountAlias.placeholderString = "Alias visible · Trabajo, Personal, Cliente…"
        accountName.placeholderString = "Identificador interno · GoogleDrive-2"
        clientID.placeholderString = "ID de cliente OAuth · opcional si ya existe"
        secret.placeholderString = "Secreto del cliente OAuth · opcional si ya existe"
        let aliasLabel = label("Alias visible", size: 12, bold: true)
        let remoteLabel = label("Identificador interno", size: 12, bold: true)
        writeAccess.title = "Permitir sincronización y cambios desde Finder"
        let help = NSButton(title: "Cómo funciona la autorización", target: self, action: #selector(oauthHelp)); help.bezelStyle = .rounded
        let importExisting = NSButton(title: "Importar remoto rclone existente", target: self, action: #selector(importExistingRemote)); importExisting.bezelStyle = .rounded
        let go = NSButton(title: "Autorizar con Google", target: self, action: #selector(authorize)); go.bezelStyle = .rounded; oauthButton = go
        let close = NSButton(title: "Cerrar", target: self, action: #selector(closeSetup)); close.bezelStyle = .rounded
        let controls = stack([NSView(),close,go])
        providerHint.stringValue = "Google se abrirá en el navegador. Para otra identidad, elegí Usar otra cuenta. Nimbo conserva las conexiones existentes y no mezcla sus catálogos."
        providerHint.font = .systemFont(ofSize: 12); providerHint.textColor = .secondaryLabelColor; providerHint.maximumNumberOfLines = 4
        let advancedToggle = NSButton(checkboxWithTitle:"Usar otro cliente OAuth (avanzado)", target:self, action:#selector(toggleOAuthAdvanced(_:)))
        oauthAdvancedToggle = advancedToggle
        let importJSON = NSButton(title:"Elegir JSON de Google Cloud…",target:self,action:#selector(importOAuthClient))
        importJSON.bezelStyle = .rounded
        let advanced = stack([remoteLabel,accountName,label("Cliente OAuth de escritorio",size:12,bold:true),clientID,secret,importJSON,help],vertical:true,spacing:8)
        oauthAdvanced = advanced
        let needsClient = reusableGoogleClient(in: (try? String(contentsOf: config, encoding: .utf8)) ?? "") == nil
        advanced.isHidden = !needsClient; advancedToggle.state = needsClient ? .on : .off
        providerHint.stringValue = needsClient ? "Creá un cliente de escritorio en Google Cloud e importá su JSON. Después iniciarás sesión directamente en Google." : "Se reutilizará tu cliente de Google existente. Elegí un alias y pulsá Autorizar con Google; en el navegador seleccioná la otra cuenta. Los archivos seguirán bajo demanda."
        let form = stack([editorTitle,aliasLabel,accountAlias,writeAccess,providerHint,advancedToggle,advanced,controls],vertical:true,spacing:12)
        form.translatesAutoresizingMaskIntoConstraints = false
        let content = stack([heading,explanation,list,add,form], vertical:true, spacing:14)
        content.translatesAutoresizingMaskIntoConstraints = false; panel.contentView!.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor,constant:26),content.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor,constant:-26),content.topAnchor.constraint(equalTo: panel.contentView!.topAnchor,constant:24),content.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor,constant:-24),list.widthAnchor.constraint(equalTo: content.widthAnchor),list.heightAnchor.constraint(greaterThanOrEqualToConstant:120),explanation.widthAnchor.constraint(equalTo: content.widthAnchor),form.widthAnchor.constraint(equalTo: content.widthAnchor),providerHint.widthAnchor.constraint(equalTo: form.widthAnchor),controls.widthAnchor.constraint(equalTo: form.widthAnchor)])
        for column in [content,form,advanced] {
            for child in column.arrangedSubviews { child.widthAnchor.constraint(equalTo:column.widthAnchor).isActive = true }
        }
        go.bezelColor = .systemBlue
        renderConnectionList()
        startAddingAccount()
        panel.center(); panel.makeKeyAndOrderFront(nil)
    }
    private func aliasKey(_ remote: String) -> String { "NimboAlias." + remote }
    private func alias(for remote: String) -> String { UserDefaults.standard.string(forKey: aliasKey(remote)) ?? remote }
    /// On-screen name only. Never used for Finder domains, so renaming it
    /// cannot move the user's Finder folder.
    private func displayName(for remote: String) -> String {
        let value = alias(for: remote)
        return value == "GoogleDrive" ? "Mi Google Drive" : value
    }
    private func saveAlias(_ alias: String, remote: String) {
        let value = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value == remote { UserDefaults.standard.removeObject(forKey: aliasKey(remote)) }
        else { UserDefaults.standard.set(value, forKey: aliasKey(remote)) }
    }
    private func rowLabel(_ text: String, size: CGFloat = 13, bold: Bool = false) -> NSTextField {
        let value = NSTextField(labelWithString: text); value.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular); value.lineBreakMode = .byTruncatingTail; return value
    }
    private func remoteAllowsWrites(_ remote: String) -> Bool {
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return false }
        var selected = false
        for line in text.components(separatedBy: .newlines) {
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("[") { selected = value == "[\(remote)]" }
            if selected, let equal = value.firstIndex(of: "="), value[..<equal].trimmingCharacters(in: .whitespaces) == "scope" {
                return value[value.index(after: equal)...].trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == "," || $0.isWhitespace }).contains("drive")
            }
        }
        return false
    }
    private func renderConnectionList() {
        guard let list = connectionList else { return }
        list.arrangedSubviews.forEach { list.removeArrangedSubview($0); $0.removeFromSuperview() }
        let remotes = (try? backend.listRemotes()) ?? []
        if remotes.isEmpty { list.addArrangedSubview(rowLabel("Todavía no hay conexiones. Pulsá «Conectar otra cuenta».")) }
        for remote in remotes {
            let title = rowLabel(displayName(for: remote), size: 14, bold: true)
            let detail = rowLabel("Google Drive · \(remote) · Conectada · \(remoteAllowsWrites(remote) ? "Sincronización" : "Sólo nube")", size: 11)
            detail.textColor = .secondaryLabelColor
            let text = stack([title, detail], vertical: true, spacing: 2)
            text.alignment = .leading
            text.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
            let reconnect = NSButton(title: "Reconectar", target: self, action: #selector(reconnectAccount(_:))); reconnect.bezelStyle = .rounded; reconnect.identifier = NSUserInterfaceItemIdentifier(remote)
            let finder = NSButton(title: "Abrir en Finder", target: self, action: #selector(openAccountFinder(_:))); finder.bezelStyle = .rounded; finder.identifier = NSUserInterfaceItemIdentifier(remote)
            let rename = NSButton(title: "Renombrar", target: self, action: #selector(renameAccount(_:))); rename.bezelStyle = .rounded; rename.identifier = NSUserInterfaceItemIdentifier(remote)
            let row = stack([text, NSView(), reconnect, finder, rename]); row.alignment = .centerY; row.spacing = 8; row.translatesAutoresizingMaskIntoConstraints = false
            let box = NSBox(); box.title = ""; box.contentView = row; box.boxType = .custom; box.borderType = .bezelBorder; box.cornerRadius = 8; box.contentView?.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10).isActive = true; box.contentView?.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10).isActive = true; box.contentView?.topAnchor.constraint(equalTo: box.topAnchor, constant: 8).isActive = true; box.contentView?.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8).isActive = true
            // Activate the width constraint only once the box shares an ancestor
            // with the list; doing it before crashed the window (SIGABRT).
            list.addArrangedSubview(box)
            box.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }
    @objc private func startAddingAccount() {
        let remotes = (try? backend.listRemotes()) ?? []
        let next = (2...20).first { !remotes.contains("GoogleDrive-\($0)") } ?? (remotes.count + 1)
        accountAlias.stringValue = remotes.isEmpty ? "Mi Google Drive" : "Mi Google Drive \(next)"
        accountName.stringValue = remotes.isEmpty ? "GoogleDrive" : "GoogleDrive-\(next)"
        accountAlias.becomeFirstResponder()
        writeAccess.state = remotes.isEmpty && syncController?.engine.hasWriteAuthorization() == true ? .on : .off
    }
    @objc private func providerChanged(_ sender: NSPopUpButton) {
        let provider = sender.titleOfSelectedItem ?? "Google Drive"
        let google = provider == "Google Drive"
        oauthButton?.isEnabled = google
        writeAccess.isEnabled = google
        clientID.isEnabled = google
        secret.isEnabled = google
        if provider == "Remoto rclone existente" {
            providerHint.stringValue = "Elegí un remoto que ya exista en rclone. Nimbo importará su alias y lo usará para buscar y descargar sin modificar la configuración remota."
        } else if google {
            providerHint.stringValue = "Google se abrirá en el navegador. Para otra identidad, elegí Usar otra cuenta. Nimbo conserva las conexiones existentes y no mezcla sus catálogos."
        } else {
            providerHint.stringValue = "Configurá primero este proveedor con rclone config. Después pulsá Importar remoto rclone existente para incorporarlo a Nimbo con un alias visible."
        }
    }
    @objc private func importExistingRemote() {
        do {
            let remotes = try backend.listRemotes()
            guard !remotes.isEmpty else { showError("No hay remotos configurados en rclone. Ejecutá rclone config y volvé a intentarlo."); return }
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26)); picker.addItems(withTitles: remotes)
            let a = NSAlert(); a.messageText = "Importar una nube existente"; a.informativeText = "Seleccioná un remoto de rclone. Nimbo lo añadirá al buscador y a su panel, sin copiar datos ni cambiar su configuración."; a.accessoryView = picker; a.addButton(withTitle: "Importar"); a.addButton(withTitle: "Cancelar")
            guard a.runModal() == .alertFirstButtonReturn, let remote = picker.titleOfSelectedItem else { return }
            let aliasText = accountAlias.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            saveAlias(aliasText.isEmpty ? remote : aliasText, remote: remote)
            loadAccounts(); renderConnectionList()
            status.stringValue = "Remoto importado: \(alias(for: remote)). Actualizá el catálogo para buscarlo."
        } catch { showError("No se pudo leer la configuración de rclone: \(error.localizedDescription)") }
    }
    @objc private func reconnectAccount(_ sender: NSButton) {
        let remote = sender.identifier?.rawValue ?? "GoogleDrive"
        accountName.stringValue = remote; accountAlias.stringValue = alias(for: remote); writeAccess.state = remoteAllowsWrites(remote) ? .on : .off; accountAlias.becomeFirstResponder()
    }
    @objc private func openAccountFinder(_ sender: NSButton) {
        guard let remote = sender.identifier?.rawValue else { return }
        nativeController(for: remote)?.openRoot()
    }
    @objc private func renameAccount(_ sender: NSButton) {
        guard let remote = sender.identifier?.rawValue else { return }
        let field = NSTextField(string: alias(for: remote)); field.frame.size = NSSize(width: 300, height: 24)
        let alert = NSAlert(); alert.messageText = "Alias de la conexión"; alert.informativeText = "Este nombre se muestra en Nimbo y no cambia la cuenta de Google."; alert.accessoryView = field; alert.addButton(withTitle: "Guardar"); alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        saveAlias(field.stringValue, remote: remote); renderConnectionList(); loadAccounts()
    }
    @objc private func toggleOAuthAdvanced(_ sender: NSButton) {
        oauthAdvanced?.isHidden = sender.state != .on
        if sender.state != .on { clientID.stringValue = ""; secret.stringValue = "" }
    }
    @objc private func importOAuthClient() {
        guard let url = GoogleClientPanel.chooseJSON() else { return }
        do {
            let client = try OAuthDesktopClient.read(url)
            clientID.stringValue = client.id; secret.stringValue = client.secret
        } catch {
            let alert = NSAlert(); alert.messageText = "No se pudo importar el cliente OAuth"
            alert.informativeText = OAuthDesktopClient.ImportError.invalidDesktopFile.localizedDescription
            alert.runModal()
        }
    }
    @objc func closeSetup() { clientID.stringValue = ""; secret.stringValue = ""; setup?.orderOut(nil); setup = nil }
    @objc func oauthHelp() {
        let local = Bundle.main.resourceURL!.appendingPathComponent("CONECTAR_GOOGLE_DRIVE.html")
        NSWorkspace.shared.open(local)
    }
    private func reusableGoogleClient(in configuration: String) -> OAuthDesktopClient? {
        let values = DriveAPI.configurationSection(configuration, remoteName: "GoogleDrive")
        guard let id = values["client_id"], let secret = values["client_secret"] else { return nil }
        return try? OAuthDesktopClient(id: id, secret: secret)
    }
    @objc func authorize() {
        guard !busy else { return }
        guard syncController?.running != true else { showError("Esperá o detené la transferencia desde Sincronizaciones antes de renovar la cuenta."); return }
        guard finderBridge.state == .disconnected || finderBridge.state == .failed else {
            showError("Desconectá Drive de Finder antes de cambiar o renovar la cuenta."); return
        }
        let id = clientID.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = secret.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteName = accountName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "GoogleDrive" : accountName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayAlias = accountAlias.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? remoteName : accountAlias.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingConfig = support.appendingPathComponent(".authorization-" + UUID().uuidString + ".conf")
        do {
            try CloudBackend.validateRemote(remoteName)
            guard remoteName == remoteName.trimmingCharacters(in: .whitespacesAndNewlines), remoteName != "-" else { throw CloudBackendError.invalidRemote }
            let original = FileManager.default.fileExists(atPath: config.path) ? (try String(contentsOf: config, encoding: .utf8)) : ""
            let hasNamedSection = original.components(separatedBy: .newlines).contains { $0.trimmingCharacters(in: .whitespaces) == "[\(remoteName)]" }
            if !FileManager.default.fileExists(atPath: config.path) || !id.isEmpty || !value.isEmpty || !hasNamedSection {
                // A second account can reuse the existing desktop OAuth
                // client automatically; only its Google identity changes.
                let client = id.isEmpty && value.isEmpty ? reusableGoogleClient(in: original) : try? OAuthDesktopClient(id: id, secret: value)
                guard let client else {
                    let a = NSAlert(); a.messageText = "Faltan los datos del cliente OAuth"; a.informativeText = "Usá la guía para crear un cliente de tipo App de escritorio. Pegá el ID y su secreto en esta ventana."; a.runModal(); return
                }
                // Stage new credentials; preserve every existing remote when
                // adding a second Google Drive identity.
                let text = try oauthConfigurationWithRemote(original, remote: remoteName, clientID: client.id, clientSecret: client.secret, writeAccess: writeAccess.state == .on)
                try Data(text.utf8).write(to: pendingConfig, options: .atomic)
            } else {
                let original = try String(contentsOf:config,encoding:.utf8)
                let updated = try oauthConfiguration(original,writeAccess:writeAccess.state == .on,remote: remoteName)
                try Data(updated.utf8).write(to:pendingConfig,options:.atomic)
            }
            try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath: pendingConfig.path)
            clientID.stringValue = ""; secret.stringValue = ""
            closeSetup(); setBusy(true, text: "Completá la autorización en el navegador de Google. Podés cancelar aquí.")
            let p = Process(); p.executableURL = backend.binaryURL
            p.arguments = ["config","reconnect",remoteName + ":","--config",pendingConfig.path,"--auto-confirm"]
            p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            oauth = p; generation += 1; let run = generation
            syncController?.suspended = true
            p.terminationHandler = { process in DispatchQueue.main.async {
                defer { try? FileManager.default.removeItem(at: pendingConfig) }
                guard run == self.generation else { return }
                self.oauthTimer?.cancel(); self.oauth = nil; self.setBusy(false)
                self.syncController?.suspended = false
                if process.terminationStatus == 0 {
                    do {
                        // Persist the invalidation before publishing a potentially different account.
                        try Data().write(to: self.refreshMarker, options: .atomic)
                        self.config = try NimboSecureConfig.publishApp(Data(contentsOf: pendingConfig), support: self.support)
                        self.overviewTask?.cancel()
                        self.overviewLoading = false
                        self.overviewLoadedAt = nil
                        self.overviews.removeValue(forKey: remoteName)
                        self.overviewErrors.removeValue(forKey: remoteName)
                        self.saveAlias(displayAlias, remote: remoteName)
                        // Stale rows remain unusable even if cache deletion fails.
                        try? FileManager.default.removeItem(at: self.backend.cacheDirectory)
                        self.loadAccounts()
                        if self.window != nil { self.refreshOverview() }
                        self.renderConnectionList()
                        self.status.stringValue = "Autorización completada para \(remoteName). Actualizá su catálogo para empezar a buscar."
                        // A new account gets its own place in Finder right away.
                        // Also the first account: without this a fresh Mac never got its Finder location.
                        if let controller = remoteName == "GoogleDrive" ? self.nativeController : self.nativeController(for: remoteName) {
                            controller.onConnected = { [weak controller] in guard let controller else { return }; controller.onConnected = nil; Task { if let url = try? await controller.client.location() { await MainActor.run { _ = NSWorkspace.shared.open(url) } } } }
                            controller.connect(reimport: false)
                        }
                    } catch { self.loadAccounts(); self.showError("No se pudo guardar la conexión. Volvé a conectar.") }
                } else {
                    self.loadAccounts()
                    self.showError("La autorización no terminó. La conexión anterior se conserva; verificá el cliente OAuth y volvé a conectar.")
                }
            } }
            try p.run()
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, run == self.generation, self.oauth?.isRunning == true else { return }
                self.cancelWork(); self.status.stringValue = "Se agotó el tiempo de autorización (10 minutos). Podés volver a conectar."
            }
            oauthTimer = timeout; DispatchQueue.main.asyncAfter(deadline:.now()+600, execute:timeout)
        } catch {
            try? FileManager.default.removeItem(at: pendingConfig)
            setBusy(false); showError("No se pudo iniciar la autorización: " + error.localizedDescription)
            syncController?.suspended = false
        }
    }
}

if CommandLine.arguments.dropFirst().first == "--native-file-action" {
    Task { exit(await NativeFileCommand.run(Array(CommandLine.arguments.dropFirst()))) }
    dispatchMain()
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
// Both login and manual launches stay in the menu bar; the dashboard is lazy.
app.setActivationPolicy(.accessory)
app.run()

extension App: NSMenuDelegate {
    private func refreshBandwidthChecks() {
        let settings = syncController?.engine.settings ?? SyncSettings()
        for item in bandwidthMenu?.items ?? [] {
            guard let raw = item.representedObject as? String, let direction = TransferDirection(rawValue: raw) else { continue }
            item.state = settings[direction] == item.tag ? .on : .off
        }
    }
    func menuWillOpen(_ menu: NSMenu) {
        if menu === bandwidthMenu { refreshBandwidthChecks(); return }
        refreshBandwidthChecks()
        guard menu === statusItem?.menu else { return }
        connectionStateItem?.title = connectionStateTitle()
        let reason = nativeController?.connected == true ? nil : nativeController?.lastConnectionError
        connectionStateItem?.toolTip = reason
        reconnectMenuItem?.isHidden = remoteNeedingSignIn() == nil
        let paused = pausedUntil
        pauseMenuItem?.isHidden = paused != nil
        resumeMenuItem?.isHidden = paused == nil
        if let paused {
            let f = DateFormatter(); f.locale = Locale(identifier: "es"); f.dateStyle = Calendar.current.isDateInToday(paused) ? .none : .short; f.timeStyle = .short
            resumeMenuItem?.title = "Reanudar sincronización (pausada hasta " + f.string(from: paused) + ")"
        }
        rebuildAccountItems(in: menu)
    }
    /// Remote names read from the local configuration headers ("[GoogleDrive]").
    /// Cheap enough to run every time the menu opens.
    func configuredRemotes() -> [String] {
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return [] }
        return text.components(separatedBy: .newlines).compactMap { line in
            let value = line.trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("["), value.hasSuffix("]"), value.count > 2 else { return nil }
            return String(value.dropFirst().dropLast())
        }
    }
    func menuTitle(for remote: String) -> String {
        let name = UserDefaults.standard.string(forKey: "NimboAlias." + remote) ?? remote
        return name == "GoogleDrive" ? "Mi Google Drive" : name
    }
    /// One row per account: clicking it opens that Drive in Finder.
    func rebuildAccountItems(in menu: NSMenu) {
        accountMenuItems.forEach { menu.removeItem($0) }
        accountMenuItems = []
        guard let anchor = accountsAnchorItem else { return }
        var remotes = configuredRemotes()
        if remotes.isEmpty { remotes = ["GoogleDrive"] }
        let single = remotes.count == 1
        var index = menu.index(of: anchor)
        for remote in remotes {
            let title = single ? "Abrir Google Drive en Finder" : "Abrir «\(menuTitle(for: remote))»"
            let item = NSMenuItem(title: title, action: #selector(openAccountFromMenu(_:)), keyEquivalent: single ? "o" : "")
            item.target = self; item.representedObject = remote
            if let icon = NSImage(systemSymbolName: "folder", accessibilityDescription: nil) { icon.size = NSSize(width: 15, height: 15); item.image = icon }
            menu.insertItem(item, at: index); index += 1
            accountMenuItems.append(item)
        }
    }
    @objc func openAccountFromMenu(_ sender: NSMenuItem) {
        let remote = sender.representedObject as? String ?? "GoogleDrive"
        guard remote != "GoogleDrive", let controller = nativeController(for: remote) else { openFinderDrive(); return }
        Task {
            if let url = try? await controller.client.location() { await MainActor.run { _ = NSWorkspace.shared.open(url) } }
            else { await MainActor.run { controller.connect(reimport: false) } }
        }
    }
    /// Review alias and permission before opening Google. Cancelling has no side effects.
    @objc func addAccountSimple() {
        guard !busy, oauth == nil else {
            showError("Terminá o cancelá la operación actual antes de agregar otra cuenta."); return
        }
        NSApp.activate(ignoringOtherApps: true)
        let remotes = configuredRemotes()
        var next = 2
        while remotes.contains("GoogleDrive-\(next)") { next += 1 }
        let remote = remotes.isEmpty ? "GoogleDrive" : "GoogleDrive-\(next)"
        let defaultAlias = remotes.isEmpty ? "Mi Google Drive" : "Cuenta \(next)"
        guard let selection = AddDriveAccountPanel().present(defaultAlias: defaultAlias,
                canReuseClient: reusableGoogleClient(in: (try? String(contentsOf: config, encoding: .utf8)) ?? "") != nil) else { return }
        var customClient: OAuthDesktopClient?
        if selection.configureClient {
            guard let client = GoogleClientPanel().present(alias: selection.alias) else { return }
            customClient = client
        }
        accountName.stringValue = remote
        accountAlias.stringValue = selection.alias
        defer { clientID.stringValue = ""; secret.stringValue = "" }
        clientID.stringValue = customClient?.id ?? ""
        secret.stringValue = customClient?.secret ?? ""
        writeAccess.state = selection.allowChanges ? .on : .off
        authorize()
    }
}

// MARK: - Configuración (antes: lista larga en «Más opciones»)
extension App {
    @objc func showSettings() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 760), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.minSize = NSSize(width: 640, height: 520)
        w.isReleasedWhenClosed = false; w.title = "Configuración de Nimbo"; w.titleVisibility = .hidden
        NimboWindowStyle.apply(to: w)
        let content = w.contentView!

        func popup(_ entries: [(String, Int)], current: Int, action: Selector, represented: String? = nil) -> NSPopUpButton {
            let button = NSPopUpButton(frame: .zero, pullsDown: false)
            for (title, tag) in entries {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self; item.tag = tag; item.representedObject = represented
                button.menu?.addItem(item)
                if tag == current { button.select(item) }
            }
            return button
        }
        func row(_ title: String, _ detail: String, _ control: NSView) -> NSView {
            let detailLabel = NimboUI.wrapping(detail, size: 12)
            detailLabel.preferredMaxLayoutWidth = 360
            let text = NimboUI.vstack([NimboUI.text(title, size: 13, weight: .medium), detailLabel], spacing: 3)
            text.widthAnchor.constraint(greaterThanOrEqualToConstant: 340).isActive = true
            text.setContentHuggingPriority(.defaultLow, for: .horizontal)
            text.setContentCompressionResistancePriority(.required, for: .horizontal)
            control.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
            let line = NimboUI.hstack([text, NSView(), control], spacing: 16, align: .centerY)
            control.toolTip = detail; text.toolTip = detail
            return line
        }
        func toggle(_ key: String, on: Bool) -> NSSwitch {
            let s = NSSwitch(); s.state = on ? .on : .off
            s.identifier = NSUserInterfaceItemIdentifier(key); s.target = self; s.action = #selector(settingsSwitchChanged(_:))
            return s
        }
        func section(_ title: String, _ rows: [NSView]) -> NSView {
            var views: [NSView] = []
            for (i, r) in rows.enumerated() {
                if i > 0 {
                    let line = NSBox(); line.boxType = .custom; line.borderWidth = 0; line.fillColor = NSColor.white.withAlphaComponent(0.08)
                    line.heightAnchor.constraint(equalToConstant: 1).isActive = true; views.append(line)
                }
                views.append(r)
            }
            return NimboUI.vstack([NimboUI.text(title, size: 13, weight: .semibold, color: NimboPalette.textSecondary),
                                   NimboGlassCard(NimboUI.vstack(views, spacing: 12), padding: 16)], spacing: 8)
        }
        let settings = syncController?.engine.settings ?? SyncSettings()
        let unsync = UserDefaults.standard.object(forKey: "NimboAutoUnsyncPreset") as? Int ?? 0
        let general = section("General", [
            row("Liberar espacio automáticamente", "Si no abrís un archivo descargado durante este tiempo, vuelve a quedar sólo en la nube. Lo que conservás sin conexión no se toca.",
                popup([("Nunca", 0), ("Tras 1 día sin usar", 1), ("Tras 1 semana sin usar", 7), ("Tras 1 mes sin usar", 30)], current: unsync, action: #selector(setAutoUnsyncPreset(_:)))),
            row("Usar como máximo en este Mac", "Si lo descargado de Drive pasa este tamaño, Nimbo libera primero lo que hace más tiempo que no abrís. Lo que conservás sin conexión no se toca.",
                popup([("Sin límite", 0), ("10 GB", 10), ("25 GB", 25), ("50 GB", 50), ("100 GB", 100), ("250 GB", 250)], current: UserDefaults.standard.integer(forKey: "NimboLocalLimitGB"), action: #selector(setLocalLimit(_:)))),
            row("Velocidad de descarga", "Limitala si necesitás internet para otra cosa, como una videollamada.",
                popup(SyncSettings.allowed.map { (SyncSettings.label($0), $0) }, current: settings.downloadKBps, action: #selector(setBandwidthPreset(_:)), represented: TransferDirection.download.rawValue)),
            row("Velocidad de subida", "Lo mismo para lo que Nimbo sube a Google Drive.",
                popup(SyncSettings.allowed.map { (SyncSettings.label($0), $0) }, current: settings.uploadKBps, action: #selector(setBandwidthPreset(_:)), represented: TransferDirection.upload.rawValue)),
            row("Abrir Nimbo al iniciar sesión", "Mantiene tus cuentas en Finder y las sincronizaciones al día.", toggle("launch", on: LaunchAtLogin.isEnabled())),
            row("Avisos", "Sólo cuando importa: sesión vencida, conflictos o errores de subida.", toggle("notifications", on: NimboNotifier.shared.enabled)),
            row("Buscar desde cualquier lugar", "Atajo " + NimboHotKey.display + " para abrir la búsqueda de Google Drive.", toggle("hotkey", on: UserDefaults.standard.object(forKey: "NimboHotKeyEnabled") as? Bool ?? true))
        ])
        let accountsButton = NimboUI.button("Administrar cuentas…", target: self, action: #selector(showConnect))
        let accounts = section("Cuentas", [row("Cuentas de Google", "Cambiar nombres, volver a iniciar sesión o quitar una cuenta.", accountsButton)])
        let tools = section("Herramientas visibles", [
            row("Enviar a Drive", "Sube archivos a una carpeta de Drive sin pasar por Finder.", toggle("NimboShowSend", on: UserDefaults.standard.bool(forKey: "NimboShowSend"))),
            row("Unidades compartidas", "Carpetas de equipo de Google Workspace que no son de tu Drive personal.", toggle("NimboShowSharedDrives", on: UserDefaults.standard.bool(forKey: "NimboShowSharedDrives"))),
            row("Enlaces en el clic derecho", "Agrega «Copiar enlace de Google Drive» y «Abrir vista web en Google Drive» al menú de Finder.", toggle("NimboShowLinkActions", on: UserDefaults.standard.bool(forKey: "NimboShowLinkActions")))
        ])
        let autoDownload = UserDefaults.standard.object(forKey: "NimboAutoDownloadPreset") as? Int ?? -1
        let trash = UserDefaults.standard.object(forKey: "NimboAutoEmptyTrashDays") as? Int ?? 0
        let advancedBody = section("Avanzado", [
            row("Sincronización automática", "Cada cuánto se actualizan solas las carpetas de Sincronizaciones.",
                popup([("Nunca", -1), ("Inmediatamente", 0), ("Cada 15 min", 15), ("Cada hora", 60), ("Una vez por día", 1440)], current: autoDownload, action: #selector(setAutoDownloadPreset(_:)))),
            row("Vaciar la papelera de Drive", "Borra para siempre lo que esté en la papelera de Google Drive. No se puede deshacer.",
                popup([("Nunca", 0), ("Tras 1 día", 1), ("Tras 1 semana", 7), ("Tras 1 mes", 30)], current: trash, action: #selector(setAutoEmptyTrash(_:)))),
            row("Dividir archivos nuevos en Finder", "Sube los archivos muy grandes en partes; si se corta, sigue desde la última parte.",
                popup(SyncSettings.segmentSizes.map { (SyncSettings.segmentLabel($0), $0) }, current: settings.finderSegmentMB, action: #selector(setFinderSegments(_:)))),
            row("Dividir en carpetas sincronizadas", "Lo mismo para archivos nuevos en Sincronizaciones.",
                popup(SyncSettings.segmentSizes.map { (SyncSettings.segmentLabel($0), $0) }, current: settings.linkedSegmentMB, action: #selector(setLinkedSegments(_:)))),
            row("Dividir en backups", "Lo mismo para las copias de seguridad.",
                popup(SyncSettings.segmentSizes.map { (SyncSettings.segmentLabel($0), $0) }, current: settings.backupSegmentMB, action: #selector(setBackupSegments(_:)))),
            row("Bloques de subida de 64 MiB", "Puede subir más rápido con buen internet; usa más memoria.", toggle("split64", on: settings.splitLargeFiles)),
            row("Proteger credenciales con Llavero", "Pide el Llavero de macOS para desbloquear tus cuentas.", toggle("keychain", on: NimboSecureConfig.isKeychainLocked)),
            row("Ajustes de Finder", "Extensiones de Finder de macOS para Nimbo.", NimboUI.button("Abrir", target: self, action: #selector(openFinderSettings)))
        ])
        let advanced = NSView()
        let disclosure = NSButton(title: "Mostrar opciones avanzadas", target: nil, action: nil)
        disclosure.setButtonType(.pushOnPushOff); disclosure.bezelStyle = .disclosure; disclosure.title = ""
        let disclosureLabel = NimboUI.secondary("Opciones avanzadas", size: 13)
        advancedBody.isHidden = true
        disclosure.target = self; disclosure.action = #selector(toggleAdvancedSettings(_:))
        objc_setAssociatedObject(disclosure, &AssociatedKeys.advanced, advancedBody, .OBJC_ASSOCIATION_RETAIN)
        _ = advanced
        let header = NimboUI.vstack([NimboUI.title("Configuración", size: 26), NimboUI.secondary("Lo que usás a diario arriba; lo técnico, en Opciones avanzadas", size: 13)], spacing: 4)
        let column = NimboUI.vstack([header, general, accounts, tools, NimboUI.hstack([disclosure, disclosureLabel, NSView()], spacing: 4), advancedBody], spacing: 20)
        let document = NSView(); column.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(column)
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false; document.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 8), scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            column.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28), column.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -28),
            column.topAnchor.constraint(equalTo: document.topAnchor, constant: 16), column.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -28)
        ])
        settingsWindow = w
        w.center()
        NimboEmbedding.present(w, key: "settings")
    }
    var pausedUntil: Date? {
        guard let date = UserDefaults.standard.object(forKey: "NimboPausedUntil") as? Date, date > Date() else { return nil }
        return date
    }
    @objc func pauseSyncFromMenu(_ sender: NSMenuItem) {
        let until: Date
        if sender.tag < 0 {
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
            until = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        } else { until = Date().addingTimeInterval(Double(sender.tag) * 60) }
        UserDefaults.standard.set(until, forKey: "NimboPausedUntil")
        let f = DateFormatter(); f.locale = Locale(identifier: "es"); f.timeStyle = .short; f.dateStyle = Calendar.current.isDateInToday(until) ? .none : .short
        let reason = "Pausado en Nimbo hasta " + f.string(from: until)
        syncController?.suspended = true
        for remote in configuredRemotes() { if let c = nativeController(for: remote) { Task { await c.client.pauseSync(reason: reason) } } }
        activityController?.record(operation: "Pausa", detail: reason + ".", success: true)
        statusTick()
    }
    @objc func resumeSyncFromMenu() {
        UserDefaults.standard.removeObject(forKey: "NimboPausedUntil")
        syncController?.suspended = false
        for remote in configuredRemotes() { if let c = nativeController(for: remote) { Task { await c.client.resumeSync() } } }
        activityController?.record(operation: "Pausa", detail: "Sincronización reanudada.", success: true)
        statusTick()
    }
    @objc func setLocalLimit(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: "NimboLocalLimitGB")
        lastLimitCheck = nil
        enforceLocalLimit()
    }
    /// Keeps the space Nimbo uses on this Mac under the chosen limit.
    func enforceLocalLimit() {
        let limitGB = UserDefaults.standard.integer(forKey: "NimboLocalLimitGB")
        guard limitGB > 0, !limitRunning, lastLimitCheck.map({ Date().timeIntervalSince($0) > 600 }) ?? true else { return }
        let controllers = configuredRemotes().compactMap { nativeController(for: $0) }.filter { $0.connected }
        guard !controllers.isEmpty else { return }
        limitRunning = true; lastLimitCheck = Date()
        Task { [weak self] in
            var total: Int64 = 0
            for c in controllers { total += await c.client.localFootprint(unusedDays: 30).downloadedBytes }
            var excess = total - Int64(limitGB) * 1_000_000_000
            var freed: Int64 = 0
            for c in controllers where excess > 0 {
                let released = await c.client.releaseLeastRecentlyUsed(bytes: excess)
                freed += released; excess -= released
            }
            await MainActor.run {
                guard let self else { return }
                self.limitRunning = false
                if freed > 0 {
                    self.activityController?.record(operation: "Límite de espacio", detail: "Se liberaron \(NimboUI.bytes(freed)) para no pasar de \(limitGB) GB en este Mac.", success: true)
                    self.localFootprints.removeAll()
                }
            }
        }
    }
    @objc func toggleAdvancedSettings(_ sender: NSButton) {
        (objc_getAssociatedObject(sender, &AssociatedKeys.advanced) as? NSView)?.isHidden = sender.state != .on
    }
    /// Switches reuse the menu actions, which flip a menu item's state: give
    /// them a proxy item already in the opposite state.
    @objc func settingsSwitchChanged(_ sender: NSSwitch) {
        let on = sender.state == .on
        let proxy = NSMenuItem(); proxy.state = on ? .off : .on
        switch sender.identifier?.rawValue ?? "" {
        case "launch": toggleLaunchAtLogin(proxy); sender.state = proxy.state
        case "keychain": toggleKeychainLock(proxy); sender.state = proxy.state
        case "split64": setSplitLargeFiles(proxy); sender.state = proxy.state
        case "notifications": NimboNotifier.shared.enabled = on
        case "hotkey": UserDefaults.standard.set(on, forKey: "NimboHotKeyEnabled"); if on { NimboHotKey.shared.register() }
        case "NimboShowLinkActions":
            UserDefaults.standard.set(on, forKey: "NimboShowLinkActions")
            for remote in configuredRemotes() { nativeController(for: remote)?.applyLinkActions() }
        case let key where key.hasPrefix("NimboShow"):
            UserDefaults.standard.set(on, forKey: key)
            rebuildMainWindowIfNeeded()
        default: break
        }
    }
    /// The sidebar tools list is built once; rebuild the window when it changes.
    func rebuildMainWindowIfNeeded() {
        guard let current = window else { return }
        let visible = current.isVisible
        current.orderOut(nil); window = nil
        if visible { showDashboard() }
    }

    /// Background check: status icon, menu wording and discreet notifications.
    func startStatusWatcher() {
        NimboNotifier.shared.start()
        NimboNotifier.shared.onOpen = { [weak self] in self?.showDashboard() }
        NimboHotKey.shared.action = { [weak self] in self?.showSearchWindow() }
        if UserDefaults.standard.object(forKey: "NimboHotKeyEnabled") as? Bool ?? true { NimboHotKey.shared.register() }
        syncController?.engine.onEvent = { [weak self] event in
            guard !event.success else { return }
            let conflict = event.detail.lowercased().contains("conflicto")
            DispatchQueue.main.async {
                NimboNotifier.shared.post(conflict ? "conflict" : "sync-error", title: conflict ? "Nimbo guardó dos versiones" : "No se pudo sincronizar",
                                          body: event.detail)
            }
        }
        refreshOverview()
        Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.statusTick() }
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.overviewLoadedAt = nil; self?.refreshOverview() }
    }
    func statusTick() {
        if UserDefaults.standard.object(forKey: "NimboPausedUntil") != nil && pausedUntil == nil { resumeSyncFromMenu(); return }
        let active = TransferCenter.shared.recent(limit: 50).contains { $0.state == .running || $0.state == .queued }
        let failing = remoteNeedingSignIn()
        let symbol = pausedUntil != nil ? "pause.circle" : failing != nil ? "exclamationmark.icloud" : active ? "arrow.triangle.2.circlepath.icloud" : "cloud"
        if statusSymbol != symbol, let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: "Nimbo") {
            icon.isTemplate = true; icon.size = NSSize(width: 18, height: 16)
            statusItem?.button?.image = icon; statusSymbol = symbol
        }
        statusItem?.button?.toolTip = connectionStateTitle()
        enforceLocalLimit()
        if let failing {
            NimboNotifier.shared.post("signin-" + failing, title: "«\(displayName(for: failing))» necesita iniciar sesión",
                                      body: "Google cerró la sesión. Abrí Nimbo y tocá «Iniciar sesión en Google». Tus archivos en este Mac están a salvo.")
        }
        for transfer in TransferCenter.shared.recent(limit: 20) where transfer.state == .failed {
            guard let finished = transfer.finishedAt, Date().timeIntervalSince(finished) < 10 else { continue }
            NimboNotifier.shared.post("transfer-" + transfer.id.uuidString, title: "No se pudo completar «\(transfer.name)»",
                                      body: transfer.error ?? "Revisá la conexión e intentá de nuevo.")
        }
    }
}
private enum AssociatedKeys { static var advanced = 0 }
