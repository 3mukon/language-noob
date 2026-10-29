import AppKit

extension ApplicationChecks {
    @MainActor static func windowRoutingChecks() async throws {
        func layout(_ polygons: [[[Double]]], width: Double = 400, height: Double = 300) -> WindowSurfaceLayout {
            WindowSurfaceLayout(width: width, height: height, polygons: polygons.map { $0.map { .init(x: $0[0], y: $0[1]) } })
        }
        let paper = layout([[[100,40],[220,60],[200,220],[80,200]]])
        let viewport = NSSize(width: 400, height: 300)
        try check(paper.isValid && paper.contains(NSPoint(x: 150,y: 130), viewport: viewport), "painted paper accepts input")
        try check(!paper.contains(NSPoint(x: 85,y: 45), viewport: viewport), "empty corner of the paper bounding rectangle passes through")
        try check(!paper.contains(NSPoint(x: 150,y: 270), viewport: viewport), "transparent bottom margin passes through")
        try check(!paper.contains(NSPoint(x: 150,y: 130), viewport: NSSize(width: 700,height: 650)), "a resized viewport cannot reuse stale input geometry")
        try check(!layout([[[40,40],[40,40],[40,40],[40,40]]]).contains(NSPoint(x: 10,y: 10), viewport: viewport), "degenerate outlines never capture the whole window")
        try check(!layout([], width: .infinity).isValid && !layout([[[0,0],[1,0],[1,.nan],[0,1]]]).isValid, "nonfinite native bridge geometry is rejected")
        try check(!layout(Array(repeating: [[0,0],[1,0],[1,1],[0,1]], count: 13)).isValid, "bridge geometry has a bounded surface count")

        let window = PaperWindow(contentRect: NSRect(origin: .zero, size: viewport), styleMask: [.borderless], backing: .buffered, defer: false)
        let screenBounds = NSScreen.main!.visibleFrame
        window.setFrameOrigin(NSPoint(x: screenBounds.minX + 40, y: screenBounds.minY + 40))
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(origin: .zero, size: viewport))
        let underlay = NSWindow(contentRect: window.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        underlay.isReleasedWhenClosed = false
        underlay.level = .floating; window.level = .floating
        underlay.orderFront(nil); window.order(.above, relativeTo: underlay.windowNumber)
        defer { window.stopPointerRouting(); window.close(); underlay.close() }
        func screen(_ point: NSPoint) -> NSPoint { window.convertPoint(toScreen: NSPoint(x: point.x,y: viewport.height-point.y)) }
        let inside = screen(NSPoint(x: 150,y: 130)), outside = screen(NSPoint(x: 150,y: 270))
        func expectHit(_ point: NSPoint, _ number: Int, _ message: String) async throws {
            // Window ordering and input-shape commits reach WindowServer at the
            // next run-loop boundary, rather than synchronously with the setter.
            for _ in 0..<20 {
                if NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == number { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try check(false, "\(message); expected \(number), received \(NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)), point \(point), frame \(window.frame)")
        }
        try check(window.updateSurfaceLayout(paper), "valid renderer outlines replace the native input map")
        window.refreshMouseRouting(at: inside, pressedButtons: 0)
        try check(!window.ignoresMouseEvents, "entering a paper restores native events")
        try await expectHit(inside, window.windowNumber, "WindowServer routes a paper click to the study window")
        window.refreshMouseRouting(at: outside, pressedButtons: 1)
        try check(!window.ignoresMouseEvents, "a held paper gesture remains owned outside its outline")
        window.refreshMouseRouting(at: outside, pressedButtons: 0)
        try check(window.ignoresMouseEvents, "release outside the paper enables click-through")
        try await expectHit(outside, underlay.windowNumber, "WindowServer routes the next transparent-area click directly to the underlying window")
        window.refreshMouseRouting(at: inside, pressedButtons: 1)
        try check(window.ignoresMouseEvents, "a held gesture from another application cannot be stolen on re-entry")
        window.refreshMouseRouting(at: inside, pressedButtons: 0)
        try check(!window.ignoresMouseEvents, "re-entry after release accepts the next paper gesture")
        try check(!window.updateSurfaceLayout(layout([], width: .nan)), "invalid bridge updates are refused")
        window.refreshMouseRouting(at: inside, pressedButtons: 0)
        try check(!window.ignoresMouseEvents, "refused geometry cannot erase the last valid map")
        window.resetSurfaceLayout()
        window.refreshMouseRouting(at: inside, pressedButtons: 0)
        try check(window.ignoresMouseEvents, "a terminated renderer cannot leave a stale input surface")
        window.startPointerRouting(); window.startPointerRouting(); window.stopPointerRouting(); window.stopPointerRouting()
        try check(window.ignoresMouseEvents, "monitor shutdown is idempotent and releases native input")
        window.updateSurfaceLayout(paper); window.orderOut(nil)
        window.refreshMouseRouting(at: inside, pressedButtons: 0)
        try check(window.ignoresMouseEvents, "unavailable windows cannot capture input")
        print("PASS: native paper outlines, transparent margins, gesture ownership and routing lifecycle")
    }
}
