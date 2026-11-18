import AppKit

final class ActivityController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let log: ActivityLog
    private var window: NSWindow?
    private let table = NSTableView()
    private let refresh = NSButton(title: "Actualizar", target: nil, action: nil)
    private let clear = NSButton(title: "Borrar historial", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private var rows: [ActivityEvent] = []
    /// Supplied by the app: the transfers list and the downloads folder live in this same window.
    var transfersView: (() -> NSView)?
    var openDownloads: (() -> Void)?
    private let tabs = NSTabView()
    private let picker = NSSegmentedControl(labels: ["Historial", "Transferencias"], trackingMode: .selectOne, target: nil, action: nil)
    init(file: URL) { log = ActivityLog(file: file); super.init() }
    func showTransfers() { show(); picker.selectedSegment = 1; tabs.selectTabViewItem(at: 1) }
    /// Keychain-backed journal writes can block while macOS unlocks or
    /// decrypts the item. Finder actions must never wait on that I/O from the
    /// main AppKit thread, so activity is recorded asynchronously.
    func record(operation: String, detail: String, success: Bool) {
        let log=self.log
        DispatchQueue.global(qos:.utility).async {
            log.append(operation: operation, detail: detail, success: success)
        }
    }
    func show() { if window == nil { build() }; reload(); NimboEmbedding.present(window, key: "activity") }
    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Nimbo · Actividad"; w.minSize = NSSize(width: 720, height: 500); w.center(); w.isReleasedWhenClosed = false
        NimboWindowStyle.apply(to: w)
        let intro = NimboWindowStyle.header("Actividad", subtitle: "Lo que hizo Nimbo, lo que se está transfiriendo y tus descargas, en un solo lugar")
        table.delegate = self; table.dataSource = self; table.rowHeight = 36
        for (id, title, width) in [("date", "Cuándo", 150.0), ("operation", "Operación", 160.0), ("detail", "Detalle", 540.0)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); c.title = title; c.width = width; table.addTableColumn(c)
        }
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        NimboWindowStyle.table(table, scroll: scroll)
        refresh.target = self; refresh.action = #selector(refreshPressed); refresh.bezelStyle = .rounded
        clear.target = self; clear.action = #selector(clearPressed); clear.bezelStyle = .rounded
        status.textColor = .secondaryLabelColor
        let buttons = NSStackView(views: [refresh, status, NSView(), clear]); buttons.orientation = .horizontal; buttons.alignment = .centerY; buttons.spacing = 10
        let history = NSStackView(views: [scroll, buttons]); history.orientation = .vertical; history.spacing = 12; history.alignment = .width
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        let historyItem = NSTabViewItem(identifier: "history"); historyItem.view = history
        let transferItem = NSTabViewItem(identifier: "transfers")
        let downloads = NSButton(title: "Abrir carpeta de descargas", target: self, action: #selector(openDownloadsPressed)); downloads.bezelStyle = .rounded
        downloads.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil); downloads.imagePosition = .imageLeading
        let transferContent = transfersView?() ?? NSView()
        let transfers = NSStackView(views: [transferContent, downloads]); transfers.orientation = .vertical; transfers.alignment = .leading; transfers.spacing = 12
        transferContent.widthAnchor.constraint(equalTo: transfers.widthAnchor).isActive = true
        transferItem.view = transfers
        tabs.tabViewType = .noTabsNoBorder; tabs.drawsBackground = false
        tabs.addTabViewItem(historyItem); tabs.addTabViewItem(transferItem)
        picker.target = self; picker.action = #selector(switchTab); picker.selectedSegment = 0
        let root = NSStackView(views: [intro, picker, tabs]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 16; root.translatesAutoresizingMaskIntoConstraints = false
        w.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor, constant: 24), root.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor, constant: -24), root.topAnchor.constraint(equalTo: w.contentView!.topAnchor, constant: 22), root.bottomAnchor.constraint(equalTo: w.contentView!.bottomAnchor, constant: -20), intro.widthAnchor.constraint(equalTo: root.widthAnchor), tabs.widthAnchor.constraint(equalTo: root.widthAnchor)])
        tabs.setContentHuggingPriority(.defaultLow, for: .vertical)
        window = w
    }
    @objc private func switchTab() { tabs.selectTabViewItem(at: picker.selectedSegment) }
    @objc private func openDownloadsPressed() { openDownloads?() }
    private func reload() { rows = log.events(); table.reloadData(); status.stringValue = rows.isEmpty ? "Todavía no hay operaciones" : "\(rows.count) eventos · se guardan los últimos 500" }
    @objc private func refreshPressed() { reload() }
    @objc private func clearPressed() { let a = NSAlert(); a.messageText = "¿Borrar el historial?"; a.informativeText = "Sólo se borran los mensajes locales de actividad. No se modifican archivos de Google Drive."; a.addButton(withTitle: "Borrar"); a.addButton(withTitle: "Cancelar"); guard a.runModal() == .alertFirstButtonReturn else { return }; log.clear(); reload() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }; let event = rows[row]; let warning = !event.success && !NimboPresentation.isRoutineActivity(operation: event.operation, detail: event.detail); let id = tableColumn?.identifier.rawValue ?? "detail"; let value: String
        if id == "date" { let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; value = f.string(from: event.date) } else if id == "operation" { value = warning ? "⚠︎ " + event.operation : event.operation } else { value = event.detail }
        let cell = NSTableCellView(); cell.toolTip = event.detail; let label = NSTextField(labelWithString: value); label.translatesAutoresizingMaskIntoConstraints = false; label.lineBreakMode = .byTruncatingTail; if warning { label.textColor = .systemOrange }; cell.addSubview(label); NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)]); return cell
    }
}
