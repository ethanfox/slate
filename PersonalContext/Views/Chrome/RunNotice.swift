import AppKit
import SwiftUI
import UserNotifications

/// A card at the top right saying a Run ended. Runs are not in the sidebar, so this is how the user finds out.
struct RunNotice: Identifiable, Equatable {
    /// The Run's id.
    var id: UUID
    var title: String
    var status: RunStatus
    var detail: String
    var fix: RunNoticeFix?
    /// The worker marked the Run's task done.
    var completedTask = false

    var headline: String {
        switch status {
        case .succeeded: completedTask ? "Finished and marked the task done" : "Finished"
        case .couldNot: "Couldn’t do it"
        default: "Failed"
        }
    }
}

/// The one click that puts a Run that could not be done in front of a worker that can.
enum RunNoticeFix: Equatable {
    case send(LocalAgent)
    case allowEdits(LocalAgent)

    var title: String {
        switch self {
        case .send(let agent): "Send to \(agent.title)"
        case .allowEdits: "Try Again with Edits On"
        }
    }
}

extension AppModel {
    func postRunNotice(for run: AgentRun) {
        guard run.status == .succeeded || run.status == .couldNot || run.status == .failed else { return }
        let summary = run.status == .succeeded ? run.resultSummary : run.statusDetail
        var fix: RunNoticeFix?
        if run.status == .couldNot {
            if let agent = LocalAgent(rawValue: run.providerID) {
                fix = run.allowEdits ? nil : .allowEdits(agent)
            } else if let agent = LocalAgent.allCases.first(where: isConnected) {
                fix = .send(agent)
            }
        }
        let notice = RunNotice(
            id: run.id,
            title: run.displayTitle,
            status: run.status,
            detail: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            fix: fix,
            completedTask: run.status == .succeeded
                && (run.task?.isCompleted == true || run.task?.workflowStatus == .done)
        )
        withAnimation(Motion.snappy) {
            runNotices.removeAll { $0.id == notice.id }
            runNotices.insert(notice, at: 0)
            if runNotices.count > 4 { runNotices.removeLast(runNotices.count - 4) }
        }
        if notice.status == .succeeded {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                self?.dismissRunNotice(notice.id, onlyIf: .succeeded)
            }
        }
        if !NSApp.isActive {
            RunNoticeCenter.deliver(notice)
        }
    }

    func dismissRunNotice(_ id: UUID, onlyIf status: RunStatus? = nil) {
        guard runNotices.contains(where: { $0.id == id && (status == nil || $0.status == status) }) else { return }
        withAnimation(Motion.quick) {
            runNotices.removeAll { $0.id == id }
        }
    }

    func openRunNotice(_ notice: RunNotice) {
        dismissRunNotice(notice.id)
        guard let run = RunStore.run(notice.id, in: container.mainContext) else { return }
        open(run)
    }

    /// Opens the New Run form with the same request and the fix applied. The user still starts it.
    func applyFix(for notice: RunNotice) {
        guard let fix = notice.fix, let run = RunStore.run(notice.id, in: container.mainContext) else { return }
        var draft = RunStore.retryDraft(from: run)
        switch fix {
        case .send(let agent):
            draft.providerID = agent.rawValue
            draft.modelID = ""
            draft.allowEdits = false
        case .allowEdits:
            draft.allowEdits = true
        }
        dismissRunNotice(notice.id)
        present(.newRun(draft))
    }
}

/// The system notification, for when Membrae is not the app in front.
enum RunNoticeCenter {
    static func deliver(_ notice: RunNotice) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = notice.headline
            content.subtitle = notice.title
            content.body = notice.detail
            content.sound = .default
            center.add(UNNotificationRequest(identifier: notice.id.uuidString, content: content, trigger: nil))
        }
    }
}

struct RunNoticeStack: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .trailing, spacing: 18) {
            ForEach(app.runNotices) { notice in
                RunNoticeCard(notice: notice)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .trailing).combined(with: .opacity)
                    )
            }
        }
    }
}

private struct RunNoticeCard: View {
    var notice: RunNotice

    @Environment(AppModel.self) private var app
    @State private var hovering = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(notice.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Text(notice.detail.isEmpty ? notice.headline : "\(notice.headline). \(notice.detail)")
                .font(CraftFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if let fix = notice.fix {
                Button(fix.title) { app.applyFix(for: notice) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(app.accent.color)
                    .padding(.top, 2)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 28)
        .padding(.vertical, 12)
        .frame(width: 300, alignment: .leading)
        .background {
            shape
                .fill(.clear)
                .glassEffect(.regular, in: shape)
        }
        .contentShape(shape)
        .onTapGesture { app.openRunNotice(notice) }
        .overlay(alignment: .topTrailing) {
            Button {
                app.dismissRunNotice(notice.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(6)
            .opacity(hovering ? 1 : 0)
            .help("Dismiss")
        }
        .overlay(alignment: .topLeading) {
            RunReaction(status: notice.status)
                .offset(x: -12, y: -14)
        }
        .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(notice.headline): \(notice.title)")
        .accessibilityAddTraits(.isButton)
    }
}

/// The result, drawn like a reaction on a message bubble: a small filled bubble with a tail, sitting on the corner.
private struct RunReaction: View {
    var status: RunStatus

    @Environment(AppModel.self) private var app

    private var symbol: String {
        switch status {
        case .succeeded: "hand.thumbsup.fill"
        case .couldNot: "questionmark"
        default: "exclamationmark.2"
        }
    }

    private var fill: Color {
        switch status {
        case .succeeded: app.accent.color
        case .couldNot: .orange
        default: .red
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(fill)
                .frame(width: 10, height: 10)
                .offset(x: 11, y: 11)
            Circle()
                .fill(fill)
                .frame(width: 4, height: 4)
                .offset(x: 18, y: 17)
            Circle()
                .fill(fill)
                .frame(width: 30, height: 30)
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        .accessibilityHidden(true)
    }
}
