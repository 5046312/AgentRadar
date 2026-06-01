import AppKit
import QuartzCore

final class TrafficLightView: NSView {
    private let dot = CALayer()
    private let badge = CATextLayer()
    private var currentStatus: SessionStatus = .idle
    private var currentCount: Int = 0
    private let dotWidth: CGFloat = 5 * 2 // radius*2
    private let padding: CGFloat = 6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        setupDots()
    }

    required init?(coder: NSCoder) { fatalError() }

    private let radius: CGFloat = 5
    private let gap: CGFloat = 5
    private let badgeFontSize: CGFloat = 12
    private let badgeHeight: CGFloat = 16

    private func setupDots() {
        dot.cornerRadius = radius
        dot.backgroundColor = NSColor(white: 0.5, alpha: 0.35).cgColor
        layer?.addSublayer(dot)
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
        dot.frame = CGRect(
            x: padding,
            y: dotY,
            width: radius * 2,
            height: radius * 2
        )
        if !badge.isHidden, let text = badge.string as? String {
            let bw = badgeWidth(for: text)
            badge.frame = CGRect(
                x: padding + dotWidth + gap,
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
        switch currentStatus {
        case .running:
            dot.backgroundColor = NSColor.systemGreen.cgColor
        case .error:
            dot.backgroundColor = NSColor.systemRed.cgColor
        case .idle, .waiting, .completed:
            dot.backgroundColor = dim
        }
    }

    private func applyAnimation() {
        dot.removeAllAnimations()

        switch currentStatus {
        case .running:
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.35
            pulse.duration = 0.7
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(pulse, forKey: "pulse")
        case .idle, .error, .waiting, .completed:
            break
        }
    }

    private func applyBadge() {
        if currentCount > 0 {
            let text = "\(currentCount)"
            badge.string = text
            badge.isHidden = false
            let bw = badgeWidth(for: text)
            let totalW = padding + dotWidth + gap + bw + padding
            updateItemWidth(totalW)
            layoutLayers()
        } else {
            badge.string = ""
            badge.isHidden = true
            let totalW = padding + dotWidth + 4
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
