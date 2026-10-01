import SwiftUI

struct RecordRow<Marks: View>: View {
    var systemImage: String
    var title: String
    var subtitle = ""
    var meta = ""
    var marks: Marks
    var action: () -> Void
    @State private var hovering = false

    init(
        systemImage: String,
        title: String,
        subtitle: String = "",
        meta: String = "",
        @ViewBuilder marks: () -> Marks,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
        self.meta = meta
        self.marks = marks()
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 17)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .layoutPriority(1)
                        marks
                    }
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if !meta.isEmpty {
                        Text(meta)
                            .font(CraftFont.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? CraftColor.hover : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -8)
        .onHover { hovering = $0 }
    }
}

extension RecordRow where Marks == EmptyView {
    init(
        systemImage: String,
        title: String,
        subtitle: String = "",
        meta: String = "",
        action: @escaping () -> Void
    ) {
        self.init(systemImage: systemImage, title: title, subtitle: subtitle, meta: meta, marks: { EmptyView() }, action: action)
    }
}
