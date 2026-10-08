import SwiftUI

struct ChromeChoiceItem<Value: Hashable>: Identifiable {
    var value: Value
    var title: String
    var symbol: String

    var id: Value { value }
}

/// Liquid Glass tile picker. Two to eight options, at most four per row, tiles grow to fill the row.
struct ChromeChoiceDialog<Value: Hashable>: View {
    var title: String
    var subtitle: String? = nil
    var footer: String? = nil
    var selectAllTitle: String? = nil
    var onSelectAll: (() -> Void)? = nil
    var options: [ChromeChoiceItem<Value>]
    @Binding var selection: Value

    private var visible: [ChromeChoiceItem<Value>] {
        let clipped = Array(options.prefix(Self.maxOptions))
        if options.count < Self.minOptions || options.count > Self.maxOptions {
            assertionFailure("ChromeChoiceDialog needs \(Self.minOptions)–\(Self.maxOptions) options, got \(options.count).")
        }
        return clipped
    }

    private var columns: Int {
        min(Self.maxColumns, max(visible.count, 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns),
                spacing: 8
            ) {
                ForEach(visible) { option in
                    tile(option)
                }
            }
            if let footer {
                Text(footer)
                    .font(CraftFont.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(width: panelWidth)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(CraftFont.section)
                if let subtitle {
                    Text(subtitle)
                        .font(CraftFont.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let selectAllTitle, let onSelectAll {
                Button(selectAllTitle, action: onSelectAll)
                    .buttonStyle(.plain)
                    .font(CraftFont.body)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func tile(_ option: ChromeChoiceItem<Value>) -> some View {
        let selected = option.value == selection
        return Button {
            selection = option.value
        } label: {
            VStack(spacing: 6) {
                Image(systemName: option.symbol)
                    .font(.system(size: 16, weight: .medium))
                    .frame(height: 22)
                Text(option.title)
                    .font(CraftFont.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 72)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? CraftColor.elevated : Color.clear)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Color.clear : CraftColor.hairline)
            }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var panelWidth: CGFloat {
        switch columns {
        case 2: 280
        case 3: 340
        default: 400
        }
    }

    static var minOptions: Int { 2 }
    static var maxOptions: Int { 8 }
    static var maxColumns: Int { 4 }
    static var maxRows: Int { 4 }
}

/// Glass capsule that opens ``ChromeChoiceDialog``. Sit it in a `GlassEffectContainer` next to other chrome.
struct ChromeChoiceControl<Value: Hashable>: View {
    var title: String
    var subtitle: String? = nil
    var footer: String? = nil
    var selectAllTitle: String? = nil
    var onSelectAll: (() -> Void)? = nil
    var options: [ChromeChoiceItem<Value>]
    @Binding var selection: Value
    @State private var isPresented = false

    private var current: ChromeChoiceItem<Value>? {
        options.first { $0.value == selection } ?? options.first
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: current?.symbol ?? "square.grid.2x2")
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .glassEffect(.regular, in: Capsule())
        .help(current?.title ?? title)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ChromeChoiceDialog(
                title: title,
                subtitle: subtitle,
                footer: footer,
                selectAllTitle: selectAllTitle,
                onSelectAll: {
                    onSelectAll?()
                    isPresented = false
                },
                options: options,
                selection: $selection
            )
            .onChange(of: selection) { _, _ in
                isPresented = false
            }
        }
        .accessibilityLabel(title)
        .accessibilityValue(current?.title ?? "")
    }
}
