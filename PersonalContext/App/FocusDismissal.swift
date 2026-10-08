import AppKit

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
