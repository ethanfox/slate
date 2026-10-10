import AppKit
import SwiftUI

struct SettingsOrbPage: View {
    @Environment(AppModel.self) private var app
    @State private var previewState: OrbState = .thinking

    var body: some View {
        @Bindable var app = app
        SettingsPage {
            preview
            states
            colors(palette: $app.orbPalette)
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview")
                .font(CraftFont.section)
            ZStack {
                Color.black
                ChatOrb(
                    state: previewState,
                    palette: app.orbPalette,
                    size: 220,
                    showsStatus: false
                )
            }
            .frame(maxWidth: .infinity)
            .frame(height: 340)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(CraftColor.hairline)
            )
        }
    }

    private var states: some View {
        SettingsGroup("State") {
            SettingsRow {
                Text("Chat state")
                Spacer(minLength: 16)
                Picker("Chat state", selection: $previewState) {
                    ForEach(OrbState.allCases) { state in
                        Text(state.title).tag(state)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private func colors(palette: Binding<OrbPalette>) -> some View {
        SettingsGroup("Colors") {
            OrbColorRow(title: "Sky", note: "Top of the glass", hex: palette.sky)
            Hairline().padding(.horizontal, 16)
            OrbColorRow(title: "Horizon", note: "Middle fade", hex: palette.horizon)
            Hairline().padding(.horizontal, 16)
            OrbColorRow(title: "Ember", note: "Warm glow", hex: palette.ember)
            Hairline().padding(.horizontal, 16)
            OrbColorRow(title: "Ink", note: "Bottom pool", hex: palette.ink)
            Hairline().padding(.horizontal, 16)
            SettingsRow {
                Spacer(minLength: 0)
                Button("Reset to Default", action: reset)
                    .disabled(app.orbPalette == .membrae)
            }
        }
    }

    private func reset() {
        app.orbPalette = .membrae
    }
}

private struct OrbColorRow: View {
    var title: String
    var note: String
    @Binding var hex: String
    @State private var panel = ColorPanelLink()

    var body: some View {
        SettingsRow {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(note)
                    .font(CraftFont.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Text("#\(hex)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
            Button {
                panel.open(color: NSColor(Color(hex: hex))) { hex = Color(nsColor: $0).hexString }
            } label: {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(hex: hex))
                    .frame(width: 38, height: 22)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(CraftColor.hairline)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title) color")
            .accessibilityValue("#\(hex)")
        }
    }
}

/// Opens the shared color panel beside the cursor instead of wherever macOS last left it.
@MainActor
private final class ColorPanelLink: NSObject {
    private var onChange: ((NSColor) -> Void)?

    func open(color: NSColor, onChange: @escaping (NSColor) -> Void) {
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = color
        self.onChange = onChange
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.setFrameOrigin(origin(for: panel.frame.size))
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        onChange?(sender.color)
    }

    private func origin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        var origin = NSPoint(x: mouse.x + 12, y: mouse.y - size.height - 12)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            let bounds = screen.visibleFrame
            origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size.width)
            origin.y = min(max(origin.y, bounds.minY), bounds.maxY - size.height)
        }
        return origin
    }
}
