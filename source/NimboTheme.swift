import AppKit

/// Original drawing code: only the visual direction (dark sky, soft glows,
/// glass cards, one colour per cloud) is inspired by Nimbus.
enum NimboPalette {
    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
    static let skyTop = rgb(0x0B1640), skyMiddle = rgb(0x0A1030), skyBottom = rgb(0x150C38)
    static let glowBlue = rgb(0x488CFF), glowViolet = rgb(0x8854FF), glowPink = rgb(0xFF5CA8)
    static let glassTop = NSColor.white.withAlphaComponent(0.10), glassBottom = NSColor.white.withAlphaComponent(0.05)
    static let glassBorder = NSColor.white.withAlphaComponent(0.16)
    static let track = NSColor.white.withAlphaComponent(0.15)
    static let driveLight = rgb(0x4C9BFF), driveDeep = rgb(0x2563FF)
    static let textSecondary = NSColor.white.withAlphaComponent(0.80)
    static let ok = rgb(0x45E3AA), warning = rgb(0xFFB84D), error = rgb(0xFF8080)
    static let tableFill = rgb(0x111A44, 0.92)
}

final class NimboGradientView: NSView {
    var bright = false { didSet { needsDisplay = true } }
    var sidebar = false { didSet { needsDisplay = true } }
    /// Hosted inside the main window: the main window already draws the sky.
    var transparent = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { false }

    private func glow(_ color: NSColor, alpha: CGFloat, x: CGFloat, y: CGFloat, radius: CGFloat) {
        let size = max(bounds.width, bounds.height) * radius
        let center = NSPoint(x: bounds.minX + bounds.width * x, y: bounds.minY + bounds.height * (1 - y))
        NSGradient(colors: [color.withAlphaComponent(alpha), color.withAlphaComponent(0)])?
            .draw(fromCenter: center, radius: 0, toCenter: center, radius: size, options: [])
    }

    override func draw(_ dirtyRect: NSRect) {
        if transparent { return }
        if sidebar || bright {
            // Glass card: translucent white over the sky, hairline border.
            let radius: CGFloat = sidebar ? 18 : 20
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            NSGraphicsContext.saveGraphicsState(); shape.addClip()
            NSColor.white.withAlphaComponent(sidebar ? 0.04 : 0.02).setFill(); bounds.fill()
            if bright {
                // Header washed in the Drive colour, like a cloud page header.
                NSGradient(colors: [NimboPalette.driveDeep.withAlphaComponent(0.55), NimboPalette.glowViolet.withAlphaComponent(0.30)])?.draw(in: bounds, angle: -20)
                glow(NimboPalette.driveLight, alpha: 0.45, x: 0.9, y: -0.2, radius: 0.6)
            }
            NSGradient(colors: [NimboPalette.glassTop, NimboPalette.glassBottom])?.draw(in: bounds, angle: -90)
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.withAlphaComponent(0.09).setStroke(); shape.lineWidth = 1; shape.stroke()
            return
        }
        NSGradient(colorsAndLocations: (NimboPalette.skyTop, 0), (NimboPalette.skyMiddle, 0.45), (NimboPalette.skyBottom, 1))?
            .draw(in: bounds, angle: -70)
        // Two soft light sources only; the content provides the colour.
        glow(NimboPalette.glowBlue, alpha: 0.30, x: 0.85, y: -0.10, radius: 0.50)
        glow(NimboPalette.glowViolet, alpha: 0.26, x: 0.05, y: 1.10, radius: 0.45)
    }
}
final class NimboQuotaRing: NSView {
    var fraction: Double? { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let width: CGFloat = 14
        let radius = max(1, min(bounds.width, bounds.height) / 2 - width)
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let track = NSBezierPath(ovalIn: NSRect(x: center.x-radius, y: center.y-radius, width: radius*2, height: radius*2))
        track.lineWidth = width; NimboPalette.track.setStroke(); track.stroke()
        guard let fraction else { return }
        let value = CGFloat(min(1, max(0, fraction)))
        let arc = NSBezierPath(); arc.lineWidth = width; arc.lineCapStyle = .round
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - value * 360, clockwise: true)
        // Drive blue with a soft glow; amber when the account is nearly full.
        let colors = value > 0.9 ? [NimboPalette.warning, NimboPalette.rgb(0xFF8A00)] : [NimboPalette.driveLight, NimboPalette.driveDeep]
        NSGraphicsContext.saveGraphicsState()
        colors[0].setStroke(); arc.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Shared shell for the utility windows. All controls remain native AppKit.
enum NimboWindowStyle {
    static func apply(to window: NSWindow) {
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NimboPalette.skyMiddle
        window.contentView = NimboGradientView()
    }
    static func applyDialog(to window: NSWindow) {
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NimboPalette.skyMiddle
        window.contentView = NimboGradientView()
    }

