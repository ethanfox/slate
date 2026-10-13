import SwiftData
import SwiftUI

struct ProjectsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<TitleIndex> { $0.kindRaw == "project" })
    private var projects: [TitleIndex]
    @State private var pendingDelete: TitleIndex?
    @State private var sort = ProjectSort.updated
    @State private var sortAscending = false

    private var ordered: [TitleIndex] {
        projects.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            return sortAscending ? compare(lhs, rhs) : compare(rhs, lhs)
        }
    }

    var body: some View {
        ScrollView {
            PageBody {
                VStack(alignment: .leading, spacing: 0) {
                    if ordered.isEmpty {
                        EmptyLine(text: "Create a project with a name, an icon, and a short description.")
                    } else if app.projectsLayout == .table {
                        ProjectsTable(
                            projects: ordered,
                            sort: sort,
                            sortAscending: sortAscending,
                            onSort: sortBy,
                            onOpen: { app.open($0) },
                            onOpenNewTab: { app.open($0, newTab: true) },
                            onEdit: edit,
                            onPin: pin,
                            onDelete: { pendingDelete = $0 }
                        )
                    } else {
                        projectCards
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .scrollContentBackground(.hidden)
        .onAppear { NavTrace.event("projects appear count=\(projects.count)") }
        .alert(
            "Delete \(pendingDelete?.displayTitle ?? "this project")?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let row = pendingDelete, let project = TitleIndexStore.project(row.id, in: context) {
                    CodeReferenceStore.deleteOwnedReferences(in: project, context: context)
                    context.delete(project)
                    try? context.persist()
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Tracks, notes, decisions, and conversations in this project will be removed from this Mac.")
        }
    }

    private var projectCards: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], alignment: .leading, spacing: 16) {
            ForEach(ordered) { project in
                Button {
                    app.open(project)
                } label: {
                    ProjectCard(row: project)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    projectMenu(project)
                }
            }
        }
    }

    @ViewBuilder
    private func projectMenu(_ project: TitleIndex) -> some View {
        Button {
            edit(project)
        } label: {
            Label("Edit…", systemImage: "pencil")
        }
        Button {
            app.open(project, newTab: true)
        } label: {
            Label("Open in New Tab", systemImage: "plus.square.on.square")
        }
        Button {
            pin(project)
        } label: {
            Label(project.isPinned ? "Unpin" : "Pin", systemImage: project.isPinned ? "pin.slash" : "pin")
        }
        Divider()
        Button(role: .destructive) {
            pendingDelete = project
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func sortBy(_ field: ProjectSort) {
        if sort == field {
            sortAscending.toggle()
        } else {
            sort = field
            sortAscending = field == .name
        }
    }

    private func edit(_ row: TitleIndex) {
        if let project = TitleIndexStore.project(row.id, in: context) {
            app.showProjectSettings(project)
        }
    }

    private func pin(_ row: TitleIndex) {
        guard let project = TitleIndexStore.project(row.id, in: context) else { return }
        project.isPinned.toggle()
        project.touch()
        try? context.persist()
    }

    private func compare(_ lhs: TitleIndex, _ rhs: TitleIndex) -> Bool {
        switch sort {
        case .name:
            lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
        case .status:
            lhs.projectStatus.label.localizedCaseInsensitiveCompare(rhs.projectStatus.label) == .orderedAscending
        case .updated:
            lhs.updatedAt < rhs.updatedAt
        case .created:
            lhs.createdAt < rhs.createdAt
        }
    }
}

private struct ProjectsTable: View {
    var projects: [TitleIndex]
    var sort: ProjectSort
    var sortAscending: Bool
    var onSort: (ProjectSort) -> Void
    var onOpen: (TitleIndex) -> Void
    var onOpenNewTab: (TitleIndex) -> Void
    var onEdit: (TitleIndex) -> Void
    var onPin: (TitleIndex) -> Void
    var onDelete: (TitleIndex) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                header(.name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                header(.status)
                    .frame(width: 88, alignment: .leading)
                header(.updated)
                    .frame(width: 110, alignment: .trailing)
                header(.created)
                    .frame(width: 110, alignment: .trailing)
            }
            .padding(.bottom, 8)

            Hairline()

            ForEach(projects) { project in
                Button {
                    onOpen(project)
                } label: {
                    ProjectTableRow(project: project)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button {
                        onEdit(project)
                    } label: {
                        Label("Edit…", systemImage: "pencil")
                    }
                    Button {
                        onOpenNewTab(project)
                    } label: {
                        Label("Open in New Tab", systemImage: "plus.square.on.square")
                    }
                    Button {
                        onPin(project)
                    } label: {
                        Label(project.isPinned ? "Unpin" : "Pin", systemImage: project.isPinned ? "pin.slash" : "pin")
                    }
                    Divider()
                    Button(role: .destructive) {
                        onDelete(project)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func header(_ field: ProjectSort) -> some View {
        Button {
            onSort(field)
        } label: {
            HStack(spacing: 4) {
                Text(field.label)
                if sort == field {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
            }
        }
        .buttonStyle(.plain)
        .font(CraftFont.caption)
        .foregroundStyle(.secondary)
        .help("Sort by \(field.label)")
    }
}

private struct ProjectTableRow: View {
    var project: TitleIndex
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: project.symbol.isEmpty ? "folder" : project.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                Text(project.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if project.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(project.projectStatus.label)
                .font(CraftFont.caption)
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)

            Text(project.updatedAt.relativeLabel)
                .font(CraftFont.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 110, alignment: .trailing)

            Text(project.createdAt.relativeLabel)
                .font(CraftFont.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 110, alignment: .trailing)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? CraftColor.hover : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, -8)
        .onHover { hovering = $0 }
    }
}

private struct ProjectCard: View {
    var row: TitleIndex
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: row.symbol.isEmpty ? "folder" : row.symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                Spacer(minLength: 0)
                if row.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            Text(row.displayTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Text("\(row.projectStatus.label) · \(row.updatedAt.relativeLabel)")
                .font(CraftFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hovering ? CraftColor.selection : CraftColor.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(CraftColor.hairline)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering = $0 }
    }
}