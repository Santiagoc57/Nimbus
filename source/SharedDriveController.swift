import AppKit

/// Drive-specific inventory for accounts that expose Shared Drives. The
/// current Finder domain remains My Drive; this window gives the user a safe
/// way to discover and open shared-drive roots without changing that domain.
@MainActor final class SharedDriveController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let config: URL
    private let remote: String
    private let accountLabel = NSTextField(labelWithString: "")
    private let openFinderHandler: (SharedDriveInfo) -> Void
    private var window: NSWindow?
    private let table = NSTableView()
    private let refresh = NSButton(title: "Actualizar", target: nil, action: nil)
    private let open = NSButton(title: "Abrir en Google Drive", target: nil, action: nil)
    private let openFinder = NSButton(title: "Abrir en Finder", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private var rows: [SharedDriveInfo] = []
    private var loading = false
    private var openingWeb = false

    init(config: URL, remote: String = "GoogleDrive", openFinder: @escaping (SharedDriveInfo) -> Void = { _ in }) { self.config = config; self.remote = remote; self.openFinderHandler = openFinder; super.init() }
    func show(alias: String = "GoogleDrive") {
        if window == nil { build() }
        accountLabel.stringValue = "Cuenta: " + alias
        window?.title = "Nimbo · Unidades compartidas · " + alias
        NimboEmbedding.present(window, key: "shared"); load()
    }
    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Nimbo · Unidades compartidas de Google Drive"; w.minSize = NSSize(width: 660, height: 440); w.center(); w.isReleasedWhenClosed = false
        NimboWindowStyle.apply(to: w)
        let intro = NimboWindowStyle.header("Unidades compartidas", subtitle: "Accedé a las unidades de tu equipo desde Google Drive o Finder. Cada unidad mantiene su propia carpeta bajo demanda.")
        table.delegate = self; table.dataSource = self; table.usesAlternatingRowBackgroundColors = true; table.rowHeight = 38
        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")); name.title = "UNIDAD COMPARTIDA"; name.width = 420
        let date = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("created")); date.title = "CREADA"; date.width = 180
        table.addTableColumn(name); table.addTableColumn(date)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.translatesAutoresizingMaskIntoConstraints = false
        NimboWindowStyle.table(table, scroll: scroll)
        scroll.hasHorizontalScroller = true
        refresh.target = self; refresh.action = #selector(refreshPressed); refresh.bezelStyle = .rounded
        open.target = self; open.action = #selector(openPressed); open.bezelStyle = .rounded; open.isEnabled = false
        openFinder.target = self; openFinder.action = #selector(openFinderPressed); openFinder.bezelStyle = .rounded; openFinder.isEnabled = false
        let buttons = NSStackView(views: [refresh, NSView(), openFinder, open]); buttons.orientation = .horizontal; buttons.alignment = .centerY; buttons.spacing = 10; buttons.translatesAutoresizingMaskIntoConstraints = false
        status.textColor = .secondaryLabelColor; status.translatesAutoresizingMaskIntoConstraints = false
        let root = NSStackView(views: [intro, accountLabel, scroll, status, buttons]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12; root.translatesAutoresizingMaskIntoConstraints = false
        w.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor, constant: 24), root.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor, constant: -24), root.topAnchor.constraint(equalTo: w.contentView!.topAnchor, constant: 22), root.bottomAnchor.constraint(equalTo: w.contentView!.bottomAnchor, constant: -20), intro.widthAnchor.constraint(equalTo: root.widthAnchor), accountLabel.widthAnchor.constraint(equalTo: root.widthAnchor), scroll.widthAnchor.constraint(equalTo: root.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200), status.widthAnchor.constraint(equalTo: root.widthAnchor), buttons.widthAnchor.constraint(equalTo: root.widthAnchor)])
        window = w
    }
    @objc private func refreshPressed() { load() }
    private func load() {
        guard !loading, !openingWeb else { return }; loading = true; refresh.isEnabled = false; open.isEnabled = false; openFinder.isEnabled = false; status.stringValue = "Consultando las unidades compartidas…"
        let drive = DriveAPI(configuration: config, remoteName: remote)
        Task { [weak self] in
            guard let self else { return }
            do {
                let values = try await drive.allSharedDrives(limit: 500)
                let sorted = values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                self.finish(sorted)
            } catch { self.fail(error) }
        }
    }
    private func finish(_ values: [SharedDriveInfo]) { loading = false; rows = values; table.reloadData(); table.deselectAll(nil); refresh.isEnabled = true; open.isEnabled = table.selectedRow >= 0; openFinder.isEnabled = open.isEnabled; status.stringValue = values.isEmpty ? "No hay unidades compartidas disponibles para esta cuenta." : "\(values.count) unidad\(values.count == 1 ? "" : "es") compartida\(values.count == 1 ? "" : "s") disponible\(values.count == 1 ? "" : "s")." }
    private func fail(_ error: Error) { loading = false; rows = []; table.reloadData(); table.deselectAll(nil); refresh.isEnabled = true; open.isEnabled = false; openFinder.isEnabled = false; status.stringValue = "No se pudieron consultar las unidades compartidas."; let a = NSAlert(); a.messageText = "Unidades compartidas"; a.informativeText = error.localizedDescription; a.alertStyle = .warning; a.runModal() }
    @objc private func openPressed() {
        guard !loading, !openingWeb, rows.indices.contains(table.selectedRow) else { return }
        let id = rows[table.selectedRow].id
        openingWeb = true; refresh.isEnabled = false; open.isEnabled = false; openFinder.isEnabled = false
        status.stringValue = "Consultando el enlace de la unidad…"
        Task { [weak self] in
            guard let self else { return }
            defer { openingWeb = false; refresh.isEnabled = true; tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification)) }
            do {
                let link = try await DriveAPI(configuration: config, remoteName: remote).browserLink(id)
                guard NimboEmbedding.isShowing(window), rows.indices.contains(table.selectedRow), rows[table.selectedRow].id == id else { return }
                guard NSWorkspace.shared.open(link) else { throw DriveFailure.unavailable }
                status.stringValue = "Enlace abierto. Si Google pide acceso, comprobá la cuenta del navegador."
            } catch { status.stringValue = "No se pudo abrir la unidad: " + error.localizedDescription }
        }
    }
    @objc private func openFinderPressed() { guard !loading, !openingWeb, rows.indices.contains(table.selectedRow) else { return }; openFinderHandler(rows[table.selectedRow]) }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }; let id = tableColumn?.identifier.rawValue ?? "name"; let text = id == "name" ? rows[row].name : Self.date(rows[row].createdTime); let cell = NSTableCellView(); let label = NSTextField(labelWithString: text); label.translatesAutoresizingMaskIntoConstraints = false; label.lineBreakMode = .byTruncatingMiddle; cell.addSubview(label); NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)]); return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { open.isEnabled = table.selectedRow >= 0 && table.selectedRow < rows.count && !loading && !openingWeb; openFinder.isEnabled = open.isEnabled }
    private static func date(_ value: String?) -> String { guard let value, let d = NimboPresentation.date(value) else { return "Fecha no disponible" }; let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f.string(from: d) }
}
