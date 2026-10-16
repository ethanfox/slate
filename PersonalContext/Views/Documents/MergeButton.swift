import SwiftUI

/// Brings a track's branch into main. Reads "Bringing into main…" while it works, "In main" once it is in,
/// and keeps one short line under it when it could not.
struct MergeButton: View {
    var track: ProjectThread
    var disabled = false

    @Environment(AppModel.self) private var app

    private var base: String { track.baseBranch.isEmpty ? "main" : track.baseBranch }
    private var state: AppModel.MergeState? { app.mergeStates[track.id] }
    private var isIn: Bool { state == .merged || track.status == .completed }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                app.bringIntoMain(track)
            } label: {
                HStack(spacing: 5) {
                    if state == .merging {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: isIn ? "checkmark" : "arrow.triangle.merge")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(isIn ? Color.secondary : Color.white)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(isIn ? CraftColor.elevated : Color.accentColor, in: Capsule())
                .overlay(Capsule().strokeBorder(CraftColor.hairline, lineWidth: isIn ? 1 : 0))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(disabled || isIn || state == .merging)
            .help(isIn ? "\(track.branch) is in \(base)" : "Merge \(track.branch) into \(base)")
            if case .failed(let reason) = state {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.red)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private var title: String {
        if isIn { return "In \(base)" }
        if state == .merging { return "Bringing into \(base)…" }
        return "Bring into \(base)"
    }
}
