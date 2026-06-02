import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Assets/AppIcon-1024.png")
let pixels = 1024
let size = CGSize(width: pixels, height: pixels)

func drawRoundedRect(_ rect: CGRect, radius: CGFloat, fill: NSColor) {
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func drawRoundedGradient(_ rect: CGRect, radius: CGFloat, colors: [NSColor], angle: CGFloat) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSGradient(colors: colors)?.draw(in: path, angle: angle)
}

func strokeRoundedRect(_ rect: CGRect, radius: CGFloat, color: NSColor, width: CGFloat) {
    color.setStroke()
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    path.lineWidth = width
    path.stroke()
}

func drawRunningCell(in rect: CGRect, tone: Int) {
    let colors: [NSColor]
    switch tone {
    case 0:
        colors = [
            NSColor(calibratedRed: 0.78, green: 1.0, blue: 0.78, alpha: 1),
            NSColor(calibratedRed: 0.42, green: 0.92, blue: 0.48, alpha: 1),
            NSColor(calibratedRed: 0.10, green: 0.62, blue: 0.22, alpha: 1)
        ]
    case 2:
        colors = [
            NSColor(calibratedRed: 0.38, green: 0.82, blue: 0.42, alpha: 1),
            NSColor(calibratedRed: 0.08, green: 0.54, blue: 0.20, alpha: 1),
            NSColor(calibratedRed: 0.01, green: 0.28, blue: 0.10, alpha: 1)
        ]
    default:
        colors = [
            NSColor(calibratedRed: 0.62, green: 1.0, blue: 0.70, alpha: 1),
            NSColor.systemGreen,
            NSColor(calibratedRed: 0.04, green: 0.45, blue: 0.18, alpha: 1)
        ]
    }

    drawRoundedRect(rect.insetBy(dx: -12, dy: -12), radius: 34, fill: NSColor.systemGreen.withAlphaComponent(0.10))
    drawRoundedGradient(rect, radius: 30, colors: colors, angle: -45)
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

// App icon 所有尺寸都从 1024 画布缩放，确保小尺寸下九宫格仍然清晰。
bitmap.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics

let canvas = CGRect(origin: .zero, size: size)
drawRoundedGradient(
    canvas.insetBy(dx: 64, dy: 64),
    radius: 212,
    colors: [
        NSColor(calibratedRed: 0.02, green: 0.06, blue: 0.08, alpha: 1),
        NSColor(calibratedRed: 0.02, green: 0.16, blue: 0.13, alpha: 1),
        NSColor(calibratedRed: 0.01, green: 0.09, blue: 0.13, alpha: 1)
    ],
    angle: -35
)

strokeRoundedRect(
    canvas.insetBy(dx: 96, dy: 96),
    radius: 186,
    color: NSColor.white.withAlphaComponent(0.08),
    width: 16
)

let board = CGRect(x: 214, y: 214, width: 596, height: 596)
drawRoundedRect(board.insetBy(dx: -34, dy: -34), radius: 86, fill: NSColor.black.withAlphaComponent(0.18))
strokeRoundedRect(board.insetBy(dx: -34, dy: -34), radius: 86, color: NSColor.white.withAlphaComponent(0.08), width: 12)

let gap: CGFloat = 30
let cell = (board.width - gap * 2) / 3
let litCells = 7
let tones = [0, 1, 1, 2, 0, 1, 2]
let idleCellFill = NSColor(calibratedRed: 0.13, green: 0.22, blue: 0.22, alpha: 1)

for index in 0..<9 {
    let row = index / 3
    let column = index % 3
    let rect = CGRect(
        x: board.minX + CGFloat(column) * (cell + gap),
        y: board.maxY - cell - CGFloat(row) * (cell + gap),
        width: cell,
        height: cell
    )

    if index < litCells {
        drawRunningCell(in: rect, tone: tones[index])
    } else {
        // 未运行格用不透明深色，避免边缘透出绿色底色形成浅绿边框。
        drawRoundedRect(rect, radius: 30, fill: idleCellFill)
    }
}

let highlight = NSBezierPath(roundedRect: canvas.insetBy(dx: 110, dy: 110), xRadius: 170, yRadius: 170)
NSColor.white.withAlphaComponent(0.045).setStroke()
highlight.lineWidth = 18
highlight.stroke()

graphics.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("failed to render app icon")
}

try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try png.write(to: output)
