import AppKit
import SwiftUI

enum CraftColor {
    static let canvas = dynamic(
        dark: NSColor(srgbRed: 0.141, green: 0.141, blue: 0.137, alpha: 1),
        light: NSColor(srgbRed: 0.965, green: 0.965, blue: 0.957, alpha: 1)
    )
    static let elevated = dynamic(
        dark: NSColor(srgbRed: 0.176, green: 0.176, blue: 0.176, alpha: 1),
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    )
    static let selection = dynamic(
        dark: NSColor(srgbRed: 0.227, green: 0.227, blue: 0.220, alpha: 1),
        light: NSColor(srgbRed: 0.88, green: 0.88, blue: 0.867, alpha: 1)
    )
    static let hover = dynamic(
        dark: NSColor(white: 1, alpha: 0.05),
        light: NSColor(white: 0, alpha: 0.04)
    )
    static let hairline = dynamic(
        dark: NSColor(white: 1, alpha: 0.08),
        light: NSColor(white: 0, alpha: 0.08)
    )
    static let field = dynamic(
        dark: NSColor(white: 1, alpha: 0.04),
        light: NSColor(white: 1, alpha: 1)
    )
    static let scrim = dynamic(
        dark: NSColor(white: 0, alpha: 0.25),
        light: NSColor(white: 0, alpha: 0.12)
    )

    private static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}
enum CraftClipboard {
    static func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension View {
    func tooltip(_ text: String) -> some View {
        modifier(HoverTooltip(text: text))
    }
}

private struct HoverTooltip: ViewModifier {
    var text: String
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .onHover { visible = $0 }
            .overlay(alignment: .bottom) {
                if visible {
                    Text(text)
                        .font(CraftFont.caption)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(CraftColor.elevated, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(CraftColor.hairline))
                        .fixedSize()
                        .offset(y: 22)
                        .allowsHitTesting(false)
                }
            }
            .zIndex(visible ? 1 : 0)
    }
}

extension TaskWorkflowStatus {
    var tint: Color {
        switch self {
        case .ready: AccentPreference.blue.color
        case .inProgress: AccentPreference.yellow.color
        case .blocked: AccentPreference.red.color
        case .done: AccentPreference.green.color
        }
    }
}

enum CraftFont {
    static let display = Font.system(size: 34, weight: .bold)
    static let dayNumber = Font.system(size: 15, weight: .medium).monospacedDigit()
    static let sidebar = Font.system(size: 13)
    static let sidebarIcon = Font.system(size: 14)
    static let section = Font.system(size: 13, weight: .semibold)
    static let sectionNote = Font.system(size: 11)
    static let title = Font.system(size: 20, weight: .semibold)
    static let titleIcon = Font.system(size: 16, weight: .semibold)
    static let tab = Font.system(size: 15, weight: .semibold)
    static let tabIdle = Font.system(size: 15, weight: .regular)
    static let tabIcon = Font.system(size: 14, weight: .semibold)
    static let body = Font.system(size: 13)
    static let chatBody = Font.system(size: 15)
    static let caption = Font.system(size: 11)
}
