import SwiftData
import SwiftUI

/// The pane beside the Tracks view: the stop or the signal the user picked.
struct TrackLaneInspector: View {
    var space: Space

    @Environment(AppModel.self) private var app
    @Query private var stops: [TrackStop]
    @Query private var junctions: [TrackJunction]

    var body: some View {
        Group {
            if let id = app.selectedStopID, let stop = stops.first(where: { $0.id == id }) {
                StopDocument(stop: stop, space: space)
                    .id(id)
            } else if let id = app.selectedJunctionID, let junction = junctions.first(where: { $0.id == id }) {
                JunctionDocument(junction: junction, space: space)
                    .id(id)
            } else {
                Text("Select a stop or a signal.")
                    .font(CraftFont.body)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onExitCommand {
            app.selectStop(nil)
            app.selectJunction(nil)
        }
        .onChange(of: app.selectedStopID) { _, id in
            guard let id, !stops.contains(where: { $0.id == id }) else { return }
            app.selectedStopID = nil
        }
        .onChange(of: app.selectedJunctionID) { _, id in
            guard let id, !junctions.contains(where: { $0.id == id }) else { return }
            app.selectedJunctionID = nil
        }
    }
}

private struct StopDocument: View {
    @Bindable var stop: TrackStop
    var space: Space

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context

    private var track: ProjectThread? { stop.thread }

    private var ordered: [TrackStop] { track?.orderedStops ?? [] }

    private var index: Int? { ordered.firstIndex { $0.id == stop.id } }

    private var tasks: [AgendaItem] {
        stop.tasks.filter { $0.kind == .task }.sorted { $0.createdAt < $1.createdAt }
    }

    private var decisions: [Decision] {
        (track?.decisions ?? [])
            .filter { $0.status == .active }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(3)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Hairline().padding(.vertical, 14)
                    taskList
                    if !decisions.isEmpty {
                        Hairline().padding(.vertical, 14)
                        decided
                    }
                    Hairline().padding(.vertical, 14)
                    next
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
            actions
                .padding(18)
        }
        .onChange(of: stop.title) { _, _ in touch() }
        .onChange(of: stop.body) { _, _ in touch() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let track {
                    Circle().fill(track.color.tint).frame(width: 8, height: 8)
                    Text(LaneModel.title(track))
                        .lineLimit(1)
                }
                if let index {
                    Text("· stop \(index + 1) of \(ordered.count)")
                        .fixedSize()
                }
                Spacer(minLength: 8)
                Button {
                    StopStore.setDone(!stop.isDone, on: stop, in: context)
                } label: {
                    HStack(spacing: 5) {
                        TaskGlyph(state: stop.isDone ? .done : .open, size: 12)
                        Text(stop.isDone ? "Done" : "Mark Done")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(stop.isDone ? Color.secondary : Color.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(stop.isDone ? "Mark this stop not done" : "Mark this stop done")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            TextField("Stop", text: $stop.title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1...2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
                .help(stop.displayTitle)

            TextField("What this stop is", text: $stop.body, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...10)
                .padding(.top, 2)
        }
    }

    private var taskList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tasks")
                .font(CraftFont.section)
            if tasks.isEmpty {
                Text("No tasks on this stop.")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
            ForEach(tasks) { task in
                Button {
                    app.present(.editTask(task))
                } label: {
                    HStack(spacing: 10) {
                        TaskGlyph(state: TaskGlyph.state(of: task))
                        Text(task.displayTitle)
                            .font(.system(size: 13))
                            .foregroundStyle(task.isCompleted ? Color.secondary : Color.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(height: 30)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var decided: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Decided on this track")
                .font(CraftFont.section)
            ForEach(decisions) { decision in
                Button {
                    app.open(decision, newTab: false)
                } label: {
                    Text(decision.title.isEmpty ? "Untitled" : decision.title)
                        .font(.system(size: 13))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var next: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Next")
                .font(CraftFont.section)
            if let index, index + 1 < ordered.count {
                Button {
                    app.selectStop(ordered[index + 1].id)
                } label: {
                    Text(ordered[index + 1].displayTitle)
                        .font(.system(size: 13))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Text("Last stop on this track.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            ForEach(stop.heldBy) { junction in
                let met = junction.orderedRequirements.filter(\.isMet).count
                Button {
                    app.selectJunction(junction.id)
                } label: {
                    Text("\(junction.second.map(LaneModel.title) ?? "A track") waits here · \(met) of \(junction.requirements.count)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                app.presentNewRun(origin: .project, project: space, brief: brief)
            } label: {
                Text("Hand to an Agent")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Color.accentColor, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            if let track {
                Button {
                    app.open(track, newTab: false)
                } label: {
                    Text("Open Track")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(CraftColor.elevated, in: Capsule())
                        .overlay(Capsule().strokeBorder(CraftColor.hairline))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var brief: String {
        var lines = ["Work on the stop \"\(stop.displayTitle)\" of the track \"\(track.map(LaneModel.title) ?? "Untitled")\" in \(space.name)."]
        let body = stop.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { lines.append(body) }
        return lines.joined(separator: "\n\n")
    }

    private func touch() {
        stop.updatedAt = .now
        track?.updatedAt = .now
        track?.project?.touch()
    }
}

private struct JunctionDocument: View {
    var junction: TrackJunction
    var space: Space

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context

    private var first: String { junction.first.map(LaneModel.title) ?? "Another track" }
    private var second: String { junction.second.map(LaneModel.title) ?? "A track" }
    private var requirements: [JunctionRequirement] { junction.orderedRequirements }
    private var met: Int { requirements.filter(\.isMet).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        if let track = junction.second {
                            Circle().fill(track.color.tint).frame(width: 8, height: 8)
                        }
                        if let track = junction.first {
                            Circle().fill(track.color.tint).frame(width: 8, height: 8)
                        }
                        Text(junction.kind == .wait ? "Signal" : "Merge")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                    Text(headline)
                        .font(.system(size: 17, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)

                    Text(sentence)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)

                    Hairline().padding(.vertical, 14)

                    Text(requirements.isEmpty ? "Requirements" : "Requirements · \(met) of \(requirements.count) met")
                        .font(CraftFont.section)
                        .padding(.bottom, 4)
                    if requirements.isEmpty {
                        Text(junction.kind == .wait ? "Met when \(first) is completed." : "Nothing listed to reconcile yet.")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(requirements) { requirement in
                        requirementRow(requirement)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)

            HStack(spacing: 8) {
                if let track = junction.second { openButton(track) }
                if let track = junction.first { openButton(track) }
            }
            .padding(18)
        }
    }

    private func requirementRow(_ requirement: JunctionRequirement) -> some View {
        let backed = requirement.stop != nil || requirement.task != nil
        return HStack(alignment: .top, spacing: 10) {
            Button {
                guard !backed else { return }
                JunctionStore.setChecked(!requirement.isChecked, on: requirement, in: context)
            } label: {
                TaskGlyph(state: requirement.isMet ? .done : .open)
                    .padding(.top, 1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(backed)
            .help(backed ? "Met by the stop or task it points at" : (requirement.isMet ? "Mark not met" : "Mark met"))
            VStack(alignment: .leading, spacing: 2) {
                Text(requirement.displayText)
                    .font(.system(size: 13))
                    .foregroundStyle(requirement.isMet ? Color.secondary : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let stop = requirement.stop {
                    Button {
                        app.selectStop(stop.id)
                    } label: {
                        Text("Stop · \(stop.displayTitle)")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else if let task = requirement.task {
                    Button {
                        app.present(.editTask(task))
                    } label: {
                        Text("Task · \(task.displayTitle)")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 5)
    }

    private func openButton(_ track: ProjectThread) -> some View {
        Button {
            app.open(track, newTab: false)
        } label: {
            Text(LaneModel.title(track))
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(CraftColor.elevated, in: Capsule())
                .overlay(Capsule().strokeBorder(CraftColor.hairline))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Open \(LaneModel.title(track))")
    }

    private var headline: String {
        switch junction.kind {
        case .wait: "\(second) waits on \(first)"
        case .merge: "\(second) merges into \(first)"
        }
    }

    private var sentence: String {
        switch junction.kind {
        case .wait:
            if let held = junction.heldStop {
                return "Held at \(held.displayTitle) until \(first) has done what is listed."
            }
            return "The whole track is held until \(first) has done what is listed."
        case .merge:
            return "Reconcile what is listed, then the two become one track."
        }
    }
}
