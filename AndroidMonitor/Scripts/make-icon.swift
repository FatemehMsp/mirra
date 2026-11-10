import AppKit

// Renders the Mirra app icon (phone mirrored on a monitor) into an appiconset.
func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.055
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: tile, xRadius: s * 0.225, yRadius: s * 0.225)
    NSGradient(colors: [NSColor(red: 0.04, green: 0.16, blue: 0.22, alpha: 1), NSColor(red: 0.05, green: 0.45, blue: 0.42, alpha: 1)])!.draw(in: bg, angle: -50)

    // monitor
    let monitor = NSRect(x: s * 0.17, y: s * 0.30, width: s * 0.66, height: s * 0.45)
    let m = NSBezierPath(roundedRect: monitor, xRadius: s * 0.04, yRadius: s * 0.04)
    NSColor(white: 1, alpha: 0.14).setFill(); m.fill()
    NSColor(white: 1, alpha: 0.85).setStroke(); m.lineWidth = s * 0.018; m.stroke()
    let stand = NSBezierPath(roundedRect: NSRect(x: s * 0.40, y: s * 0.22, width: s * 0.20, height: s * 0.035), xRadius: s * 0.015, yRadius: s * 0.015)
    NSColor(white: 1, alpha: 0.85).setFill(); stand.fill()
    NSBezierPath(rect: NSRect(x: s * 0.475, y: s * 0.25, width: s * 0.05, height: s * 0.05)).fill()

    // phone
    let phone = NSRect(x: s * 0.395, y: s * 0.36, width: s * 0.21, height: s * 0.36)
    let p = NSBezierPath(roundedRect: phone, xRadius: s * 0.035, yRadius: s * 0.035)
    NSColor(red: 0.62, green: 0.95, blue: 0.55, alpha: 1).setFill(); p.fill()
    let screen = phone.insetBy(dx: s * 0.015, dy: s * 0.03)
    NSColor(red: 0.04, green: 0.16, blue: 0.22, alpha: 1).setFill()
    NSBezierPath(roundedRect: screen, xRadius: s * 0.015, yRadius: s * 0.015).fill()
    // pulse line on the phone screen
    let pulse = NSBezierPath()
    let y = screen.midY
    pulse.move(to: NSPoint(x: screen.minX + s * 0.012, y: y))
    pulse.line(to: NSPoint(x: screen.minX + s * 0.045, y: y))
    pulse.line(to: NSPoint(x: screen.minX + s * 0.06, y: y + s * 0.06))
    pulse.line(to: NSPoint(x: screen.minX + s * 0.08, y: y - s * 0.06))
    pulse.line(to: NSPoint(x: screen.minX + s * 0.095, y: y))
    pulse.line(to: NSPoint(x: screen.maxX - s * 0.012, y: y))
    NSColor(red: 0.62, green: 0.95, blue: 0.55, alpha: 1).setStroke()
    pulse.lineWidth = s * 0.012; pulse.lineJoinStyle = .round; pulse.lineCapStyle = .round; pulse.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = CommandLine.arguments[1]
let sizes: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [String] = []
for (pt, scale) in sizes {
    let name = "icon_\(pt)x\(pt)@\(scale)x.png"
    try render(pt * scale).write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
    images.append(#"{"filename":"\#(name)","idiom":"mac","scale":"\#(scale)x","size":"\#(pt)x\#(pt)"}"#)
}
try #"{"images":[\#(images.joined(separator: ","))],"info":{"author":"xcode","version":1}}"#
    .write(toFile: "\(dir)/Contents.json", atomically: true, encoding: .utf8)
