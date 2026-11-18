import AppKit

/// A presentation-only step. No account or credential is persisted until OAuth succeeds.
final class AddDriveAccountPanel: NSObject, NSWindowDelegate {
    struct Selection {
        let alias: String
        let allowChanges: Bool
        let configureClient: Bool
    }
    private let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let aliasField = NSTextField(string: "")
    private let changes = NSButton(checkboxWithTitle: "Permitir crear, modificar y eliminar archivos desde Finder", target: nil, action: nil)
    private var defaultAlias = ""

    func present(defaultAlias: String, canReuseClient: Bool) -> Selection? {
        self.defaultAlias = defaultAlias
        panel.title = "Nimbo · Agregar Google Drive"
        panel.isReleasedWhenClosed = false; panel.delegate = self
        NimboWindowStyle.apply(to: panel)
        let header = NimboWindowStyle.header("Conectá tu Google Drive", subtitle: "Otra cuenta, su propio nombre y un lugar separado en Finder.")
        let aliasLabel = NSTextField(labelWithString: "Nombre de esta cuenta")
        aliasLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        aliasField.placeholderString = "Personal, Trabajo, Cliente…"
        aliasField.stringValue = defaultAlias
        aliasField.font = .systemFont(ofSize: 15)
        aliasField.setAccessibilityLabel("Alias de la nueva cuenta")
        let cloud = NSTextField(wrappingLabelWithString: "Sólo nube · Tus archivos se descargan cuando los abrís. Agregar una cuenta no descarga todo tu Drive.")
        cloud.textColor = .systemCyan
        changes.state = .on
        let permission = NSTextField(wrappingLabelWithString: "Si desmarcás esta opción, la conexión será de sólo lectura. La descarga bajo demanda funciona en ambos casos.")
        permission.textColor = .secondaryLabelColor; permission.font = .systemFont(ofSize: 12)
        let steps = NSTextField(wrappingLabelWithString: canReuseClient
            ? "1. Continuá en Google y elegí la cuenta que querés agregar.\n2. Revisá los permisos e iniciá sesión.\n3. Al terminar, Nimbo creará su acceso en Finder."
            : "Primero configurá tu cliente de Google con el JSON de una aplicación de escritorio. Después iniciarás sesión directamente en Google.")
        steps.font = .systemFont(ofSize: 13)
        let existing = NSTextField(wrappingLabelWithString: "Tus conexiones actuales se conservan. El alias sólo cambia cómo reconocés esta cuenta en Nimbo.")
        existing.textColor = .secondaryLabelColor; existing.font = .systemFont(ofSize: 12)
        let advanced = NSButton(title: "Usar mi cliente de Google…", target: self, action: #selector(configure))
        advanced.bezelStyle = .rounded; advanced.isHidden = !canReuseClient
        let cancel = NSButton(title: "Cancelar", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        let next = NSButton(title: canReuseClient ? "Continuar en Google" : "Configurar Google…", target: self,
                            action: canReuseClient ? #selector(proceed) : #selector(configure))
        next.bezelStyle = .rounded; next.bezelColor = .systemBlue; next.keyEquivalent = "\r"
        let buttons = NSStackView(views: [advanced, NSView(), cancel, next]); buttons.spacing = 10
        let content = NSStackView(views: [header, aliasLabel, aliasField, cloud, changes, permission, steps, existing, NSView(), buttons])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 24),
            content.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -24),
            aliasField.heightAnchor.constraint(equalToConstant: 28)
        ])
        for view in content.arrangedSubviews { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        panel.initialFirstResponder = aliasField
        panel.center(); panel.makeKeyAndOrderFront(nil)
        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        guard response == .OK || response == .alertThirdButtonReturn else { return nil }
        let alias = aliasField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return Selection(alias: alias.isEmpty ? defaultAlias : alias, allowChanges: changes.state == .on,
                         configureClient: response == .alertThirdButtonReturn)
    }
    @objc private func proceed() { NSApp.stopModal(withCode: .OK) }
    @objc private func configure() { NSApp.stopModal(withCode: .alertThirdButtonReturn) }
    @objc private func cancel() { NSApp.stopModal(withCode: .cancel) }
    func windowWillClose(_ notification: Notification) {
        if NSApp.modalWindow === panel { NSApp.stopModal(withCode: .cancel) }
    }
}
