import SwiftData
import SwiftUI

/// Every saved source in one place: links, PDFs, and articles, whichever projects they are linked to.
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Query(sort: \SavedSource.createdAt, order: .reverse) private var sources: [SavedSource]
    @Query(sort: \Project.name) private var projects: [Project]
    @State private var query = ""
    @State private var filter = Filter.all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case unread = "Unread"
        case archived = "Archived"

        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            PageBody {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if shown.isEmpty {
                        emptyState
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(shown) { source in
                                SourceRow(source: source, projects: projects, open: { open(source) })
                            }
                        }
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
            }
        }
        .scrollContentBackground(.hidden)
        .captureBar(placeholder: "Paste a link to save it")
        .onAppear { SourceFetcher.fillPending(container: context.container) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Library")
                .font(CraftFont.title)
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("Search what you saved", text: $query)
                        .textFieldStyle(.plain)
                        .font(CraftFont.body)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(CraftColor.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(CraftColor.hairline))
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "books.vertical")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 12)
            Text(sources.isEmpty ? "Nothing saved yet." : "Nothing matches.")
                .font(CraftFont.title)
            Text(sources.isEmpty ? "Paste a link below and Membrae keeps the page for you." : "Try other words, or switch what is shown.")
                .font(CraftFont.body)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var shown: [SavedSource] {
        sources.filter { source in
            switch filter {
            case .all: if source.isArchived { return false }
            case .unread: if source.isArchived || source.readAt != nil { return false }
            case .archived: if !source.isArchived { return false }
            }
            return source.matches(query)
        }
    }

    private func open(_ source: SavedSource) {
        guard let url = URL(string: source.url) else { return }
        openURL(url)
        if source.readAt == nil {
            source.readAt = .now
            try? context.persist()
        }
    }
}

private struct SourceRow: View {
    var source: SavedSource
    var projects: [Project]
    var open: () -> Void

    @Environment(\.modelContext) private var context
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(source.readAt == nil ? Color.accentColor : .clear)
                    .frame(width: 6, height: 6)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.displayTitle)
                        .font(CraftFont.body.weight(.medium))
                        .lineLimit(1)
                    if !source.blurb.isEmpty {
                        Text(source.blurb)
                            .font(CraftFont.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text(meta)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(hovering ? CraftColor.elevated : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .accessibilityLabel("\(source.displayTitle), \(source.readAt == nil ? "unread" : "read")")
        .accessibilityHint("Opens the page")
    }

    private var meta: String {
        var parts: [String] = []
        if !source.host.isEmpty { parts.append(source.host) }
        parts.append(source.createdAt.relativeLabel)
        let linked = source.projects.map(\.name).sorted()
        if !linked.isEmpty { parts.append(linked.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var menu: some View {
        Button(source.readAt == nil ? "Mark as Read" : "Mark as Unread") {
            change { $0.readAt = $0.readAt == nil ? .now : nil }
        }
        Menu("Link to Project") {
            ForEach(projects) { project in
                let linked = source.projects.contains { $0.id == project.id }
                Button {
                    change { source in
                        if linked {
                            source.projects.removeAll { $0.id == project.id }
                        } else {
                            source.projects.append(project)
                        }
                    }
                } label: {
                    if linked {
                        Label(project.name, systemImage: "checkmark")
                    } else {
                        Text(project.name)
                    }
                }
            }
        }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(source.url, forType: .string)
        }
        Divider()
        Button(source.isArchived ? "Move Back to Library" : "Archive") {
            change { $0.isArchived.toggle() }
        }
        Button("Delete", role: .destructive) {
            context.delete(source)
            try? context.persist()
        }
    }

    private func change(_ edit: (SavedSource) -> Void) {
        edit(source)
        source.updatedAt = .now
        try? context.persist()
    }
}
