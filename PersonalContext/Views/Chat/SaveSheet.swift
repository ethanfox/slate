import SwiftData
import SwiftUI

struct SaveSheet: View {
    var kind: SaveKind
    var text: String
    var project: Project?
    var conversation: Conversation

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppModel.self) private var app
    @Query(sort: \Project.name) private var projects: [Project]

    @State private var title = ""
    @State private var bodyText = ""
    @State private var rationale = ""
    @State private var source = ""
    @State private var kindChoice: ThreadKind = .topic
    @State private var threadID: UUID?
    @State private var projectID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(heading)
                .font(CraftFont.title)

            if project == nil {
                Picker("Project", selection: $projectID) {
                    Text("Choose a project").tag(UUID?.none)
                    ForEach(projects) { item in
                        Text(item.name).tag(Optional(item.id))
                    }
                }
            }

            switch kind {
            case .note:
                TextField("Title", text: $title)
                    .textFieldStyle(.roundedBorder)
                TextEditor(text: $bodyText)
                    .font(CraftFont.body)
                    .frame(minHeight: 160)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(CraftColor.field, in: RoundedRectangle(cornerRadius: 8))
                TextField("Source", text: $source)
                    .textFieldStyle(.roundedBorder)
                threadPicker
            case .thread:
                TextField("Title", text: $title)
                    .textFieldStyle(.roundedBorder)
                Picker("Type", selection: $kindChoice) {
                    ForEach(ThreadKind.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                threadPicker
                TextField("Summary", text: $rationale, axis: .vertical)
                    .lineLimit(2...4)
                TextEditor(text: $bodyText)
                    .font(CraftFont.body)
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(CraftColor.field, in: RoundedRectangle(cornerRadius: 8))
            case .addToThread:
                threadPicker
                Text(bodyText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
            case .decision:
                TextField("Title", text: $title)
                    .textFieldStyle(.roundedBorder)
                Text("Decision")
                    .font(CraftFont.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $bodyText)
                    .font(CraftFont.body)
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(CraftColor.field, in: RoundedRectangle(cornerRadius: 8))
                TextField("Rationale", text: $rationale, axis: .vertical)
                    .lineLimit(2...4)
                threadPicker
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(confirmTitle) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear(perform: prefill)
    }

    private var heading: String {
        switch kind {
        case .note: "Save to Notes"
        case .thread: "Create Track"
        case .addToThread: "Add to Track"
        case .decision: "Create Decision"
        }
    }

    private var confirmTitle: String {
        switch kind {
        case .note: "Save Note"
        case .thread: "Create Track"
        case .addToThread: "Add"
        case .decision: "Save Decision"
        }
    }

    private var targetProject: Project? {
        if let project { return project }
        return projects.first { $0.id == projectID }
    }

    private var canSave: Bool {
        guard targetProject != nil else { return false }
        switch kind {
        case .addToThread:
            return threadID != nil
        case .note, .thread, .decision:
            return !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    @ViewBuilder
    private var threadPicker: some View {
        if let targetProject, !targetProject.threads.isEmpty, kind != .thread || true {
            Picker(kind == .thread ? "Parent" : "Track", selection: $threadID) {
                Text(kind == .thread ? "No parent" : "No track").tag(UUID?.none)
                ForEach(targetProject.threads.sorted { $0.title < $1.title }) { thread in
                    Text(thread.title.isEmpty ? "Untitled" : thread.title).tag(Optional(thread.id))
                }
            }
        }
    }

    private func prefill() {
        bodyText = text
        projectID = project?.id
        let firstLine = text
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch kind {
        case .note:
            source = "Conversation: \(conversation.title)"
        case .thread:
            title = String(firstLine.prefix(80))
            rationale = clip(text, 240)
        case .decision:
            title = String(firstLine.prefix(80))
        case .addToThread:
            break
        }
    }

    private func save() {
        guard let target = targetProject else { return }
        let thread = target.threads.first { $0.id == threadID }
        switch kind {
        case .note:
            let note = Note(
                content: bodyText,
                project: target,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                source: source,
                thread: thread
            )
            context.insert(note)
            app.flash("Saved to Notes")
        case .thread:
            let created = ProjectThread(title: title.isEmpty ? "Untitled" : title, kind: kindChoice, project: target, parent: thread)
            created.summary = rationale
            created.body = bodyText
            context.insert(created)
            app.selectedThread = created.id
            app.flash("Track created")
        case .addToThread:
            guard let thread else { return }
            let stamp = Date.now.formatted(date: .abbreviated, time: .shortened)
            let block = "\n\nFrom \(conversation.title) · \(stamp)\n\n\(text)"
            thread.body += block
            thread.updatedAt = .now
            if conversation.thread == nil {
                conversation.thread = thread
            }
            app.flash("Added to \(thread.title)")
        case .decision:
            let decision = Decision(
                title: title.isEmpty ? "Decision" : title,
                decision: bodyText,
                project: target,
                rationale: rationale,
                thread: thread
            )
            context.insert(decision)
            app.selectedDecision = decision.id
            app.flash("Decision saved")
        }
        target.touch()
        try? context.save()
        dismiss()
    }
}
