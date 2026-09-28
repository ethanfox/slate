import SwiftUI

struct ProjectLine: View {
    var project: Project

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: project.symbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 17)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(project.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if project.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                if !project.summary.isEmpty {
                    Text(plainPreview(project.summary))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text("\(project.status.label) · \(project.lastActivity.relativeLabel)")
                    .font(CraftFont.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
