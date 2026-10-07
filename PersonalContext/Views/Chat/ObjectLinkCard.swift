import SwiftData
import SwiftUI

struct ObjectLinkCard: View {
    var source: ChatSource
    var action: () -> Void
    @Environment(\.modelContext) private var modelContext
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: mark)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(CraftColor.field, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title)
                        .font(CraftFont.section)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(detail)
                        .font(CraftFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                hovering ? CraftColor.selection : CraftColor.elevated,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(CraftColor.hairline)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .accessibilityHint("Opens this \(card.subtitle)")
    }

    private var card: (source: ChatSource, title: String, subtitle: String) {
        source.presented(in: modelContext)
    }

    private var detail: String {
        let snippet = source.snippet(in: modelContext)
        return snippet.isEmpty ? card.subtitle : snippet
    }

    private var mark: String {
        if source.kind == .project, let symbol = source.project(in: modelContext)?.symbol, !symbol.isEmpty {
            return symbol
        }
        return card.source.symbol
    }
}
