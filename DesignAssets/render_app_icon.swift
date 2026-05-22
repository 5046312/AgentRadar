import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Assets/AppIcon-1024.png")
let pixels = 1024
let size = CGSize(width: pixels, height: pixels)

func drawRoundedSquare(in rect: CGRect, radius: CGFloat, colors: [NSColor]) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    let gradient = NSGradient(colors: colors)!
    gradient.draw(in: path, angle: -45)
}

func strokeCircle(center: CGPoint, radius: CGFloat, color: NSColor, width: CGFloat) {
    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    let path = NSBezierPath(ovalIn: rect)
    color.setStroke()
    path.lineWidth = width
    path.stroke()
}

func fillCircle(center: CGPoint, radius: CGFloat, color: NSColor) {
    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    color.setFill()
    NSBezierPath(ovalIn: rect).fill()
}

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixels,
    pixelsHigh: pixels,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bitmapFormat: [],
    bytesPerRow: 0,
    bitsPerPixel: 0
), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("failed to create icon bitmap")
}

// App icon 所有尺寸都从 1024 画布缩放，避免不同尺寸出现构图偏移。
bitmap.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics

let rect = CGRect(origin: .zero, size: size)
drawRoundedSquare(
    in: rect.insetBy(dx: 64, dy: 64),
    radius: 212,
    colors: [
        NSColor(calibratedRed: 0.03, green: 0.08, blue: 0.12, alpha: 1),
        NSColor(calibratedRed: 0.02, green: 0.22, blue: 0.24, alpha: 1),
        NSColor(calibratedRed: 0.04, green: 0.09, blue: 0.16, alpha: 1)
    ]
)

let center = CGPoint(x: 512, y: 528)
let radarGreen = NSColor(calibratedRed: 0.18, green: 0.92, blue: 0.63, alpha: 1)
let mutedGreen = NSColor(calibratedRed: 0.24, green: 0.72, blue: 0.66, alpha: 0.42)
let gridWhite = NSColor.white.withAlphaComponent(0.12)

for radius in [120, 210, 300] as [CGFloat] {
    strokeCircle(center: center, radius: radius, color: gridWhite, width: 14)
}

let cross = NSBezierPath()
cross.move(to: CGPoint(x: center.x, y: center.y - 322))
cross.line(to: CGPoint(x: center.x, y: center.y + 322))
cross.move(to: CGPoint(x: center.x - 322, y: center.y))
cross.line(to: CGPoint(x: center.x + 322, y: center.y))
gridWhite.setStroke()
cross.lineWidth = 12
cross.lineCapStyle = .round
cross.stroke()

let sweep = NSBezierPath()
sweep.move(to: center)
sweep.line(to: CGPoint(x: 754, y: 704))
sweep.appendArc(withCenter: center, radius: 300, startAngle: 36, endAngle: 78)
sweep.close()
NSColor(calibratedRed: 0.19, green: 0.95, blue: 0.69, alpha: 0.28).setFill()
sweep.fill()

let beam = NSBezierPath()
beam.move(to: center)
beam.line(to: CGPoint(x: 760, y: 700))
radarGreen.withAlphaComponent(0.92).setStroke()
beam.lineWidth = 24
beam.lineCapStyle = .round
beam.stroke()

strokeCircle(center: center, radius: 28, color: radarGreen.withAlphaComponent(0.95), width: 22)
fillCircle(center: CGPoint(x: 385, y: 706), radius: 34, color: NSColor.systemRed)
fillCircle(center: CGPoint(x: 628, y: 706), radius: 34, color: NSColor.systemYellow)
fillCircle(center: CGPoint(x: 536, y: 318), radius: 42, color: radarGreen)

let letter = NSAttributedString(
    string: "A",
    attributes: [
        .font: NSFont.systemFont(ofSize: 300, weight: .black),
        .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        .kern: -12
    ]
)
let letterSize = letter.size()
letter.draw(at: CGPoint(x: center.x - letterSize.width / 2, y: center.y - letterSize.height / 2 - 6))

let shine = NSBezierPath(roundedRect: rect.insetBy(dx: 112, dy: 112), xRadius: 172, yRadius: 172)
NSColor.white.withAlphaComponent(0.045).setStroke()
shine.lineWidth = 16
shine.stroke()

graphics.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("failed to render app icon")
}

try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try png.write(to: output)
