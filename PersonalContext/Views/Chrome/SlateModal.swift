import AppKit
import SwiftData
import SwiftUI

enum AppModal: Identifiable {
    case newProject
    case newEvent
    case editEvent(CalendarEvent)
    case newTask(Project?)
    case newTaskFromNote(Note)
    case editReminder(ReminderItem)
    case editTask(AgendaItem)
    case save(SaveKind)
    case connectCursor
    case connectChatGPT
    case connectGitHub
    case connectGitLab
    case editProject(Project)
    case editConversation(Conversation)
    case editThread(ProjectThread)
    case editDecision(Decision)
    case editNote(Note)

    var id: String {
        switch self {
        case .newProject: "new-project"
        case .newEvent: "new-event"
        case .editEvent(let event): "edit-event-\(event.id)"
        case .newTask(let project): project.map { "new-task-\($0.id.uuidString)" } ?? "new-task"
        case .newTaskFromNote(let note): "new-task-note-\(note.id.uuidString)"
        case .editReminder(let reminder): "edit-reminder-\(reminder.id)"
        case .editTask(let task): "edit-task-\(task.id.uuidString)"
        case .save(let kind): "save-\(kind.id)"
        case .connectCursor: "connect-cursor"
        case .connectChatGPT: "connect-chatgpt"
        case .connectGitHub: "connect-github"
        case .connectGitLab: "connect-gitlab"
        case .editProject(let project): "edit-project-\(project.id.uuidString)"
        case .editConversation(let conversation): "edit-conversation-\(conversation.id.uuidString)"
        case .editThread(let thread): "edit-thread-\(thread.id.uuidString)"
        case .editDecision(let decision): "edit-decision-\(decision.id.uuidString)"
        case .editNote(let note): "edit-note-\(note.id.uuidString)"
        }
    }

    var panelWidth: CGFloat {
        switch self {
        case .newEvent, .editEvent, .newTask, .newTaskFromNote, .editReminder, .editTask: 520
        default: 440
        }
    }

}

struct ModalDismissAction {
    let action: () -> Void
    func callAsFunction() { action() }
}

enum ModalHost {
    case main
    case settings
}

extension EnvironmentValues {
    @Entry var modalDismiss = ModalDismissAction(action: {})
    @Entry var modalHost = ModalHost.main
    @Entry var modalInnerSize = CGSize.zero
}

struct SlateModalPresenter<ModalContent: View>: View {
    var modal: AppModal?
    var onDismiss: () -> Void
    @ViewBuilder var modalContent: (AppModal) -> ModalContent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let margin: CGFloat = 40
            let panelWidth = min(modal?.panelWidth ?? 440, max(geo.size.width - margin * 2, 280))
            let available = max(geo.size.height - margin * 2, 240)
            ZStack {
                if let modal {
                    CraftColor.scrim
                        .ignoresSafeArea()
                        .onTapGesture(perform: onDismiss)
                        .transition(.opacity)

                    ModalHeightClamp(maxWidth: panelWidth, maxHeight: available) {
                        modalContent(modal)
                            .environment(\.modalDismiss, ModalDismissAction(action: onDismiss))
                            .environment(\.modalInnerSize, CGSize(width: panelWidth - 40, height: available - 40))
                            .padding(20)
                            .frame(width: panelWidth)
                            .textSelection(.enabled)
                    }
                    .background {
                        panelShape
                            .fill(.clear)
                            .glassEffect(.regular, in: panelShape)
                    }
                    .contentShape(panelShape)
                    .shadow(color: .black.opacity(0.20), radius: 30, y: 12)
                    .transition(panelTransition)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(modalAnimation, value: modal?.id)
        }
        .allowsHitTesting(modal != nil)
        .onExitCommand {
            if modal != nil { onDismiss() }
        }
    }

