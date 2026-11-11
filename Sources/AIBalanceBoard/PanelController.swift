import AppKit
import SwiftUI

/// AppKit only owns the floating window; SwiftUI owns the displayed values.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let panel: FloatingBalancePanel
    private let hostingView: PassiveHostingView<AnyView>
    private let positionKey = "AIBalanceBoard.panelPosition"
    private var hasBeenShown = false

    init(content: AnyView) {
        hostingView = PassiveHostingView(rootView: content)
        panel = FloatingBalancePanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 520),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.title = "AI 额度看板"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        panel.contentView = hostingView
        resizeKeepingTopEdge()
        restorePosition()
    }

    func show() {
        if !hasBeenShown { restorePosition(); hasBeenShown = true }
        keepInsideScreen()
        panel.orderFrontRegardless()
    }

    func hide() {
        savePosition()
        panel.orderOut(nil)
    }

    func update(content: AnyView) {
        hostingView.rootView = content
        resizeKeepingTopEdge()
        keepInsideScreen()
    }

    func windowDidMove(_ notification: Notification) {
        if hasBeenShown { savePosition() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    private func resizeKeepingTopEdge() {
        hostingView.layoutSubtreeIfNeeded()
        let height = max(220, hostingView.fittingSize.height)
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - height, width: 340, height: height), display: true)
    }

    private func restorePosition() {
        if let raw = UserDefaults.standard.string(forKey: positionKey) {
            let point = NSPointFromString(raw)
            panel.setFrameOrigin(point)
        } else if let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 20, y: visible.maxY - panel.frame.height - 20))
        }
        keepInsideScreen()
    }

    private func keepInsideScreen() {
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(panel.frame) })
                ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let x = min(max(panel.frame.minX, visible.minX), max(visible.minX, visible.maxX - panel.frame.width))
        let y = min(max(panel.frame.minY, visible.minY), max(visible.minY, visible.maxY - panel.frame.height))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func savePosition() {
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: positionKey)
    }
}

private final class FloatingBalancePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PassiveHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// An explicit AppKit drag surface works on macOS 14 and on a non-key panel.
/// Keep it over the title only so buttons and the scroll view retain their input.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragView {
        let view = WindowDragView()
        view.toolTip = "拖动标题栏移动看板"
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: WindowDragView, context: Context) {}
}

final class WindowDragView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}
