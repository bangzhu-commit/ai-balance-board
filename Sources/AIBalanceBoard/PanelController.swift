import AppKit
import SwiftUI

/// A logical canvas stays fixed during dragging so every glyph and hit target shares one zoom.
enum PanelZoom {
    static let canvas = NSSize(width: 340, height: 520)
    static let minimum: CGFloat = 0.8
    static let maximum: CGFloat = 1.6

    static func size(at scale: CGFloat, canvas: NSSize = PanelZoom.canvas) -> NSSize {
        NSSize(width: canvas.width * scale, height: canvas.height * scale)
    }

    static func fittingScale(_ size: NSSize, canvas: NSSize = PanelZoom.canvas) -> CGFloat {
        min(size.width / canvas.width, size.height / canvas.height)
    }

    static func bounded(_ scale: CGFloat, upperLimit: CGFloat = maximum) -> CGFloat {
        let upper = max(0.01, min(maximum, upperLimit))
        return min(max(scale.isFinite ? scale : 1, min(minimum, upper)), upper)
    }

    /// Choose the dimension the user moved most, then resize both dimensions.
    static func proposedSize(_ proposed: NSSize, from current: NSSize,
                             minimum minSize: NSSize, maximum maxSize: NSSize, canvas: NSSize = PanelZoom.canvas) -> NSSize {
        let widthChange = (proposed.width - current.width) / canvas.width
        let heightChange = (proposed.height - current.height) / canvas.height
        let proposedScale = abs(widthChange) >= abs(heightChange)
            ? proposed.width / canvas.width : proposed.height / canvas.height
        let lower = max(minSize.width / canvas.width, minSize.height / canvas.height)
        let upper = min(maxSize.width / canvas.width, maxSize.height / canvas.height)
        return size(at: min(max(proposedScale, lower), upper), canvas: canvas)
    }
}

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

    static func clamped(_ frame: NSRect, inside screen: NSRect, canvas: NSSize = PanelZoom.canvas) -> NSRect {
        let visible = screen.insetBy(dx: 8, dy: 8)
        let scale = PanelZoom.bounded(PanelZoom.fittingScale(frame.size, canvas: canvas),
                                     upperLimit: PanelZoom.fittingScale(visible.size, canvas: canvas))
        let size = PanelZoom.size(at: scale, canvas: canvas)
        let x = frame.minX.isFinite ? min(max(frame.minX, visible.minX), visible.maxX - size.width) : visible.minX
        let y = frame.minY.isFinite ? min(max(frame.minY, visible.minY), visible.maxY - size.height) : visible.maxY - size.height
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// AppKit owns a persistent drag surface, independent of SwiftUI value refreshes.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let panel: FloatingBalancePanel
    private let container: PanelContentView
    private let defaults: UserDefaults
    private let positionKey = "AIBalanceBoard.panelPosition"
    private let sizeKey = "AIBalanceBoard.panelSize"
    private let scaleKey = "AIBalanceBoard.panelScale"
    private var canvasSize: NSSize
    private var preferredScale: CGFloat = 1
    private var adjustingFrame = false
    var alwaysOnTop: Bool { defaults.bool(forKey: "AIBalanceBoard.alwaysOnTop") }
    private var hasBeenShown = false
    private var isDragging = false
    private var pendingContent: AnyView?
    private var pendingCanvasSize: NSSize?

    init(content: AnyView, canvasSize: NSSize = PanelZoom.canvas, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.canvasSize = canvasSize
        container = PanelContentView(content: content, canvasSize: canvasSize)
        panel = FloatingBalancePanel(
            contentRect: NSRect(origin: .zero, size: canvasSize),
            styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false
        )
        super.init()
        panel.title = "AI 额度看板"
        panel.level = alwaysOnTop ? .floating : .normal
        panel.contentAspectRatio = canvasSize
        panel.minSize = PanelZoom.size(at: PanelZoom.minimum, canvas: canvasSize)
        panel.maxSize = PanelZoom.size(at: PanelZoom.maximum, canvas: canvasSize)
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
            // Capture the completed user zoom against the old logical canvas
            // before pending content changes the canvas or screen fitting.
            self.preferredScale = PanelZoom.fittingScale(self.panel.frame.size, canvas: self.canvasSize)
            self.isDragging = false
            if let content = self.pendingContent {
                self.pendingContent = nil
                let canvas = self.pendingCanvasSize
                self.pendingCanvasSize = nil
                self.update(content: content, canvasSize: canvas)
            }
            self.keepInsideScreen()
            self.savePosition()
            self.saveSize(captureCurrentScale: false)
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

    func update(content: AnyView, canvasSize newCanvas: NSSize? = nil) {
        // A provider may finish while AppKit is in its mouse tracking loop.
        // Do not replace content or change the base canvas beneath an active drag.
        guard !isDragging else { pendingContent = content; pendingCanvasSize = newCanvas; return }
        container.update(content: content)
        if let newCanvas, newCanvas != canvasSize {
            canvasSize = newCanvas
            container.canvasSize = newCanvas
            panel.contentAspectRatio = newCanvas
            panel.minSize = PanelZoom.size(at: PanelZoom.minimum, canvas: newCanvas)
            panel.maxSize = PanelZoom.size(at: PanelZoom.maximum, canvas: newCanvas)
            applyPreferredSizeKeepingTopEdge()
        }
        keepInsideScreen()
    }

    /// User-invoked recovery; no automatic focus change during background refresh.
    func resetPosition() {
        defaults.removeObject(forKey: positionKey)
        resetSize()
        placeAtDefaultPosition()
        savePosition()
        saveSize(captureCurrentScale: false)
        show()
    }

    /// Restore 100% without moving the window's top-left corner or changing focus.
    func resetSize() {
        preferredScale = 1
        applyPreferredSizeKeepingTopEdge()
        keepInsideScreen()
        saveSize(captureCurrentScale: false)
        savePosition()
    }

    func windowDidMove(_ notification: Notification) {
        if hasBeenShown && !isDragging { savePosition() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }

    @objc private func screenParametersChanged() {
        guard !isDragging else { return }
        applyPreferredSizeKeepingTopEdge()
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

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        PanelZoom.proposedSize(frameSize, from: sender.frame.size,
                               minimum: sender.minSize, maximum: sender.maxSize, canvas: canvasSize)
    }

    func windowWillStartLiveResize(_ notification: Notification) { isDragging = true }
    func windowDidEndLiveResize(_ notification: Notification) { container.resizeView.onResizeEnded?() }
    func windowDidResize(_ notification: Notification) {
        if hasBeenShown && !adjustingFrame && !isDragging { saveSize(); savePosition() }
    }

    private func restoreSize() {
        let scale: CGFloat
        if defaults.object(forKey: scaleKey) != nil {
            scale = CGFloat(defaults.double(forKey: scaleKey))
        } else if let raw = defaults.string(forKey: sizeKey) {
            // Migrate the old arbitrary rectangle by fitting the complete canvas,
            // rather than interpreting its width alone and making a tall window.
            scale = PanelZoom.fittingScale(NSSizeFromString(raw), canvas: canvasSize)
        } else { scale = 1 }
        preferredScale = PanelZoom.bounded(scale)
        setFrame(NSRect(origin: panel.frame.origin, size: PanelZoom.size(at: preferredScale, canvas: canvasSize)))
    }

    private func saveSize(captureCurrentScale: Bool = true) {
        if captureCurrentScale { preferredScale = PanelZoom.fittingScale(panel.frame.size, canvas: canvasSize) }
        defaults.set(preferredScale, forKey: scaleKey)
        // Keep a valid rectangle for older app versions if the user rolls back.
        defaults.set(NSStringFromSize(panel.frame.size), forKey: sizeKey)
    }

    private func applyPreferredSizeKeepingTopEdge() {
        let size = PanelZoom.size(at: preferredScale, canvas: canvasSize)
        setFrame(NSRect(x: panel.frame.minX, y: panel.frame.maxY - size.height, width: size.width, height: size.height))
    }

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
        let visibleSize = screen.insetBy(dx: 8, dy: 8).size
        let maximumScale = min(PanelZoom.maximum, PanelZoom.fittingScale(visibleSize, canvas: canvasSize))
        panel.minSize = PanelZoom.size(at: min(PanelZoom.minimum, maximumScale), canvas: canvasSize)
        panel.maxSize = PanelZoom.size(at: maximumScale, canvas: canvasSize)
        let next = PanelPlacement.clamped(panel.frame, inside: screen, canvas: canvasSize)
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

@MainActor
private final class PanelRenderingState: ObservableObject {
    @Published var content: AnyView
    @Published var canvasSize: NSSize
    @Published var scale: CGFloat = 1
    init(content: AnyView, canvasSize: NSSize) { self.content = content; self.canvasSize = canvasSize }
}

private struct ScaledPanelContent: View {
    @ObservedObject var state: PanelRenderingState
    var body: some View {
        state.content
            .frame(width: state.canvasSize.width, height: state.canvasSize.height)
            .scaleEffect(state.scale, anchor: .topLeading)
            .frame(width: state.canvasSize.width * state.scale,
                   height: state.canvasSize.height * state.scale, alignment: .topLeading)
            .transaction { $0.animation = nil }
    }
}

/// SwiftUI owns both the drawing transform and its matching event transform.
/// Native drag and resize siblings remain mounted during data and zoom updates.
final class PanelContentView: NSView {
    let hostingView: NSView
    let dragView = WindowDragView()
    let resizeView = WindowResizeView()
    private let rendering: PanelRenderingState
    var canvasSize: NSSize {
        didSet {
            resizeView.canvasSize = canvasSize
            rendering.canvasSize = canvasSize
            needsLayout = true
        }
    }

    init(content: AnyView, canvasSize: NSSize = PanelZoom.canvas) {
        self.canvasSize = canvasSize
        rendering = PanelRenderingState(content: content, canvasSize: canvasSize)
        hostingView = PassiveHostingView(rootView: ScaledPanelContent(state: rendering))
        super.init(frame: NSRect(origin: .zero, size: canvasSize))
        resizeView.canvasSize = canvasSize
        addSubview(hostingView)
        addSubview(dragView)
        addSubview(resizeView)
        resizeView.toolTip = "拖动右下角等比例缩放文字和卡片"
        resizeView.setAccessibilityLabel("等比例缩放看板")
        dragView.toolTip = "拖动标题栏移动看板；也可从菜单栏恢复窗口位置"
        dragView.setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }

    func update(content: AnyView) { rendering.content = content }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let scale = PanelZoom.fittingScale(bounds.size, canvas: canvasSize)
        if rendering.scale != scale { rendering.scale = scale }
        hostingView.frame = bounds
        resizeView.frame = NSRect(x: bounds.width - 25 * scale, y: 0, width: 25 * scale, height: 25 * scale)
        resizeView.setBoundsSize(NSSize(width: 25, height: 25))
        dragView.frame = NSRect(x: 5 * scale, y: bounds.height - 63 * scale,
                                width: (canvasSize.width - 121) * scale, height: 58 * scale)
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
    var canvasSize = PanelZoom.canvas
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

    static func resizedFrame(initial: NSRect, delta: NSPoint, minimum: NSSize, maximum: NSSize, canvas: NSSize = PanelZoom.canvas) -> NSRect {
        let size = PanelZoom.proposedSize(NSSize(width: initial.width + delta.x, height: initial.height - delta.y),
                                          from: initial.size, minimum: minimum, maximum: maximum, canvas: canvas)
        return NSRect(x: initial.minX, y: initial.maxY - size.height, width: size.width, height: size.height)
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
                                          minimum: window.minSize, maximum: window.maxSize, canvas: canvasSize)
            window.setFrame(frame, display: true)
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
}
