import SwiftData
import SwiftUI

struct NewRunSheet: View {
    var draft: NewRunDraft
    @Environment(AppModel.self) private var app
    @Query(sort: \Project.name) private var projects: [Project]
    @FocusState private var focusPrompt: Bool

    @State private var prompt: String
    @State private var projectID: UUID?
    @State private var taskID: UUID?
    @State private var providerID: String
    @State private var modelID: String
    @State private var selectedLocators: Set<String>
    @State private var allowEdits: Bool

    init(draft: NewRunDraft) {
        self.draft = draft
        _prompt = State(initialValue: draft.brief)
        _projectID = State(initialValue: draft.projectID)
        _taskID = State(initialValue: draft.taskID)
        _providerID = State(initialValue: draft.providerID)
        _modelID = State(initialValue: draft.modelID)
        _selectedLocators = State(initialValue: Set(draft.repositoryLocators))
        _allowEdits = State(initialValue: draft.allowEdits)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Run")
                .font(CraftFont.title)

            ModalField("Prompt") {
                TextField(promptPlaceholder, text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(4...10)
                    .focused($focusPrompt)
            }

            if !workers.isEmpty {
                ModalField("Send to", boxed: false) {
                    HStack(alignment: .top, spacing: 8) {
                        WorkerCard(
                            title: "Membrae agent",
                            symbol: "sparkles",
                            can: ["Notes and tasks", "Browses the web", "Reads code"],
                            cannot: ["Change code"],
                            isSelected: agent == nil
                        ) { worker.wrappedValue = "" }
                        ForEach(workers) { option in
                            WorkerCard(
                                title: option.title,
                                symbol: "terminal",
                                can: ["Changes code", "Runs commands", "Notes and tasks"],
                                cannot: ["Browse the web"],
                                isSelected: agent == option
                            ) { worker.wrappedValue = option.rawValue }
                        }
                    }
                }
            }

            if agent == .codex, !allowEdits {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Turn on the switch below to use Codex. Codex can only work from Membrae with its own sandbox off.")
                        .font(CraftFont.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.orange.opacity(0.35))
                )
                .accessibilityElement(children: .combine)
            }

            if agent != nil {
                ModalControlRow("Let it edit files and run commands") {
                    Toggle("Let it edit files and run commands", isOn: $allowEdits)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            if !attachments.isEmpty {
                ModalField("Code", boxed: false) {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: 8, alignment: .top),
                            count: attachments.count == 1 ? 1 : 2
                        ),
                        spacing: 8
                    ) {
                        ForEach(attachments, id: \.id) { attachment in
                            let isOn = binding(for: attachment)
                            CodeCard(
                                title: attachment.title.isEmpty ? attachment.locator : attachment.title,
                                path: Self.shortPath(attachment.locator),
                                isSelected: isOn.wrappedValue
                            ) { isOn.wrappedValue.toggle() }
                        }
                    }
                }
            }

            if let selectedProject {
                HStack(spacing: 6) {
                    Text("For")
                        .foregroundStyle(.secondary)
                    Text(selectedTask.map { "\(selectedProject.displayName) · \($0.displayTitle)" } ?? selectedProject.displayName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    // A Run started from a task is about that task, so there is nothing to clear.
                    if draft.taskID == nil {
                        Button(action: clearFiling) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 22)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Run without a Space")
                        .accessibilityLabel("Remove Space")
                    }
                }
                .font(CraftFont.body)
            }

            if let disclosure {
                Text(disclosure)
                    .font(CraftFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ModalFooter(
                actionTitle: hasPrompt ? "Start Run with Prompt" : "Start Run",
                actionEnabled: canStart,
                action: start
            )
        }
        .onAppear { focusPrompt = true }
    }

    private var selectedProject: Project? {
        projects.first { $0.id == projectID }
    }

