// Draws the placeholder app icon and writes an .icns.
//
//     swift scripts/make-icon.swift App/AppIcon.icns
//
// A deep teal squircle with a door symbol and a small check badge: "nothing
// comes in until you approve it".
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "App/AppIcon.icns"

func render(_ px: Int) -> Data {
    let size = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Apple's grid: the body is ~80% of the canvas, centered.
    let inset = size * 0.1
    let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let radius = rect.width * 0.225
    let body = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(body)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let colors = [NSColor(red: 0.13, green: 0.55, blue: 0.62, alpha: 1).cgColor,
                  NSColor(red: 0.05, green: 0.24, blue: 0.36, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY),
                           end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    // Soft top highlight.
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.07).cgColor)
    ctx.fillEllipse(in: CGRect(x: rect.minX - rect.width * 0.2, y: rect.midY,
                               width: rect.width * 1.4, height: rect.height))
    ctx.restoreGState()

    // Door glyph.
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.40, weight: .medium)
        .applying(.init(paletteColors: [.white]))
    if let door = NSImage(systemSymbolName: "door.left.hand.open", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let s = door.size
        let r = CGRect(x: rect.midX - s.width / 2 - size * 0.03, y: rect.midY - s.height / 2 + size * 0.01,
                       width: s.width, height: s.height)
        door.draw(in: r)
    }

    // Check badge, lower right.
    let d = size * 0.25
    let badge = CGRect(x: rect.maxX - d - size * 0.07, y: rect.minY + size * 0.07, width: d, height: d)
    ctx.setShadow(offset: .zero, blur: size * 0.015, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.setFillColor(NSColor(red: 0.30, green: 0.80, blue: 0.45, alpha: 1).cgColor)
    ctx.fillEllipse(in: badge)
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    let checkConfig = NSImage.SymbolConfiguration(pointSize: d * 0.5, weight: .heavy)
        .applying(.init(paletteColors: [.white]))
    if let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
        .withSymbolConfiguration(checkConfig) {
        let s = check.size
        check.draw(in: CGRect(x: badge.midX - s.width / 2, y: badge.midY - s.height / 2, width: s.width, height: s.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Mudroom-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out]
try p.run()
p.waitUntilExit()
try? fm.removeItem(at: iconset)
if p.terminationStatus != 0 { exit(p.terminationStatus) }
// Also keep a PNG for the README.
try render(512).write(to: URL(fileURLWithPath: out).deletingPathExtension().appendingPathExtension("png"))
print("wrote \(out)")