    /// SF Pro Rounded for titles, like Nimbus' display style.
    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// One glowing primary action per screen.
    static func primary(_ button: NSButton) {
        button.bezelStyle = .rounded
        button.bezelColor = NimboPalette.driveDeep
        button.contentTintColor = .white
        button.keyEquivalent = "\r"
    }

    static func driveTile(size: CGFloat) -> NSView {
        let tile = NSView()
        tile.wantsLayer = true
        tile.layer?.cornerRadius = size * 0.28
        let fill = CAGradientLayer()
        fill.colors = [NimboPalette.driveLight.cgColor, NimboPalette.driveDeep.cgColor]
        fill.startPoint = CGPoint(x: 0, y: 1); fill.endPoint = CGPoint(x: 1, y: 0)
        fill.frame = CGRect(x: 0, y: 0, width: size, height: size); fill.cornerRadius = size * 0.28
        tile.layer?.addSublayer(fill)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "cloud.fill", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size * 0.52, weight: .medium)
        icon.contentTintColor = .white
        icon.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(icon)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: size), tile.heightAnchor.constraint(equalToConstant: size),
            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor), icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor)
        ])
        return tile
    }

    static func header(_ title: String, subtitle: String) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NimboWindowStyle.rounded(26, .semibold)
        titleLabel.textColor = .white
        let description = NSTextField(wrappingLabelWithString: subtitle)
        description.font = .systemFont(ofSize: 13.5)
        description.textColor = NimboPalette.textSecondary
        let text = NSStackView(views: [titleLabel, description])
        text.orientation = .vertical; text.alignment = .leading; text.spacing = 6
        let background = NimboGradientView(); background.bright = true
        background.wantsLayer = true; background.layer?.cornerRadius = 20
        background.layer?.masksToBounds = true
        text.translatesAutoresizingMaskIntoConstraints = false; background.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            text.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -18),
            text.topAnchor.constraint(equalTo: background.topAnchor, constant: 16),
            text.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -16),
            description.widthAnchor.constraint(equalTo: text.widthAnchor)
        ])
        return background
    }
    static func table(_ table: NSTableView, scroll: NSScrollView) {
        table.backgroundColor = NimboPalette.tableFill
        table.selectionHighlightStyle = .regular
        table.rowHeight = max(table.rowHeight, 30)
        table.intercellSpacing = NSSize(width: 8, height: 4)
        table.gridStyleMask = []
        scroll.borderType = .noBorder; scroll.wantsLayer = true; scroll.drawsBackground = false
        scroll.layer?.cornerRadius = 14; scroll.layer?.masksToBounds = true
        scroll.layer?.borderWidth = 1; scroll.layer?.borderColor = NimboPalette.glassBorder.cgColor
    }
}

extension NSPopUpButton {
    func setDriveAccounts(_ accounts: [(remote: String, alias: String)], selected: String? = nil, allTitle: String? = nil) {
        let accountMenu = NSMenu()
        if let allTitle { accountMenu.addItem(withTitle: allTitle, action: nil, keyEquivalent: "") }
        let aliasCounts = Dictionary(grouping: accounts, by: { $0.alias }).mapValues { $0.count }
        for account in accounts {
            let ambiguous = aliasCounts[account.alias] != 1 || account.alias == allTitle
            let title = ambiguous ? account.alias + " · " + account.remote : account.alias
            let item = accountMenu.addItem(withTitle: title, action: nil, keyEquivalent: "")
            item.representedObject = account.remote
        }
        menu = accountMenu
        if let selected, let item = itemArray.first(where: { $0.representedObject as? String == selected }) {
            select(item)
        } else if numberOfItems > 0 {
            selectItem(at: 0)
        }
    }
}

