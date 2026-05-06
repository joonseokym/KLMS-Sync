import AppKit
import Foundation

struct IconGenerator {
  let outputDirectory: URL

  func generate() throws {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    let sizes: [(String, CGFloat)] = [
      ("icon_16x16.png", 16),
      ("icon_16x16@2x.png", 32),
      ("icon_32x32.png", 32),
      ("icon_32x32@2x.png", 64),
      ("icon_128x128.png", 128),
      ("icon_128x128@2x.png", 256),
      ("icon_256x256.png", 256),
      ("icon_256x256@2x.png", 512),
      ("icon_512x512.png", 512),
      ("icon_512x512@2x.png", 1024)
    ]

    for (filename, size) in sizes {
      let image = drawIcon(size: size)
      try writePNG(image, to: outputDirectory.appendingPathComponent(filename))
    }
  }

  private func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let scale = size / 1024
    func r(_ value: CGFloat) -> CGFloat { value * scale }
    func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
      NSRect(x: r(x), y: r(y), width: r(width), height: r(height))
    }

    NSColor.clear.setFill()
    NSRect(origin: .zero, size: image.size).fill()

    let canvas = NSBezierPath(roundedRect: rect(74, 74, 876, 876), xRadius: r(198), yRadius: r(198))
    let baseGradient = NSGradient(colors: [
      NSColor(red: 0.08, green: 0.18, blue: 0.28, alpha: 1),
      NSColor(red: 0.09, green: 0.36, blue: 0.52, alpha: 1),
      NSColor(red: 0.18, green: 0.63, blue: 0.66, alpha: 1)
    ])
    baseGradient?.draw(in: canvas, angle: 135)

    NSColor.white.withAlphaComponent(0.16).setStroke()
    canvas.lineWidth = r(8)
    canvas.stroke()

    let glow = NSBezierPath(ovalIn: rect(132, 112, 760, 760))
    NSColor(red: 0.54, green: 0.88, blue: 0.94, alpha: 0.16).setFill()
    glow.fill()

    let calendarShadow = NSBezierPath(roundedRect: rect(248, 252, 528, 528), xRadius: r(92), yRadius: r(92))
    NSColor.black.withAlphaComponent(0.22).setFill()
    calendarShadow.transform(using: AffineTransform(translationByX: r(0), byY: -r(24)))
    calendarShadow.fill()

    let calendar = NSBezierPath(roundedRect: rect(248, 276, 528, 528), xRadius: r(92), yRadius: r(92))
    NSColor(red: 0.96, green: 0.98, blue: 1.00, alpha: 1).setFill()
    calendar.fill()

    let header = NSBezierPath(roundedRect: rect(248, 642, 528, 162), xRadius: r(92), yRadius: r(92))
    NSColor(red: 0.18, green: 0.47, blue: 0.83, alpha: 1).setFill()
    header.fill()
    NSColor(red: 0.18, green: 0.47, blue: 0.83, alpha: 1).setFill()
    rect(248, 642, 528, 78).fill()

    let binderColor = NSColor(red: 0.77, green: 0.93, blue: 1.00, alpha: 1)
    for x in [360, 664] as [CGFloat] {
      let ring = NSBezierPath(roundedRect: rect(x - 26, 730, 52, 108), xRadius: r(26), yRadius: r(26))
      binderColor.setFill()
      ring.fill()
      NSColor(red: 0.09, green: 0.28, blue: 0.45, alpha: 0.18).setFill()
      NSBezierPath(roundedRect: rect(x - 16, 746, 32, 78), xRadius: r(16), yRadius: r(16)).fill()
    }

    let gridColor = NSColor(red: 0.42, green: 0.55, blue: 0.64, alpha: 0.28)
    gridColor.setFill()
    for y in [552, 460] as [CGFloat] {
      rect(336, y, 352, 18).fill()
    }
    for x in [336, 452, 568, 684] as [CGFloat] {
      NSBezierPath(ovalIn: rect(x, 380, 44, 44)).fill()
    }

    let orbit = NSBezierPath()
    orbit.appendOval(in: rect(190, 210, 644, 566))
    var transform = AffineTransform()
    transform.translate(x: r(512), y: r(493))
    transform.rotate(byDegrees: -23)
    transform.translate(x: -r(512), y: -r(493))
    orbit.transform(using: transform)
    NSColor(red: 0.73, green: 0.94, blue: 0.96, alpha: 0.72).setStroke()
    orbit.lineWidth = r(24)
    orbit.stroke()

    let check = NSBezierPath()
    check.move(to: NSPoint(x: r(388), y: r(502)))
    check.line(to: NSPoint(x: r(480), y: r(412)))
    check.line(to: NSPoint(x: r(646), y: r(600)))
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    NSColor(red: 0.08, green: 0.64, blue: 0.47, alpha: 1).setStroke()
    check.lineWidth = r(64)
    check.stroke()

    let sparkle = NSBezierPath()
    sparkle.move(to: NSPoint(x: r(776), y: r(310)))
    sparkle.line(to: NSPoint(x: r(812), y: r(394)))
    sparkle.line(to: NSPoint(x: r(896), y: r(430)))
    sparkle.line(to: NSPoint(x: r(812), y: r(466)))
    sparkle.line(to: NSPoint(x: r(776), y: r(550)))
    sparkle.line(to: NSPoint(x: r(740), y: r(466)))
    sparkle.line(to: NSPoint(x: r(656), y: r(430)))
    sparkle.line(to: NSPoint(x: r(740), y: r(394)))
    sparkle.close()
    NSColor(red: 1.00, green: 0.77, blue: 0.32, alpha: 1).setFill()
    sparkle.fill()

    return image
  }

  private func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
      throw NSError(domain: "IconGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not render PNG"])
    }
    try pngData.write(to: url)
  }
}

guard CommandLine.arguments.count == 2 else {
  FileHandle.standardError.write(Data("usage: GenerateKLMSAppIcon <output.iconset>\n".utf8))
  exit(2)
}

do {
  try IconGenerator(outputDirectory: URL(fileURLWithPath: CommandLine.arguments[1])).generate()
} catch {
  FileHandle.standardError.write(Data("icon generation failed: \(error.localizedDescription)\n".utf8))
  exit(1)
}
