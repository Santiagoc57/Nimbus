import AppKit
import Carbon.HIToolbox
import UserNotifications
import FileProvider

// MARK: - Visual building blocks
//
// Direction: quiet dark glass. Depth comes from surface steps and 8 % hairlines
// (unslop), one accent (Drive blue), status dots plus words, weights ≤ 600,
// 4 pt grid. Original AppKit drawing; Nimbus only inspired the direction.

enum NimboMetrics {
    static let row: CGFloat = 10, card: CGFloat = 16, panel: CGFloat = 18
    static let pagePadding: CGFloat = 28
}

/// Translucent card. On macOS 13–15 a behind-window material gives the glass;
/// a neutral white fill and hairline keep it legible over the sky backdrop.
final class NimboGlassCard: NSView {
    enum Tone { case normal, raised, warning, selected }
    var tone: Tone = .normal { didSet { restyle() } }
    private let blur = NSVisualEffectView()
    init(_ content: NSView, padding: CGFloat = 20, tone: Tone = .normal, radius: CGFloat = NimboMetrics.card) {
        super.init(frame: .zero)
        self.tone = tone
        wantsLayer = true
        layer?.cornerRadius = radius; layer?.cornerCurve = .continuous; layer?.masksToBounds = true
        blur.material = .hudWindow; blur.blendingMode = .withinWindow; blur.state = .active
        blur.alphaValue = 0.35
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: leadingAnchor), blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor), blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            content.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding)
        ])
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func restyle() {
        let fill: NSColor, border: NSColor
        switch tone {
        case .normal: fill = NSColor.white.withAlphaComponent(0.06); border = NSColor.white.withAlphaComponent(0.09)
        case .raised: fill = NSColor.white.withAlphaComponent(0.09); border = NSColor.white.withAlphaComponent(0.12)
        case .selected: fill = NSColor.white.withAlphaComponent(0.11); border = NSColor.white.withAlphaComponent(0.16)
        case .warning: fill = NimboPalette.warning.withAlphaComponent(0.10); border = NimboPalette.warning.withAlphaComponent(0.35)
        }
        layer?.backgroundColor = fill.cgColor
        layer?.borderWidth = 1; layer?.borderColor = border.cgColor
    }
}

/// Thin usage bar: neutral track, one accent fill (amber above 90 %).
final class NimboUsageBar: NSView {
    var fraction: Double? { didSet { needsDisplay = true; isHidden = fraction == nil } }
    var height: CGFloat = 6
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height) }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.height / 2
        NimboPalette.track.setFill(); NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        guard let fraction else { return }
        let value = CGFloat(min(1, max(0, fraction)))
        guard value > 0 else { return }
        let fill = NSRect(x: 0, y: 0, width: max(bounds.height, bounds.width * value), height: bounds.height)
        (value > 0.9 ? NimboPalette.warning : NimboPalette.driveLight).setFill()
        NSBezierPath(roundedRect: fill, xRadius: r, yRadius: r).fill()
    }
}

