import AppKit
import SwiftUI
import BalanceCore

final class InputFixtureWindow: NSWindow {
    var dragCalls = 0
    var events: [NSEvent] = []
    override func performDrag(with event: NSEvent) { dragCalls += 1 }
    override func nextEvent(matching mask: NSEvent.EventTypeMask) -> NSEvent? {
        events.isEmpty ? nil : events.removeFirst()
    }
}

@MainActor final class ClickCounter: NSObject {
    var count = 0
    @objc func clicked() { count += 1 }
}

struct FixtureButton: NSViewRepresentable {
    let counter: ClickCounter
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Connect", target: counter, action: #selector(ClickCounter.clicked))
        button.bezelStyle = .rounded
        return button
    }
    func updateNSView(_ nsView: NSButton, context: Context) {}
}

struct RenderFixture: View {
    let counter: ClickCounter
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            Text("87%").font(.system(size: 40, weight: .bold)).foregroundColor(.black)
                .frame(width: 140, height: 60).offset(x: 30, y: 90)
            RoundedRectangle(cornerRadius: 12).fill(Color(red: 0, green: 0, blue: 1)).frame(width: 240, height: 90).offset(x: 30, y: 160)
            FixtureButton(counter: counter).frame(width: 100, height: 30).offset(x: 30, y: 280)
            Rectangle().fill(Color(red: 1, green: 0, blue: 0)).frame(width: 24, height: 24).offset(x: 280, y: 460)
        }.frame(width: 340, height: 520)
    }
}

