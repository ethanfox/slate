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
            var hit = content.hitTest(point)
            while let view = hit {
                if view is NSText || view is NSTextView || view is NSTextField { return event }
                hit = view.superview
            }
            window.makeFirstResponder(nil)
            return event
        }
    }
}
