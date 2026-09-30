import SwiftData
import SwiftUI

enum AppModal: Identifiable {
    case newProject
    case newEvent
    case editEvent(CalendarEvent)
    case newReminder
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
        case .newEvent, .editEvent: 520
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

    var body: some View {
        HStack {
            Button("Cancel") { modalDismiss() }
                .keyboardShortcut(.cancelAction)
            leading()
            Spacer()
            Button(actionTitle, action: action)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!actionEnabled)
        }
        // VStack spacing is 16; this makes the footer 20 below the last field.
        .padding(.top, 4)
    }
}

extension ModalFooter where Leading == EmptyView {
    init(actionTitle: String, actionEnabled: Bool = true, action: @escaping () -> Void) {
        self.init(actionTitle: actionTitle, actionEnabled: actionEnabled, action: action) {
            EmptyView()
        }
    }
}
