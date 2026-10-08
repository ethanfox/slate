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

            ModalField("Code", boxed: false) {
                ProjectCodeSection(project: project)
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

            ModalControlRow("Tags") {
                TagField(tags: conversation.tags) { conversation.tags = $0 }
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
    @Query(sort: \Project.name) private var projects: [Project]
    @FocusState private var focusTitle: Bool

    @State private var title: String
    @State private var kind: ThreadKind
    @State private var status: ThreadStatus
    @State private var summary: String
    @State private var projectID: UUID
    @State private var pendingMove: MovePlan?

    init(thread: ProjectThread) {
        self.thread = thread
        _title = State(initialValue: thread.title)
        _kind = State(initialValue: thread.kind)
        _status = State(initialValue: thread.status)
        _summary = State(initialValue: thread.summary)
        _projectID = State(initialValue: thread.project?.id ?? UUID())
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

            ModalControlRow("Project") {
                Picker("Project", selection: $projectID) {
                    ForEach(projects) { project in
                        Text(project.displayName).tag(project.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }

            ModalControlRow("Tags") {
                TagField(tags: thread.tags) { thread.tags = $0 }
            }

            ModalFooter(actionTitle: "Save", action: save)
        }
        .onAppear { focusTitle = true }
        .confirmationDialog("Move this track?", isPresented: Binding(get: { pendingMove != nil }, set: { if !$0 { pendingMove = nil } }), titleVisibility: .visible) {
            Button("Move") { commitMove() }
            Button("Cancel", role: .cancel) {
                projectID = thread.project?.id ?? projectID
                pendingMove = nil
            }
        } message: {
            Text(moveMessage)
        }
    }

    private var moveMessage: String {
        guard let plan = pendingMove else { return "" }
        let rows = plan.summary
        if rows.isEmpty { return "This track moves to \(plan.project.displayName)." }
        return "This also moves:\n" + rows.joined(separator: "\n")
    }

    private func save() {
        thread.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        thread.kind = kind
        thread.status = status
        thread.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        thread.updatedAt = .now
        if let target = projects.first(where: { $0.id == projectID }), target.id != thread.project?.id {
            pendingMove = AssociationService.cascade(moving: thread, to: target, in: context)
            return
        }
        thread.project?.touch()
        try? context.save()
        modalDismiss()
    }

    private func commitMove() {
        guard let plan = pendingMove else { return }
        thread.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        thread.kind = kind
        thread.status = status
        thread.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        thread.updatedAt = .now
        AssociationService.apply(plan, in: context)
        pendingMove = nil
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

            ModalControlRow("Tags") {
                TagField(tags: decision.tags) { decision.tags = $0 }
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
    @Query(sort: \Project.name) private var projects: [Project]
    @FocusState private var focusTitle: Bool

    @State private var title: String
    @State private var projectID: UUID
    @State private var pendingMove: MovePlan?

    init(note: Note) {
        self.note = note
        _title = State(initialValue: note.title)
        _projectID = State(initialValue: note.project?.id ?? UUID())
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

            ModalControlRow("Project") {
                Picker("Project", selection: $projectID) {
                    ForEach(projects) { project in
                        Text(project.displayName).tag(project.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }

            ModalControlRow("Tags") {
                TagField(tags: note.tags) { note.tags = $0 }
            }

            ModalFooter(actionTitle: "Save", action: save)
        }
        .onAppear { focusTitle = true }
        .confirmationDialog("Move this note?", isPresented: Binding(get: { pendingMove != nil }, set: { if !$0 { pendingMove = nil } }), titleVisibility: .visible) {
            Button("Move") { commitMove() }
            Button("Cancel", role: .cancel) {
                projectID = note.project?.id ?? projectID
                pendingMove = nil
            }
        } message: {
            Text(moveMessage)
        }
    }

    private var moveMessage: String {
        guard let plan = pendingMove else { return "" }
        let rows = plan.summary
        if rows.isEmpty { return "This note moves to \(plan.project.displayName)." }
        return "This also moves:\n" + rows.joined(separator: "\n")
    }

    private func save() {
        note.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        note.updatedAt = .now
        if let target = projects.first(where: { $0.id == projectID }), target.id != note.project?.id {
            pendingMove = AssociationService.cascade(moving: note, to: target, in: context)
            return
        }
        note.project?.touch()
        try? context.save()
        modalDismiss()
    }

    private func commitMove() {
        guard let plan = pendingMove else { return }
        note.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        note.updatedAt = .now
        AssociationService.apply(plan, in: context)
        pendingMove = nil
        modalDismiss()
    }
}
