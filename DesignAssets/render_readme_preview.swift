import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Assets/README-preview.png")
let pixelsWide = 1600
let pixelsHigh = 960
let size = CGSize(width: pixelsWide, height: pixelsHigh)

func roundedPath(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func fillRounded(_ rect: CGRect, radius: CGFloat, color: NSColor) {
    color.setFill()
    roundedPath(rect, radius: radius).fill()
}

func strokeRounded(_ rect: CGRect, radius: CGFloat, color: NSColor, width: CGFloat) {
    color.setStroke()
    let path = roundedPath(rect, radius: radius)
    path.lineWidth = width
    path.stroke()
}

func drawText(_ text: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color
    ]
    (text as NSString).draw(at: point, withAttributes: attrs)
}

func drawCenteredText(_ text: String, in rect: CGRect, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color
    ]
    let textSize = (text as NSString).size(withAttributes: attrs)
    let point = CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2)
    (text as NSString).draw(at: point, withAttributes: attrs)
}

func drawCircle(center: CGPoint, radius: CGFloat, color: NSColor) {
    color.setFill()
    NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
}

func drawMiniGrid(in rect: CGRect, lit: Int, scaleGlow: Bool = false) {
    let gap: CGFloat = rect.width * 0.055
    let cell = (rect.width - gap * 2) / 3
    let corner = cell * 0.18
    let tones = [
        NSColor(calibratedRed: 0.68, green: 1.0, blue: 0.72, alpha: 1),
        NSColor.systemGreen,
        NSColor(calibratedRed: 0.06, green: 0.44, blue: 0.16, alpha: 1)
    ]

    for index in 0..<9 {
        let row = index / 3
        let column = index % 3
        let cellRect = CGRect(
            x: rect.minX + CGFloat(column) * (cell + gap),
            y: rect.maxY - cell - CGFloat(row) * (cell + gap),
            width: cell,
            height: cell
        )
        if index < lit {
            if scaleGlow, index == lit - 1 {
                fillRounded(cellRect.insetBy(dx: -4, dy: -4), radius: corner + 4, color: NSColor.systemGreen.withAlphaComponent(0.16))
            }
            let path = roundedPath(cellRect, radius: corner)
            NSGradient(colors: [
                tones[index % tones.count].withAlphaComponent(0.96),
                NSColor(calibratedRed: 0.02, green: 0.36, blue: 0.14, alpha: 1)
            ])?.draw(in: path, angle: -45)
        } else {
            fillRounded(cellRect, radius: corner, color: NSColor.white.withAlphaComponent(0.16))
        }
    }
}

func drawProjectRow(y: CGFloat, name: String, status: String, color: NSColor) {
    drawCircle(center: CGPoint(x: 466, y: y + 15), radius: 6, color: color)
    drawText(name, at: CGPoint(x: 484, y: y + 5), size: 18, weight: .semibold, color: NSColor.white.withAlphaComponent(0.92))
    drawText(status, at: CGPoint(x: 812, y: y + 7), size: 15, weight: .medium, color: color)
    NSColor.white.withAlphaComponent(0.08).setStroke()
    let line = NSBezierPath()
    line.move(to: CGPoint(x: 440, y: y - 13))
    line.line(to: CGPoint(x: 920, y: y - 13))
    line.lineWidth = 1
    line.stroke()
}

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixelsWide,
    pixelsHigh: pixelsHigh,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bitmapFormat: [],
    bytesPerRow: 0,
    bitsPerPixel: 0
), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("failed to create preview bitmap")
}

bitmap.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics

let canvas = CGRect(origin: .zero, size: size)
NSGradient(colors: [
    NSColor(calibratedRed: 0.015, green: 0.025, blue: 0.032, alpha: 1),
    NSColor(calibratedRed: 0.025, green: 0.095, blue: 0.080, alpha: 1),
    NSColor(calibratedRed: 0.020, green: 0.030, blue: 0.045, alpha: 1)
])?.draw(in: NSBezierPath(rect: canvas), angle: -30)

for (x, y, alpha) in [(310, 740, 0.18), (1210, 280, 0.14), (980, 780, 0.10)] as [(CGFloat, CGFloat, CGFloat)] {
    NSColor.systemGreen.withAlphaComponent(alpha).setFill()
    NSBezierPath(ovalIn: CGRect(x: x - 190, y: y - 190, width: 380, height: 380)).fill()
}

drawText("AgentRadar", at: CGPoint(x: 130, y: 790), size: 56, weight: .bold, color: .white)
drawText("Project-level Claude Code and Codex task radar for macOS.", at: CGPoint(x: 132, y: 744), size: 24, weight: .medium, color: NSColor.white.withAlphaComponent(0.66))

