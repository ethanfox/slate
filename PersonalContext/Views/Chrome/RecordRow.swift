import SwiftUI

struct RecordRow<Marks: View>: View {
    var systemImage: String
    var title: String
    var subtitle = ""
    var meta = ""
    var isBusy = false
    var findField: ObjectFind.Field? = nil
    var marks: Marks
    var action: () -> Void
    @Environment(\.objectFind) private var find
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    init(
        systemImage: String,
        title: String,
        subtitle: String = "",
        meta: String = "",
        isBusy: Bool = false,
        findField: ObjectFind.Field? = nil,
        @ViewBuilder marks: () -> Marks,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
        self.meta = meta
        self.isBusy = isBusy
        self.findField = findField
        self.marks = marks()
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Group {
                    if isBusy, !reduceMotion {
                        ProgressView()
                            .controlSize(.small)
                    } else if isBusy {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: systemImage)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
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
                    .fill(rowFill)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -8)
        .onHover { hovering = $0 }
        .modifier(FindAnchorIfNeeded(field: findField))
    }

    private var rowFill: Color {
        if let findField, let mark = find?.mark(for: findField), mark != .none {
            return mark.fill
        }
        return hovering ? CraftColor.hover : .clear
    }
}

extension RecordRow where Marks == EmptyView {
    init(
        systemImage: String,
        title: String,
        subtitle: String = "",
        meta: String = "",
        isBusy: Bool = false,
        findField: ObjectFind.Field? = nil,
        action: @escaping () -> Void
    ) {
        self.init(
            systemImage: systemImage,
            title: title,
            subtitle: subtitle,
            meta: meta,
            isBusy: isBusy,
            findField: findField,
            marks: { EmptyView() },
            action: action
        )
    }
}