/// Several accounts in one bar, each a shade of the accent.
final class NimboSegmentBar: NSView {
    var segments: [Double] = [] { didSet { needsDisplay = true } }   // fractions of the total
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 8) }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.height / 2
        let track = NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r)
        NimboPalette.track.setFill(); track.fill()
        NSGraphicsContext.saveGraphicsState(); track.addClip()
        var x: CGFloat = 0
        let shades: [NSColor] = [NimboPalette.driveLight, NimboPalette.rgb(0x7FB6FF), NimboPalette.rgb(0x2E6BE6), NimboPalette.rgb(0xA9CCFF)]
        for (i, value) in segments.enumerated() {
            let w = bounds.width * CGFloat(max(0, value))
            shades[i % shades.count].setFill()
            NSRect(x: x, y: 0, width: max(0, w - 2), height: bounds.height).fill()
            x += w
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

enum NimboStatus {
    case ok, warning, error, muted, busy
    var color: NSColor {
        switch self {
        case .ok: return NimboPalette.ok
        case .warning, .busy: return NimboPalette.warning
        case .error: return NimboPalette.error
        case .muted: return NSColor.white.withAlphaComponent(0.45)
        }
    }
}

final class NimboDot: NSView {
    var status: NimboStatus = .muted { didSet { layer?.backgroundColor = status.color.cgColor } }
    init(_ status: NimboStatus, size: CGFloat = 8) {
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = size / 2
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
        self.status = status; layer?.backgroundColor = status.color.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
}

enum NimboUI {
    static func text(_ value: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .white) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }
    static func secondary(_ value: String, size: CGFloat = 12) -> NSTextField { text(value, size: size, color: NimboPalette.textSecondary) }
    static func muted(_ value: String, size: CGFloat = 12) -> NSTextField { text(value, size: size, color: NSColor.white.withAlphaComponent(0.55)) }
    static func wrapping(_ value: String, size: CGFloat = 12.5, color: NSColor = NimboPalette.textSecondary) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value)
        field.font = .systemFont(ofSize: size); field.textColor = color
        return field
    }
    static func title(_ value: String, size: CGFloat) -> NSTextField {
        let field = text(value, size: size, weight: .semibold)
        field.font = NimboWindowStyle.rounded(size, .semibold)
        return field
    }
    static func hstack(_ views: [NSView], spacing: CGFloat = 8, align: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
        let s = NSStackView(views: views); s.orientation = .horizontal; s.alignment = align; s.spacing = spacing; return s
    }
    static func vstack(_ views: [NSView], spacing: CGFloat = 8, fill: Bool = true) -> NSStackView {
        let s = NSStackView(views: views); s.orientation = .vertical; s.alignment = fill ? .width : .leading; s.spacing = spacing
        if fill { for v in views { v.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true } }
        return s
    }
    static func chip(_ value: String) -> NSView {
        let label = text(value, size: 11, weight: .medium, color: NimboPalette.textSecondary)
        let box = NSView(); box.wantsLayer = true
        box.layer?.cornerRadius = 9; box.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        label.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8), label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
                                     label.topAnchor.constraint(equalTo: box.topAnchor, constant: 2), label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2)])
        return box
    }
    /// Status as dot + words, never colour alone.
    static func status(_ value: String, _ status: NimboStatus) -> NSStackView {
        let line = secondary(value, size: 12)
        return hstack([NimboDot(status, size: 7), line], spacing: 6)
    }
    /// Rounded square with an SF Symbol, for tools in the sidebar.
    static func toolTile(_ symbol: String, color: NSColor, size: CGFloat = 22) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.28, yRadius: size * 0.28)
            color.setFill(); path.fill()
            let config = NSImage.SymbolConfiguration(pointSize: size * 0.5, weight: .semibold)
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let tinted = NSImage(size: image.size, flipped: false) { r in image.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true }
                let s = tinted.size
                tinted.draw(in: NSRect(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2, width: s.width, height: s.height))
            }
            return true
        }
    }
    static func driveTileImage(size: CGFloat = 22) -> NSImage { toolTile("cloud.fill", color: NimboPalette.driveDeep, size: size) }
    /// The account's own symbol and colour (chosen with «Ícono…»).
    static func accountTileImage(_ remote: String, size: CGFloat = 22) -> NSImage {
        let style = NimboFinderIcon.style(for: remote)
        return toolTile(style.symbol, color: NimboPalette.rgb(style.color), size: size)
    }
    static func button(_ title: String, primary: Bool = false, target: AnyObject?, action: Selector?) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .rounded; b.controlSize = .regular
        if primary { b.bezelColor = NimboPalette.driveDeep; b.contentTintColor = .white }
        return b
    }
    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.locale = Locale(identifier: "es"); f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
    static func bytes(_ value: Int64) -> String {
        let f = ByteCountFormatter(); f.countStyle = .file; f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: value)
    }
}

// MARK: - Local footprint per account ("Descargado en este Mac")

struct NimboLocalFootprint {
    var downloadedBytes: Int64 = 0
    var unusedBytes: Int64 = 0       // downloaded, not opened in `days`, not kept offline
    var unusedCount = 0
    var keptOffline: [(name: String, url: URL)] = []
}

extension NativeClient {
    /// Walks the availability index of this account (bounded) and measures the
    /// files that are really on this Mac. Metadata only: nothing is downloaded.
    func localFootprint(unusedDays: Int = 30, limit: Int = 20_000) async -> NimboLocalFootprint {
        var result = NimboLocalFootprint()
        var cursor: String?, seen = 0, pages = Set<String>()
        let cutoff = Date().addingTimeInterval(-Double(unusedDays) * 86_400)
        repeat {
            guard let page = try? await availabilityPage(after: cursor) else { break }
            for item in page.items {
                seen += 1
                if item.pinned, result.keptOffline.count < 12, let url = try? await location(item.id) {
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                        result.keptOffline.append((url.lastPathComponent, url))
                    }
                }
                guard item.downloadedAt != nil, let local = try? await localAvailability(item.id),
                      let url = try? await location(item.id),
                      let size = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize else { continue }
                result.downloadedBytes += Int64(size)
                if !item.pinned && max(local.accessed, local.modified) < cutoff { result.unusedBytes += Int64(size); result.unusedCount += 1 }
            }
            cursor = page.next
            if let cursor, !pages.insert(cursor).inserted { break }
        } while cursor != nil && seen < limit
        return result
    }

    /// Releases downloaded files not used in `days`. Files kept offline, open
    /// or with pending uploads are skipped by the extension's own checks.
    func releaseUnused(days: Int = 30) async -> (released: Int, bytes: Int64) {
        var released = 0, bytes: Int64 = 0
        var cursor: String?, pages = Set<String>()
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        repeat {
            guard let page = try? await availabilityPage(after: cursor) else { break }
            for item in page.items where !item.pinned && item.downloadedAt != nil {
                guard let local = try? await localAvailability(item.id), max(local.accessed, local.modified) < cutoff,
                      let url = try? await location(item.id) else { continue }
                let size = (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
                if (try? await evictAutomatically(item.id)) != nil { released += 1; bytes += Int64(size) }
            }
            cursor = page.next
            if let cursor, !pages.insert(cursor).inserted { break }
        } while cursor != nil
        return (released, bytes)
    }
}

