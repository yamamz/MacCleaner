// Renders MacSweep's app icon into Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (run from the project root)
import AppKit

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // macOS icon grid: 824pt tile centred on a 1024pt canvas, with a soft drop shadow.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28 * s
    shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Purple → pink → blue, matching the Smart Scan screen.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [NSColor(red: 0.42, green: 0.25, blue: 0.95, alpha: 1),
                        NSColor(red: 0.85, green: 0.30, blue: 0.75, alpha: 1),
                        NSColor(red: 1.00, green: 0.50, blue: 0.55, alpha: 1)])!
        .draw(in: tile, angle: -50)
    // Glossy highlight across the top half.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
    // A faint ring, like a sweep.
    let ring = NSBezierPath(ovalIn: tile.insetBy(dx: 120 * s, dy: 120 * s))
    ring.lineWidth = 26 * s
    NSColor.white.withAlphaComponent(0.18).setStroke()
    ring.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // White sparkles glyph with a soft glow.
    let config = NSImage.SymbolConfiguration(pointSize: 420 * s, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let glyph = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let g = glyph.size
        let rect = NSRect(x: tile.midX - g.width / 2, y: tile.midY - g.height / 2 - 6 * s,
                          width: g.width, height: g.height)
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = NSColor(red: 0.3, green: 0.1, blue: 0.5, alpha: 0.45)
        glow.shadowBlurRadius = 30 * s
        glow.shadowOffset = NSSize(width: 0, height: -10 * s)
        glow.set()
        glyph.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = render(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}
try fm.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try task.run()
task.waitUntilExit()
try render(size: 512).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Resources/AppIcon-preview.png"))
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
