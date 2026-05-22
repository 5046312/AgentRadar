import AppKit
import QuartzCore

final class TrafficLightView: NSView {
    private let red = CALayer()
    private let yellow = CALayer()
    private let green = CALayer()
    private let badge = CATextLayer()
    private var currentStatus: SessionStatus = .idle
    private var currentCount: Int = 0
    private let dotsWidth: CGFloat = 5 * 2 * 3 + 4 * 2 // radius*2*3 + spacing*2
    private let padding: CGFloat = 6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        setupDots()
    }

    required init?(coder: NSCoder) { fatalError() }

    private let radius: CGFloat = 5
    private let spacing: CGFloat = 4
    private let gap: CGFloat = 5
    private let badgeFontSize: CGFloat = 12
    private let badgeHeight: CGFloat = 16

    private func setupDots() {
        for dot in [red, yellow, green] {
            dot.cornerRadius = radius
            dot.backgroundColor = NSColor(white: 0.5, alpha: 0.35).cgColor
            layer?.addSublayer(dot)
        }
        badge.fontSize = badgeFontSize
        badge.font = NSFont.systemFont(ofSize: badgeFontSize, weight: .bold)
        badge.alignmentMode = .center
        badge.foregroundColor = NSColor.labelColor.cgColor
        badge.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(badge)
        layoutLayers()
    }

    override func layout() {
        super.layout()
        layoutLayers()
    }

    private func layoutLayers() {
        let dotY = (bounds.height - radius * 2) / 2
        for (i, dot) in [red, yellow, green].enumerated() {
            dot.frame = CGRect(
                x: padding + CGFloat(i) * (radius * 2 + spacing),
                y: dotY,
                width: radius * 2,
                height: radius * 2
            )
        }
        if !badge.isHidden, let text = badge.string as? String {
            let bw = badgeWidth(for: text)
            badge.frame = CGRect(
                x: padding + dotsWidth + gap,
                y: (bounds.height - badgeHeight) / 2,
                width: bw,
                height: badgeHeight
            )
        }
    }

    func update(status: SessionStatus, activeCount: Int) {
        currentStatus = status
        currentCount = activeCount
        applyColors()
        applyAnimation()
        applyBadge()
    }

    private func applyColors() {
        let dim = NSColor(white: 0.5, alpha: 0.35).cgColor
        red.backgroundColor = dim
        yellow.backgroundColor = dim
        green.backgroundColor = dim
        switch currentStatus {
        case .error:
            red.backgroundColor = NSColor.systemRed.cgColor
        case .waiting:
            yellow.backgroundColor = NSColor.systemYellow.cgColor
        case .running:
            green.backgroundColor = NSColor.systemGreen.cgColor
        case .completed:
            green.backgroundColor = NSColor.systemGreen.cgColor
        case .idle:
            break
        }
    }

    private func applyAnimation() {
        red.removeAllAnimations()
        yellow.removeAllAnimations()
        green.removeAllAnimations()

        switch currentStatus {
        case .running:
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.35
            pulse.duration = 0.7
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            green.add(pulse, forKey: "pulse")
        case .completed:
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1.0
            scale.toValue = 1.5
            scale.duration = 0.4
            scale.autoreverses = true
            scale.repeatCount = 4
            green.add(scale, forKey: "flash")
        case .waiting:
            let blink = CABasicAnimation(keyPath: "opacity")
            blink.fromValue = 1.0
            blink.toValue = 0.3
            blink.duration = 0.5
            blink.autoreverses = true
            blink.repeatCount = .infinity
            yellow.add(blink, forKey: "blink")
        case .error:
            let blink = CABasicAnimation(keyPath: "opacity")
            blink.fromValue = 1.0
            blink.toValue = 0.2
            blink.duration = 0.4
            blink.autoreverses = true
            blink.repeatCount = .infinity
            red.add(blink, forKey: "blink")
        case .idle:
            break
        }
    }

    private func applyBadge() {
        if currentCount > 0 {
            let text = "\(currentCount)"
            badge.string = text
            badge.isHidden = false
            let bw = badgeWidth(for: text)
            let totalW = padding + dotsWidth + gap + bw + padding
            updateItemWidth(totalW)
            layoutLayers()
        } else {
            badge.string = ""
            badge.isHidden = true
            let totalW = padding + dotsWidth + padding
            updateItemWidth(totalW)
        }
    }

    private func badgeWidth(for text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: badgeFontSize, weight: .bold)
        let size = (text as NSString).size(withAttributes: [.font: font])
        return ceil(size.width) + 2
    }

    weak var statusItem: NSStatusItem?

    private func updateItemWidth(_ width: CGFloat) {
        statusItem?.length = width
        frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
    }
}
