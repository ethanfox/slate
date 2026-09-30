import SwiftData
import SwiftUI

enum AppModal: Identifiable {
    case newProject
    case newEvent
    case editEvent(CalendarEvent)
    case newReminder
    case newReminderFromNote(Note)
    case editReminder(ReminderItem)
    case save(SaveKind)
    case connectCursor
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
        case .newReminder: "new-reminder"
        case .newReminderFromNote(let note): "new-reminder-note-\(note.id.uuidString)"
        case .editReminder(let reminder): "edit-reminder-\(reminder.id)"
        case .save(let kind): "save-\(kind.id)"
        case .connectCursor: "connect-cursor"
        case .editProject(let project): "edit-project-\(project.id.uuidString)"
        case .editConversation(let conversation): "edit-conversation-\(conversation.id.uuidString)"
        case .editThread(let thread): "edit-thread-\(thread.id.uuidString)"
        case .editDecision(let decision): "edit-decision-\(decision.id.uuidString)"
        case .editNote(let note): "edit-note-\(note.id.uuidString)"
        }
    }

    var panelWidth: CGFloat {
        switch self {
        case .newEvent, .editEvent, .newReminder, .newReminderFromNote, .editReminder: 520
        default: 440
        }
    }

    var panelHeight: CGFloat? {
        switch self {
        case .newEvent, .editEvent: 640
        default: nil
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
}

struct SlateModalPresenter<ModalContent: View>: View {
    var modal: AppModal?
    var onDismiss: () -> Void
    @ViewBuilder var modalContent: (AppModal) -> ModalContent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let modal {
                    CraftColor.scrim
                        .ignoresSafeArea()
                        .onTapGesture(perform: onDismiss)
                        .transition(.opacity)

                    modalContent(modal)
                        .environment(\.modalDismiss, ModalDismissAction(action: onDismiss))
                        .padding(20)
                        .frame(width: modal.panelWidth)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .shadow(color: .black.opacity(0.20), radius: 30, y: 12)
                        .position(x: geo.size.width / 2, y: geo.size.height * 0.4)
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
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 10) {
            Button(actionTitle, action: action)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(app.accent.color.opacity(actionEnabled ? 1 : 0.4), in: Capsule())
                .disabled(!actionEnabled)

            HStack(spacing: 10) {
                Button("Cancel") { modalDismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain)
                    .font(CraftFont.body)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(CraftColor.elevated, in: Capsule())
                leading()
            }
        }
        .padding(.top, 4)
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
