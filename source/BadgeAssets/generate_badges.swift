// Generates Nimbo's Finder status badges (File Provider decorations).
//   NimboCheckBadge: blue circle + white check   -> "Disponible sin conexión"
//   NimboCloudBadge: small light cloud outline    -> "Sólo en la nube"
// Usage: generate_badges <output directory>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")

func render(_ size: Int, _ draw: (CGFloat) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw(CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func check(_ s: CGFloat) {
    // White ring keeps the badge readable over any file icon.
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: s, height: s)).fill()
    let inset = s * 0.07
    NSColor(srgbRed: 0.18, green: 0.62, blue: 0.90, alpha: 1).setFill()   // compact odrive-like blue
    NSBezierPath(ovalIn: NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)).fill()
    let mark = NSBezierPath()
    mark.move(to: NSPoint(x: s * 0.29, y: s * 0.51))
    mark.line(to: NSPoint(x: s * 0.44, y: s * 0.35))
    mark.line(to: NSPoint(x: s * 0.72, y: s * 0.66))
    mark.lineWidth = s * 0.115
    mark.lineCapStyle = .round
    mark.lineJoinStyle = .round
    NSColor.white.setStroke()
    mark.stroke()
}

func cloud(_ s: CGFloat) {
    // Three overlapping circles + flat base: a compact cloud silhouette.
    let path = NSBezierPath()
    let base = s * 0.30, w = s * 0.84, x0 = s * 0.08
    path.appendRoundedRect(NSRect(x: x0, y: base, width: w, height: s * 0.22), xRadius: s * 0.11, yRadius: s * 0.11)
    path.appendOval(in: NSRect(x: s * 0.16, y: base + s * 0.02, width: s * 0.32, height: s * 0.32))
    path.appendOval(in: NSRect(x: s * 0.33, y: base + s * 0.07, width: s * 0.42, height: s * 0.42))
    path.appendOval(in: NSRect(x: s * 0.56, y: base + s * 0.03, width: s * 0.28, height: s * 0.28))
    path.windingRule = .nonZero
    // Soft outline first, then the pale fill on top, so overlaps leave no seams.
    NSGraphicsContext.saveGraphicsState()
    NSColor(srgbRed: 0.45, green: 0.64, blue: 0.86, alpha: 1).setStroke()
    path.lineWidth = max(1, s * 0.09)
    path.lineJoinStyle = .round
    path.stroke()
    NSGraphicsContext.restoreGraphicsState()
    NSColor(srgbRed: 0.91, green: 0.95, blue: 0.99, alpha: 1).setFill()
    path.fill()
}

func disc(_ s: CGFloat, _ color: NSColor) {
    NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: s, height: s)).fill()
    let inset = s * 0.07
    color.setFill(); NSBezierPath(ovalIn: NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)).fill()
}
func upload(_ s: CGFloat) {
    // Blue disc with a white upward arrow: "subiendo a Google Drive".
    disc(s, NSColor(srgbRed: 0.15, green: 0.39, blue: 1.0, alpha: 1))
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: s * 0.5, y: s * 0.28)); arrow.line(to: NSPoint(x: s * 0.5, y: s * 0.72))
    arrow.move(to: NSPoint(x: s * 0.32, y: s * 0.54)); arrow.line(to: NSPoint(x: s * 0.5, y: s * 0.72)); arrow.line(to: NSPoint(x: s * 0.68, y: s * 0.54))
    arrow.lineWidth = s * 0.11; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    NSColor.white.setStroke(); arrow.stroke()
}
func failed(_ s: CGFloat) {
    // Orange disc with a white exclamation mark: "no se pudo subir".
    disc(s, NSColor(srgbRed: 0.96, green: 0.55, blue: 0.10, alpha: 1))
    let bar = NSBezierPath(); bar.move(to: NSPoint(x: s * 0.5, y: s * 0.44)); bar.line(to: NSPoint(x: s * 0.5, y: s * 0.72))
    bar.lineWidth = s * 0.12; bar.lineCapStyle = .round; NSColor.white.setStroke(); bar.stroke()
    NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: s * 0.44, y: s * 0.22, width: s * 0.12, height: s * 0.12)).fill()
}

let fm = FileManager.default
for (name, draw) in [("NimboCheckBadge", check), ("NimboCloudBadge", cloud), ("NimboUploadBadge", upload), ("NimboErrorBadge", failed)] as [(String, (CGFloat) -> Void)] {
    let iconset = output.appendingPathComponent(name + ".iconset")
    try? fm.removeItem(at: iconset)
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        try render(base, draw).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
        try render(base * 2, draw).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
    try render(64, draw).write(to: output.appendingPathComponent(name + ".png"))
}
print("ok")
