import AppKit

final class SyncController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let engine: SyncEngine
    private let queue = DispatchQueue(label:"Nimbo.sync",qos:.utility)
    private var timer: Timer?
    private(set) var running = false
    private(set) var rows: [SyncRelation] = []
    var needsAuthorization: (() -> Void)?
    private var stopping = false
    private var attempts: [UUID:Date] = [:]
    var suspended = false
    private var window: NSWindow?
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString:"Elegí una carpeta del catálogo y pulsá Sincronizar carpeta.")
    private let downloadLimit = NSPopUpButton()
    private let uploadLimit = NSPopUpButton()
    var bandwidthDidChange: (() -> Void)?
    private var buttons: [NSButton] = []
    init(engine: SyncEngine) {
        self.engine = engine; super.init(); rows = engine.relations
        engine.onActivity = { [weak self] text in DispatchQueue.main.async { self?.status.stringValue = text } }
        timer = Timer.scheduledTimer(withTimeInterval:60,repeats:true) { [weak self] _ in self?.tick() }
        // Do not make a scheduled relation wait for the first 60-second timer
        // tick after login or app launch.
        DispatchQueue.main.async { [weak self] in self?.tick() }
    }
    func shutdown(_ completion: @escaping () -> Void) {
        stopping = true; timer?.invalidate(); engine.cancel()
        queue.async { DispatchQueue.main.async { completion() } }
    }
    func resumeAfterCancelledQuit() {
        stopping = false
        timer = Timer.scheduledTimer(withTimeInterval:60,repeats:true) { [weak self] _ in self?.tick() }
        DispatchQueue.main.async { [weak self] in self?.tick() }
    }
    func add(_ entry: RemoteEntry) {
        guard !running else { show(); return }
        guard engine.hasWriteAuthorization(remote: entry.remote) else { needsAuthorization?(); return }
        show()
        let alert = NSAlert(); alert.messageText = "Sincronizar «\(entry.item.Name)»"
        alert.informativeText = "Se descargará esta carpeta para trabajar sin internet. Nimbo subirá tus cambios y traerá los de Drive periódicamente mientras esté abierto. Los conflictos conservan ambas versiones; los borrados requieren revisión. Los documentos de Google se abren en la web y no se sincronizan como archivos."
        alert.addButton(withTitle:"Crear copia nueva"); alert.addButton(withTitle:"Vincular carpeta existente…"); alert.addButton(withTitle:"Cancelar")
        let choice=alert.runModal()
        if choice == .alertFirstButtonReturn {
            perform { let id = try self.engine.add(remote:entry.remote,item:entry.item); try self.engine.synchronize(id) }
        } else if choice == .alertSecondButtonReturn {chooseExisting(entry)}
    }
    private func chooseExisting(_ entry:RemoteEntry) {
        #if NIMBO_TESTING
        if let path=ProcessInfo.processInfo.environment["NIMBO_SYNC_TEST_LOCAL"] {
            prepareExisting(entry,local:URL(fileURLWithPath:path));return
        }
        #endif
        let picker=NSOpenPanel();picker.title="Carpeta de este Mac para vincular con Drive"
        picker.message="Puede contener archivos. Nimbo preparará un plan antes de cambiar nada."
        picker.canChooseDirectories=true;picker.canChooseFiles=false;picker.allowsMultipleSelection=false;picker.canCreateDirectories=false
        picker.prompt="Revisar carpeta"
        guard picker.runModal() == .OK,let local=picker.url else{return}
        prepareExisting(entry,local:local)
    }
    private func prepareExisting(_ entry:RemoteEntry,local:URL) {
        var plan:SyncFolderPlan?
        perform({plan=try self.engine.previewExisting(remote:entry.remote,item:entry.item,local:local)},onSuccess:{
            guard let plan else{return}
            let a=NSAlert();a.messageText="Vincular con «\(entry.item.Name)»"
            a.informativeText="Se unirán ambas carpetas: los archivos locales se subirán y los remotos se descargarán. Las coincidencias de contenido se mantienen; los conflictos del Mac se renombran para conservar ambas versiones. Cerrá los archivos durante la primera sincronización."
            let scroll=NSScrollView(frame:NSRect(x:0,y:0,width:610,height:250))
            let text=NSTextView(frame:scroll.bounds);text.isEditable=false;text.isVerticallyResizable=true;text.autoresizingMask=[.width]
            text.string="Mac: \(plan.localPath)\nDrive: \(plan.remote):/\(plan.folder.Path)\n\nArchivos locales: \(plan.localFileCount)\nArchivos remotos: \(plan.remoteFileCount)\nConflictos que se conservarán por separado: \(plan.moves.count)\n\n"+plan.moves.map{"\($0.from)\n → \($0.to)"}.joined(separator:"\n\n")
            scroll.documentView=text;scroll.hasVerticalScroller=true;a.accessoryView=scroll
            a.addButton(withTitle:"Vincular y sincronizar");a.addButton(withTitle:"Cancelar")
            if a.runModal() == .alertFirstButtonReturn {
                self.perform {let id=try self.engine.addExisting(plan);try self.engine.synchronize(id)}
            }
        })
    }
    private func perform(_ operation: @escaping () throws -> Void,
                         transferContext: (operation: String, relation: SyncRelation)? = nil,
                         onSuccess:(()->Void)?=nil) {
        guard !running, !stopping, !suspended else { return }
        // Use the relation being executed, even when the window is closed
        // or another row is selected. Account keys must not include a path.
        let transfer = transferContext.map { context in
            TransferCenter.shared.begin(remote: context.relation.remote,
                                        name: context.relation.name,
                                        operation: context.operation,
                                        totalBytes: 0)
        }
        running = true; status.stringValue = transferContext.map { "\($0.operation)…" } ?? "Comprobando carpetas…"; updateButtons()
        queue.async {
            var errorText: String?
            do {
                try operation()
                if let transfer { TransferCenter.shared.finish(transfer, verified: true) }
            } catch {
                errorText = error.localizedDescription
                if let transfer { TransferCenter.shared.finish(transfer, verified: false, error: errorText) }
            }
            let snapshot = self.engine.relations
            DispatchQueue.main.async {
                let selectedID = self.selected()?.id
                self.rows = snapshot; self.running = false; self.table.reloadData()
                if let index = snapshot.firstIndex(where:{$0.id == selectedID}) ?? (snapshot.count == 1 ? 0 : nil) {
                    self.table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false)
                }
                self.updateButtons()
                self.status.stringValue = errorText ?? self.selected().map(self.displayStatus) ?? snapshot.last.map(self.displayStatus) ?? "Sin carpetas sincronizadas."
                if errorText==nil{onSuccess?()}
            }
        }
    }
    private func tick() {
        guard !running, !stopping, !suspended else { return }
        if let backup = rows.filter({ !$0.paused && engine.backupIsDue($0.id) }).min(by: { (attempts[$0.id] ?? .distantPast) < (attempts[$1.id] ?? .distantPast) }) {
            attempts[backup.id] = Date()
            perform({ try self.engine.runBackup(backup.id) }, transferContext: (operation: "Backup", relation: backup))
            return
        }
        if let row = rows.filter({ !$0.paused && $0.pendingDeletes.isEmpty && engine.syncIsDue($0.id) }).min(by: { (attempts[$0.id] ?? .distantPast) < (attempts[$1.id] ?? .distantPast) }) {
            attempts[row.id] = Date()
            perform({ try self.engine.synchronize(row.id) }, transferContext: (operation: "Sincronización", relation: row))
            return
        }
    }
    func show() {
        if window == nil { build() }
        NimboEmbedding.present(window, key: "sync")
    }
    private func build() {
        let w = NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:700),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        w.title = "Nimbo · Carpetas sin conexión"; w.isReleasedWhenClosed = false; w.minSize = NSSize(width:920,height:620); w.center(); window = w
        NimboWindowStyle.apply(to: w)
        let header = NimboWindowStyle.header("Carpetas sin conexión", subtitle: "Copias locales vinculadas a Google Drive. Editá desde Finder y administrá aquí su sincronización, programación y backups.")
        table.delegate = self; table.dataSource = self; table.rowHeight = 52; table.usesAlternatingRowBackgroundColors = true
        for (id,title,width) in [("name","CARPETA",230.0),("status","ESTADO",590.0)] {
            let c = NSTableColumn(identifier:NSUserInterfaceItemIdentifier(id)); c.title = title; c.width = width; table.addTableColumn(c)
        }
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        NimboWindowStyle.table(table, scroll: scroll)
        let actions = NSStackView(); actions.spacing = 8
        let scheduling = NSStackView(); scheduling.spacing = 8
        for (text,selector) in [("Abrir carpeta",#selector(openLocal)),("Sincronizar ahora",#selector(syncNow)),("Pausar / reanudar",#selector(togglePause)),("Revisar borrados",#selector(reviewDeletes)),("Desvincular",#selector(forget))] {
            let b = NSButton(title:text,target:self,action:selector); b.bezelStyle = .rounded; buttons.append(b); actions.addArrangedSubview(b)
        }
        for (text,selector) in [("Programar sincronización",#selector(configureSync)),("Configurar backup",#selector(configureBackup)),("Backup ahora",#selector(runBackupNow)),("Reglas de exclusión",#selector(configureFilters))] {
            let b = NSButton(title:text,target:self,action:selector); b.bezelStyle = .rounded; buttons.append(b); scheduling.addArrangedSubview(b)
        }
        let restore = NSButton(title:"Restaurar versión…",target:self,action:#selector(restoreVersion)); restore.bezelStyle = .rounded; buttons.append(restore)
        let remoteRestore = NSButton(title: "Restaurar backup de Drive…", target: self, action: #selector(restoreDriveBackup))
        remoteRestore.bezelStyle = .rounded
        buttons.append(remoteRestore)
        let cancel = NSButton(title:"Detener transferencia",target:self,action:#selector(cancel)); cancel.bezelStyle = .rounded; buttons.append(cancel)
        let versions = NSButton(title:"Versiones conservadas en este Mac",target:self,action:#selector(openVersions)); versions.bezelStyle = .rounded
        let bottom = NSStackView(views:[restore,remoteRestore,cancel,versions]); bottom.spacing = 12
        let bandwidthRow = NSStackView()
        bandwidthRow.spacing = 12
        for (direction, picker) in [(TransferDirection.download, downloadLimit), (.upload, uploadLimit)] {
            bandwidthRow.addArrangedSubview(NSTextField(labelWithString: direction.title))
            picker.setAccessibilityLabel("Límite de " + direction.title.lowercased())
            for value in SyncSettings.allowed {
                picker.addItem(withTitle: SyncSettings.label(value))
                picker.lastItem?.tag = value
            }
            picker.selectItem(withTag: engine.settings[direction])
            picker.target = self
            picker.action = #selector(bandwidthChanged(_:))
            bandwidthRow.addArrangedSubview(picker)
        }
        status.maximumNumberOfLines = 3
        status.textColor = .secondaryLabelColor
        let schedulingLabel = NSTextField(labelWithString:"PROGRAMACIÓN Y BACKUPS")
        schedulingLabel.font = .systemFont(ofSize:11,weight:.semibold); schedulingLabel.textColor = .secondaryLabelColor
        let root = NSStackView(views:[header,scroll,actions,schedulingLabel,scheduling,bottom,bandwidthRow,status]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 16
        root.translatesAutoresizingMaskIntoConstraints = false; w.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:w.contentView!.leadingAnchor,constant:24),root.trailingAnchor.constraint(equalTo:w.contentView!.trailingAnchor,constant:-24),root.topAnchor.constraint(equalTo:w.contentView!.topAnchor,constant:24),root.bottomAnchor.constraint(equalTo:w.contentView!.bottomAnchor,constant:-24),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:180)])
        for v in [header,scroll,status] { v.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }
        scroll.setContentHuggingPriority(.defaultLow,for:.vertical); updateButtons()
    }
    @objc private func bandwidthChanged(_ picker: NSPopUpButton) {
        do { try setBandwidthLimit(picker.selectedTag(), for: picker === downloadLimit ? .download : .upload) }
        catch { status.stringValue = error.localizedDescription }
    }

    func setBandwidthLimit(_ kbps: Int, for direction: TransferDirection) throws {
        defer {
            downloadLimit.selectItem(withTag: engine.settings.downloadKBps)
            uploadLimit.selectItem(withTag: engine.settings.uploadKBps)
        }
        try engine.setBandwidthLimit(kbps, for: direction)
        status.stringValue = direction.title + " · " + SyncSettings.label(kbps) + " desde la próxima transferencia."
        bandwidthDidChange?()
    }
    func setSplitLargeFiles(_ enabled: Bool) {
        do {
            try engine.setSplitLargeFiles(enabled)
            status.stringValue = enabled ? "Archivos grandes: subida por bloques de 64 MiB activada." : "Archivos grandes: subida por bloques desactivada."
        } catch { status.stringValue = error.localizedDescription }
    }
    private func selected() -> SyncRelation? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    private func displayStatus(_ relation: SyncRelation) -> String {
        var parts = [(relation.paused ? "Pausada · " : "") + relation.message]
        if let schedule = relation.syncSchedule { parts.append(schedule.message) }
        if let backup = relation.backupSchedule { parts.append(backup.message) }
        return parts.joined(separator: " · ")
    }
    private func updateButtons() {
        for b in buttons { b.isEnabled = !running && selected() != nil }
        buttons.last?.isEnabled = running
        if buttons.count > 3 { buttons[3].isEnabled = !running && selected()?.pendingDeletes.isEmpty == false }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView,viewFor tableColumn: NSTableColumn?,row:Int) -> NSView? {
        let r = rows[row]
        let label = NSTextField(labelWithString:tableColumn?.identifier.rawValue == "name" ? r.name : displayStatus(r))
        label.lineBreakMode = .byTruncatingTail; label.toolTip = r.localPath + "\n" + r.message
        return label
    }
    func tableViewSelectionDidChange(_ notification:Notification) { updateButtons(); if !running { status.stringValue = selected().map(displayStatus) ?? "Seleccioná una carpeta." } }
    @objc private func openLocal() { if let r = selected() { NSWorkspace.shared.open(URL(fileURLWithPath:r.localPath)) } }
    @objc private func syncNow() {
        if let r = selected() {
            perform({ try self.engine.synchronize(r.id) }, transferContext: (operation: "Sincronización", relation: r))
        }
    }
    @objc private func runBackupNow() {
        if let r = selected() {
            perform({ try self.engine.runBackup(r.id) }, transferContext: (operation: "Backup", relation: r))
        }
    }
    @objc private func configureFilters() {
        guard let r = selected() else { return }
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 150)); text.isEditable = true; text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.string = (r.filters?.patterns ?? SyncFilters.defaults).joined(separator: "\n")
        let scroll = NSScrollView(frame: text.frame); scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let a = NSAlert(); a.messageText = "Reglas de exclusión para «\(r.name)»"; a.informativeText = "Una regla por línea. Se aplican a la sincronización y a los backups; los nombres excluidos no se suben ni se borran del otro lado. Dejá sólo los patrones que quieras conservar."; a.accessoryView = scroll; a.addButton(withTitle: "Guardar"); a.addButton(withTitle: "Cancelar")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        perform { try self.engine.setFilters(r.id, patterns: text.string.components(separatedBy: .newlines)) }
    }
    @objc private func configureSync() {
        guard let r = selected() else { return }
        let current = r.syncSchedule ?? SyncSchedule()
        let enabled = NSButton(checkboxWithTitle: "Activar sincronización programada", target: nil, action: nil); enabled.state = current.enabled ? .on : .off
        let interval = NSPopUpButton(frame: .zero, pullsDown: false); interval.addItems(withTitles: ["Cada 15 minutos", "Cada hora", "Cada 6 horas", "Cada día"])
        for item in interval.itemArray { item.tag = ["Cada 15 minutos":15, "Cada hora":60, "Cada 6 horas":360, "Cada día":1440][item.title] ?? 60 }
        interval.selectItem(withTag: current.intervalMinutes)
        let label = NSTextField(labelWithString: "Frecuencia")
        let accessory = NSStackView(views: [enabled, NSStackView(views: [label, interval])]); accessory.orientation = .vertical; accessory.alignment = .leading; accessory.spacing = 10
        let a = NSAlert(); a.messageText = "Sincronización de «\(r.name)»"
        a.informativeText = "Nimbo sincroniza continuamente mientras está abierto. Activá esta opción para espaciar el sondeo de Google Drive y reducir actividad de red; los cambios pendientes se procesan en la próxima ejecución."
        a.accessoryView = accessory; a.addButton(withTitle: "Guardar"); a.addButton(withTitle: "Cancelar")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        perform { try self.engine.setSyncSchedule(r.id, enabled: enabled.state == .on, intervalMinutes: interval.selectedTag()) }
    }
    @objc private func configureBackup() {
        guard let r = selected() else { return }
        let current = r.backupSchedule ?? SyncBackupSchedule()
        let enabled = NSButton(checkboxWithTitle: "Activar backup programado", target: nil, action: nil); enabled.state = current.enabled ? .on : .off
        let interval = NSPopUpButton(frame: .zero, pullsDown: false); interval.addItems(withTitles: ["Cada 15 minutos", "Cada hora", "Cada 6 horas", "Cada día"]); interval.selectItem(withTag: current.intervalMinutes)
        for item in interval.itemArray { item.tag = ["Cada 15 minutos":15, "Cada hora":60, "Cada 6 horas":360, "Cada día":1440][item.title] ?? 1440 }
        interval.selectItem(withTag: current.intervalMinutes)
        let retention = NSPopUpButton(frame: .zero, pullsDown: false); retention.addItems(withTitles: ["1 copia", "3 copias", "7 copias", "14 copias", "30 copias"])
        for item in retention.itemArray { item.tag = Int(String(item.title.split(separator: " ").first ?? "7")) ?? 7 }
        retention.selectItem(withTag: current.retention)
        let encrypted = NSButton(checkboxWithTitle: "Cifrar el contenido del backup en Google Drive", target: nil, action: nil); encrypted.state = current.encrypted ? .on : .off
        let passphrase = NSSecureTextField(); passphrase.placeholderString = current.encrypted ? "Frase (vacío conserva la actual)" : "Frase de al menos 8 caracteres"; passphrase.translatesAutoresizingMaskIntoConstraints = false; passphrase.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let passphraseRow = NSStackView(views: [NSTextField(labelWithString: "Frase"), passphrase]); passphraseRow.spacing = 8
        let intervalLabel = NSTextField(labelWithString: "Frecuencia"); let retentionLabel = NSTextField(labelWithString: "Conservar")
        let accessory = NSStackView(views: [enabled, NSStackView(views: [intervalLabel, interval]), NSStackView(views: [retentionLabel, retention]), encrypted, passphraseRow]); accessory.orientation = .vertical; accessory.alignment = .leading; accessory.spacing = 10
        let a = NSAlert(); a.messageText = "Backup de «\(r.name)»"; a.informativeText = "Nimbo copia la carpeta local a .Nimbo Backups en Google Drive. Podés cifrar nombres y contenido con una frase que Nimbo no puede recuperar; si la perdés, el backup no se puede restaurar. Nunca borra archivos de la carpeta sincronizada; al superar la retención elimina sólo snapshots antiguos creados por Nimbo."; a.accessoryView = accessory
        a.addButton(withTitle: "Guardar"); a.addButton(withTitle: "Cancelar")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        perform { try self.engine.setBackupSchedule(r.id, enabled: enabled.state == .on, intervalMinutes: interval.selectedTag(), retention: retention.selectedTag(), encrypted: encrypted.state == .on, passphrase: passphrase.stringValue.isEmpty ? nil : passphrase.stringValue) }
    }
    @objc private func togglePause() { if let r = selected() { perform { try self.engine.setPaused(r.id,!r.paused) } } }
    @objc private func cancel() { engine.cancel(); status.stringValue = "Deteniendo de forma segura…" }
    @objc private func openVersions() {
        let path = engine.root.appendingPathComponent("Versions")
        try? FileManager.default.createDirectory(at:path,withIntermediateDirectories:true)
        NSWorkspace.shared.open(path)
    }
    @objc private func restoreDriveBackup() {
        guard let relation = selected() else { return }
        var names: [String] = []
        perform({ names = try self.engine.remoteBackups(relation.id) }, onSuccess: {
            guard !names.isEmpty else { self.status.stringValue = "Todavía no hay respaldos disponibles para esta carpeta."; return }
            let picker = NSPopUpButton()
            let input = DateFormatter()
            input.locale = Locale(identifier: "en_US_POSIX")
            input.timeZone = TimeZone(secondsFromGMT: 0)
            input.dateFormat = "yyyyMMdd-HHmmss"
            for name in names.reversed() {
                let raw = String(name.prefix(15))
                let stamp = input.date(from: raw).map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .medium) } ?? raw
                picker.addItem(withTitle: name)
                picker.lastItem?.representedObject = name
                picker.lastItem?.title = stamp + (name.contains("-s") ? " · dividido" : "")
                picker.lastItem?.toolTip = name
            }
            let alert = NSAlert()
            alert.messageText = "Restaurar un respaldo de " + relation.name
            alert.informativeText = "Elegí la copia. Se restaurará en una carpeta nueva."
            alert.accessoryView = picker
            alert.addButton(withTitle: "Elegir destino…"); alert.addButton(withTitle: "Cancelar")
            guard alert.runModal() == .alertFirstButtonReturn, let name = picker.selectedItem?.representedObject as? String else { return }
            let save = NSSavePanel()
            save.nameFieldStringValue = relation.name + " recuperada"
            save.prompt = "Restaurar"
            guard save.runModal() == .OK, let destination = save.url else { return }
            self.perform({ try self.engine.restoreRemoteBackup(relation.id, snapshot: name, destination: destination) },
                         transferContext: (operation: "Restauración", relation: relation),
                         onSuccess: { NSWorkspace.shared.activateFileViewerSelecting([destination]) })
        })
    }
    @objc private func restoreVersion() {
        guard let r=selected() else{return}
        let panel=NSOpenPanel();panel.title="Elegí una versión conservada";panel.message="El archivo actual se conservará con un nombre de conflicto antes de restaurar.";panel.canChooseFiles=true;panel.canChooseDirectories=false;panel.allowsMultipleSelection=false;panel.canCreateDirectories=false;panel.prompt="Restaurar"
        panel.directoryURL=engine.root.appendingPathComponent("Versions/"+r.id.uuidString)
        guard panel.runModal() == .OK,let url=panel.url else{return}
        perform {try self.engine.restoreLocalBackup(r.id,url:url)}
    }
    @objc private func forget() {
        guard let r = selected() else { return }
        let a = NSAlert(); a.messageText = "Desvincular «\(r.name)»"; a.informativeText = "Dejará de sincronizarse. Se conservan los archivos locales, los de Drive y sus versiones."
        a.addButton(withTitle:"Desvincular"); a.addButton(withTitle:"Cancelar")
        if a.runModal() == .alertFirstButtonReturn { perform { try self.engine.forget(r.id) } }
    }
    @objc private func reviewDeletes() {
        guard let r = selected(), !r.pendingDeletes.isEmpty else { return }
        let a = NSAlert(); a.messageText = "Propagar \(r.pendingDeletes.count) borrados"
        a.informativeText = "Se eliminarán también del otro lado. Se conserva una copia en Versiones. Si cambió la lista, tendrás que revisarla otra vez.\n\n" + r.pendingDeletes.map { "Falta en \($0.missingFrom): \($0.path)" }.joined(separator:"\n")
        // A scrollable, selectable review supports large batches without hiding entries.
        let scroll = NSScrollView(frame:NSRect(x:0,y:0,width:580,height:240)); let text = NSTextView(frame:scroll.bounds)
        text.string = a.informativeText; text.isEditable = false; text.isVerticallyResizable = true; text.autoresizingMask = [.width]; scroll.documentView = text; scroll.hasVerticalScroller = true
        a.informativeText = "Revisá la lista completa antes de confirmar."; a.accessoryView = scroll
        a.addButton(withTitle:"Propagar borrados"); a.addButton(withTitle:"Conservar por ahora")
        if a.runModal() == .alertFirstButtonReturn { perform { try self.engine.synchronize(r.id,approving:r.pendingDeletes) } }
    }
}
