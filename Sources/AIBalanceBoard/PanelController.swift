import AppKit
import SwiftUI

/// Geometry is independent of live screens so restored and disconnected-display positions are testable.
enum PanelPlacement {
    static func screen(for frame: NSRect, visibleFrames: [NSRect]) -> NSRect? {
        visibleFrames.max { left, right in
            intersectionArea(frame, left) < intersectionArea(frame, right)
        }
    }

    private static func intersectionArea(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let overlap = a.intersection(b)
        return overlap.isNull ? 0 : overlap.width * overlap.height
    }

    static func clamped(_ frame: NSRect, inside screen: NSRect) -> NSRect {
        let visible = screen.insetBy(dx: 8, dy: 8)
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        let x = frame.minX.isFinite ? min(max(frame.minX, visible.minX), visible.maxX - width) : visible.minX
        let y = frame.minY.isFinite ? min(max(frame.minY, visible.minY), visible.maxY - height) : visible.maxY - height
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

/// AppKit owns a persistent drag surface, independent of SwiftUI value refreshes.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let panel: FloatingBalancePanel
    private let hostingView: PassiveHostingView<AnyView>
    private let container: PanelContentView
    private let defaults: UserDefaults
    private let positionKey = "AIBalanceBoard.panelPosition"
    private let sizeKey = "AIBalanceBoard.panelSize"
    private var adjustingFrame = false
    var alwaysOnTop: Bool { defaults.bool(forKey: "AIBalanceBoard.alwaysOnTop") }
    private var hasBeenShown = false
    private var isDragging = false
    private var pendingContent: AnyView?

    init(content: AnyView, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hostingView = PassiveHostingView(rootView: content)
        container = PanelContentView(hostingView: hostingView)
        panel = FloatingBalancePanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 520),
            styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false
        )
        super.init()
        panel.title = "AI 额度看板"
        panel.level = alwaysOnTop ? .floating : .normal
        panel.minSize = NSSize(width: 300, height: 240)
        panel.maxSize = NSSize(width: 800, height: 1400)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = alwaysOnTop
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
        panel.contentView = container
        container.dragView.onDragBegan = { [weak self] in self?.isDragging = true }
        container.resizeView.onResizeBegan = { [weak self] in self?.isDragging = true }
        container.dragView.onDragEnded = { [weak self] in
            guard let self else { return }
            self.isDragging = false
            if let content = self.pendingContent {
                self.pendingContent = nil
                self.update(content: content)
            }
            self.keepInsideScreen()
            self.savePosition()
            self.saveSize()
        }
        container.resizeView.onResizeEnded = container.dragView.onDragEnded
        NotificationCenter.default.addObserver(self, selector: #selector(presentationChanged),
                                              name: Notification.Name("AIBalanceBoard.panelPreferencesChanged"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
                                              name: NSApplication.didChangeScreenParametersNotification, object: nil)
        restoreSize()
        restorePosition()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func show() {
        if !hasBeenShown { restorePosition(); hasBeenShown = true }
        keepInsideScreen()
        panel.orderFrontRegardless()
    }

    func hide() { savePosition(); panel.orderOut(nil) }

    func update(content: AnyView) {
        // A provider may finish while AppKit is in its mouse tracking loop.
        // Do not replace content or resize the window beneath an active drag.
        guard !isDragging else { pendingContent = content; return }
        hostingView.rootView = content
        // User-owned size remains stable when readings, errors or cards change.
        keepInsideScreen()
    }

    /// User-invoked recovery; no automatic focus change during background refresh.
    func resetPosition() {
        defaults.removeObject(forKey: positionKey)
        defaults.removeObject(forKey: sizeKey)
        setFrame(NSRect(origin: panel.frame.origin, size: NSSize(width: 340, height: 520)))
        placeAtDefaultPosition()
        savePosition()
        saveSize()
        show()
    }

    func windowDidMove(_ notification: Notification) {
        if hasBeenShown && !isDragging { savePosition() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }

    @objc private func screenParametersChanged() {
        guard !isDragging else { return }
        // User-owned size remains stable when readings, errors or cards change.
        keepInsideScreen()
        if hasBeenShown { savePosition() }
    }

    func setAlwaysOnTop(_ enabled: Bool) {
        defaults.set(enabled, forKey: "AIBalanceBoard.alwaysOnTop")
        NotificationCenter.default.post(name: Notification.Name("AIBalanceBoard.panelPreferencesChanged"), object: nil)
        presentationChanged()
    }

    @objc private func presentationChanged() {
        panel.isFloatingPanel = alwaysOnTop
        panel.level = alwaysOnTop ? .floating : .normal
    }

    func windowWillStartLiveResize(_ notification: Notification) { isDragging = true }
    func windowDidEndLiveResize(_ notification: Notification) { container.resizeView.onResizeEnded?() }
    func windowDidResize(_ notification: Notification) {
        if hasBeenShown && !adjustingFrame && !isDragging { saveSize(); savePosition() }
    }

    private func restoreSize() {
        guard let raw = defaults.string(forKey: sizeKey) else { return }
        let size = NSSizeFromString(raw)
        guard size.width.isFinite, size.height.isFinite else { return }
        let bounded = NSSize(width: min(max(size.width, panel.minSize.width), panel.maxSize.width),
                             height: min(max(size.height, panel.minSize.height), panel.maxSize.height))
        setFrame(NSRect(origin: panel.frame.origin, size: bounded))
    }

    private func saveSize() { defaults.set(NSStringFromSize(panel.frame.size), forKey: sizeKey) }

    private func setFrame(_ frame: NSRect) {
        guard frame != panel.frame else { return }
        adjustingFrame = true
        panel.setFrame(frame, display: true)
        adjustingFrame = false
    }

    private func restorePosition() {
        if let raw = defaults.string(forKey: positionKey) {
            let point = NSPointFromString(raw)
            if point.x.isFinite && point.y.isFinite { panel.setFrameOrigin(point) }
            else { placeAtDefaultPosition() }
        } else { placeAtDefaultPosition() }
        keepInsideScreen()
    }

    private func placeAtDefaultPosition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 20,
                                     y: visible.maxY - panel.frame.height - 20))
        keepInsideScreen()
    }

    private func keepInsideScreen() {
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        guard let screen = PanelPlacement.screen(for: panel.frame, visibleFrames: visibleFrames) else { return }
        let next = PanelPlacement.clamped(panel.frame, inside: screen)
        setFrame(next)
    }

    private func savePosition() {
        defaults.set(NSStringFromPoint(panel.frame.origin), forKey: positionKey)
    }
}

