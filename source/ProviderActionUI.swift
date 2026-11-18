import AppKit
import FileProvider
import FileProviderUI

@objc(NimboProviderActionUI)
final class NimboProviderActionUI: FPUIActionExtensionViewController {
    private let heading = NSTextField(labelWithString: "Enlaces de Google Drive")
    private let message = NSTextField(wrappingLabelWithString: "Consultando enlaces…")
    private let closeButton = NSButton(title: "Cancelar", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private var work: Task<Void, Never>?
    private var finished = false
    private var prepared = false
    private var completionError: NSError?

    override func loadView() {
        let root = NimboGradientView(frame: NSRect(x: 0, y: 0, width: 520, height: 230))
        root.appearance = NSAppearance(named: .darkAqua)
        heading.font = .systemFont(ofSize: 21, weight: .bold)
        message.textColor = .secondaryLabelColor
        spinner.style = .spinning; spinner.controlSize = .small
        closeButton.target = self; closeButton.action = #selector(closeAction)
        closeButton.bezelStyle = .rounded
        let row = NSStackView(views: [spinner, NSView(), closeButton]); row.spacing = 12
        let stack = NSStackView(views: [heading, message, NSView(), row])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24)
        ])
        for child in stack.arrangedSubviews { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        view = root; preferredContentSize = NSSize(width: 520, height: 230)
    }

    override func prepare(forAction actionIdentifier: String, itemIdentifiers: [NSFileProviderItemIdentifier]) {
        // macOS can call prepare before loadView.
        _ = view
        guard !prepared else { return }; prepared = true
        do {
            let request = try ProviderWebLinks(action: actionIdentifier,
                domain: extensionContext.domainIdentifier?.rawValue,
                identifiers: itemIdentifiers.map(\.rawValue))
            if request.action == .share || request.action == .revoke {
                openSharingConfirmation(request)
                return
            }
            heading.stringValue = request.action == .copy ? "Copiar enlaces de Google Drive" : "Abrir en Google Drive"
            message.stringValue = "Consultando \(request.identifiers.count) enlace(s). Tus archivos permanecen bajo demanda."
            spinner.startAnimation(nil)
            work = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    // FileProviderUI may pass a filesystem document identifier,
                    // not the provider's Drive ID. Resolve it through macOS;
                    // never parse the private identifier or read file contents.
                    let links = try await request.resolve(identify: { domain, id in
                        let client = NativeClient(identifier: domain)
                        let url = try await client.location(id)
                        let identity = try await client.identifierForUserVisibleFile(url)
                        return (identity.domain, identity.id)
                    }) { domain, id in
                        try await NativeClient(identifier: domain).browserLink(id)
                    }
                    try Task.checkCancellation()
                    if request.action == .copy {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        guard pasteboard.setString(links.map(\.absoluteString).joined(separator: "\n"), forType: .string) else {
                            throw CocoaError(.fileWriteUnknown)
                        }
                        message.stringValue = "\(links.count) enlace(s) copiado(s). Los permisos de Drive no cambiaron."
                    } else {
                        var opened = 0
                        for link in links {
                            guard NSWorkspace.shared.open(link) else {
                                message.stringValue = "Se abrieron \(opened) de \(links.count) enlaces. No se pudo abrir el siguiente en el navegador."
                                finish(error: CocoaError(.featureUnsupported)); return
                            }
                            opened += 1
                        }
                        message.stringValue = "\(opened) enlace(s) abierto(s). Google puede pedir que elijas la cuenta correcta en el navegador."
                    }
                    finish()
                } catch is CancellationError {
                    // closeAction already ended this request; no late clipboard mutation.
                } catch {
                    message.stringValue = "No se pudo completar la acción: " + error.localizedDescription
                    finish(error: error)
                }
            }
        } catch {
            message.stringValue = "No se pudo identificar la cuenta o la selección de Finder. Cerrá este panel y volvé a intentarlo."
            finish(error: error)
        }
    }

    private func openSharingConfirmation(_ request: ProviderWebLinks) {
        heading.stringValue = request.action == .share ? "Compartir enlace público" : "Revocar enlace público"
        message.stringValue = "Identificando la selección en Finder…"
        spinner.startAnimation(nil)
        work = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let route = try await request.confirmationURL { domain, opaqueID in
                    let client = NativeClient(identifier: domain)
                    let url = try await client.location(opaqueID)
                    let identity = try await client.identifierForUserVisibleFile(url)
                    return (identity.domain, identity.id, url)
                }
                // Open the app containing this extension, even if Launch Services
                // knows several development builds with the same URL scheme.
                let host = Bundle.main.bundleURL.deletingLastPathComponent()
                    .deletingLastPathComponent().deletingLastPathComponent()
                guard host.pathExtension == "app" else { throw CocoaError(.fileNoSuchFile) }
                try Task.checkCancellation()
                _ = try await NSWorkspace.shared.open([route], withApplicationAt: host,
                                                       configuration: NSWorkspace.OpenConfiguration())
                finished = true
                extensionContext.completeRequest()
            } catch is CancellationError {
                return
            } catch {
                message.stringValue = error.localizedDescription
                finish(error: error)
            }
        }
    }
    override func prepare(forError error: Error) {
        _ = view
        message.stringValue = "Abrí Nimbo para revisar la conexión de Google Drive. " + error.localizedDescription
        finish(error: error)
    }
    override func viewDidDisappear() {
        super.viewDidDisappear()
        if !finished { work?.cancel() }
    }
    private func finish(error: Error? = nil) {
        completionError = error.map { NSError(domain: FPUIErrorDomain, code: 1,
            userInfo: [NSLocalizedDescriptionKey: $0.localizedDescription]) }
        spinner.stopAnimation(nil); finished = true; closeButton.title = "Cerrar"
    }
    @objc private func closeAction() {
        work?.cancel()
        if let completionError { extensionContext.cancelRequest(withError: completionError) }
        else if finished { extensionContext.completeRequest() }
        else { extensionContext.cancelRequest(withError: NSError(domain: FPUIErrorDomain, code: 0)) }
    }
    deinit { work?.cancel() }
}