    private struct ModalHeightClamp: Layout {
        var maxWidth: CGFloat
        var maxHeight: CGFloat

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
            guard let child = subviews.first else { return .zero }
            let widthCap = min(proposal.width ?? maxWidth, maxWidth)
            let ideal = child.sizeThatFits(.init(width: widthCap, height: nil))
            var width = min(max(ideal.width, 1), widthCap)
            var height = ideal.height
            if ideal.width > widthCap {
                let fitted = child.sizeThatFits(.init(width: widthCap, height: nil))
                width = min(fitted.width, widthCap)
                height = fitted.height
            }
            if height > maxHeight {
                let fitted = child.sizeThatFits(.init(width: width, height: maxHeight))
                width = min(max(fitted.width, 1), widthCap)
                height = maxHeight
            }
            return CGSize(width: width, height: min(height, maxHeight))
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
            guard let child = subviews.first else { return }
            child.place(at: bounds.origin, proposal: .init(width: bounds.width, height: bounds.height))
        }
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
    }

    private var modalAnimation: Animation {
        if reduceMotion { return Motion.quick }
        return modal == nil ? Motion.quick : Motion.snappy
    }

    private var panelTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .scale(scale: 0.96).combined(with: .opacity),
            removal: .scale(scale: 0.98).combined(with: .opacity)
        )
    }
}

struct ModalScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView(.vertical) {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 12)
            }
            .scrollIndicators(.visible, axes: .vertical)
            .scrollIndicators(.hidden, axes: .horizontal)
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .clipped()
            .background(ModalScrollLock())
        }
    }
}

private struct ModalScrollLock: NSViewRepresentable {
    func makeNSView(context: Context) -> ModalScrollLockView {
        ModalScrollLockView()
    }

    func updateNSView(_ nsView: ModalScrollLockView, context: Context) {
        nsView.lock()
    }
}

private final class ModalScrollLockView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        lock()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        lock()
    }

    override func layout() {
        super.layout()
        lock()
    }

    func lock() {
        var cursor: NSView? = self
        while let view = cursor {
            apply(to: view)
            cursor = view.superview
        }
        apply(in: enclosingScrollView ?? superview)
    }

    private func apply(in root: NSView?) {
        guard let root else { return }
        apply(to: root)
        for child in root.subviews {
            apply(in: child)
        }
    }

    private func apply(to view: NSView) {
        guard let scroll = view as? NSScrollView else { return }
        scroll.hasHorizontalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.usesPredominantAxisScrolling = true
    }
}

struct ModalField<Content: View>: View {
    var title: String
    var boxed = true
    @ViewBuilder var content: () -> Content

    init(_ title: String, boxed: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.boxed = boxed
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(CraftFont.section)
            if boxed {
                content()
                    .padding(10)
                    .background(CraftColor.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(CraftColor.hairline)
                    )
            } else {
                content()
            }
        }
    }
}

struct ModalControlRow<Control: View>: View {
    var title: String
    @ViewBuilder var control: () -> Control

    init(_ title: String, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.control = control
    }

    var body: some View {
        HStack {
            Text(title)
                .font(CraftFont.body)
            Spacer(minLength: 16)
            control()
        }
        .frame(height: 28)
    }
}

struct ModalFooter<Leading: View>: View {
    var actionTitle: String
    var actionEnabled = true
    var action: () -> Void
    @ViewBuilder var leading: () -> Leading

    @Environment(\.modalDismiss) private var modalDismiss

    var body: some View {
        VStack(spacing: 10) {
            ModalFooterButton(title: actionTitle, role: .primary, enabled: actionEnabled, action: action)
                .keyboardShortcut(.defaultAction)

            HStack(spacing: 10) {
                ModalFooterButton(title: "Cancel", action: { modalDismiss() })
                    .keyboardShortcut(.cancelAction)
                leading()
            }
        }
        .padding(.top, 4)
    }
}

struct ModalFooterButton: View {
    enum Role {
        case primary
        case secondary
        case destructive
    }

    var title: String
    var role = Role.secondary
    var enabled = true
    var action: () -> Void

    @Environment(AppModel.self) private var app

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(role == .primary ? .system(size: 15, weight: .medium) : CraftFont.body)
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(fill, in: Capsule())
                .overlay {
                    if role != .primary {
                        Capsule().stroke(CraftColor.hairline)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var foreground: Color {
        switch role {
        case .primary: .white
        case .secondary: .primary
        case .destructive: .red
        }
    }

    private var fill: Color {
        switch role {
        case .primary: app.accent.color.opacity(enabled ? 1 : 0.4)
        case .secondary, .destructive: CraftColor.elevated
        }
    }
}

struct ModalActionRow: View {
    var title: String
    var systemImage: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(CraftFont.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text(title)
                    .font(CraftFont.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(CraftFont.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension ModalFooter where Leading == EmptyView {
    init(actionTitle: String, actionEnabled: Bool = true, action: @escaping () -> Void) {
        self.init(actionTitle: actionTitle, actionEnabled: actionEnabled, action: action) {
            EmptyView()
        }
    }
}