/// Filled cloud on each account's Finder folder, like odrive's glyph on its
/// own folder. Finder stores it in a local "Icon\r" file that the File
/// Provider extension excludes from sync, so nothing is uploaded to Drive.
enum NimboFinderIcon {
    /// Symbol and colour chosen for an account («Ícono…» in Inicio). Default: blue cloud.
    static let symbols: [(String, String)] = [("Nube", "cloud.fill"), ("Básquet", "basketball.fill"), ("Fútbol", "soccerball"), ("Trabajo", "briefcase.fill"),
        ("Casa", "house.fill"), ("Estrella", "star.fill"), ("Cámara", "camera.fill"), ("Música", "music.note"), ("Corazón", "heart.fill"), ("Carpeta", "folder.fill")]
    static let colors: [(String, UInt32)] = [("Azul", 0x2F7BF6), ("Naranja", 0xF28C28), ("Verde", 0x10A877), ("Violeta", 0x6D4DFF), ("Rojo", 0xE5484D), ("Gris", 0x5B6478)]
    static func style(for remote: String) -> (symbol: String, color: UInt32) {
        let raw = UserDefaults.standard.string(forKey: "NimboAccountIcon." + remote) ?? ""
        let parts = raw.split(separator: "|")
        if parts.count == 2, let hex = UInt32(parts[1], radix: 16) { return (String(parts[0]), hex) }
        return ("cloud.fill", 0x2F7BF6)
    }
    static func setStyle(_ symbol: String, _ color: UInt32, for remote: String) {
        UserDefaults.standard.set(symbol + "|" + String(color, radix: 16), forKey: "NimboAccountIcon." + remote)
    }
    static func image(symbol: String = "cloud.fill", color: UInt32 = 0x2F7BF6) -> NSImage {
        let size = NSSize(width: 512, height: 512)
        return NSImage(size: size, flipped: false) { rect in
            let config = NSImage.SymbolConfiguration(pointSize: 360, weight: .regular)
            guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return false }
            let tinted = NSImage(size: glyph.size, flipped: false) { r in
                glyph.draw(in: r); NimboPalette.rgb(color).set(); r.fill(using: .sourceAtop); return true
            }
            let s = tinted.size, scale = min(rect.width * 0.92 / s.width, rect.height * 0.92 / s.height)
            let w = s.width * scale, h = s.height * scale
            tinted.draw(in: NSRect(x: (rect.width - w) / 2, y: (rect.height - h) / 2, width: w, height: h))
            return true
        }
    }
    /// Account folder icon in Finder (stored in a local "Icon\r" file that is never uploaded).
    static func apply(to folder: URL, remote: String? = nil, force: Bool = false) {
        let style = remote.map { self.style(for: $0) } ?? ("cloud.fill", 0x2F7BF6)
        let key = "NimboFinderIconApplied." + folder.path
        let signature = style.0 + String(style.1)
        guard force || UserDefaults.standard.string(forKey: key) != signature else { return }
        if NSWorkspace.shared.setIcon(image(symbol: style.0, color: style.1), forFile: folder.path, options: []) { UserDefaults.standard.set(signature, forKey: key) }
    }
    /// Monochrome symbol for the Finder sidebar (Finder tints it like its own icons).
    static func sidebarIconFile(symbol: String = "cloud.fill") -> URL? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Nimbo")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let file = support.appendingPathComponent("Sidebar-" + symbol + ".icns")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, "com.apple.icns" as CFString, 2, nil) else { return nil }
        for size in [32, 64] {
            let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                let config = NSImage.SymbolConfiguration(pointSize: CGFloat(size) * 0.62, weight: .medium)
                guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return false }
                let s = glyph.size
                glyph.draw(in: NSRect(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2, width: s.width, height: s.height))
                return true
            }
            if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) { CGImageDestinationAddImage(destination, cg, nil) }
        }
        return CGImageDestinationFinalize(destination) ? file : nil
    }
}
