import AppKit

@MainActor
enum AppMenus {
    /// Standard edit actions follow the focused text field or WebKit responder.
    /// Keep targets nil so each editor owns validation, selection and undo state.
    static func makeEditMenu() -> NSMenu {
        let menu = NSMenu(title: "编辑")
        menu.autoenablesItems = true
        let undo = NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        undo.keyEquivalentModifierMask = .command
        menu.addItem(undo)
        let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        for (title, action, key) in [
            ("剪切", #selector(NSText.cut(_:)), "x"),
            ("复制", #selector(NSText.copy(_:)), "c"),
            ("粘贴", #selector(NSText.paste(_:)), "v"),
            ("全选", #selector(NSText.selectAll(_:)), "a")
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = .command
            menu.addItem(item)
        }
        return menu
    }
}
