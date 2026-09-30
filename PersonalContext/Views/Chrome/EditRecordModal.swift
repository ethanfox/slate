import SwiftData
import SwiftUI

struct EditProjectModal: View {
    var project: Project
    @Environment(\.modelContext) private var context
    @Environment(\.modalDismiss) private var modalDismiss
    @FocusState private var focusName: Bool

    @State private var name: String
    @State private var symbol: String
    @State private var summary: String
    @State private var status: ProjectStatus
    @State private var isPinned: Bool

    init(project: Project) {
        self.project = project
        _name = State(initialValue: project.name)
        _symbol = State(initialValue: project.symbol)
        _summary = State(initialValue: project.summary)
        _status = State(initialValue: project.status)
        _isPinned = State(initialValue: project.isPinned)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Project")
                .font(CraftFont.title)

            ModalField("Name") {
                TextField("Article One", text: $name)
                    .textFieldStyle(.plain)
                    .focused($focusName)
            }

            ModalField("Icon", boxed: false) {
                SymbolPicker(selection: $symbol)
            }

            ModalField("Description") {
                TextField("What this project is", text: $summary, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(3...6)
            }

            ModalControlRow("Status") {
                Picker("Status", selection: $status) {
                    ForEach(ProjectStatus.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }

            ModalControlRow("Pinned") {
                Toggle("Pinned", isOn: $isPinned)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            ModalFooter(actionTitle: "Save", actionEnabled: canSave, action: save)
        }
        .onAppear { focusName = true }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        project.name = trimmed
        project.symbol = symbol
        project.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        project.status = status
        project.isPinned = isPinned
        project.touch()
        try? context.save()
        modalDismiss()
    }
}

struct EditConversationModal: View {
    var conversation: Conversation
    @Environment(\.modelContext) private var context
    @Environment(\.modalDismiss) private var modalDismiss
    @FocusState private var focusTitle: Bool

    @State private var title: String
    @State private var isArchived: Bool

    init(conversation: Conversation) {
        self.conversation = conversation
        _title = State(initialValue: conversation.title)
        _isArchived = State(initialValue: conversation.isArchived)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Chat")
                .font(CraftFont.title)

            ModalField("Title") {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .focused($focusTitle)
            }

            ModalControlRow("Archived") {
                Toggle("Archived", isOn: $isArchived)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            ModalFooter(actionTitle: "Save", action: save)
        }
        .onAppear { focusTitle = true }
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { conversation.title = trimmed }
        conversation.isArchived = isArchived
        conversation.updatedAt = .now
        conversation.project?.touch()
        try? context.save()
        modalDismiss()
    }
}

struct EditThreadModal: View {
    var thread: ProjectThread
    @Environment(\.modelContext) private var context
    @Environment(\.modalDismiss) private var modalDismiss
    @FocusState private var focusTitle: Bool

    @State private var title: String
    @State private var kind: ThreadKind
    @State private var status: ThreadStatus
    @State private var summary: String

    init(thread: ProjectThread) {
        self.thread = thread
        _title = State(initialValue: thread.title)
        _kind = State(initialValue: thread.kind)
        _status = State(initialValue: thread.status)
        _summary = State(initialValue: thread.summary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Track")
                .font(CraftFont.title)

            ModalField("Title") {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .focused($focusTitle)
            }

            ModalControlRow("Kind") {
                Picker("Kind", selection: $kind) {
                    ForEach(ThreadKind.allCases) { item in
                        Label(item.label, systemImage: item.symbol).tag(item)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }

            ModalControlRow("Status") {
                Picker("Status", selection: $status) {
                    ForEach(ThreadStatus.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }

            ModalField("Summary") {
                TextField("Summary", text: $summary, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(3...6)
            }

            ModalFooter(actionTitle: "Save", action: save)
        }
        .onAppear { focusTitle = true }
    }

    private func save() {
        thread.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        thread.kind = kind
        thread.status = status
        thread.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        thread.updatedAt = .now
        thread.project?.touch()
        try? context.save()
        modalDismiss()
    }
}

struct EditDecisionModal: View {
    var decision: Decision
    @Environment(\.modelContext) private var context
    @Environment(\.modalDismiss) private var modalDismiss
    @FocusState private var focusTitle: Bool

    @State private var title: String
    @State private var status: DecisionStatus
    @State private var decisionText: String
    @State private var rationale: String

    init(decision: Decision) {
        self.decision = decision
        _title = State(initialValue: decision.title)
        _status = State(initialValue: decision.status)
        _decisionText = State(initialValue: decision.decision)
        _rationale = State(initialValue: decision.rationale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Decision")
                .font(CraftFont.title)

            ModalField("Title") {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .focused($focusTitle)
            }

            ModalControlRow("Status") {
                Picker("Status", selection: $status) {
                    ForEach(DecisionStatus.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }

            ModalField("Decision") {
                TextField("Decision", text: $decisionText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(3...6)
            }

            ModalField("Rationale") {
                TextField("Rationale", text: $rationale, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(3...6)
            }

            ModalFooter(actionTitle: "Save", action: save)
        }
        .onAppear { focusTitle = true }
    }

    private func save() {
        decision.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        decision.status = status
        decision.decision = decisionText.trimmingCharacters(in: .whitespacesAndNewlines)
        decision.rationale = rationale.trimmingCharacters(in: .whitespacesAndNewlines)
        decision.project?.touch()
        try? context.save()
        modalDismiss()
    }
}

struct EditNoteModal: View {
    var note: Note
    @Environment(\.modelContext) private var context
    @Environment(\.modalDismiss) private var modalDismiss
    @FocusState private var focusTitle: Bool

    @State private var title: String

    init(note: Note) {
        self.note = note
        _title = State(initialValue: note.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Note")
                .font(CraftFont.title)

            ModalField("Title") {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .focused($focusTitle)
            }

            ModalFooter(actionTitle: "Save", action: save)
        }
        .onAppear { focusTitle = true }
    }

    private func save() {
        note.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        note.updatedAt = .now
        note.project?.touch()
        try? context.save()
        modalDismiss()
    }
}
