import AppKit

@MainActor final class SendController: NSObject, NSComboBoxDelegate, NSTextFieldDelegate {
    private let splitSize = NSPopUpButton()
    private let engine: CloudSendEngine
    private let config: URL
    private var window: NSWindow?
    private let account=NSPopUpButton(frame:.zero,pullsDown:false)
    private let folder=NSComboBox()
    private let fileSummary = NSTextField(labelWithString: "Ningún archivo elegido")
    private let cancelButton = NSButton(title: "Cancelar", target: nil, action: nil)
    private var panelStack: NSStackView?
    private let filesText=NSTextField(wrappingLabelWithString:"")
    private let permission=NSTextField(wrappingLabelWithString:"")
    private let status=NSTextField(wrappingLabelWithString:"")
    private let pendingLabel=NSTextField(wrappingLabelWithString:"")
    private let bar=NSProgressIndicator()
    private let choose=NSButton(title:"Elegir archivos…",target:nil,action:nil)
    private let sendButton=NSButton(title:"Enviar",target:nil,action:nil)
    private let retryButton=NSButton(title:"Reintentar pendientes",target:nil,action:nil)
    private let stopButton=NSButton(title:"Detener",target:nil,action:nil)
    private var files:[URL]=[], entries:[RemoteEntry]=[], aliases:[String:String]=[:]
    private var destinations:[(path:String,id:String)]=[]
    private var pending:[SendTicket]=[]
    private var task:Task<Void,Never>?
    private var activeID:UUID?
    private var permissionGeneration=UUID()
    private var writable=false
    private(set) var isRunning=false
    var onCompleted: ((String)->Void)?
    var onTransfers: (()->Void)?
    init(config:URL,root:URL) {
        self.config=config
        engine=CloudSendEngine(root:root) { remote in GoogleSendService(config:config,remote:remote) }
        super.init()
    }
    func show(accounts:[String:String],entries:[RemoteEntry],selected:String?) {
        if window==nil { build() }
        if !isRunning {
            aliases=accounts; self.entries=entries
            account.setDriveAccounts(accounts.keys.sorted().map { ($0, accounts[$0] ?? $0) }, selected: selected)
            accountChanged(); reloadPending()
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    func raiseIfVisible() -> Bool {
        guard let window, window.isVisible else { return false }
        window.makeKeyAndOrderFront(nil)
        return true
    }
    private var remote:String? { account.selectedItem?.representedObject as? String }
    private var destination:SendDestination? {
        guard let remote, let value=destinations.first(where:{$0.path==folder.stringValue}) else { return nil }
        return SendDestination(remote:remote,folderID:value.id,path:value.path)
    }
    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 340),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Enviar a Nimbo"
        w.isReleasedWhenClosed = false
        NimboWindowStyle.applyDialog(to: w)
        let heading = NSTextField(labelWithString: "Enviar a Nimbo")
        heading.font = .systemFont(ofSize: 24, weight: .bold)
        fileSummary.font = .systemFont(ofSize: 14, weight: .semibold)
        filesText.maximumNumberOfLines = 2
        filesText.lineBreakMode = .byTruncatingTail
        filesText.textColor = .secondaryLabelColor
        folder.delegate = self
        folder.completes = true
        folder.numberOfVisibleItems = 12
        folder.placeholderString = "Buscar carpeta…"
        folder.setAccessibilityLabel("Carpeta de destino")
        account.setAccessibilityLabel("Cuenta de destino")
        account.target = self
        account.action = #selector(accountChanged)
        permission.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 3
        pendingLabel.maximumNumberOfLines = 2
        choose.target = self
        choose.action = #selector(chooseFiles)
        cancelButton.target = self
        cancelButton.action = #selector(cancelSelection)
        cancelButton.keyEquivalent = "\u{1b}"
        sendButton.target = self
        sendButton.action = #selector(sendFiles)
        sendButton.bezelColor = .systemBlue
        sendButton.keyEquivalent = "\r"
        retryButton.target = self
        retryButton.action = #selector(retryPending)
        stopButton.target = self
        stopButton.action = #selector(stop)
        let transfers = NSButton(title: "Transferencias", target: self, action: #selector(showTransfers))
        for button in [choose, sendButton, retryButton, stopButton, transfers, cancelButton] { button.bezelStyle = .rounded }
        let selection = NSStackView(views: [fileSummary, NSView(), choose])
        let to = NSStackView(views: [NSTextField(labelWithString: "Destino"), account, folder])
        account.widthAnchor.constraint(equalToConstant: 160).isActive = true
        folder.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [transfers, retryButton, NSView(), stopButton, cancelButton, sendButton])
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        for size in SyncSettings.segmentSizes {
            splitSize.addItem(withTitle: SyncSettings.segmentLabel(size))
            splitSize.lastItem?.tag = size
        }
        splitSize.selectItem(withTag: UserDefaults.standard.integer(forKey: "NimboSendSegmentMB"))
        splitSize.target = self
        splitSize.action = #selector(splitSizeChanged)
        splitSize.setAccessibilityLabel("Dividir archivos de este envío")
        splitSize.toolTip = "Los archivos mayores al valor elegido se guardan en partes en Drive. Finder los muestra como un solo archivo."
        let splitRow = NSStackView(views: [NSTextField(labelWithString: "Dividir archivos grandes"), splitSize, NSView()])
        let root = NSStackView(views: [heading, selection, filesText, to, splitRow, permission, bar, status, pendingLabel, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        w.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: w.contentView!.topAnchor, constant: 20)
        ])
        for row in root.arrangedSubviews { row.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        panelStack = root
        window = w
        updateControls()
        w.center()
    }
    @objc private func splitSizeChanged() {
        UserDefaults.standard.set(splitSize.selectedTag(), forKey: "NimboSendSegmentMB")
    }
    private func updateControls() {
        splitSize.isEnabled = !isRunning
        choose.isEnabled = !isRunning
        account.isEnabled = !isRunning
        folder.isEnabled = !isRunning
        sendButton.isEnabled = !isRunning && writable && !files.isEmpty && destination != nil
        stopButton.isHidden = !isRunning
        cancelButton.isHidden = isRunning
        bar.isHidden = !isRunning
        retryButton.isHidden = pending.isEmpty
        retryButton.isEnabled = !isRunning
        filesText.isHidden = filesText.stringValue.isEmpty
        pendingLabel.isHidden = pendingLabel.stringValue.isEmpty
        status.isHidden = status.stringValue.isEmpty
        if let window, let panelStack {
            window.contentView?.layoutSubtreeIfNeeded()
            let height = max(226, ceil(panelStack.fittingSize.height) + 42)
            var frame = window.frame
            let difference = height - (window.contentView?.bounds.height ?? height)
            if abs(difference) > 1 {
                frame.origin.y -= difference
                frame.size.height += difference
                window.setFrame(frame, display: true)
            }
        }
    }
    @objc private func cancelSelection() {
        guard !isRunning else { return }
        files = []
        filesText.stringValue = ""
        filesText.toolTip = nil
        fileSummary.stringValue = "Ningún archivo elegido"
        status.stringValue = ""
        window?.orderOut(nil)
        updateControls()
    }
    @objc private func accountChanged() {
        destinations=[("Mi unidad","root")]
        if let remote {
            let folders=entries.filter{$0.remote==remote && $0.item.IsDir && $0.item.ID?.isEmpty==false}.sorted{$0.item.Path.localizedStandardCompare($1.item.Path) == .orderedAscending}
            // Ambiguous paths must not silently choose one of two Google IDs.
            let counts=Dictionary(grouping:folders,by:{$0.item.Path})
            destinations += folders.compactMap { counts[$0.item.Path]?.count == 1 ? ($0.item.Path,$0.item.ID!) : nil }
        }
        folder.removeAllItems(); folder.addItems(withObjectValues:destinations.map(\.path)); folder.selectItem(at:0); folder.stringValue="Mi unidad"
        writable=false; permission.stringValue="Comprobando permisos…"; updateControls()
        let generation=UUID(); permissionGeneration=generation
        guard let remote else { permission.stringValue="Primero conectá una cuenta de Google Drive."; return }
        Task { [weak self] in
            guard let self else { return }
            let permitted=(try? await DriveAPI(configuration:config,remoteName:remote).permitsWrites()) == true
            guard permissionGeneration==generation else { return }
            writable=permitted
            permission.stringValue=permitted ? "Se enviarán copias; tus archivos originales quedan en el Mac." : "Esta cuenta es de sólo lectura. Reconectala con permiso de sincronización para enviar archivos."
            updateControls()
        }
    }
    func comboBoxSelectionDidChange(_ notification:Notification) { DispatchQueue.main.async { [weak self] in self?.updateControls() } }
    func controlTextDidChange(_ notification:Notification) { updateControls() }
    @objc private func chooseFiles() {
        guard !isRunning else { return }
        let picker=NSOpenPanel(); picker.title="Archivos para enviar a Google Drive"; picker.prompt="Elegir"; picker.canChooseFiles=true; picker.canChooseDirectories=false; picker.allowsMultipleSelection=true
        guard picker.runModal() == .OK else { return }
        do { try useSelection(picker.urls) }
        catch { status.stringValue = error.localizedDescription; updateControls() }
    }
    func useSelection(_ urls: [URL]) throws {
        guard !isRunning, !urls.isEmpty else { throw CocoaError(.userCancelled) }
        var selected: [URL] = []
        var seen = Set<URL>()
        var total: Int64 = 0
        var sizeKnown = true
        for url in urls {
            let file = url.standardizedFileURL
            guard seen.insert(file).inserted else { continue }
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard file.isFileURL, info.isRegularFile == true, info.isSymbolicLink != true else {
                throw NSError(domain: "NimboSend", code: 1, userInfo: [NSLocalizedDescriptionKey: "Seleccioná archivos individuales. La selección incluye una carpeta o un enlace."])
            }
            selected.append(file)
            if let size = info.fileSize { total += Int64(size) } else { sizeKnown = false }
        }
        files = selected
        let count = files.count == 1 ? "1 archivo" : "\(files.count) archivos"
        fileSummary.stringValue = sizeKnown ? count + " · " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file) : count
        filesText.stringValue = files.map(\.lastPathComponent).joined(separator: ", ")
        filesText.toolTip = files.map(\.path).joined(separator: "\n")
        status.stringValue = ""
        updateControls()
    }
    private func reloadPending() {
        Task { [weak self] in
            guard let self else { return }
            do {
                pending=try await engine.pending()
                pendingLabel.stringValue=pending.isEmpty ? "" : "\(pending.count) envío(s) pendiente(s). Podés reintentarlos con su destino original."
                pendingLabel.toolTip=pending.map{(aliases[$0.destination.remote] ?? $0.destination.remote)+" / "+$0.destination.path+" / "+$0.name}.joined(separator:"\n")
            } catch { pendingLabel.stringValue="No se pudieron leer los envíos pendientes: "+error.localizedDescription }
            updateControls()
        }
    }
    @objc private func sendFiles() { guard let destination,!files.isEmpty,writable else { return }; run(files:files,destination:destination,tickets:[]) }
    @objc private func retryPending() { run(files:[],destination:nil,tickets:pending) }
    private func run(files:[URL],destination:SendDestination?,tickets:[SendTicket]) {
        guard !isRunning else { return }
        // Consume this selection once. Prepared jobs keep their original IDs and
        // destinations; only Retry may resume them after failure or cancellation.
        if destination != nil {
            self.files=[]; filesText.toolTip=nil
            fileSummary.stringValue = "Envío de archivos"
            filesText.stringValue="Preparando \(files.count) archivo(s). Los envíos pendientes se recuperan con «Reintentar pendientes»."
        }
        isRunning=true; bar.doubleValue=0; status.stringValue="Preparando envío…"; updateControls()
        task=Task { [weak self] in
            guard let self else { return }
            do {
                let work: [SendTicket]
                if let destination { work=try await engine.prepare(files:files,destination:destination,segmentMB:splitSize.selectedTag()) } else { work=tickets }
                var completed=0
                for ticket in work {
                    try Task.checkCancellation(); activeID=ticket.id; bar.doubleValue=0
                    status.stringValue="Enviando \(ticket.name)…"
                    _ = try await engine.send(ticket.id) { [weak self] bytes,total in
                        Task { @MainActor in
                            guard let self,self.isRunning,self.activeID==ticket.id else { return }
                            self.bar.doubleValue=total>0 ? Double(bytes)/Double(total):0
                            self.status.stringValue="\(ticket.name) · \(ByteCountFormatter.string(fromByteCount:bytes,countStyle:.file)) de \(ByteCountFormatter.string(fromByteCount:total,countStyle:.file))"
                        }
                    }
                    completed+=1; onCompleted?(ticket.destination.remote)
                }
                bar.doubleValue=1; status.stringValue="\(completed) archivo(s) enviado(s) y comprobado(s) en Google Drive."
                if destination != nil { filesText.stringValue="Elegí archivos para realizar otro envío." }
            } catch is CancellationError {
                status.stringValue="Envío detenido. Usá «Reintentar pendientes» para continuar los archivos preparados."
                if destination != nil { filesText.stringValue="Tus originales siguen en el Mac. Los archivos que no llegaron a prepararse se pueden elegir otra vez." }
            }
            catch {
                status.stringValue="No se completó el envío: "+error.localizedDescription
                if destination != nil { filesText.stringValue="Reintentá los pendientes antes de elegir otra vez estos archivos. Tus originales siguen en el Mac." }
            }
            activeID=nil; isRunning=false; task=nil; fileSummary.stringValue = "Ningún archivo elegido"; updateControls(); reloadPending()
        }
    }
    @objc func stop() { task?.cancel() }
    @objc private func showTransfers() { onTransfers?() }
}
