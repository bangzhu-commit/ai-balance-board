import AppKit

/// The fixture replaces clipboard I/O only. NSTextView still owns insertion,
/// selection and undo. No system or named pasteboard is read or written.
@MainActor
final class MenuFixtureEditor: NSTextView {
    var clipboard = ""
    var pasteCalls = 0
    let history = UndoManager()
    private var fixtureStorage: NSTextStorage?
    override var undoManager: UndoManager? { history }

    convenience init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 320, height: 80))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        self.init(frame: NSRect(x: 0, y: 0, width: 320, height: 80), textContainer: container)
        fixtureStorage = storage
    }
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        isRichText = false
        isEditable = true
        allowsUndo = true
        history.groupsByEvent = false
    }
    required init?(coder: NSCoder) { nil }

    override func paste(_ sender: Any?) {
        pasteCalls += 1
        replaceSelection(with: clipboard)
    }
    override func copy(_ sender: Any?) {
        clipboard = (string as NSString).substring(with: selectedRange())
    }
    override func cut(_ sender: Any?) {
        copy(sender)
        replaceSelection(with: "")
    }
    @objc func undo(_ sender: Any?) { history.undo() }
    @objc func redo(_ sender: Any?) { history.redo() }

    private func replaceSelection(with text: String) {
        history.beginUndoGrouping()
        insertText(text, replacementRange: selectedRange())
        history.endUndoGrouping()
    }

    // Native paste validation consults the general pasteboard. Keep the test
    // validation local too, including a real disabled-state regression.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(NSText.paste(_:)): return isEditable && !clipboard.isEmpty
        case #selector(NSText.copy(_:)): return selectedRange().length > 0
        case #selector(NSText.cut(_:)): return isEditable && selectedRange().length > 0
        case #selector(NSText.selectAll(_:)): return !string.isEmpty
        case #selector(MenuFixtureEditor.undo(_:)): return history.canUndo
        case #selector(MenuFixtureEditor.redo(_:)): return history.canRedo
        default: return false
        }
    }
}

@main
struct EditMenuChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let previousResponder = app.nextResponder
        let previousMenu = app.mainMenu
        defer { app.nextResponder = previousResponder; app.mainMenu = previousMenu }
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }
            count += 1
        }
        func key(_ character: String, modifiers: NSEvent.ModifierFlags = .command) -> NSEvent {
            let codes: [String: UInt16] = ["v": 9, "c": 8, "x": 7, "a": 0, "z": 6]
            return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil,
                characters: modifiers.contains(.shift) ? character.uppercased() : character,
                charactersIgnoringModifiers: character, isARepeat: false, keyCode: codes[character]!)!
        }

        let first = MenuFixtureEditor()
        first.clipboard = "https://quota.example.com/"
        app.nextResponder = first
        let main = NSMenu()
        app.mainMenu = main
        check(!main.performKeyEquivalent(with: key("v")), "Without Edit menu the paste shortcut has no command")
        check(first.string.isEmpty && first.pasteCalls == 0, "Missing-menu regression does not insert clipboard text")

        let edit = AppMenus.makeEditMenu()
        let parent = NSMenuItem(title: edit.title, action: nil, keyEquivalent: "")
        parent.submenu = edit
        main.addItem(parent)
        check(edit.autoenablesItems, "Editors retain control of command validation")
        let commands = edit.items.filter { !$0.isSeparatorItem }
        check(commands.count == 6 && commands.allSatisfy { $0.target == nil }, "All six editing commands use the responder chain")
        check(app.target(forAction: #selector(NSText.paste(_:))) as AnyObject? === first, "AppKit resolves nil-target paste to the fixture editor")

        func perform(_ character: String, modifiers: NSEvent.ModifierFlags = .command) {
            edit.update()
            check(main.performKeyEquivalent(with: key(character, modifiers: modifiers)), "Main menu handles the requested editing shortcut")
        }
        perform("v")
        check(first.string == first.clipboard && first.pasteCalls == 1, "Command-V routes to insertion and changes actual NSTextView text")
        perform("a")
        check(first.selectedRange() == NSRange(location: 0, length: (first.string as NSString).length), "Command-A selects all actual text")
        first.clipboard = ""
        perform("c")
        check(first.clipboard == first.string, "Command-C receives the editor's selected text")
        perform("x")
        check(first.string.isEmpty && first.clipboard == "https://quota.example.com/", "Command-X removes selected text and preserves copied content")
        perform("z")
        check(first.string == "https://quota.example.com/", "Command-Z undoes the cut using NSTextView undo history")
        perform("z", modifiers: [.command, .shift])
        check(first.string.isEmpty, "Command-Shift-Z redoes the cut independently of undo")

        let second = MenuFixtureEditor()
        second.clipboard = "第二个输入框"
        app.nextResponder = second
        check(app.target(forAction: #selector(NSText.paste(_:))) as AnyObject? === second, "Changing the active responder changes the command target")
        perform("v")
        check(second.string == second.clipboard && first.string.isEmpty && first.pasteCalls == 1, "Paste goes only to the current editor")
        second.setSelectedRange(NSRange(location: 0, length: (second.string as NSString).length))
        second.clipboard = "{\"schemaVersion\":1}"
        perform("v")
        check(second.string == second.clipboard, "Paste replaces a selection, including JSON configuration text")
        let calls = second.pasteCalls
        check(!main.performKeyEquivalent(with: key("v", modifiers: [])), "Plain V is not intercepted as an editing command")
        check(second.pasteCalls == calls, "Typing without Command does not invoke paste")
        second.isEditable = false
        edit.update()
        let paste = commands.first { $0.action == #selector(NSText.paste(_:)) }!
        check(!paste.isEnabled, "Read-only editor disables paste through menu validation")
        _ = main.performKeyEquivalent(with: key("v"))
        check(second.pasteCalls == calls, "Disabled paste does not mutate a read-only editor")
        check(app.windows.allSatisfy { !$0.isVisible }, "All editing checks stay offscreen")
        check(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground, "Local key equivalents preserve the foreground app")
        print("Edit menu: \(count) checks passed; local key equivalents, NSTextView and in-memory clipboard fixture only")
    }
}
