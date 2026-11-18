import AppKit
import FileProvider
import notify

/// UI and orchestration only. The sandboxed extension owns metadata and cloud IO.
final class NativeController:NSObject {
    let client:NativeClient, config:URL
    private let enabledKey:String
    private var window:NSWindow?
    private let message=NSTextField(wrappingLabelWithString:"Activá Google Drive para ver sus carpetas en Finder. El contenido se descarga cuando abrís un archivo.")
    private let selected=NSTextField(wrappingLabelWithString:"")
    private let activate=NSButton(title:"Activar archivos bajo demanda",target:nil,action:nil)
    private let open=NSButton(title:"Abrir carpeta en Finder",target:nil,action:nil)
    private let keep=NSButton(title:"Conservar archivo sin conexión",target:nil,action:nil)
    private let release=NSButton(title:"Liberar espacio del archivo",target:nil,action:nil)
    private let downloadLimit=NSPopUpButton(frame:.zero,pullsDown:false)
    private let reveal=NSButton(title:"Mostrar archivo en Finder",target:nil,action:nil)
    private let conflicts=NSButton(title:"Revisar conflictos",target:nil,action:nil)
    private let deactivate=NSButton(title:"Desactivar carpeta en Finder",target:nil,action:nil)
    private var busy=false
    /// True only after a real Google Drive query succeeded (configure reads the
    /// Drive root, change anchor and scopes). Revalidated every 5 minutes.
    private(set) var connected=false
    private(set) var lastConnectionError:String?
    private var refreshTicks=0
    private var timer:Timer?
    private var availabilityTask:Task<Void,Never>?
    private let automatic:NativeAutoUnsync
    private let autoEnable=NSButton(checkboxWithTitle:"Liberar automáticamente archivos sin uso",target:nil,action:nil)
    private let autoAge=NSPopUpButton(frame:.zero,pullsDown:false)
    private let autoRun=NSButton(title:"Revisar ahora",target:nil,action:nil)
    private let autoMessage=NSTextField(wrappingLabelWithString:"Liberación automática desactivada.")
    private var autoBusy=false
    private var autoTask:Task<Void,Never>?
    var selection:(()->(id:String,name:String,isFolder:Bool)?)?
    var onConnected:(()->Void)?
    var onAutoReport:((NativeAutoUnsyncReport)->Void)?
    private var finderPathMapKey:String { "NimboFinderPathIDs." + client.domain.identifier.rawValue.replacingOccurrences(of:"/",with:"_") }
    init(config:URL,client:NativeClient=NativeClient()) {
        self.config=config;self.client=client
        self.enabledKey="NimboNativeEnabled."+client.domain.identifier.rawValue.replacingOccurrences(of:"/",with:"_")
        let support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        let domain=client.domain.identifier.rawValue.replacingOccurrences(of:"/",with:"_")
        automatic=NativeAutoUnsync(file:support.appendingPathComponent("Nimbo/AutoUnsync-"+domain+".json"),source:client)
        super.init()
        var token:Int32=0
        notify_register_dispatch(nimboMaterializeNotification,&token,DispatchQueue.main){ [weak self] _ in
            guard let client=self?.client else { return }
            Task { await client.materializePending() }
        }
        var evictionToken:Int32=0
        notify_register_dispatch(nimboEvictionFailedNotification,&evictionToken,DispatchQueue.main){ [weak self] _ in
            guard let client=self?.client else { return }
            Task {
                guard let messages=try? await client.takeEvictionMessages(), !messages.isEmpty else { return }
                await MainActor.run {
                    let alert=NSAlert()
                    alert.messageText="No se liberó espacio"
                    alert.informativeText=messages.joined(separator:"\n\n")
                    alert.alertStyle = .warning
                    NSApp.activate(ignoringOtherApps:true)
                    alert.runModal()
                }
            }
        }
    }
    func show() {
        if window==nil {build()}; loadAutomatic();update(); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    private var bandwidthUpdate: Task<Void, Never>?

    /// Shows or hides «Copiar enlace» and «Abrir vista web» in Finder's menu.
    func applyLinkActions() {
        let enabled = UserDefaults.standard.bool(forKey: "NimboShowLinkActions")
        Task {
            let _: Bool? = try? await client.call { proxy, done in
                proxy.setShowLinkActions(enabled) { error in done(error.map { .failure($0) } ?? .success(true)) }
            }
        }
    }
    @MainActor func refreshTransferLimits() {
        guard connected else { return }
        let previous = bandwidthUpdate
        bandwidthUpdate = Task {
            await previous?.value
            let settings = SyncSettings.read(at: SyncSettings.file(for: config))
            do {
                let _: Bool = try await client.call { proxy, done in
                    proxy.setFinderTransferSettings(download: settings.downloadKBps, upload: settings.uploadKBps, segmentMB: settings.finderSegmentMB) { error in
                        done(error.map { .failure($0) } ?? .success(true))
                    }
                }
            } catch {
                message.stringValue = "Finder no pudo aplicar los ajustes de transferencia. Nimbo volverá a intentarlo. " + readable(error)
            }
        }
    }

    func restore() {
        let legacy = client.rootID == nil && UserDefaults.standard.bool(forKey:"NimboNativeEnabled")
        NSLog("Nimbo restore %@ enabled=%d", enabledKey, UserDefaults.standard.bool(forKey:enabledKey) ? 1 : 0)
        if UserDefaults.standard.bool(forKey:enabledKey) || legacy { connect(reimport:false) }
    }
    /// Apply an automatic unsync preset from the menu bar without requiring
    /// the settings window. `nil` disables the policy; otherwise the value is
    /// the inactivity age in days (1, 7 or 30).
    func configureAutomaticUnsync(days: Int?) {
        let enabled = days != nil
        let value = days ?? 7
        Task {
            do {
                try await automatic.configure(enabled: enabled, days: value)
                await MainActor.run {
                    self.autoEnable.state = enabled ? .on : .off
                    self.autoAge.selectItem(withTag: value)
                    self.autoMessage.stringValue = enabled ? "Activada. Se liberarán copias después de \(value) días sin uso." : "Liberación automática desactivada."
                    self.update()
                }
            } catch {
                await MainActor.run { self.autoMessage.stringValue = self.readable(error) }
            }
        }
    }
    private func build() {
        let w=NSWindow(contentRect:NSRect(x:0,y:0,width:710,height:700),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        w.title="Nimbo · \(client.domain.displayName) bajo demanda"; w.center(); w.isReleasedWhenClosed=false; window=w
        let title=NSTextField(labelWithString:"\(client.domain.displayName) en Finder")
        title.font = .systemFont(ofSize:24,weight:.semibold)
        let detail=NSTextField(wrappingLabelWithString:"Navegá sin descargar todo. Abrí un archivo para descargarlo, conservalo para usarlo sin internet o liberá su copia local cuando termines.\n\nEn Finder también podés hacer clic derecho sobre un archivo de Google Drive para conservarlo sin conexión o desincronizarlo y liberar espacio.\n\nCon permiso de sincronización, podés crear, editar y mover archivos desde Finder. Los borrados van a la papelera de Google Drive. Si hay cambios simultáneos, Nimbo guarda una copia con «conflicto Mac». Los documentos de Google se abren en el navegador.")
        detail.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize:13,weight:.medium)
        selected.font = .systemFont(ofSize:13)
        let pairs:[(NSButton,Selector)]=[(activate,#selector(connectFromButton)),(open,#selector(openRoot)),(keep,#selector(pinSelected)),(release,#selector(evictSelected)),(reveal,#selector(revealSelected)),(conflicts,#selector(reviewConflicts)),(deactivate,#selector(disconnect))]
        for (button,action) in pairs {button.target=self; button.action=action; button.bezelStyle = .rounded}
        let row=NSStackView(views:[activate,open]); row.spacing=12
        let actions=NSStackView(views:[keep,release]); actions.spacing=12
        for (title,tag) in [("Sin límite",-1),("100 MiB",100*1024*1024),("500 MiB",500*1024*1024),("1 GiB",1024*1024*1024),("2 GiB",2*1024*1024*1024)] {
            downloadLimit.addItem(withTitle:title); downloadLimit.lastItem?.tag=tag
        }
        downloadLimit.selectItem(withTag:-1)
        let limitLabel=NSTextField(labelWithString:"Límite de descarga al conservar una carpeta")
        let limitRow=NSStackView(views:[limitLabel,downloadLimit]); limitRow.spacing=12
        let limitDetail=NSTextField(wrappingLabelWithString:"Los archivos que superen el límite permanecen como placeholders. Los hijos conservados explícitamente siguen teniendo prioridad.")
        limitDetail.textColor = .secondaryLabelColor; limitDetail.font = .systemFont(ofSize:12)
        autoEnable.target=self;autoEnable.action=#selector(saveAutomatic)
        for days in [1,7,30] {autoAge.addItem(withTitle:days==1 ? "1 día" : "\(days) días");autoAge.lastItem?.tag=days}
        autoAge.selectItem(withTag:7);autoAge.target=self;autoAge.action=#selector(saveAutomatic)
        autoRun.target=self;autoRun.action=#selector(reviewNow);autoRun.bezelStyle = .rounded
        let autoRow=NSStackView(views:[autoAge,autoRun]);autoRow.spacing=12
        let autoDetail=NSTextField(wrappingLabelWithString:"Cuenta desde la primera revisión y el último acceso, cambio o descarga detectados. Se revisa mientras Nimbo está abierto; respeta los archivos conservados sin conexión y los cambios pendientes.")
        autoDetail.textColor = .secondaryLabelColor;autoDetail.font = .systemFont(ofSize:12)
        autoMessage.font = .systemFont(ofSize:12)
        let root=NSStackView(views:[title,detail,row,message,selected,actions,limitRow,limitDetail,reveal,conflicts,autoEnable,autoRow,autoDetail,autoMessage,deactivate]); root.orientation = .vertical; root.alignment = .leading; root.spacing=18
        root.translatesAutoresizingMaskIntoConstraints=false; w.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:w.contentView!.leadingAnchor,constant:24),root.trailingAnchor.constraint(equalTo:w.contentView!.trailingAnchor,constant:-24),root.topAnchor.constraint(equalTo:w.contentView!.topAnchor,constant:24)])
        for view in [detail,message,selected,limitDetail,autoDetail,autoMessage] {view.widthAnchor.constraint(equalTo:root.widthAnchor).isActive=true}
    }
    func update() {
        let item=selection?()
        selected.stringValue=item.map{"Seleccionado en Nimbo: "+$0.name} ?? "Seleccioná un archivo o carpeta en la ventana principal para conservarlo o liberar espacio."
        activate.isEnabled = !busy; open.isEnabled = connected && !busy
        activate.title=connected ? "Actualizar conexión" : "Activar archivos bajo demanda"
        keep.title=item?.isFolder==true ? "Conservar carpeta sin conexión" : "Conservar archivo sin conexión"
        release.title=item?.isFolder==true ? "Liberar espacio de la carpeta" : "Liberar espacio del archivo"
        keep.isEnabled = connected && !busy && item != nil
        release.isEnabled = false; reveal.isEnabled = connected && !busy && item != nil; conflicts.isEnabled = connected && !busy
        downloadLimit.isEnabled = connected && !busy && item?.isFolder == true
        deactivate.isEnabled = !busy
        autoRun.isEnabled=connected && !busy && !autoBusy && autoEnable.state == .on
        autoAge.isEnabled=autoEnable.state == .on
        availabilityTask?.cancel()
        guard let item, keep.isEnabled else { return }
        availabilityTask=Task { [weak self] in
            guard let client=self?.client else { return }
            let available=(try? await client.localAvailability(item.id)) != nil
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.selection?()?.id == item.id, self.connected, !self.busy else { return }
                self.release.isEnabled=available
                if !available { self.release.title="Ya está sólo en la nube" }
            }
        }
    }
    private func run(_ pending:String,_ operation:@escaping () async throws->String) {
        guard !busy else{return};autoTask?.cancel(); busy=true; message.stringValue=pending; message.textColor = .secondaryLabelColor; update()
        Task {
            do {let result=try await operation(); await MainActor.run{self.message.stringValue=result; self.busy=false; self.update()}}
            catch {await MainActor.run{self.message.stringValue=self.readable(error); self.message.textColor = .systemOrange; self.busy=false; if pending.hasPrefix("Preparando") { NSLog("Nimbo connect failed: %@", String(describing:error)); UserDefaults.standard.set("connect: "+String(describing:error),forKey:"NimboLastConnectionErrorDetail"); self.connected=false; self.lastConnectionError=self.readable(error) }; self.update()}}
        }
    }
    func readable(_ error:Error)->String {
        let e=error as NSError
        if e.domain==NSFileProviderErrorDomain && [-2001,-2013,-2011].contains(e.code) {return "Finder todavía no habilitó Nimbo. Abrí Finder y activá Nimbo si macOS lo solicita; después pulsá Activar archivos bajo demanda."}
        if e.domain==NSFileProviderErrorDomain && e.code == NSFileProviderError.notAuthenticated.rawValue {return "Renová la autorización en Cuenta de Google Drive y volvé a activar esta conexión."}
        if e.domain==NSFileProviderErrorDomain && [-2008,-2009].contains(e.code) {return "El archivo aún está en uso o conservado sin conexión. Cerralo y volvé a intentar liberar espacio."}
        if e.domain==NSFileProviderErrorDomain && e.code == NSFileProviderError.unsyncedEdits.rawValue {return "El archivo tiene cambios locales pendientes. Guardá y cerrá el archivo, esperá su sincronización y volvé a intentar desincronizarlo; Nimbo conserva la copia local para no perder esos cambios."}
        if e.domain==NSFileProviderErrorDomain && e.code==NSFileProviderError.nonEvictableChildren.rawValue {return "Liberación parcial: quedan archivos abiertos, con cambios pendientes o conservados por separado. Cerrá los archivos, esperá su sincronización o liberá su preferencia individual antes de reintentar."}
        if e.domain==NSPOSIXErrorDomain && e.code==16 {return "El archivo está abierto. Cerralo antes de liberar su copia local."}
        if e.domain==NSCocoaErrorDomain && [4097,4099,4101].contains(e.code) {return "macOS reinició la conexión. Volvé a intentar la operación."}
        return e.localizedDescription
    }
    @objc func connectFromButton() { connect(reimport:true) }
    /// `reimport` asks macOS to re-scan the whole domain. Only an explicit user
    /// "Actualizar conexión" does that; automatic launches must not, because a
    /// full re-import re-submits every local item and used to create copies.
    func connect(reimport:Bool) {
        run("Preparando Google Drive en Finder…") {
            #if NIMBO_TESTING
            if ProcessInfo.processInfo.environment["NIMBO_NATIVE_FIXTURE"]=="1" {try await self.client.configureFixture()}
            else {try await self.client.configure(Data(contentsOf:self.config))}
            #else
            guard NimboSecureConfig.ensureRuntime(self.config) else { throw NSError(domain:NSFileProviderErrorDomain,code:NSFileProviderError.notAuthenticated.rawValue,userInfo:[NSLocalizedDescriptionKey:"No se encontró la autorización de Google Drive. Reconectá la cuenta en Cuentas autorizadas."]) }
            try await self.client.configure(Data(contentsOf:self.config))
            #endif
            let writable=try await self.client.isWritable()
            if reimport { await self.client.reimportMetadata() }
            await MainActor.run {
                self.connected=true; self.lastConnectionError=nil; UserDefaults.standard.set(true,forKey:self.enabledKey)
                self.timer?.invalidate(); self.timer=Timer.scheduledTimer(withTimeInterval:60,repeats:true){[weak self] _ in self?.backgroundRefresh()}
                self.refreshTransferLimits()
                self.onConnected?()
            }
            Task { await self.client.materializePending() }
            self.applyLinkActions()
            // Filled cloud on this account's Finder folder (sidebar and windows).
            Task { if let url = try? await self.client.location() { await MainActor.run {
                NimboFinderIcon.apply(to: url)
                // Finder sidebar: "Mi Google Drive" / "Cuenta 2" with a cloud, not the folder name.
                var name = self.client.domain.displayName.replacingOccurrences(of: "Google Drive · ", with: "")
                if name == "GoogleDrive" || name.isEmpty { name = "Mi Google Drive" }
                NimboFinderIcon.addToSidebar(url, name: name)
            } } }
            return writable ? "Google Drive conectado con sincronización. Los cambios de Finder se suben a la nube." : "Google Drive conectado en modo de lectura. Activá Permitir sincronización en Cuenta de Google Drive para subir cambios."
        }
    }
    private func loadAutomatic() {
        Task {
            do {
                let settings=try await automatic.settings(),report=try await automatic.lastReport()
                await MainActor.run {
                    self.autoEnable.state=settings.enabled ? .on:.off;self.autoAge.selectItem(withTag:settings.days)
                    self.autoMessage.stringValue=settings.enabled ? (report?.message ?? "Se revisará automáticamente cada minuto.") : "Liberación automática desactivada."
                    self.update()
                }
            }catch{await MainActor.run{self.autoMessage.stringValue=self.readable(error)}}
        }
    }
    @objc private func saveAutomatic() {
        let enabled=autoEnable.state == .on,days=autoAge.selectedTag()
        Task {
            do{try await automatic.configure(enabled:enabled,days:days);await MainActor.run{self.autoMessage.stringValue=enabled ? "Activada. Los archivos recién observados tendrán el plazo completo antes de liberarse." : "Liberación automática desactivada.";self.update()}}
            catch{await MainActor.run{self.autoMessage.stringValue=self.readable(error);self.loadAutomatic()}}
        }
    }
    private func backgroundRefresh(){
        client.signalChanges();reviewAutomatic()
        Task { await self.client.materializePending() }
        refreshTicks += 1
        if refreshTicks % 5 == 0 { revalidate() }
    }
    /// Silent connection check: regenerates the runtime if needed and queries
    /// Drive again, so the menu never claims "conectado" after Drive stopped
    /// answering, and a temporary failure recovers without user action.
    func revalidate() {
        guard !busy else { return }
        Task {
            do {
                guard NimboSecureConfig.ensureRuntime(self.config) else { throw DriveFailure.notAuthenticated }
                try await self.client.configure(Data(contentsOf:self.config))
                await MainActor.run { self.connected=true; self.lastConnectionError=nil; self.refreshTransferLimits(); self.update() }
            } catch {
                NSLog("Nimbo revalidate failed: %@", String(describing:error)); UserDefaults.standard.set("revalidate: "+String(describing:error),forKey:"NimboLastConnectionErrorDetail"); await MainActor.run { self.connected=false; self.lastConnectionError=self.readable(error); self.update() }
            }
        }
    }
    @objc private func reviewNow(){reviewAutomatic()}
    private func reviewAutomatic() {
        guard connected,!busy,!autoBusy else{return}
        autoBusy=true;update()
        autoTask=Task {
            do{
                var now=Date()
                #if NIMBO_TESTING
                if ProcessInfo.processInfo.environment["NIMBO_NATIVE_FIXTURE"]=="1",let text=ProcessInfo.processInfo.environment["NIMBO_AUTO_TEST_ADVANCE_SECONDS"],let advance=Double(text){now=now.addingTimeInterval(advance)}
                #endif
                let report=try await automatic.run(now:now);await MainActor.run{self.autoMessage.stringValue=report.message;self.onAutoReport?(report)}
            }
            catch is CancellationError {}
            catch{await MainActor.run{self.autoMessage.stringValue="No se pudo completar la revisión: "+self.readable(error)}}
            await MainActor.run{self.autoBusy=false;self.autoTask=nil;self.update()}
        }
    }
    private func openLocation(_ id:String?,reveal:Bool) async throws {
        let url=try await client.location(id)
        await MainActor.run {
            let access=url.startAccessingSecurityScopedResource(); defer{if access{url.stopAccessingSecurityScopedResource()}}
            if reveal {NSWorkspace.shared.activateFileViewerSelecting([url])} else {NSWorkspace.shared.open(url)}
        }
    }
    @objc func openRoot() {run("Abriendo Finder…"){try await self.openLocation(nil,reveal:false); return "Tus archivos se descargan al abrirlos."}}
    @objc func revealSelected() {guard let item=selection?() else{return}; run("Buscando archivo en Finder…"){try await self.openLocation(item.id,reveal:true); return "Archivo mostrado en Finder."}}
    @objc func pinSelected() {
        guard let item=selection?() else{return}
        let limit: Int64? = item.isFolder && downloadLimit.selectedTag() >= 0 ? Int64(downloadLimit.selectedTag()) : nil
        run("Preparando disponibilidad sin conexión…") {
            try await self.client.pin(item.id,true,limit:limit)
            if item.isFolder, let limit {
                let mib=limit / (1024*1024)
                return "Conservación activada para \(item.name) hasta \(mib) MiB por archivo. Los archivos mayores quedan como placeholders."
            }
            return item.isFolder ? "Conservación activada para \(item.name) y sus descendientes, salvo preferencias individuales. Finder descargará el contenido; comprobá que termine antes de desconectarte." : "Conservación activada para \(item.name). Finder descargará el archivo; comprobá que termine antes de desconectarte de internet."
        }
    }
    @objc func evictSelected() {
        guard let item=selection?() else{return}
        run("Liberando copia local…") {
            try await self.client.evict(item.id)
            return "Espacio liberado: \(item.name). El contenido sigue en Google Drive."
        }
    }
    /// Resolve once. An error from the actual file action must reach Finder
    /// without repeating the operation or scanning every file in the account.
    private func finderID(for path: String, allowMissing: Bool = true) async throws -> String? {
        let target = URL(fileURLWithPath: path).standardizedFileURL
        do {
            let resolved = try await client.identifierForUserVisibleFile(target)
            guard resolved.domain == client.domain.identifier.rawValue else { return nil }
            rememberFinderID(resolved.id, for: target)
            return resolved.id
        } catch let error as NSError where !allowMissing && error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            return nil
        } catch {
            // Some placeholders temporarily lack a direct path-to-ID mapping.
        }
        let targetPath = Self.normalizedFinderPath(target)
        if let cached = rememberedFinderID(for: target) {
            if let visible = try? await client.location(cached), Self.normalizedFinderPath(visible) == targetPath {
                return cached
            }
            forgetFinderID(for: target)
        }
        var cursor: String?
        var seen = Set<String>()
        repeat {
            let page = try await client.availabilityPage(after: cursor)
            for candidate in page.items {
                if let visible = try? await client.location(candidate.id), Self.normalizedFinderPath(visible) == targetPath {
                    rememberFinderID(candidate.id, for: target)
                    return candidate.id
                }
            }
            cursor = page.next
            if let cursor, !seen.insert(cursor).inserted { throw DriveFailure.invalidResponse }
        } while cursor != nil
        return nil
    }

    func evictPath(_ path: String) async throws -> Bool {
        guard let id = try await finderID(for: path, allowMissing: false) else { return false }
        try await client.evict(id)
        return true
    }

    func syncPath(_ path: String) async throws -> Bool {
        guard let id = try await finderID(for: path) else { return false }
        try await client.downloadNow(id)
        return true
    }

    func pinPath(_ path: String, limit: Int64? = nil) async throws -> Bool {
        guard let id = try await finderID(for: path) else { return false }
        try await client.pin(id, true, limit: limit)
        return true
    }
    /// Creates an explicit Google Drive anyone-with-link reader permission
    /// after the app has shown its consent alert. The Finder extension never
    /// receives OAuth credentials or mutates Drive directly.
    func shareLinkPath(_ path: String, expectedDomain: String? = nil, expectedID: String? = nil) async throws -> String? {
        guard expectedDomain == nil || expectedDomain == client.domain.identifier.rawValue else { return nil }
        let target = URL(fileURLWithPath: path).standardizedFileURL
        let resolved = try await client.identifierForUserVisibleFile(target)
        guard resolved.domain == client.domain.identifier.rawValue else { return nil }
        guard expectedID == nil || resolved.id == expectedID else { throw DriveFailure.invalidResponse }
        let id = resolved.id == NSFileProviderItemIdentifier.rootContainer.rawValue ? (client.rootID ?? "root") : resolved.id
        return try await DriveAPI(configuration: config, remoteName: client.remoteName).createPublicLink(id)
    }
    func revokeSharePath(_ path: String, expectedDomain: String? = nil, expectedID: String? = nil) async throws -> Int? {
        guard expectedDomain == nil || expectedDomain == client.domain.identifier.rawValue else { return nil }
        let target = URL(fileURLWithPath: path).standardizedFileURL
        let resolved = try await client.identifierForUserVisibleFile(target)
        guard resolved.domain == client.domain.identifier.rawValue else { return nil }
        guard expectedID == nil || resolved.id == expectedID else { throw DriveFailure.invalidResponse }
        let id = resolved.id == NSFileProviderItemIdentifier.rootContainer.rawValue ? (client.rootID ?? "root") : resolved.id
        return try await DriveAPI(configuration: config, remoteName: client.remoteName).revokePublicLinks(id)
    }
    private static func normalizedFinderPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping
    }
    private func rememberFinderID(_ id:String,for url:URL) {
        var values=UserDefaults.standard.dictionary(forKey:finderPathMapKey) as? [String:String] ?? [:]
        values[Self.normalizedFinderPath(url)]=id
        UserDefaults.standard.set(values,forKey:finderPathMapKey)
    }
    private func rememberedFinderID(for url:URL)->String? {
        (UserDefaults.standard.dictionary(forKey:finderPathMapKey) as? [String:String])?[Self.normalizedFinderPath(url)]
    }
    private func forgetFinderID(for url:URL) {
        var values=UserDefaults.standard.dictionary(forKey:finderPathMapKey) as? [String:String] ?? [:]
        values.removeValue(forKey:Self.normalizedFinderPath(url))
        UserDefaults.standard.set(values,forKey:finderPathMapKey)
    }
    @objc private func reviewConflicts() {
        run("Buscando conflictos guardados…") {
            let values=try await self.client.conflicts()
            guard !values.isEmpty else { return "No hay conflictos pendientes en esta carpeta de Google Drive." }
            let actionable=values.filter{$0.remoteID != nil}
            let choice=await MainActor.run { () -> Int in
                let alert=NSAlert(); alert.messageText="Conflictos conservados (\(values.count))"
                alert.informativeText="Nimbo conserva ambas versiones o detiene cambios de metadatos cuando un cambio local y otro remoto no se pueden combinar. Revisá desde Finder:\n\n" + values.prefix(100).map{"[\($0.kind)] \($0.name)"}.joined(separator:"\n") + (values.count>100 ? "\n… y \(values.count-100) más." : "")
                alert.addButton(withTitle:"Abrir en Finder")
                if actionable.isEmpty { alert.addButton(withTitle:"Marcar como revisados") }
                else { alert.addButton(withTitle:"Aplicar cambios locales (\(actionable.count))"); alert.addButton(withTitle:"Conservar Drive") }
                alert.addButton(withTitle:"Cerrar")
                switch alert.runModal() { case .alertFirstButtonReturn: return 0; case .alertSecondButtonReturn: return 1; case .alertThirdButtonReturn: return 2; default: return 3 }
            }
            if choice == 0 { try await self.openLocation(nil,reveal:false); return "Finder abierto. Revisá las copias conflicto Mac y volvé a pulsar Revisar conflictos cuando termines." }
            if choice == 1 && !actionable.isEmpty {
                var applied=0; var failed:[String]=[]
                for value in actionable {
                    do { try await self.client.resolveConflict(value.id,action:"retryLocal"); applied += 1 }
                    catch { failed.append(value.name) }
                }
                if applied > 0 { self.client.signalChanges() }
                if failed.isEmpty { return "Se aplicaron \(applied) cambios locales con la condición actual de Google Drive. Las copias separadas permanecen como respaldo." }
                return "Se aplicaron \(applied) cambios locales. No se pudieron aplicar: \(failed.prefix(5).joined(separator:", "))\(failed.count > 5 ? " y (failed.count-5) más" : ""). Revisá esos conflictos en Finder."
            }
            if (choice == 1 && actionable.isEmpty) || (choice == 2 && !actionable.isEmpty) {
                var kept=0; var failed:[String]=[]
                for value in values {
                    do { try await self.client.resolveConflict(value.id,action:"keepRemote"); kept += 1 }
                    catch { failed.append(value.name) }
                }
                if kept > 0 { self.client.signalChanges() }
                if failed.isEmpty { return "Se conservaron las versiones de Google Drive y se marcaron \(kept) conflictos como revisados." }
                return "Se conservaron \(kept) versiones de Google Drive. No se pudieron revisar: \(failed.prefix(5).joined(separator:", "))\(failed.count > 5 ? " y (failed.count-5) más" : "")."
            }
            return "Hay \(values.count) conflictos para revisar en Finder."
        }
    }
    @objc func disconnect() {
        run("Desactivando carpeta de Finder…") {
            self.autoTask?.cancel()
            try await self.client.remove()
            await MainActor.run{self.connected=false; self.timer?.invalidate(); UserDefaults.standard.set(false,forKey:self.enabledKey)}
            return "Carpeta de Finder desactivada. Tus archivos siguen en Google Drive."
        }
    }
}
