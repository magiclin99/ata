// Draws the disk image window background: ATA on the left, Applications on the right, an arrow between them and
// one line of instructions in English and Traditional Chinese.
//   swift scripts/make-dmg-background.swift   → Resources/dmg/background.tiff (1x + 2x)
// Icon positions must match scripts/dmg-settings.py (window 640×420 points, icons centred at x 170 and 470, y 200).
import AppKit

let W: CGFloat = 640, H: CGFloat = 420
func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // Background: soft paper white with a faint ink tint (brand ink #1B2348).
    NSColor(calibratedRed: 0.965, green: 0.968, blue: 0.980, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: W, height: H).fill()

    // Arrow from ATA (x 170) to Applications (x 470); Finder's y axis runs top-down, AppKit's bottom-up.
    let y = H - 200
    let ember = NSColor(calibratedRed: 1.0, green: 0.478, blue: 0.271, alpha: 1)   // brand ember #FF7A45
    ember.setStroke(); ember.setFill()
    let shaft = NSBezierPath()
    shaft.move(to: NSPoint(x: 250, y: y)); shaft.line(to: NSPoint(x: 376, y: y))
    shaft.lineWidth = 8; shaft.lineCapStyle = .round; shaft.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 394, y: y)); head.line(to: NSPoint(x: 368, y: y + 18)); head.line(to: NSPoint(x: 368, y: y - 18)); head.close()
    head.fill()

    // Instructions.
    let ink = NSColor(calibratedRed: 0.106, green: 0.137, blue: 0.282, alpha: 1)
    let para = NSMutableParagraphStyle(); para.alignment = .center
    func line(_ s: String, size: CGFloat, weight: NSFont.Weight, y: CGFloat) {
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: ink, .paragraphStyle: para]
        NSAttributedString(string: s, attributes: a).draw(in: NSRect(x: 20, y: y, width: W - 40, height: size * 1.5))
    }
    line("把 ATA 拖到「應用程式」", size: 20, weight: .semibold, y: 70)
    line("Drag ATA to Applications", size: 15, weight: .regular, y: 44)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/dmg/background.tiff")
let img = NSImage(size: NSSize(width: W, height: H))
img.addRepresentation(render(scale: 1))
img.addRepresentation(render(scale: 2))
try! img.tiffRepresentation(using: .lzw, factor: 0)!.write(to: out)
print("wrote \(out.path)")
