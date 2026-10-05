// Scales a screenshot to 1280x795 and adds a caption bar below it, for the
// demo GIF (scripts/make-gif.sh).
//
//   swift scripts/caption.swift in.png out.png "Caption text"
import AppKit

let args = CommandLine.arguments
guard args.count == 4, let source = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write(Data("usage: caption.swift in.png out.png text\n".utf8))
    exit(2)
}
let width = 1280, shotHeight = 795, barHeight = 85
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: shotHeight + barHeight,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(calibratedWhite: 0.11, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: width, height: shotHeight + barHeight).fill()
source.draw(in: NSRect(x: 0, y: barHeight, width: width, height: shotHeight))
let style = NSMutableParagraphStyle()
style.alignment = .center
let text = NSAttributedString(string: args[3], attributes: [
    .font: NSFont.systemFont(ofSize: 34, weight: .semibold),
    .foregroundColor: NSColor.white,
    .paragraphStyle: style,
])
let size = text.size()
text.draw(in: NSRect(x: 0, y: (CGFloat(barHeight) - size.height) / 2, width: CGFloat(width), height: size.height))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
