import AppKit

enum WindowChrome {
    static let main = NSUserInterfaceItemIdentifier("membrae.main")

    static func isMain(_ window: NSWindow) -> Bool {
        var current: NSWindow? = window
        while let candidate = current {
            if candidate.identifier == main { return true }
            current = candidate.parent
        }
        return window.titleVisibility == .hidden && window.styleMask.contains(.fullSizeContentView)
    }
}

enum CloseTabShortcut {
    private static var monitor: Any?

    static func install(_ app: AppModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isCommandW(event) else { return event }
            var consumed = false
            let apply = {
                let window = event.window ?? NSApp.keyWindow
                if let window, window.attachedSheet != nil { return }
                if let window, !WindowChrome.isMain(window) { return }
                if app.modal != nil {
                    app.dismissModal()
                    consumed = true
                    return
                }
                app.closeSelectedTab()
                consumed = true
            }
            if Thread.isMainThread {
                apply()
            } else {
                DispatchQueue.main.sync(execute: apply)
            }
            return consumed ? nil : event
        }
    }

    private static func isCommandW(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(.command),
              !mods.contains(.shift),
              !mods.contains(.option),
              !mods.contains(.control) else { return false }
        return event.charactersIgnoringModifiers?.lowercased() == "w"
    }
}

enum FocusDismissal {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let window = event.window,
                  window.firstResponder is NSText,
                  let content = window.contentView else { return event }
            let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            guard let hit = content.hitTest(point) else { return event }
            if keepsSelection(from: hit) { return event }
            window.makeFirstResponder(nil)
            return event
        }
    }

    private static func keepsSelection(from hit: NSView) -> Bool {
        var cursor: NSView? = hit
        while let view = cursor {
            if view is NSText || view is NSTextView || view is NSTextField { return true }
            cursor = view.superview
        }
        return isSelectableText(hit)
    }

    private static func isSelectableText(_ view: NSView) -> Bool {
        switch view.accessibilityRole() {
        case .staticText, .textArea, .textField, .comboBox:
            return true
        default:
            let name = String(describing: type(of: view))
            return name.contains("Text") && !name.contains("Hosting")
        }
    }
}
