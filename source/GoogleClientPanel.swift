import AppKit
import UniformTypeIdentifiers

private final class ClientJSONDropView: NSView {
    var importFile: ((URL) -> Bool)?

    private func file(in sender: NSDraggingInfo) -> URL? {
        let board = sender.draggingPasteboard
        guard let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              urls.count == 1, urls[0].pathExtension.lowercased() == "json" else { return nil }
        return urls[0]
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        file(in: sender) == nil ? [] : .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = file(in: sender) else { return false }
        return importFile?(url) ?? false
    }
}

final class GoogleClientPanel: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let identifier = NSTextField()
    private let secret = NSSecureTextField()
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let next = NSButton(title: "Continuar en Google", target: nil, action: nil)
    private var result: OAuthDesktopClient?

    static func chooseJSON() -> URL? {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        picker.allowedContentTypes = [.json]
        picker.prompt = "Importar"
        picker.message = "Elegí el JSON del cliente de tipo Aplicación de escritorio."
        return picker.runModal() == .OK ? picker.url : nil
    }

    func present(alias: String) -> OAuthDesktopClient? {
        panel.title = "Nimbo · Cliente de Google"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        NimboWindowStyle.applyDialog(to: panel)
        let heading = NSTextField(labelWithString: "Tu cliente de Google para " + alias)
        heading.font = .systemFont(ofSize: 23, weight: .bold)
        heading.lineBreakMode = .byTruncatingTail
        heading.toolTip = heading.stringValue
        let intro = NSTextField(wrappingLabelWithString: "Si ya descargaste el JSON de escritorio, importalo abajo. Para crear uno, seguí estos pasos en el mismo proyecto de Google Cloud.")
        intro.textColor = .secondaryLabelColor
        let steps = NSStackView()
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 5
        let links = [
            ("1. Crear o elegir el proyecto", "https://console.cloud.google.com/projectcreate"),
            ("2. Habilitar Google Drive API", "https://console.cloud.google.com/apis/library/drive.googleapis.com"),
            ("3. Configurar la audiencia y los usuarios de prueba", "https://console.cloud.google.com/auth/audience"),
            ("4. Crear un cliente de escritorio y descargar su JSON", "https://console.cloud.google.com/auth/clients")
        ]
        for (text, address) in links {
            let link = NSButton(title: text, target: self, action: #selector(openGoogle(_:)))
            link.isBordered = false
            link.contentTintColor = .systemBlue
            link.alignment = .left
            link.identifier = NSUserInterfaceItemIdentifier(address)
            steps.addArrangedSubview(link)
        }
        let drop = ClientJSONDropView()
        drop.wantsLayer = true
        drop.layer?.cornerRadius = 8
        drop.layer?.borderWidth = 1
        drop.layer?.borderColor = NSColor.separatorColor.cgColor
        drop.registerForDraggedTypes([.fileURL])
        drop.importFile = { [weak self] url in self?.importFile(url) ?? false }
        let choose = NSButton(title: "Elegir JSON…", target: self, action: #selector(chooseFile))
        let dropRow = NSStackView(views: [NSTextField(labelWithString: "Arrastrá el JSON aquí"), NSView(), choose])
        dropRow.translatesAutoresizingMaskIntoConstraints = false
        drop.addSubview(dropRow)
        NSLayoutConstraint.activate([
            dropRow.leadingAnchor.constraint(equalTo: drop.leadingAnchor, constant: 12),
            dropRow.trailingAnchor.constraint(equalTo: drop.trailingAnchor, constant: -12),
            dropRow.topAnchor.constraint(equalTo: drop.topAnchor, constant: 7),
            dropRow.bottomAnchor.constraint(equalTo: drop.bottomAnchor, constant: -7)
        ])
        identifier.placeholderString = "ID de cliente"
        secret.placeholderString = "Secreto del cliente"
        identifier.setAccessibilityLabel("ID de cliente de Google")
        secret.setAccessibilityLabel("Secreto del cliente de Google")
        identifier.delegate = self
        secret.delegate = self
        feedback.textColor = .secondaryLabelColor
        feedback.stringValue = "También podés pegar el ID y el secreto. Después elegirás la cuenta en Google."
        feedback.font = .systemFont(ofSize: 12)
        let cancel = NSButton(title: "Cancelar", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        next.target = self
        next.action = #selector(proceed)
        next.keyEquivalent = "\r"
        next.bezelColor = .systemBlue
        next.isEnabled = false
        let guide = NSButton(title: "Guía de conexión", target: self, action: #selector(openGuide))
        let buttons = NSStackView(views: [guide, NSView(), cancel, next])
        let stack = NSStackView(views: [heading, intro, steps, drop, identifier, secret, feedback, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = panel.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22)
        ])
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        content.layoutSubtreeIfNeeded()
        panel.setContentSize(NSSize(width: 620, height: ceil(stack.fittingSize.height) + 46))
        panel.initialFirstResponder = identifier
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        identifier.stringValue = ""
        secret.stringValue = ""
        defer { result = nil }
        return response == .OK ? result : nil
    }

    private var client: OAuthDesktopClient? {
        try? OAuthDesktopClient(id: identifier.stringValue, secret: secret.stringValue)
    }
    func controlTextDidChange(_ obj: Notification) {
        next.isEnabled = client != nil
        feedback.textColor = .secondaryLabelColor
        feedback.stringValue = "El ID termina en .apps.googleusercontent.com y el secreto figura en el mismo cliente."
    }
    @objc private func openGoogle(_ sender: NSButton) {
        guard let address = sender.identifier?.rawValue, let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }
    @objc private func openGuide() {
        if let url = Bundle.main.url(forResource: "CONECTAR_GOOGLE_DRIVE", withExtension: "html") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func chooseFile() {
        if let url = Self.chooseJSON() { _ = importFile(url) }
    }
    private func importFile(_ url: URL) -> Bool {
        do {
            let client = try OAuthDesktopClient.read(url)
            identifier.stringValue = client.id
            secret.stringValue = client.secret
            feedback.textColor = .secondaryLabelColor
            feedback.stringValue = "Cliente de escritorio importado. Ya podés continuar en Google."
            next.isEnabled = true
            return true
        } catch {
            identifier.stringValue = ""
            secret.stringValue = ""
            feedback.textColor = .systemOrange
            feedback.stringValue = OAuthDesktopClient.ImportError.invalidDesktopFile.localizedDescription
            next.isEnabled = false
            return false
        }
    }
    @objc private func proceed() {
        guard let client else { return }
        result = client
        NSApp.stopModal(withCode: .OK)
    }
    @objc private func cancel() { NSApp.stopModal(withCode: .cancel) }
    func windowWillClose(_ notification: Notification) {
        if NSApp.modalWindow === panel { cancel() }
    }
}
