import AppKit

// Original Androdo mark. All artwork is drawn locally; no external assets.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func icon(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                        isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0),
          let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("No icon drawing context") }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let background = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 204, yRadius: 204)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor(calibratedRed: 0.20, green: 0.40, blue: 0.79, alpha: 1).setFill()
    background.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.40, blue: 0.79, alpha: 1),
               ending: NSColor(calibratedRed: 0.18, green: 0.56, blue: 0.59, alpha: 1))!
        .draw(in: background, angle: -45)
    let phone = NSBezierPath(roundedRect: NSRect(x: 285, y: 270, width: 287, height: 502), xRadius: 63, yRadius: 63)
    NSColor.white.setStroke()
    phone.lineWidth = 40
    phone.stroke()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 375, y: 726, width: 108, height: 22), xRadius: 11, yRadius: 11).fill()
    NSBezierPath(roundedRect: NSRect(x: 455, y: 215, width: 350, height: 242), xRadius: 40, yRadius: 40).fill()
    NSColor(calibratedRed: 0.70, green: 0.43, blue: 0.25, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 564, y: 365, width: 134, height: 31), xRadius: 15, yRadius: 15).fill()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode icon") }
    return png
}

for size in [16, 32, 128, 256, 512] {
    try icon(size: size).write(to: output.appendingPathComponent("icon_\(size)x\(size).png"))
    try icon(size: size * 2).write(to: output.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
