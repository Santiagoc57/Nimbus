import AppKit

final class TransferController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private var rows: [NimboTransfer] = []
    private var timer: Timer?
    private let cancelButton = NSButton(title: "Cancelar transferencia", target: nil, action: nil)
    private var aliases: [String: String] = [:]
    private let emptyState = NSTextField(wrappingLabelWithString: "No hay transferencias en curso. Lo que descargues o subas con Nimbo aparece acá con su progreso")

    func show(aliases: [String: String] = [:]) {
        self.aliases = aliases
        if window == nil { build() }
        reload(); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        timer?.invalidate(); timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.reload() }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate(); timer = nil
    }

    /// Same transfer list, hosted inside the Actividad window.
    func embeddedView(aliases: [String: String] = [:]) -> NSView {
        self.aliases = aliases
        let root = makeRoot(header: false)
        reload()
        timer?.invalidate(); timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.reload() }
        return root
    }
    private func makeRoot(header includeHeader: Bool) -> NSStackView {
        table.delegate = self; table.dataSource = self; table.rowHeight = 42; table.usesAlternatingRowBackgroundColors = false
        if table.tableColumns.isEmpty {
            for (id, title, width) in [("name", "Archivo", 200.0), ("account", "Cuenta", 100.0), ("operation", "Operación", 90.0), ("progress", "Progreso", 190.0), ("speed", "Velocidad", 95.0), ("eta", "Restante", 85.0), ("state", "Estado", 110.0), ("verified", "Verificación", 115.0)] {
                let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); col.title = title; col.width = width; table.addTableColumn(col)
            }
        }
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .noBorder
        status.textColor = .secondaryLabelColor
        cancelButton.target = self; cancelButton.action = #selector(cancelSelected)
        NimboWindowStyle.table(table, scroll: scroll)
        emptyState.textColor = .secondaryLabelColor
        var views: [NSView] = [emptyState, scroll, cancelButton, status]
        if includeHeader { views.insert(NimboWindowStyle.header("Transferencias", subtitle: "Progreso de tus descargas y envíos."), at: 0) }
        let root = NSStackView(views: views)
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 14
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        for view in views where view !== cancelButton { view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        return root
    }
    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.delegate = self
        NimboWindowStyle.apply(to: w)
        w.title = "Nimbo · Transferencias"; w.minSize = NSSize(width: 700, height: 460); w.center(); w.isReleasedWhenClosed = false
        let root = makeRoot(header: true)
        root.translatesAutoresizingMaskIntoConstraints = false; w.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor, constant: 22),
            root.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor, constant: -22),
            root.topAnchor.constraint(equalTo: w.contentView!.topAnchor, constant: 20),
            root.bottomAnchor.constraint(equalTo: w.contentView!.bottomAnchor, constant: -20)
        ])
        window = w
    }

    private func reload() {
        let selectedID = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
        rows = TransferCenter.shared.recent(); emptyState.isHidden = !rows.isEmpty; table.reloadData()
        if let selectedID, let index = rows.firstIndex(where: { $0.id == selectedID }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        updateControls()
        let active = rows.filter { $0.state == .running || $0.state == .queued }.count
        status.stringValue = active == 0 ? "No hay transferencias activas." : "\(active) transferencia\(active == 1 ? "" : "s") en curso."
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateControls() }
    private func updateControls() {
        cancelButton.isEnabled = rows.indices.contains(table.selectedRow) && TransferCenter.shared.canCancel(rows[table.selectedRow].id)
    }
    @objc private func cancelSelected() {
        guard rows.indices.contains(table.selectedRow) else { return }
        TransferCenter.shared.requestCancellation(rows[table.selectedRow].id); reload()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let id = tableColumn?.identifier.rawValue else { return nil }
        let item = rows[row]; let value: String
        switch id {
        case "name": value = item.name
        case "account": value = aliases[item.remote] ?? item.remote
        case "operation": value = item.operation
        case "speed": value = item.bytesPerSecond.map { ByteCountFormatter.string(fromByteCount: Int64(min(Double(Int64.max / 2), $0)), countStyle: .file) + "/s" } ?? "—"
        case "eta":
            if let seconds = item.estimatedSeconds {
                let minutes = Int(min(525600, max(0, seconds / 60)))
                value = minutes < 1 ? "< 1 min" : (minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min")
            } else { value = "—" }
        case "progress":
            if let fraction = item.fraction { value = "\(Int(fraction * 100))% · \(ByteCountFormatter.string(fromByteCount: item.completedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file))" }
            else if item.completedBytes > 0 || item.state == .completed {
                value = ByteCountFormatter.string(fromByteCount: item.completedBytes, countStyle: .file)
            } else { value = item.state == .failed || item.state == .cancelled ? "Sin progreso confirmado" : "Preparando…" }
        case "state":
            switch item.state {
            case .queued: value = "En cola"
            case .running: value = item.cancellationRequested == true ? "Cancelando…" : "En curso"
            case .completed: value = "Completada"
            case .failed: value = "⚠︎ Falló"
            case .cancelled: value = "Cancelada"
            }
        default: value = item.verified ? "✓ Comprobado" : (item.state == .completed ? "No verificado" : "Pendiente")
        }
        let label = NSTextField(labelWithString: value); label.lineBreakMode = .byTruncatingMiddle; label.translatesAutoresizingMaskIntoConstraints = false
        let cell = NSTableCellView(); cell.toolTip = item.error; cell.addSubview(label); NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        if id == "progress", let fraction = item.fraction {
            // Use the measured fraction; an unknown total never becomes a fake percentage.
            let bar = NSProgressIndicator(); bar.isIndeterminate = false
            bar.minValue = 0; bar.maxValue = 1; bar.doubleValue = fraction
            bar.controlSize = .small; bar.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(bar)
            for constraint in cell.constraints where constraint.firstAttribute == .centerY { constraint.isActive = false }
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
                bar.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                bar.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                bar.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4)
            ])
        }
        if item.state == .failed { label.textColor = .systemOrange }
        else if id == "state" && item.state == .completed { label.textColor = .systemGreen }
        return cell
    }
}
