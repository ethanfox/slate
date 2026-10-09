import SwiftData
import SwiftUI

struct NewRunSheet: View {
    var draft: NewRunDraft
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \Project.name) private var projects: [Project]
    @FocusState private var focusBrief: Bool

    @State private var brief: String
    @State private var projectID: UUID?
    @State private var taskID: UUID?
    @State private var providerID: String
    @State private var modelID: String
    @State private var pathRaw: String
    @State private var selectedLocators: Set<String>

    init(draft: NewRunDraft) {
        self.draft = draft
        _brief = State(initialValue: draft.brief)
        _projectID = State(initialValue: draft.projectID)
        _taskID = State(initialValue: draft.taskID)
        _providerID = State(initialValue: draft.providerID)
        _modelID = State(initialValue: draft.modelID)
        _pathRaw = State(initialValue: draft.pathRaw)
        _selectedLocators = State(initialValue: Set(draft.repositoryLocators))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Run")
                .font(CraftFont.title)

            ModalField("Brief") {
                TextField("What should this run do?", text: $brief, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(3...8)
                    .focused($focusBrief)
            }

            ModalControlRow("Project") {
                Picker("Project", selection: $projectID) {
                    Text("No project").tag(Optional<UUID>.none)
                    ForEach(projects) { project in
                        Text(project.displayName).tag(Optional(project.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }

            ModalControlRow("Task") {
                Picker("Task", selection: $taskID) {
                    Text("None").tag(Optional<UUID>.none)
                    ForEach(incompleteTasks) { item in
                        Text(item.displayTitle).tag(Optional(item.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .disabled(projectID == nil)
            }

            ModalControlRow("Model") {
                ModelPicker(providerID: $providerID, modelID: $modelID)
            }

            if TalkProvider(rawValue: providerID) == .cursor, !WorkerRegistry.paths(for: providerID).isEmpty {
                ModalControlRow("Path") {
                    Picker("Path", selection: $pathRaw) {
                        ForEach(WorkerRegistry.paths(for: providerID)) { path in
                            Text(path.title).tag(path.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            if !attachments.isEmpty {
                ModalField("Code", boxed: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(attachments, id: \.id) { attachment in
                            Toggle(isOn: binding(for: attachment)) {
                                Text(attachment.title.isEmpty ? attachment.locator : attachment.title)
                                    .font(CraftFont.body)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }

            Text(disclosure)
                .font(CraftFont.caption)
                .foregroundStyle(.secondary)

            ModalFooter(actionTitle: "Start Run", actionEnabled: canStart, action: start)
        }
        .onAppear { focusBrief = true }
        .onChange(of: projectID) { _, _ in
            if projectID == nil { taskID = nil }
            if let selected = taskID, !incompleteTasks.contains(where: { $0.id == selected }) {
                taskID = nil
            }
            selectedLocators = []
        }
    }

    private var selectedProject: Project? {
        projects.first { $0.id == projectID }
    }

    private var incompleteTasks: [AgendaItem] {
        guard let selectedProject else { return [] }
        return selectedProject.agendaItems
            .filter { $0.kind == .task && !$0.isCompleted }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var attachments: [CodeAttachment] {
        selectedProject.map(ProjectCodeWorkspace.attachments(on:)) ?? []
    }

    private var canStart: Bool {
        !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && app.providerConnected(providerID)
    }

    private var disclosure: String {
        let isCursor = TalkProvider(rawValue: providerID) == .cursor
        if selectedProject != nil {
            if isCursor {
                return "Can read and write this project’s notes and tasks, search the web, and read only the code you attach. It will not complete the task."
            }
            return "Can read and write this project’s notes and tasks, and read only the code you attach. ChatGPT cannot search the web. It will not complete the task."
        }
        if isCursor {
            return "Can search the web. It has no project to write into."
        }
        return "ChatGPT cannot search the web and has no project to write into."
    }

    private func binding(for attachment: CodeAttachment) -> Binding<Bool> {
        let key = attachment.locator.isEmpty ? attachment.title : attachment.locator
        return Binding(
            get: { selectedLocators.contains(key) },
            set: { on in
                if on { selectedLocators.insert(key) }
                else { selectedLocators.remove(key) }
            }
        )
    }

    private func start() {
        var next = draft
        next.brief = brief
        next.projectID = projectID
        next.taskID = projectID == nil ? nil : taskID
        next.providerID = providerID
        next.modelID = modelID
        next.pathRaw = pathRaw
        next.repositoryLocators = Array(selectedLocators)
        app.startRun(next)
    }
}

struct EditRunModal: View {
    var run: AgentRun
    @Environment(\.modelContext) private var context
    @Environment(\.modalDismiss) private var modalDismiss
    @FocusState private var focusTitle: Bool
    @State private var title: String

    init(run: AgentRun) {
        self.run = run
        _title = State(initialValue: run.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Run")
                .font(CraftFont.title)
            ModalField("Title") {
                TextField("New run", text: $title)
                    .textFieldStyle(.plain)
                    .focused($focusTitle)
            }
            ModalFooter(actionTitle: "Save", action: save)
        }
        .onAppear { focusTitle = true }
    }

    private func save() {
        run.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        run.touch()
        run.project?.touch()
        try? context.save()
        modalDismiss()
    }
}
