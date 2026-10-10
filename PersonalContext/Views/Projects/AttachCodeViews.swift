import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ProjectCodeSection: View {
    var project: Project
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context

    @State private var repos: [GitForgeRepo] = []
    @State private var loadingRepos = false
    @State private var repoError: String?
    @State private var pickingRepo = false

    private var attachments: [CodeAttachment] {
        project.codeAttachments.sorted(by: { $0.createdAt < $1.createdAt })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !attachments.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(attachments) { attachment in
                        attachedRow(attachment)
                    }
                }
            }

            if !attachments.isEmpty {
                Text("Index repository reads this code with the project worker and writes an architecture reference. It cannot edit the source.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button("Add folder…") { addFolder() }
                if pickingRepo {
                    Button("Cancel") { pickingRepo = false }
                } else {
                    Button("Add remote…") { showRepos() }
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .font(CraftFont.body)

            if pickingRepo {
                repoPicker
            }
        }
    }

    @ViewBuilder
    private var repoPicker: some View {
        if loadingRepos {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading repos")
                    .foregroundStyle(.secondary)
            }
            .font(CraftFont.body)
            .padding(.vertical, 8)
        } else if let repoError {
            Text(repoError)
                .font(CraftFont.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else if repos.isEmpty {
            Text("No remotes on the connected accounts.")
                .font(CraftFont.body)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(repoGroups.enumerated()), id: \.element.id) { index, group in
                        if repoGroups.count > 1 {
                            Text(group.title)
                                .font(CraftFont.section)
                                .foregroundStyle(.secondary)
                                .padding(.top, index == 0 ? 4 : 16)
                                .padding(.bottom, 4)
                        }
                        ForEach(group.repos) { repo in
                            repoRow(repo)
                        }
                    }
                }
            }
            .frame(maxHeight: 280)
            .scrollIndicators(.hidden)
        }
    }

    private func attachedRow(_ attachment: CodeAttachment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            attachmentIcon(attachment.kind)
                .frame(width: 22, height: 17)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.title.isEmpty ? attachment.locator : attachment.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(attachedSubtitle(attachment))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(referenceLine(attachment))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if let run = CodeReferenceStore.activeIndexingRun(for: attachment, in: context) {
                Button("Indexing…") { app.open(run) }
                    .buttonStyle(.plain)
                    .font(CraftFont.body)
                    .foregroundStyle(.secondary)
            } else {
                Button(CodeReferenceStore.published(on: attachment, in: context) == nil ? "Index repository" : "Re-index") {
                    app.startIndexing(attachment: attachment)
                }
                .buttonStyle(.plain)
                .font(CraftFont.body)
                .foregroundStyle(.secondary)
            }
            if CodeReferenceStore.published(on: attachment, in: context) != nil {
                Button("View") { app.present(.inspectCodeReference(attachment.id)) }
                    .buttonStyle(.plain)
                    .font(CraftFont.body)
                    .foregroundStyle(.secondary)
            }
            Button("Open") {
                open(attachment)
            }
            .buttonStyle(.plain)
            .font(CraftFont.body)
            .foregroundStyle(.secondary)
            Button("Remove") {
                CodeReferenceStore.deleteOwnedReferences(for: attachment, in: context)
                context.delete(attachment)
                project.touch()
                try? context.save()
            }
            .buttonStyle(.plain)
            .font(CraftFont.body)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private func repoRow(_ repo: GitForgeRepo) -> some View {
        CodeRepoRow(
            title: repo.name,
            subtitle: repoSubtitle(repo),
            mark: repo.provider.mark
        ) {
            attach(repo)
        }
    }

    private func repoSubtitle(_ repo: GitForgeRepo) -> String {
        if repoGroups.count > 1 {
            return repo.owner
        }
        if repo.tokenName.isEmpty {
            return repo.owner
        }
        return "\(repo.owner) · \(repo.tokenName)"
    }

    private func referenceLine(_ attachment: CodeAttachment) -> String {
        if let run = CodeReferenceStore.activeIndexingRun(for: attachment, in: context) {
            return "Indexing · \(run.status.label)"
        }
        if let published = CodeReferenceStore.published(on: attachment, in: context) {
            return CodeReferenceStore.coverageLabel(published)
        }
        return "No architecture reference"
    }

    private func attachedSubtitle(_ attachment: CodeAttachment) -> String {
        var parts: [String] = []
        switch attachment.kind {
        case .folder:
            parts.append(attachment.locator)
        case .github, .gitlab:
            parts.append(attachment.kind.title)
            parts.append(attachment.locator)
            if !attachment.defaultBranch.isEmpty { parts.append(attachment.defaultBranch) }
            parts.append(connectionLabel(for: attachment))
        }
        return parts.joined(separator: " · ")
    }

    private func connectionLabel(for attachment: CodeAttachment) -> String {
        guard let id = UUID(uuidString: attachment.tokenID) else { return "Credential missing" }
        switch app.sources.tokenStatus[id] {
        case .ready: return "Connected"
        case .checking: return "Checking"
        case .failed: return "Connection failed"
        case .none: return "Credential missing"
        }
    }

    private func open(_ attachment: CodeAttachment) {
        let url: URL?
        switch attachment.kind {
        case .folder:
            url = URL(fileURLWithPath: attachment.locator)
        case .github:
            url = URL(string: GitHubRemote.url(forLocator: attachment.locator))
        case .gitlab:
            url = URL(string: "https://gitlab.com/\(attachment.locator)")
        }
        if let url { NSWorkspace.shared.open(url) }
    }

    private func attachmentIcon(_ kind: CodeAttachmentKind) -> some View {
        Group {
            if let mark = kind.mark {
                BrandMarkImage(mark: mark, size: 16)
            } else {
                Image(systemName: "folder")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var repoGroups: [RepoGroup] {
        var order: [UUID] = []
        var titles: [UUID: String] = [:]
        var buckets: [UUID: [GitForgeRepo]] = [:]
        for repo in repos {
            if buckets[repo.tokenID] == nil {
                order.append(repo.tokenID)
                titles[repo.tokenID] = repo.provider.title
            }
            if !(buckets[repo.tokenID] ?? []).contains(where: { $0.remoteURL == repo.remoteURL }) {
                buckets[repo.tokenID, default: []].append(repo)
            }
        }
        return order.map { id in
            RepoGroup(
                id: id,
                title: titles[id] ?? "",
                repos: (buckets[id] ?? []).sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            )
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Attach"
        panel.message = "Membrae can read this folder later. It cannot edit files from this."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let attachment = CodeAttachment(
            kind: .folder,
            title: url.lastPathComponent,
            locator: url.path,
            bookmark: bookmark,
            project: project
        )
        context.insert(attachment)
        project.touch()
        try? context.save()
    }

    private func showRepos() {
        guard app.sources.hasGitHub || app.sources.hasGitLab else {
            app.flash("Connect GitHub or GitLab in Settings → Sources first.")
            return
        }
        pickingRepo = true
        loadingRepos = true
        repoError = nil
        Task {
            var next: [GitForgeRepo] = []
            var errors: [String] = []
            for token in app.sources.githubTokens {
                guard let secret = app.sources.secret(for: token.id) else { continue }
                do {
                    next.append(contentsOf: try await GitForgeClient.githubRepos(token: secret).map { $0.tagged(token: token) })
                } catch {
                    errors.append("\(token.name): \(error.localizedDescription)")
                }
            }
            for token in app.sources.gitlabTokens {
                guard let secret = app.sources.secret(for: token.id) else { continue }
                do {
                    next.append(contentsOf: try await GitForgeClient.gitlabRepos(token: secret).map { $0.tagged(token: token) })
                } catch {
                    errors.append("\(token.name): \(error.localizedDescription)")
                }
            }
            repos = next
            if next.isEmpty, !errors.isEmpty {
                repoError = errors.joined(separator: " ")
            }
            loadingRepos = false
        }
    }

    private func attach(_ repo: GitForgeRepo) {
        if project.codeAttachments.contains(where: { $0.kind == repo.provider && $0.locator == repo.title && $0.tokenID == repo.tokenID.uuidString }) {
            pickingRepo = false
            return
        }
        let attachment = CodeAttachment(
            kind: repo.provider,
            title: repo.name,
            locator: repo.title,
            defaultBranch: repo.defaultBranch,
            tokenID: repo.tokenID.uuidString,
            project: project
        )
        context.insert(attachment)
        project.touch()
        try? context.save()
        pickingRepo = false
    }
}

private struct RepoGroup: Identifiable {
    var id: UUID
    var title: String
    var repos: [GitForgeRepo]
}

private struct CodeRepoRow: View {
    var title: String
    var subtitle: String
    var mark: BrandMark?
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Group {
                    if let mark {
                        BrandMarkImage(mark: mark, size: 16)
                    } else {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 22, height: 17)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? CraftColor.hover : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -8)
        .onHover { hovering = $0 }
    }
}