extension NativeClient {
    /// Frees downloaded files, least recently used first, until `bytes` are
    /// released. Kept-offline, open or pending files are refused by the extension.
    func releaseLeastRecentlyUsed(bytes target: Int64) async -> Int64 {
        var candidates: [(id: String, used: Date, size: Int64)] = []
        var cursor: String?, pages = Set<String>()
        repeat {
            guard let page = try? await availabilityPage(after: cursor) else { break }
            for item in page.items where !item.pinned && item.downloadedAt != nil {
                guard let local = try? await localAvailability(item.id), let url = try? await location(item.id),
                      let size = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize else { continue }
                candidates.append((item.id, max(local.accessed, local.modified), Int64(size)))
            }
            cursor = page.next
            if let cursor, !pages.insert(cursor).inserted { break }
        } while cursor != nil
        var freed: Int64 = 0
        for candidate in candidates.sorted(by: { $0.used < $1.used }) where freed < target {
            if (try? await evictAutomatically(candidate.id)) != nil { freed += candidate.size }
        }
        return freed
    }
}

extension NativeClient {
    /// Pause: Finder keeps showing the files and macOS shows the reason; no transfers until resume.
    func pauseSync(reason: String) async {
        guard let manager = NSFileProviderManager(for: domain) else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            manager.disconnect(reason: reason, options: [.temporary]) { _ in c.resume() }
        }
    }
    func resumeSync() async {
        guard let manager = NSFileProviderManager(for: domain) else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in manager.reconnect { _ in c.resume() } }
    }
}

// MARK: - Discreet notifications (session expired, conflicts, upload errors)

final class NimboNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NimboNotifier()
    static let enabledKey = "NimboNotificationsEnabled"
    private var lastSent: [String: Date] = [:]
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }
    func start() { UNUserNotificationCenter.current().delegate = self }
    /// One notification per `key` every 6 hours at most: only what matters.
    func post(_ key: String, title: String, body: String) {
        guard enabled else { return }
        if let last = lastSent[key], Date().timeIntervalSince(last) < 6 * 3600 { return }
        lastSent[key] = Date()
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title; content.body = body
            center.add(UNNotificationRequest(identifier: key + "-" + UUID().uuidString, content: content, trigger: nil))
        }
    }
    var onOpen: (() -> Void)?
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { self.onOpen?() }
        completionHandler()
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}

// MARK: - Global shortcut ⌃⌥Espacio → Buscar en Google Drive

final class NimboHotKey {
    static let shared = NimboHotKey()
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var action: (() -> Void)?
    static let display = "⌃⌥Espacio"
    func register() {
        guard reference == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { NimboHotKey.shared.action?() }
            return noErr
        }, 1, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x4E494D42), id: 1) // 'NIMB'
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &reference)
    }
}

// MARK: - Pantallas dentro de la ventana principal
/// Sincronizaciones, Actividad, Papelera, Unidades compartidas y Configuración
/// se muestran en el área de contenido de la ventana principal, no como
/// ventanas sueltas. Cada controlador sigue armando su vista como antes; aquí
/// se toma su contenido y se aloja en la ventana principal.
enum NimboEmbedding {
    /// Recibe la vista y la clave de la pantalla; devuelve false si no hay ventana principal.
    static var host: ((NSView, String) -> Bool)?
    private static var taken: [ObjectIdentifier: NSView] = [:]
    private(set) static var current: String?
    static func present(_ window: NSWindow?, key: String) {
        guard let window else { return }
        let id = ObjectIdentifier(window)
        let view: NSView
        if let existing = taken[id] { view = existing }
        else {
            guard let content = window.contentView else { return }
            window.contentView = NSView()
            (content as? NimboGradientView)?.transparent = true
            taken[id] = content; view = content
        }
        if host?(view, key) == true { current = key; return }
        // Sin ventana principal: devolver el contenido a su ventana.
        taken[id] = nil; window.contentView = view
        (view as? NimboGradientView)?.transparent = false
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    static func dismissed() { current = nil }
    static func isShowing(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        if window.isVisible { return true }
        guard let view = taken[ObjectIdentifier(window)] else { return false }
        return view.window?.isVisible == true && !view.isHiddenOrHasHiddenAncestor
    }
}

extension NimboFinderIcon {
    /// Adds the account folder to Finder's Favorites with its own name and a cloud.
    static func addToSidebar(_ folder: URL, name: String, remote: String? = nil, force: Bool = false) {
        let symbol = remote.map { style(for: $0).symbol } ?? "cloud.fill"
        let key = "NimboSidebarFavorite." + folder.path
        guard force || UserDefaults.standard.string(forKey: key) != name + "|" + symbol else { return }
        NimboSetFinderFavorite(folder as CFURL, name as CFString, sidebarIconFile(symbol: symbol) as CFURL?)
        UserDefaults.standard.set(name + "|" + symbol, forKey: key)
    }
}
