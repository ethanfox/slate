import SwiftData
import SwiftUI

struct RunsView: View {
    @Environment(AppModel.self) private var app
    @Query(
        filter: #Predicate<TitleIndex> { $0.kindRaw == "run" },
        sort: \TitleIndex.updatedAt,
        order: .reverse
    )
    private var runs: [TitleIndex]

    var body: some View {
        ScrollView {
            PageBody {
                VStack(alignment: .leading, spacing: 32) {
                    if active.isEmpty {
                        emptyState
                    } else {
                        runningSection
                    }
                    if !recent.isEmpty {
                        recentSection
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
            }
        }
        .scrollContentBackground(.hidden)
        .onAppear { NavTrace.event("runs appear count=\(runs.count)") }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "play.circle")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 12)
            Text("Nothing running.")
                .font(CraftFont.title)
            Text("Runs that are still working will show up here.")
                .font(CraftFont.body)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var runningSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Running")
                .font(CraftFont.section)
                .padding(.bottom, 8)
            ForEach(active) { run in
                row(run, busy: true)
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent")
                .font(CraftFont.section)
                .padding(.bottom, 8)
            ForEach(recent) { run in
                row(run, busy: false)
            }
        }
    }

    private func row(_ run: TitleIndex, busy: Bool) -> some View {
        let label = app.runCoordinator.waitLabel(for: run.id)
        return RecordRow(
            systemImage: "play.circle",
            title: run.displayTitle,
            subtitle: run.owner,
            meta: busy ? (run.runStatus == .queued ? "Queued" : (label ?? "Starting")) : run.updatedAt.relativeLabel,
            isBusy: busy
        ) {
            app.open(run)
        }
        .contextMenu { RunTitleMenu(row: run) }
        .accessibilityHint(busy ? "Opens this running job" : "Opens this run")
    }

    private var active: [TitleIndex] {
        runs.filter(\.isBusy)
    }

    private var recent: [TitleIndex] {
        Array(runs.filter { !$0.isBusy }.prefix(10))
    }
}

struct RunTitleMenu: View {
    var row: TitleIndex
    @Environment(\.modelContext) private var context

    var body: some View {
        if let run = TitleIndexStore.run(row.id, in: context) {
            RunContextMenu(run: run)
        }
    }
}

struct RunContextMenu: View {
    var run: AgentRun
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var confirmDelete = false

    var body: some View {
        Group {
            Button {
                app.present(.editRun(run))
            } label: {
                Label("Edit…", systemImage: "pencil")
            }
            Button {
                app.open(run, newTab: true)
            } label: {
                Label("Open in New Tab", systemImage: "plus.square.on.square")
            }
            if run.status.isActive {
                Button {
                    app.cancelRun(run)
                } label: {
                    Label("Cancel", systemImage: "stop.circle")
                }
            } else {
                Button {
                    app.retryRun(run)
                } label: {
                    Label("Retry…", systemImage: "arrow.clockwise")
                }
            }
            if run.status.isTerminal {
                Divider()
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .confirmationDialog("Delete this run?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                try? RunStore.deleteTerminal(run, in: context)
            }
        } message: {
            Text("It’s removed from this Mac. Notes and tasks it created stay.")
        }
    }
}
