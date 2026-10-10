import SwiftUI

struct ChatCodeBlock: View {
    var language: String
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if !language.isEmpty {
                    Text(language)
                        .font(CraftFont.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                ChatCopyControl(text: text)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 4)

            Text(text.isEmpty ? " " : text)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .background(CraftColor.wash, in: RoundedRectangle(cornerRadius: CraftRadius.plate, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CraftRadius.plate, style: .continuous)
                .strokeBorder(CraftColor.hairline, lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(language.isEmpty ? "Code" : "\(language) code")
    }
}

struct ChatMarkdownTable: View {
    var rows: [[String]]
    var alignments: [NSTextAlignment]

    var body: some View {
        let columns = rows.map(\.count).max() ?? 0
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { row, cells in
                HStack(spacing: 0) {
                    ForEach(0..<columns, id: \.self) { column in
                        Text(column < cells.count ? cells[column] : " ")
                            .font(row == 0 ? CraftFont.section : CraftFont.body)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(textAlignment(column))
                            .frame(maxWidth: .infinity, alignment: frameAlignment(column))
                            .padding(8)
                    }
                }
                .background(row == 0 ? CraftColor.wash : Color.clear)
                if row < rows.count - 1 {
                    Rectangle()
                        .fill(CraftColor.hairline)
                        .frame(height: 0.5)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: CraftRadius.plate, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CraftRadius.plate, style: .continuous)
                .strokeBorder(CraftColor.hairline, lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Table")
    }

    private func textAlignment(_ column: Int) -> TextAlignment {
        switch column < alignments.count ? alignments[column] : .left {
        case .right: .trailing
        case .center: .center
        default: .leading
        }
    }

    private func frameAlignment(_ column: Int) -> Alignment {
        switch column < alignments.count ? alignments[column] : .left {
        case .right: .trailing
        case .center: .center
        default: .leading
        }
    }
}

struct ChatQuoteBubble<Content: View>: View {
    var copyText: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
            ChatCopyControl(text: copyText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(CraftColor.incoming, in: RoundedRectangle(cornerRadius: CraftRadius.bubble, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quote. \(copyText)")
    }
}

struct ChatCopyControl: View {
    var text: String
    @State private var didConfirm = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 5) {
                Image(systemName: didConfirm ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                Text(didConfirm ? "Copied" : "Copy")
                    .font(CraftFont.caption)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(didConfirm ? "Copied" : "Copy")
    }

    private func copy() {
        CraftClipboard.copy(text)
        didConfirm = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            didConfirm = false
        }
    }
}
