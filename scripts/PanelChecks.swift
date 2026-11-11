import AppKit
import SwiftUI

final class InputFixtureWindow: NSWindow {
    var dragCalls = 0
    var events: [NSEvent] = []
    override func performDrag(with event: NSEvent) { dragCalls += 1 }
    override func nextEvent(matching mask: NSEvent.EventTypeMask) -> NSEvent? {
        events.isEmpty ? nil : events.removeFirst()
    }
}

@main
struct PanelChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
            count += 1
        }
        let left = NSRect(x: -1000, y: 0, width: 1000, height: 800)
        let right = NSRect(x: 0, y: 0, width: 1200, height: 900)
        check(PanelPlacement.screen(for: NSRect(x: -20, y: 100, width: 340, height: 520), visibleFrames: [left, right]) == right,
              "A window mostly on the right monitor must not snap to the first intersecting display")
        let offscreen = PanelPlacement.clamped(NSRect(x: 5000, y: -5000, width: 340, height: 520), inside: right)
        check(right.contains(offscreen), "Restored offscreen window must be reachable")
        check(PanelPlacement.screen(for: offscreen, visibleFrames: []) == nil, "No displays must be safe")
        let small = NSRect(x: 0, y: 0, width: 320, height: 300)
        check(small.contains(PanelPlacement.clamped(NSRect(x: 0, y: 0, width: 800, height: 1400), inside: small)), "Large window fits small display")
        let initial = NSRect(x: 50, y: 100, width: 340, height: 520)
        let grown = WindowResizeView.resizedFrame(initial: initial, delta: NSPoint(x: 100, y: -80), minimum: NSSize(width: 300, height: 240), maximum: NSSize(width: 800, height: 1400))
        check(grown.width == 440 && grown.height == 600 && grown.maxY == initial.maxY && grown.minX == initial.minX, "Corner resize anchors top left")
        let shrunk = WindowResizeView.resizedFrame(initial: initial, delta: NSPoint(x: -900, y: 900), minimum: NSSize(width: 300, height: 240), maximum: NSSize(width: 800, height: 1400))
        check(shrunk.size == NSSize(width: 300, height: 240), "Minimum readable size enforced")
        let large = WindowResizeView.resizedFrame(initial: initial, delta: NSPoint(x: 9000, y: -9000), minimum: NSSize(width: 300, height: 240), maximum: NSSize(width: 800, height: 1400))
        check(large.size == NSSize(width: 800, height: 1400), "Maximum size enforced")

        let inputWindow = InputFixtureWindow(contentRect: initial, styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        inputWindow.minSize = NSSize(width: 300, height: 240)
        inputWindow.maxSize = NSSize(width: 800, height: 1400)
        inputWindow.isReleasedWhenClosed = false
        let inputContent = PanelContentView(hostingView: NSView())
        inputWindow.contentView = inputContent
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                               windowNumber: inputWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let down = event(.leftMouseDown, NSPoint(x: 100, y: 100))
        var callbacks: [String] = []
        inputContent.dragView.onDragBegan = { callbacks.append("begin") }
        inputContent.dragView.onDragEnded = { callbacks.append("end") }
        inputContent.dragView.mouseDown(with: down)
        check(inputWindow.dragCalls == 1 && callbacks == ["begin", "end"], "A title click invokes native dragging with lifecycle callbacks")
        check(inputContent.dragView.acceptsFirstMouse(for: down), "Dragging accepts first click on inactive window")
        callbacks = []
        inputContent.resizeView.onResizeBegan = { callbacks.append("begin") }
        inputContent.resizeView.onResizeEnded = { callbacks.append("end") }
        inputWindow.events = [event(.leftMouseDragged, NSPoint(x: 140, y: 70)), event(.leftMouseUp, NSPoint(x: 140, y: 70))]
        inputContent.resizeView.mouseDown(with: down)
        check(inputWindow.frame.size == NSSize(width: 380, height: 550), "Corner input sequence changes actual hidden NSWindow frame")
        check(inputWindow.frame.maxY == initial.maxY && callbacks == ["begin", "end"], "Native resize preserves top edge and completes lifecycle")
        check(!inputWindow.isVisible, "Synthetic local events never display a window or post global input")

        let suite = "PanelChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(NSStringFromSize(NSSize(width: 480, height: 400)), forKey: "AIBalanceBoard.panelSize")
        let controller = PanelController(content: AnyView(Text("fixture")), defaults: defaults)
        let window = Mirror(reflecting: controller).children.first(where: { $0.label == "panel" })!.value as! NSPanel
        check(!window.isVisible, "Fixture must never show a window")
        check(window.level == .normal && !controller.alwaysOnTop, "New default must not cover other applications")
        check(window.styleMask.contains(.resizable), "Native edges are resizable")
        check(window.frame.size == NSSize(width: 480, height: 400), "Saved size restored")
        let content = window.contentView as! PanelContentView
        content.layoutSubtreeIfNeeded()
        check(content.dragView.frame.width > 100, "Native drag surface laid out")
        for width in [CGFloat(300), 340, 480, 800] {
            content.setFrameSize(NSSize(width: width, height: 400))
            content.needsLayout = true
            content.layoutSubtreeIfNeeded()
            check(content.hitTest(NSPoint(x: 20, y: 370)) === content.dragView, "Title receives first click at every width")
            check(content.hitTest(NSPoint(x: width - 90, y: 370)) !== content.dragView, "Settings button is not blocked")
            check(content.hitTest(NSPoint(x: width - 10, y: 10)) === content.resizeView, "Resize handle receives input")
            check(content.hitTest(NSPoint(x: 40, y: 150)) !== content.dragView, "Cards retain scroll/button input")
        }
        content.setFrameSize(window.frame.size)
        let stableFrame = window.frame
        let stableDragView = content.dragView
        for i in 0..<20 { controller.update(content: AnyView(Text("reading \(i)"))) }
        check(window.frame == stableFrame, "Repeated data refresh preserves user's position and size")
        check(content.dragView === stableDragView, "Refresh never replaces native drag surface")
        content.dragView.onDragBegan?()
        controller.update(content: AnyView(Text("arrived during drag")))
        check(window.frame == stableFrame, "Refresh during drag cannot move or resize window")
        content.dragView.onDragEnded?()
        check(defaults.string(forKey: "AIBalanceBoard.panelSize") == NSStringFromSize(window.frame.size), "Drag completion persists size")
        controller.setAlwaysOnTop(true)
        check(window.level == .floating && controller.alwaysOnTop, "Opt-in topmost applies immediately")
        controller.setAlwaysOnTop(false)
        check(window.level == .normal, "Topmost can be disabled without restart")
        check(!window.isVisible && NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground, "All tests stay offscreen and preserve foreground app")
        print("Panel: \(count) checks passed (no visible windows or global input)")
    }
}
