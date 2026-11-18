import AppKit

/// Small, explicit recovery window for Google Drive trash. It never performs
/// a bulk restore: the user selects one row and confirms that single item.
@MainActor final class TrashController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let store: TrashStore
    private let accountLabel = NSTextField(labelWithString: "")
    private var window: NSWindow?
    private let table = NSTableView()
    private let refresh = NSButton(title: "Actualizar", target: nil, action: nil)
    private let restore = NSButton(title: "Restaurar seleccionada…", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private var rows: [DriveObject] { store.items }

    init(config: URL, remote: String = "GoogleDrive") {
        store = TrashStore(service: DriveAPI(configuration: config, remoteName: remote)); super.init()
        store.onChange = { [weak self] in self?.refreshControls() }
    }
    private func refreshControls() {
        table.reloadData()
        refresh.isEnabled = !store.isBusy
        restore.isEnabled = !store.isBusy && store.permitsRestoration && rows.indices.contains(table.selectedRow)
    }

    func show(alias: String = "GoogleDrive") {
        if window == nil { buildWindow() }
        accountLabel.stringValue = "Cuenta: " + alias
        window?.title = "Nimbo · Papelera · " + alias
        NimboEmbedding.present(window, key: "trash")
        NSApp.activate(ignoringOtherApps: true)
        load()
    }

    private func buildWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 540), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Nimbo · Papelera de Google Drive"
        w.minSize = NSSize(width: 680, height: 460)
        w.center()

        table.delegate = self; table.dataSource = self
        table.usesAlternatingRowBackgroundColors = true
        table.style = .fullWidth; table.rowHeight = 36
        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")); name.title = "NOMBRE"; name.width = 390
        let date = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("modified")); date.title = "ELIMINADO / MODIFICADO"; date.width = 220
        table.addTableColumn(name); table.addTableColumn(date)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        NimboWindowStyle.apply(to: w)
        let intro = NimboWindowStyle.header("Papelera de Google Drive", subtitle: "Recuperá un archivo o carpeta de la papelera. Seleccioná el elemento y revisá la confirmación antes de restaurarlo.")
        status.textColor = .secondaryLabelColor
        NimboWindowStyle.table(table, scroll: scroll)
        scroll.hasHorizontalScroller = true
        refresh.target = self; refresh.action = #selector(refreshPressed); refresh.bezelStyle = .rounded
        restore.target = self; restore.action = #selector(restorePressed); restore.bezelStyle = .rounded; restore.isEnabled = false
        let buttons = NSStackView(views: [refresh, NSView(), restore]); buttons.orientation = .horizontal; buttons.alignment = .centerY; buttons.spacing = 10
        let root = NSStackView(views: [intro, accountLabel, scroll, status, buttons]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12; root.translatesAutoresizingMaskIntoConstraints = false
        w.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor, constant: 24), root.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: w.contentView!.topAnchor, constant: 22), root.bottomAnchor.constraint(equalTo: w.contentView!.bottomAnchor, constant: -20),
            intro.widthAnchor.constraint(equalTo: root.widthAnchor), accountLabel.widthAnchor.constraint(equalTo: root.widthAnchor), scroll.widthAnchor.constraint(equalTo: root.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            status.widthAnchor.constraint(equalTo: root.widthAnchor), buttons.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])
        w.isReleasedWhenClosed = false
        window = w
    }

    @objc private func refreshPressed() { load() }

    private func load() {
        guard !store.isBusy else { return }
        status.stringValue = "Leyendo la papelera de Google Drive…"
        Task { [weak self] in
            guard let self else { return }
            do {
                guard try await store.load() else { return }
                table.deselectAll(nil); refreshControls()
                status.stringValue = rows.isEmpty ? "La papelera está vacía o no hay elementos visibles." : "\(rows.count) elementos en la papelera."
                if !store.permitsRestoration { status.stringValue += " Sólo lectura: reconectá esta cuenta con permiso de sincronización para restaurar." }
            } catch {
                status.stringValue = "No se pudo leer la papelera."
                showError(error.localizedDescription)
            }
        }
    }

    @objc private func restorePressed() {
        guard !store.isBusy, store.permitsRestoration, rows.indices.contains(table.selectedRow) else { return }
        let item = rows[table.selectedRow]
        let alert = NSAlert(); alert.messageText = "¿Restaurar «\(item.name)»?"; alert.informativeText = accountLabel.stringValue + ". El elemento volverá a su ubicación anterior en Google Drive si esa ubicación todavía existe."; alert.alertStyle = .informational
        alert.addButton(withTitle: "Restaurar"); alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        status.stringValue = "Restaurando «\(item.name)»…"
        Task { [weak self] in
            guard let self else { return }
            do {
                guard try await store.restore(id: item.id) else { return }
                table.deselectAll(nil); refreshControls()
                status.stringValue = "Elemento restaurado en Google Drive."
            } catch {
                refreshControls()
                status.stringValue = "No se pudo restaurar el elemento."
                showError(error.localizedDescription)
            }
        }
    }

    private func showError(_ message: String) {
        let a = NSAlert(); a.messageText = "Papelera de Google Drive"; a.informativeText = message; a.alertStyle = .warning; a.runModal()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let id = tableColumn?.identifier.rawValue ?? "name"; let cell = NSTableCellView(); let text = NSTextField(labelWithString: id == "name" ? rows[row].name : Self.displayDate(rows[row].modifiedTime))
        text.lineBreakMode = .byTruncatingMiddle; text.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(text)
        NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { restore.isEnabled = table.selectedRow >= 0 && table.selectedRow < rows.count && !store.isBusy && store.permitsRestoration }

    private static func displayDate(_ value: String?) -> String {
        guard let value, let date = NimboPresentation.date(value) else { return "Fecha no disponible" }
        let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short; return formatter.string(from: date)
    }
}
