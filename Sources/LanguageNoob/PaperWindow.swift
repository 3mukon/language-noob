import AppKit

/// Coordinates are WebKit viewport points, independent of the display scale.
struct WindowSurfaceLayout: Decodable {
    struct Point: Decodable { let x: Double; let y: Double }
    let width: Double
    let height: Double
    let polygons: [[Point]]

    var isValid: Bool {
        width.isFinite && height.isFinite && (1...16_384).contains(width) && (1...16_384).contains(height)
            && polygons.count <= 12 && polygons.allSatisfy { polygon in
                polygon.count == 4 && polygon.allSatisfy { $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 65_536 && abs($0.y) <= 65_536 }
            }
    }

    func contains(_ point: NSPoint, viewport: NSSize) -> Bool {
        guard isValid, abs(width - viewport.width) < 1, abs(height - viewport.height) < 1,
              point.x >= 0, point.y >= 0, point.x <= width, point.y <= height else { return false }
        return polygons.contains { polygon in
            var positive = false, negative = false, area = 0.0
            for index in polygon.indices {
                let a = polygon[index], b = polygon[(index + 1) % polygon.count]
                let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
                positive = positive || cross > 0.01
                negative = negative || cross < -0.01
                area += a.x * b.y - b.x * a.y
            }
            return abs(area) > 1 && !(positive && negative)
        }
    }
}

final class PaperWindow: NSWindow {
    weak var paperControls: WindowControls?
    private var pointerDownEvent: NSEvent?
    private var surfaceLayout: WindowSurfaceLayout?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func startPointerRouting() {
        guard localMonitor == nil else { refreshMouseRouting(); return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                          .leftMouseUp, .rightMouseUp, .otherMouseUp, .scrollWheel]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            let point = event.window === self ? self?.convertPoint(toScreen: event.locationInWindow) : nil
            self?.refreshMouseRouting(at: point, pointerMoved: event.type == .mouseMoved)
            return event
        }
        // Mouse monitoring needs no keyboard interception or Accessibility grant.
        // It also observes re-entry while this window is passing events through.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.refreshMouseRouting(pointerMoved: event.type == .mouseMoved)
        }
        refreshMouseRouting()
    }

    func stopPointerRouting() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil; globalMonitor = nil
        pointerDownEvent = nil
        ignoresMouseEvents = true
    }

    @discardableResult func updateSurfaceLayout(_ layout: WindowSurfaceLayout) -> Bool {
        guard layout.isValid else { return false }
        surfaceLayout = layout
        refreshMouseRouting()
        return true
    }

    func resetSurfaceLayout() { surfaceLayout = nil; refreshMouseRouting() }

    func refreshMouseRouting(at screenPoint: NSPoint? = nil, pressedButtons: Int? = nil, pointerMoved: Bool = false) {
        guard isVisible, !isMiniaturized, !NSApp.isHidden, let content = contentView else {
            ignoresMouseEvents = true
            return
        }
        // Do not hand a held text selection, card/window drag or an underlying
        // application's drag to a different window halfway through the gesture.
        guard (pressedButtons ?? NSEvent.pressedMouseButtons) == 0 else { return }
        let windowPoint = convertPoint(fromScreen: screenPoint ?? NSEvent.mouseLocation)
        let local = content.convert(windowPoint, from: nil)
        let viewportPoint = NSPoint(x: local.x, y: content.isFlipped ? local.y : content.bounds.height - local.y)
        let overPaper = surfaceLayout?.contains(viewportPoint, viewport: content.bounds.size) == true
        paperControls?.updatePointerPosition(windowPoint)
        if pointerMoved && (overPaper || paperControls?.containsPointer(windowPoint, includingHidden: true) == true) {
            paperControls?.pointerActivity()
        }
        let transparent = !(overPaper || paperControls?.containsPointer(windowPoint) == true)
        if ignoresMouseEvents != transparent { ignoresMouseEvents = transparent }
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { pointerDownEvent = event }
        if event.type == .leftMouseUp { pointerDownEvent = nil }
        if [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(event.type) { paperControls?.pointerActivity() }
        if event.type == .leftMouseDown && event.modifierFlags.contains(.option) { beginPointerDrag(); return }
        super.sendEvent(event)
    }

    func beginPointerDrag() {
        guard let event = pointerDownEvent, NSEvent.pressedMouseButtons & 1 != 0 else { return }
        pointerDownEvent = nil
        performDrag(with: event)
        refreshMouseRouting()
    }
}
