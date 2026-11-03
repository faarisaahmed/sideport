// Draws Sideport's app icon: a refresh ring around a phone, on a blue-violet rounded square.
// Usage: swift make_icon.swift <out.iconset>
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.36, green: 0.42, blue: 1, alpha: 1), NSColor(red: 0.58, green: 0.27, blue: 0.95, alpha: 1)])!
        .draw(in: shape, angle: -60)
    // Refresh ring.
    let c = NSPoint(x: s / 2, y: s / 2)
    let ring = NSBezierPath()
    ring.appendArc(withCenter: c, radius: rect.width * 0.3, startAngle: 120, endAngle: 420)
    ring.lineWidth = rect.width * 0.06
    ring.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.95).setStroke()
    ring.stroke()
    // Arrow head at the ring's end.
    let a = (420.0 - 360.0) * .pi / 180, r = rect.width * 0.3
    let tip = NSPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
    let head = NSBezierPath()
    let h = rect.width * 0.09
    head.move(to: NSPoint(x: tip.x - h * 0.9, y: tip.y + h * 0.2))
    head.line(to: NSPoint(x: tip.x + h * 0.45, y: tip.y + h * 0.75))
    head.line(to: NSPoint(x: tip.x + h * 0.35, y: tip.y - h * 0.75))
    head.close()
    NSColor.white.setFill()
    head.fill()
    // Phone.
    let pw = rect.width * 0.24, ph = rect.width * 0.38
    let phone = NSBezierPath(roundedRect: NSRect(x: c.x - pw / 2, y: c.y - ph / 2, width: pw, height: ph), xRadius: pw * 0.2, yRadius: pw * 0.2)
    NSColor.white.setFill()
    phone.fill()
    let screen = NSBezierPath(roundedRect: NSRect(x: c.x - pw / 2 + pw * 0.12, y: c.y - ph / 2 + ph * 0.1, width: pw * 0.76, height: ph * 0.8), xRadius: pw * 0.1, yRadius: pw * 0.1)
    NSColor(red: 0.45, green: 0.35, blue: 0.98, alpha: 1).setFill()
    screen.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
