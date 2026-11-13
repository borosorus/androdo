import AppKit

// Compiled with AndrodoMarkGeometry.swift; no duplicate logo paths.
@main
struct GenerateAppIcon {
  static func icon(size: Int) throws -> Data {
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0),
      let graphics = NSGraphicsContext(bitmapImageRep: bitmap)
    else { fatalError("No icon drawing context") }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let background = NSBezierPath(
      roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 204, yRadius: 204)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor(calibratedRed: 0.20, green: 0.40, blue: 0.79, alpha: 1).setFill()
    background.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(
      starting: NSColor(calibratedRed: 0.20, green: 0.40, blue: 0.79, alpha: 1),
      ending: NSColor(calibratedRed: 0.18, green: 0.56, blue: 0.59, alpha: 1))!
      .draw(in: background, angle: -45)
    context.saveGState()
    context.translateBy(x: 180.48, y: 843.52)
    context.scaleBy(x: 6.6304, y: -6.6304)
    context.setFillColor(NSColor.white.cgColor)
    context.addPath(AndrodoMarkGeometry.body(in: CGRect(x: 0, y: 0, width: 100, height: 100)))
    context.drawPath(using: .eoFill)
    context.setFillColor(NSColor(calibratedRed: 0.70, green: 0.43, blue: 0.25, alpha: 1).cgColor)
    context.addPath(AndrodoMarkGeometry.fold(in: CGRect(x: 0, y: 0, width: 100, height: 100)))
    context.fillPath()
    context.restoreGState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      fatalError("Cannot encode icon")
    }
    return png
  }

  static func main() throws {
    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for size in [16, 32, 128, 256, 512] {
      try icon(size: size).write(to: output.appendingPathComponent("icon_\(size)x\(size).png"))
      try icon(size: size * 2).write(
        to: output.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
    }
  }
}
