import Cocoa

class IconManager {
    private let statusItem: NSStatusItem
    private var pulseTimer: Timer?
    private(set) var currentState: AppState = .idle

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        setIcon(dotColor: nil)
    }

    func setState(_ state: AppState) {
        currentState = state
        stopAnimations()
        switch state {
        case .needsSetup:          setIcon(dotColor: .systemOrange)
        case .idle:                setIcon(dotColor: .systemGreen)
        case .running:             startPulse(color: MLColor.gold)
        case .stopping:            startPulse(color: .systemOrange)
        case .restoring:           startPulse(color: .systemBlue)
        case .error:               setIcon(dotColor: .systemRed)
        case .diskAbsent:          setIcon(dotColor: .systemRed)
        case .stale:               setIcon(dotColor: .systemOrange)
        }
    }

    private func setIcon(dotColor: NSColor?) {
        guard let button = statusItem.button else { return }

        let symConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium, scale: .medium)
        guard let baseSymbol = NSImage(systemSymbolName: "clock.arrow.circlepath",
                                        accessibilityDescription: AppIdentity.name)?
                .withSymbolConfiguration(symConfig) else { return }

        // No dot -- use system template rendering (auto white/black)
        guard let dotColor = dotColor else {
            baseSymbol.isTemplate = true
            button.image = baseSymbol
            return
        }

        let baseSize = baseSymbol.size
        let totalW = baseSize.width + 7
        let finalSize = NSSize(width: totalW, height: baseSize.height)

        let composite = NSImage(size: finalSize, flipped: false) { rect in
            // Draw icon tinted to match menu bar (white in dark, black in light)
            let isDark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let iconColor: NSColor = isDark ? .white : .black

            let tinted = baseSymbol.copy() as! NSImage
            tinted.isTemplate = false
            tinted.lockFocus()
            iconColor.set()
            NSRect(origin: .zero, size: baseSize).fill(using: .sourceAtop)
            tinted.unlockFocus()
            tinted.draw(in: NSRect(origin: .zero, size: baseSize))

            // Colored status dot (bottom-right)
            let dotD: CGFloat = 7
            let dotRect = NSRect(x: totalW - dotD, y: 0, width: dotD, height: dotD)

            // Outline for contrast
            let outlineRect = dotRect.insetBy(dx: -1, dy: -1)
            let bgColor: NSColor = isDark ? NSColor(white: 0.1, alpha: 1) : .white
            bgColor.setFill()
            NSBezierPath(ovalIn: outlineRect).fill()

            // Dot
            dotColor.setFill()
            NSBezierPath(ovalIn: dotRect).fill()

            return true
        }
        composite.isTemplate = false
        button.image = composite
    }

    // F-22: 3-frame pulse animation with brand color — gold for backup, orange for stopping, blue for restore
    private func startPulse(color: NSColor) {
        let frames: [NSColor] = [
            color,
            color.withAlphaComponent(0.55),
            color.withAlphaComponent(0.2)
        ]
        var frame = 0
        setIcon(dotColor: frames[0])
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            frame = (frame + 1) % frames.count
            self?.setIcon(dotColor: frames[frame])
        }
    }

    private func stopAnimations() {
        pulseTimer?.invalidate()
        pulseTimer = nil
    }
}