    private var selectedTask: AgendaItem? {
        guard let taskID else { return nil }
        return selectedProject?.agendaItems.first { $0.id == taskID }
    }

    private var attachments: [CodeAttachment] {
        selectedProject.map(ProjectCodeWorkspace.attachments(on:)) ?? []
    }

    private var hasPrompt: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var promptPlaceholder: String {
        selectedTask == nil
            ? "What should this run do?"
            : "Add anything the task doesn’t say, or leave this empty to run the task as written."
    }

    private var agent: LocalAgent? {
        LocalAgent(rawValue: providerID)
    }

    /// Coding tools the user connected, plus the one a retried Run already names.
    private var workers: [LocalAgent] {
        LocalAgent.allCases.filter { app.isConnected($0) || $0 == agent }
    }

    private var worker: Binding<String> {
        Binding(
            get: { agent?.rawValue ?? "" },
            set: { id in
                if !id.isEmpty {
                    providerID = id
                    modelID = ""
                } else if LocalAgent(rawValue: draft.providerID) == nil {
                    providerID = draft.providerID
                    modelID = draft.modelID
                } else {
                    providerID = app.talkProvider.rawValue
                    modelID = app.talkModelID
                }
            }
        )
    }

    private var canStart: Bool {
        (hasPrompt || selectedTask != nil)
            && app.providerConnected(providerID)
            && !(agent == .codex && !allowEdits)
    }

    /// Only what the cards do not already say.
    private var disclosure: String? {
        if !app.providerConnected(providerID) {
            return agent == nil
                ? "Connect an AI in Settings to use the Membrae agent."
                : "Connect \(agent?.title ?? "it") in Settings first."
        }
        return nil
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

    private func clearFiling() {
        projectID = nil
        selectedLocators = []
    }

    private static func shortPath(_ locator: String) -> String {
        let home = LocalAgent.home
        return locator.hasPrefix(home) ? "~" + locator.dropFirst(home.count) : locator
    }

    private func start() {
        var next = draft
        let typed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        next.brief = typed.isEmpty ? (selectedTask?.displayTitle ?? "") : typed
        next.projectID = projectID
        next.taskID = projectID == nil ? nil : taskID
        next.providerID = providerID
        next.modelID = modelID
        next.repositoryLocators = Array(selectedLocators)
        next.allowEdits = agent != nil && allowEdits
        app.startRun(next)
    }
}

/// One worker in the New Run form, with what it can and cannot do.
private struct WorkerCard: View {
    var title: String
    var symbol: String
    var can: [String]
    var cannot: [String]
    var isSelected: Bool
    var action: () -> Void

    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(app.accent.color) : AnyShapeStyle(.secondary))
                    .frame(height: 20)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(can, id: \.self) { line(text: $0, symbol: "checkmark", style: AnyShapeStyle(.secondary)) }
                    ForEach(cannot, id: \.self) { line(text: $0, symbol: "xmark", style: AnyShapeStyle(.tertiary)) }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
            .background(
                hovering && !isSelected ? CraftColor.hover : CraftColor.elevated,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? app.accent.color : CraftColor.hairline, lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityValue("Can: \(can.joined(separator: ", ")). Cannot: \(cannot.joined(separator: ", ")).")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func line(text: String, symbol: String, style: AnyShapeStyle) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .frame(width: 10)
            Text(text)
                .font(CraftFont.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(style)
    }
}

/// One attached folder or repository in the New Run form. Any number can be on.
private struct CodeCard: View {
    var title: String
    var path: String
    var isSelected: Bool
    var action: () -> Void

    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(app.accent.color) : AnyShapeStyle(.tertiary))
                    .frame(height: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !path.isEmpty, path != title {
                        Text(path)
                            .font(CraftFont.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                hovering && !isSelected ? CraftColor.hover : CraftColor.elevated,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? app.accent.color : CraftColor.hairline, lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(path)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
        try? context.persist()
        modalDismiss()
    }
}
