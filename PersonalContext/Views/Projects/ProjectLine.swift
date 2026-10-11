import SwiftUI

struct ProjectLine: View {
    var row: TitleIndex

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: row.symbol.isEmpty ? "folder" : row.symbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 17)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.displayTitle)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if row.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text("\(row.projectStatus.label) · \(row.updatedAt.relativeLabel)")
                    .font(CraftFont.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