let screen = CGRect(x: 350, y: 158, width: 1010, height: 610)
fillRounded(screen, radius: 34, color: NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.09, alpha: 0.92))
strokeRounded(screen, radius: 34, color: NSColor.white.withAlphaComponent(0.14), width: 1.5)

let menuBar = CGRect(x: screen.minX, y: screen.maxY - 54, width: screen.width, height: 54)
fillRounded(menuBar, radius: 34, color: NSColor.white.withAlphaComponent(0.10))
fillRounded(CGRect(x: screen.minX, y: screen.maxY - 54, width: screen.width, height: 28), radius: 0, color: NSColor.white.withAlphaComponent(0.10))
drawCircle(center: CGPoint(x: 385, y: menuBar.midY), radius: 7, color: NSColor.systemRed.withAlphaComponent(0.9))
drawCircle(center: CGPoint(x: 410, y: menuBar.midY), radius: 7, color: NSColor.systemYellow.withAlphaComponent(0.9))
drawCircle(center: CGPoint(x: 435, y: menuBar.midY), radius: 7, color: NSColor.systemGreen.withAlphaComponent(0.9))
drawText("Tue 09:42", at: CGPoint(x: 1215, y: menuBar.midY - 10), size: 16, weight: .medium, color: NSColor.white.withAlphaComponent(0.68))

let statusItem = CGRect(x: 1094, y: menuBar.midY - 16, width: 84, height: 32)
fillRounded(statusItem, radius: 16, color: NSColor.white.withAlphaComponent(0.10))
drawMiniGrid(in: CGRect(x: statusItem.minX + 13, y: statusItem.minY + 7, width: 18, height: 18), lit: 6)
drawText("3", at: CGPoint(x: statusItem.minX + 43, y: statusItem.minY + 7), size: 18, weight: .bold, color: NSColor.white.withAlphaComponent(0.92))

let popover = CGRect(x: 408, y: 242, width: 560, height: 420)
fillRounded(popover, radius: 18, color: NSColor(calibratedRed: 0.102, green: 0.112, blue: 0.125, alpha: 0.96))
strokeRounded(popover, radius: 18, color: NSColor.white.withAlphaComponent(0.13), width: 1)

drawText("AgentRadar", at: CGPoint(x: 440, y: 616), size: 21, weight: .semibold, color: .white)
fillRounded(CGRect(x: 686, y: 607, width: 74, height: 30), radius: 8, color: NSColor.systemGreen.withAlphaComponent(0.18))
drawText("codex", at: CGPoint(x: 702, y: 613), size: 15, weight: .semibold, color: NSColor.white.withAlphaComponent(0.88))
fillRounded(CGRect(x: 766, y: 607, width: 78, height: 30), radius: 8, color: NSColor.white.withAlphaComponent(0.08))
drawText("claude", at: CGPoint(x: 780, y: 613), size: 15, weight: .semibold, color: NSColor.white.withAlphaComponent(0.58))

drawProjectRow(y: 548, name: "AgentRadar", status: "运行 1分24秒", color: NSColor.systemGreen)
drawProjectRow(y: 492, name: "cells-at-work", status: "等待输入", color: NSColor.systemYellow)
drawProjectRow(y: 436, name: "endless-td", status: "空闲", color: NSColor.white.withAlphaComponent(0.46))

let bubble = CGRect(x: 1012, y: 490, width: 330, height: 86)
fillRounded(bubble, radius: 18, color: NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.14, alpha: 0.96))
strokeRounded(bubble, radius: 18, color: NSColor.white.withAlphaComponent(0.13), width: 1)
drawCircle(center: CGPoint(x: 1048, y: 540), radius: 11, color: NSColor.systemGreen)
drawText("AgentRadar", at: CGPoint(x: 1070, y: 545), size: 18, weight: .semibold, color: .white)
drawText("任务完成，请及时审阅", at: CGPoint(x: 1070, y: 516), size: 16, weight: .regular, color: NSColor.white.withAlphaComponent(0.68))

let iconPanel = CGRect(x: 108, y: 292, width: 230, height: 230)
fillRounded(iconPanel, radius: 44, color: NSColor.black.withAlphaComponent(0.20))
drawMiniGrid(in: iconPanel.insetBy(dx: 42, dy: 42), lit: 7, scaleGlow: true)
drawText("running", at: CGPoint(x: 155, y: 246), size: 20, weight: .semibold, color: NSColor.systemGreen.withAlphaComponent(0.9))

graphics.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("failed to render preview")
}

try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try png.write(to: output)