private final class FloatingBalancePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PassiveHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The native sibling remains mounted when NSHostingView.rootView changes.
/// Geometry matches the header: settings/refresh/close controls start at x = 228.
final class PanelContentView: NSView {
    let hostingView: NSView
    let dragView = WindowDragView()
    let resizeView = WindowResizeView()

    init(hostingView: NSView) {
        self.hostingView = hostingView
        super.init(frame: .zero)
        addSubview(hostingView)
        addSubview(dragView)
        addSubview(resizeView)
        resizeView.toolTip = "拖动右下角调整看板大小"
        resizeView.setAccessibilityLabel("调整看板大小")
        dragView.toolTip = "拖动标题栏移动看板；也可从菜单栏恢复窗口位置"
        dragView.setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        hostingView.frame = bounds
        resizeView.frame = NSRect(x: max(0, bounds.width - 25), y: 0, width: 25, height: 25)
        dragView.frame = NSRect(x: 5, y: max(0, bounds.height - 63), width: max(0, bounds.width - 121), height: min(58, bounds.height))
    }
}

final class WindowDragView: NSView {
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        onDragBegan?()
        defer { onDragEnded?() }
        window.performDrag(with: event)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

/// Visible corner grip supplements the standard resizable window edges.
final class WindowResizeView: NSView {
    var onResizeBegan: (() -> Void)?
    var onResizeEnded: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.withAlphaComponent(0.5).setStroke()
        let path = NSBezierPath()
        for offset in [CGFloat(7), 12, 17] {
            path.move(to: NSPoint(x: bounds.maxX - offset, y: 5))
            path.line(to: NSPoint(x: bounds.maxX - 5, y: offset))
        }
        path.lineWidth = 1
        path.stroke()
    }

    static func resizedFrame(initial: NSRect, delta: NSPoint, minimum: NSSize, maximum: NSSize) -> NSRect {
        let width = min(max(initial.width + delta.x, minimum.width), maximum.width)
        let height = min(max(initial.height - delta.y, minimum.height), maximum.height)
        return NSRect(x: initial.minX, y: initial.maxY - height, width: width, height: height)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let initial = window.frame
        let start = window.convertPoint(toScreen: event.locationInWindow)
        onResizeBegan?()
        defer { onResizeEnded?() }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let point = window.convertPoint(toScreen: next.locationInWindow)
            let frame = Self.resizedFrame(initial: initial, delta: NSPoint(x: point.x - start.x, y: point.y - start.y),
                                          minimum: window.minSize, maximum: window.maxSize)
            window.setFrame(frame, display: true)
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
}
