import AppKit
import QuartzCore

/// Native window actions follow the paper while staying outside its content.
@MainActor final class WindowControls: NSView {
    private var activityTimer: Timer?
    private var pointerInside = false
    private var revealed = false
    private var positioned = false
    private var tracking: NSTrackingArea?
    var hitRegionChanged: (() -> Void)?

    init(frame: NSRect, target: AnyObject, minimize: Selector, close: Selector) {
        super.init(frame: frame)
        autoresizingMask = [.minXMargin, .minYMargin]
        wantsLayer = true
        alphaValue = 0
        for (index, kind) in WindowControlButton.Kind.allCases.enumerated() {
            let button = WindowControlButton(kind: kind)
            button.frame = NSRect(x: CGFloat(index) * 38, y: 0, width: 30, height: 30)
            button.target = target
            button.action = kind == .minimize ? minimize : close
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { nil }

    func anchor(right: CGFloat, top: CGFloat, enabled: Bool = true) {
        guard right.isFinite, top.isFinite, let parent = superview else { return }
        let x = min(max(8, right - frame.width), parent.bounds.width - frame.width - 8)
        let y = min(max(8, top - frame.height - 12), parent.bounds.height - frame.height - 8)
        setFrameOrigin(NSPoint(x: x, y: parent.bounds.height - y - frame.height))
        positioned = true
        isHidden = !enabled
        if !enabled { suspend() }
        hitRegionChanged?()
    }

    func containsPointer(_ windowPoint: NSPoint, includingHidden: Bool = false) -> Bool {
        !isHidden && positioned && (revealed || includingHidden) && bounds.contains(convert(windowPoint, from: nil))
    }

    func updatePointerPosition(_ windowPoint: NSPoint) {
        pointerInside = containsPointer(windowPoint)
    }

    func pointerActivity() {
        guard !isHidden, positioned, window?.isKeyWindow == true else { return }
        setRevealed(true)
        if let activityTimer {
            activityTimer.fireDate = Date().addingTimeInterval(1.1)
        } else {
            activityTimer = Timer.scheduledTimer(withTimeInterval: 1.1, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.activityTimer = nil
                    if !self.pointerInside && !self.hasKeyboardFocus { self.setRevealed(false) }
                }
            }
        }
    }

    func suspend() {
        activityTimer?.invalidate()
        activityTimer = nil
        pointerInside = false
        setRevealed(false)
    }

    private var hasKeyboardFocus: Bool { subviews.contains { $0 === window?.firstResponder } }

    private func setRevealed(_ value: Bool) {
        guard revealed != value else { return }
        revealed = value
        hitRegionChanged?()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : (value ? 0.14 : 0.24)
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = value ? 1 : 0
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { revealed ? super.hitTest(point) : nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { pointerInside = true; pointerActivity() }
    override func mouseExited(with event: NSEvent) { pointerInside = false; pointerActivity() }
}

@MainActor private final class WindowControlButton: NSButton {
    enum Kind: CaseIterable { case minimize, close }
    private let kind: Kind
    private var hovered = false
    private var hoverTracking: NSTrackingArea?

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryPushIn)
        focusRingType = .exterior
        let label = kind == .minimize ? "收起到 Dock" : "关闭窗口"
        toolTip = kind == .minimize ? label : "关闭窗口并结束本轮"
        setAccessibilityLabel(label)
        if kind == .close { setAccessibilityHelp("关闭窗口并结束本轮，已完成的学习进度保留。") }
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { (superview as? WindowControls)?.pointerActivity() }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { (superview as? WindowControls)?.pointerActivity() }
        return accepted
    }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 1, dy: 1) }
    override func drawFocusRingMask() { NSBezierPath(ovalIn: focusRingMaskBounds).fill() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking)
        hoverTracking = tracking
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let active = hovered || isHighlighted
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        let tint: NSColor = kind == .close && active ? .systemRed : .labelColor
        (isHighlighted ? tint.withAlphaComponent(0.13) : NSColor.windowBackgroundColor.withAlphaComponent(active ? 0.96 : 0.72)).setFill()
        circle.fill()
        NSColor.separatorColor.withAlphaComponent(active ? 0.55 : 0.25).setStroke()
        circle.lineWidth = 0.75
        circle.stroke()

        let mark = NSBezierPath()
        mark.lineWidth = 1.35
        mark.lineCapStyle = .round
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        if kind == .minimize {
            mark.move(to: NSPoint(x: center.x - 4, y: center.y))
            mark.line(to: NSPoint(x: center.x + 4, y: center.y))
        } else {
            for direction in [-1.0, 1.0] {
                mark.move(to: NSPoint(x: center.x - 3.25, y: center.y - direction * 3.25))
                mark.line(to: NSPoint(x: center.x + 3.25, y: center.y + direction * 3.25))
            }
        }
        (active ? tint : NSColor.secondaryLabelColor).setStroke()
        mark.stroke()
    }
}