@main
struct PanelChecks {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
            count += 1
        }
        func near(_ a: CGFloat, _ b: CGFloat, tolerance: CGFloat = 0.05) -> Bool { abs(a - b) <= tolerance }
        let left = NSRect(x: -1000, y: 0, width: 1000, height: 800)
        let right = NSRect(x: 0, y: 0, width: 1200, height: 900)
        check(PanelPlacement.screen(for: NSRect(x: -20, y: 100, width: 340, height: 520), visibleFrames: [left, right]) == right,
              "A window mostly on the right monitor must not snap to the first intersecting display")
        let offscreen = PanelPlacement.clamped(NSRect(x: 5000, y: -5000, width: 340, height: 520), inside: right)
        check(right.contains(offscreen), "Restored offscreen window must be reachable")
        check(PanelPlacement.screen(for: offscreen, visibleFrames: []) == nil, "No displays must be safe")
        let small = NSRect(x: 0, y: 0, width: 320, height: 300)
        let fitted = PanelPlacement.clamped(NSRect(x: 0, y: 0, width: 800, height: 1400), inside: small)
        check(small.contains(fitted) && near(fitted.width / fitted.height, 340 / 520), "Small-screen recovery must preserve proportion without clipping")
        let initial = NSRect(x: 50, y: 100, width: 340, height: 520)
        let minimum = PanelZoom.size(at: 0.8), maximum = PanelZoom.size(at: 1.6)
        let grown = WindowResizeView.resizedFrame(initial: initial, delta: NSPoint(x: 85, y: -130), minimum: minimum, maximum: maximum)
        check(grown.size == PanelZoom.size(at: 1.25) && grown.maxY == initial.maxY && grown.minX == initial.minX, "Corner zoom anchors top left and scales both dimensions")
        let horizontal = WindowResizeView.resizedFrame(initial: initial, delta: NSPoint(x: 34, y: 0), minimum: minimum, maximum: maximum)
        check(near(horizontal.width, 374) && near(horizontal.height, 572), "Horizontal-only movement still scales both dimensions")
        let shrunk = WindowResizeView.resizedFrame(initial: initial, delta: NSPoint(x: -900, y: 900), minimum: minimum, maximum: maximum)
        check(shrunk.size == minimum, "Minimum 80% zoom enforced")
        let large = WindowResizeView.resizedFrame(initial: initial, delta: NSPoint(x: 9000, y: -9000), minimum: minimum, maximum: maximum)
        check(large.size == maximum, "Maximum 160% zoom enforced")

        let inputWindow = InputFixtureWindow(contentRect: initial, styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        inputWindow.minSize = minimum; inputWindow.maxSize = maximum
        inputWindow.isReleasedWhenClosed = false
        let inputContent = PanelContentView(content: AnyView(Color.clear))
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
        inputWindow.events = [event(.leftMouseDragged, NSPoint(x: 185, y: -30)), event(.leftMouseUp, NSPoint(x: 185, y: -30))]
        inputContent.resizeView.mouseDown(with: down)
        check(inputWindow.frame.size == PanelZoom.size(at: 1.25), "Corner input sequence scales actual hidden NSWindow frame")
        check(inputWindow.frame.maxY == initial.maxY && callbacks == ["begin", "end"], "Native corner zoom preserves top edge and completes lifecycle")
        check(!inputWindow.isVisible, "Synthetic local events never display a window or post global input")

        let suite = "PanelChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(NSStringFromSize(NSSize(width: 480, height: 400)), forKey: "AIBalanceBoard.panelSize")
        let controller = PanelController(content: AnyView(Text("fixture")), defaults: defaults)
        let window = Mirror(reflecting: controller).children.first(where: { $0.label == "panel" })!.value as! NSPanel
        check(!window.isVisible, "Fixture must never show a window")
        check(window.level == .normal && !controller.alwaysOnTop, "New default must not cover other applications")
        check(window.styleMask.contains(.resizable) && window.contentAspectRatio == PanelZoom.canvas, "Native edges preserve the canvas aspect ratio")
        check(window.frame.size == minimum, "Legacy arbitrary rectangle migrates to bounded fitting zoom")
        let content = window.contentView as! PanelContentView
        content.layoutSubtreeIfNeeded()
        let stableDragView = content.dragView
        for scale: CGFloat in [0.8, 1, 1.25, 1.6] {
            content.setFrameSize(PanelZoom.size(at: scale))
            content.needsLayout = true
            content.layoutSubtreeIfNeeded()
            check(content.canvasSize == PanelZoom.canvas && content.hostingView.frame.size == PanelZoom.size(at: scale), "Logical canvas stays constant while hosting viewport follows zoom")
            check(content.hitTest(NSPoint(x: 20 * scale, y: 490 * scale)) === content.dragView, "Scaled title receives first click")
            check(content.hitTest(NSPoint(x: 240 * scale, y: 490 * scale)) !== content.dragView, "Scaled settings button is not blocked")
            check(content.hitTest(NSPoint(x: 330 * scale, y: 10 * scale)) === content.resizeView, "Scaled resize handle receives input")
            check(content.hitTest(NSPoint(x: 40 * scale, y: 150 * scale)) !== content.dragView, "Cards retain scroll/button input")
        }
        content.setFrameSize(window.frame.size)
        let stableFrame = window.frame
        for i in 0..<20 { controller.update(content: AnyView(Text("reading \(i)"))) }
        check(window.frame == stableFrame, "Repeated data refresh preserves user's position and scale")
        check(content.dragView === stableDragView, "Refresh never replaces native drag surface")
        content.dragView.onDragBegan?()
        controller.update(content: AnyView(Text("arrived during drag")))
        check(window.frame == stableFrame, "Refresh during drag cannot move or zoom window")
        content.dragView.onDragEnded?()
        check(near(CGFloat(defaults.double(forKey: "AIBalanceBoard.panelScale")), 0.8), "Drag completion persists scale")
        controller.resetSize()
        check(window.frame.size == PanelZoom.canvas && defaults.double(forKey: "AIBalanceBoard.panelScale") == 1, "Restore default returns to 100% without showing a window")
        let restored = PanelController(content: AnyView(Text("restored")), defaults: defaults)
        let restoredWindow = Mirror(reflecting: restored).children.first(where: { $0.label == "panel" })!.value as! NSPanel
        check(restoredWindow.frame.size == PanelZoom.canvas, "Persisted scale survives controller recreation")
        controller.setAlwaysOnTop(true)
        check(window.level == .floating && controller.alwaysOnTop, "Opt-in topmost applies immediately")
        controller.setAlwaysOnTop(false)
        check(window.level == .normal, "Topmost can be disabled without restart")

        // Render actual NSHostingView descendants through the production SwiftUI
        // zoom transform. Image and text pixel bounds must scale together.
        let counter = ClickCounter()
        let renderContent = PanelContentView(content: AnyView(RenderFixture(counter: counter)))
        let renderWindow = NSWindow(contentRect: NSRect(origin: .zero, size: PanelZoom.canvas), styleMask: .borderless, backing: .buffered, defer: false)
        renderWindow.isReleasedWhenClosed = false
        renderWindow.contentView = renderContent
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/panel-checks")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func snapshot(_ scale: CGFloat) throws -> NSBitmapImageRep {
            renderWindow.setFrame(NSRect(origin: .zero, size: PanelZoom.size(at: scale)), display: false)
            renderContent.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            renderContent.layoutSubtreeIfNeeded()
            let capture = renderContent.superview!
            let rectangle = renderContent.convert(renderContent.bounds, to: capture)
            let bitmap = capture.bitmapImageRepForCachingDisplay(in: rectangle)!
            capture.cacheDisplay(in: rectangle, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("zoom-fixture-\(scale).png"))
            return bitmap
        }
        func pixelBounds(_ bitmap: NSBitmapImageRep, color predicate: (NSColor) -> Bool) -> NSRect {
            var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.8, predicate(color) {
                        minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                    }
                }
            }
            return maxX < 0 ? .zero : NSRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }
        var reference: (width: Int, blue: NSRect, red: NSRect, text: NSRect)?
        for scale: CGFloat in [1, 0.8, 1.25, 1.6] {
            let bitmap = try snapshot(scale)
            let blue = pixelBounds(bitmap) { $0.blueComponent > 0.7 && $0.redComponent < 0.2 && $0.greenComponent < 0.4 }
            let red = pixelBounds(bitmap) { $0.redComponent > 0.7 && $0.greenComponent < 0.3 && $0.blueComponent < 0.3 }
            let text = pixelBounds(bitmap) { $0.redComponent < 0.15 && $0.greenComponent < 0.15 && $0.blueComponent < 0.15 }
            check(blue.width > 0 && red.width > 0 && text.width > 0, "Real SwiftUI shapes, text and bottom sentinel all render")
            if let ref = reference {
                let imageRatio = CGFloat(bitmap.pixelsWide) / CGFloat(ref.width)
                check(near(imageRatio, scale, tolerance: 0.01), "Captured output pixel dimensions follow zoom")
                check(near(blue.width / ref.blue.width, scale, tolerance: 0.02) && near(blue.height / ref.blue.height, scale, tolerance: 0.02), "Actual card pixels scale uniformly")
                check(near(red.minY / ref.red.minY, scale, tolerance: 0.02) && near(red.width / ref.red.width, scale, tolerance: 0.03), "Bottom content scales instead of being clipped")
                check(abs(text.width - ref.text.width * scale) <= 2.5 && abs(text.height - ref.text.height * scale) <= 2.5, "Actual glyph pixels scale together with content (allowing raster hinting)")
            } else { reference = (bitmap.pixelsWide, blue, red, text) }
            let buttonPoint = NSPoint(x: 80 * scale, y: (520 - 295) * scale)
            var hit: NSView? = renderContent.hitTest(buttonPoint)
            while hit != nil && !(hit is NSButton) { hit = hit?.superview }
            check(hit is NSButton, "Scaled button center resolves to the actual hosted native control")
            let beforeClick = counter.count
            (hit as? NSButton)?.performClick(nil)
            check(counter.count == beforeClick + 1, "Hosted button action works after scaled coordinate hit test")
            check(!renderWindow.isVisible, "Render and click fixtures remain hidden")
        }
        let sampleCards = [
            ServiceCard(id: .foxcode, title: "中转站 · 示例", subtitle: "剩余额度", reading: BalanceReading(service: .foxcode, metrics: [BalanceMetric(id: "payg", label: "按量余额", value: "980,000"), BalanceMetric(id: "monthly", label: "月卡额度", value: "20,000")], source: "合成示例"), status: "", needsConnection: false, connectionState: .ready),
            ServiceCard(id: .codex, title: "Codex · 示例", subtitle: "ChatGPT 套餐", reading: BalanceReading(service: .codex, metrics: [BalanceMetric(id: "week", label: "每周剩余", value: "76%", remainingFraction: 0.76, resetsAt: Date().addingTimeInterval(86_400)), BalanceMetric(id: "credits", label: "额度余额", value: "1,200")], source: "合成示例"), status: "", needsConnection: false, connectionState: .ready),
            ServiceCard(id: .grok, title: "Grok Bot · 示例", subtitle: "服务器额度", reading: BalanceReading(service: .grok, metrics: [BalanceMetric(id: "remaining", label: "剩余额度", value: "64%", remainingFraction: 0.64)], source: "合成示例"), status: "", needsConnection: false, connectionState: .ready)
        ]
        let emptySize = DashboardView.preferredLogicalSize(cards: [])
        let oneSize = DashboardView.preferredLogicalSize(cards: [sampleCards[0]])
        let threeSize = DashboardView.preferredLogicalSize(cards: sampleCards)
        check(emptySize.height > 240 && emptySize.height < 340 && oneSize.height < 340, "Empty and single-card boards use compact natural content heights")
        check(threeSize.height > oneSize.height && threeSize.height < 800, "Three normal cards are measured at their full natural height")
        let dashboard = DashboardView(cards: sampleCards, isRefreshing: false, onRefresh: {}, onConnect: {_ in}, onHide: {}, canvasSize: threeSize)
        let boardContent = PanelContentView(content: AnyView(dashboard), canvasSize: threeSize)
        let boardHost = boardContent.hostingView
        let boardWindow = NSWindow(contentRect: NSRect(origin: .zero, size: threeSize), styleMask: .borderless, backing: .buffered, defer: false)
        boardWindow.isReleasedWhenClosed = false
        boardWindow.contentView = boardContent
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let emptyContent = PanelContentView(content: AnyView(DashboardView(cards: [], isRefreshing: false,
            onRefresh: {}, onConnect: {_ in}, onHide: {}, canvasSize: emptySize)), canvasSize: emptySize)
        let emptyWindow = NSWindow(contentRect: NSRect(origin: .zero, size: emptySize), styleMask: .borderless, backing: .buffered, defer: false)
        emptyWindow.isReleasedWhenClosed = false
        emptyWindow.contentView = emptyContent
        for scale: CGFloat in [1, 0.8, 1.25] {
            emptyWindow.setFrame(NSRect(origin: .zero, size: PanelZoom.size(at: scale, canvas: emptySize)), display: false)
            emptyContent.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            emptyContent.layoutSubtreeIfNeeded()
            let scrollViews = descendants(emptyContent.hostingView).compactMap { $0 as? NSScrollView }
            check(!scrollViews.isEmpty, "First-run board has a real scroll viewport")
            for scroll in scrollViews {
                check((scroll.documentView?.frame.height ?? 0) <= scroll.contentView.bounds.height + 1,
                      "First-run content and Start Setup action fit without hidden overflow at every zoom")
            }
            check(!emptyWindow.isVisible, "First-run layout regression stays offscreen")
        }
        for scale: CGFloat in [1, 0.8, 1.25] {
            boardWindow.setFrame(NSRect(origin: .zero, size: PanelZoom.size(at: scale, canvas: threeSize)), display: false)
            boardContent.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            boardContent.layoutSubtreeIfNeeded()
            let scrollViews = descendants(boardHost).compactMap { $0 as? NSScrollView }
            check(!scrollViews.isEmpty, "Real dashboard exposes its scroll viewport for layout verification")
            for scroll in scrollViews {
                let required = scroll.documentView?.frame.height ?? 0
                check(required <= scroll.contentView.bounds.height + 1, "All three real quota cards fit at every zoom without clipping or extra scrolling")
            }
            let capture = boardContent.superview!
            let rect = boardContent.convert(boardContent.bounds, to: capture)
            let bitmap = capture.bitmapImageRepForCachingDisplay(in: rect)!
            capture.cacheDisplay(in: rect, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("dashboard-three-\(scale).png"))
            // Hidden NSWindows have no event-to-window mapping in NSEvent,
            // even at 100%. Do not claim real SwiftUI mouse-button validation
            // from a synthetic event that cannot target this hidden window.
            check(!boardWindow.isVisible, "Production dashboard visual check stays hidden")
        }
        defaults.set(1.1, forKey: "AIBalanceBoard.panelScale")
        let adaptive = PanelController(content: AnyView(dashboard), canvasSize: threeSize, defaults: defaults)
        let adaptiveWindow = Mirror(reflecting: adaptive).children.first(where: { $0.label == "panel" })!.value as! NSPanel
        let adaptiveContent = adaptiveWindow.contentView as! PanelContentView
        adaptive.update(content: AnyView(Text("one")), canvasSize: oneSize)
        check(near(PanelZoom.fittingScale(adaptiveWindow.frame.size, canvas: oneSize), 1.1), "Natural-height changes retain user zoom instead of forcing default size")
        adaptiveContent.resizeView.onResizeBegan?()
        adaptiveWindow.setFrame(NSRect(origin: adaptiveWindow.frame.origin, size: PanelZoom.size(at: 0.9, canvas: oneSize)), display: false)
        let beforeDeferred = adaptiveWindow.frame
        adaptive.update(content: AnyView(dashboard), canvasSize: threeSize)
        check(adaptiveWindow.frame == beforeDeferred, "Natural-height change waits until dragging finishes")
        adaptiveContent.resizeView.onResizeEnded?()
        check(adaptiveContent.canvasSize == threeSize && near(PanelZoom.fittingScale(adaptiveWindow.frame.size, canvas: threeSize), 0.9), "Deferred canvas update retains completed resize rather than previous zoom")
        check(near(CGFloat(defaults.double(forKey: "AIBalanceBoard.panelScale")), 0.9), "New zoom persists after a pending provider update")
        check(!window.isVisible && !restoredWindow.isVisible && NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground, "All tests stay offscreen and preserve foreground app")
        print("Panel: \(count) checks passed (hidden windows, rendered glyph/card pixels and local hit tests; no global input)")
    }
}
