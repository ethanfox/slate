import AppKit
import SwiftData
import SwiftUI

extension TrackColor {
    /// The colour as drawn, following the appearance.
    var tint: Color {
        let pair = hex
        return Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(trackHex: dark ? pair.dark : pair.light)
        })
    }
}

private extension NSColor {
    convenience init(trackHex hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// How a lane is laid out: a header column, then the line with a stop every hundred points.
enum LaneMetrics {
    static let headerWidth: CGFloat = 176
    static let firstStop: CGFloat = 36
    static let spacing: CGFloat = 100
    static let height: CGFloat = 150
    static let compactHeight: CGFloat = 116
    static let dot: CGFloat = 13
    static let currentDot: CGFloat = 16
    static let line: CGFloat = 3
    static let labelWidth: CGFloat = 96
    static let lineStart: CGFloat = 8
    static let trailing: CGFloat = 24
    /// How far past the last stop two lanes run before they bend into a merge.
    static let mergeLead: CGFloat = 55
    static let mergeRun: CGFloat = 85

    static func stopX(_ index: Int) -> CGFloat { firstStop + CGFloat(index) * spacing }
}

/// One lane, worked out once from its track.
struct LaneModel: Identifiable {
    var track: ProjectThread
    var stops: [TrackStop]
    /// The first stop not yet done, on a track still going.
    var currentIndex: Int?
    /// The Space's active track: a spinner on its current stop and a gap in the line around it.
    var isActive: Bool
    /// A signal above this stop; the line is dotted past it.
    var wait: (junction: TrackJunction, index: Int)?
    /// The merge this lane is part of.
    var merge: TrackJunction?
    /// Set when the lane drawn right after this one is the other side of `merge`.
    var mergesIntoNext = false
    var caption: String

    var id: UUID { track.id }

    init(track: ProjectThread, space: Space) {
        let stops = track.orderedStops
        let current = stops.firstIndex { !$0.isDone }
        let isActive = space.activeTrackID == track.id && track.status != .completed
        let junctions = track.junctions
        let waiting = junctions.first { $0.kind == .wait && $0.second?.id == track.id && !$0.isMet }
        let merge = junctions.first { $0.kind == .merge }

        self.track = track
        self.stops = stops
        self.currentIndex = track.status == .completed ? nil : current
        self.isActive = isActive
        if let waiting, !stops.isEmpty {
            let held = waiting.heldStop.flatMap { stop in stops.firstIndex { $0.id == stop.id } }
            self.wait = (waiting, held ?? current ?? stops.count - 1)
        } else {
            self.wait = nil
        }
        self.merge = merge
        self.caption = LaneModel.caption(for: track, isActive: isActive, current: current, stopCount: stops.count, waiting: waiting, merge: merge)
    }

    /// Where the last stop sits, from the line area's left edge.
    var lastStopX: CGFloat {
        LaneMetrics.stopX(max(stops.count - 1, 0))
    }

    static func title(_ track: ProjectThread) -> String {
        track.title.isEmpty ? "Untitled" : track.title
    }

    private static func caption(
        for track: ProjectThread,
        isActive: Bool,
        current: Int?,
        stopCount: Int,
        waiting: TrackJunction?,
        merge: TrackJunction?
    ) -> String {
        if let merge, !merge.isMet, let other = merge.other(than: track) {
            return "Merging with \(title(other))"
        }
        if let waiting, let first = waiting.first {
            return "Waiting on \(title(first))"
        }
        let day: (Date) -> String = { $0.formatted(date: .abbreviated, time: .omitted) }
        if let arrived = track.arrivedAt {
            return "Arrived \(day(arrived))"
        }
        var parts = [isActive ? "Active" : track.status.label]
        if let current, stopCount > 0 {
            parts.append("stop \(current + 1) of \(stopCount)")
        }
        if let ends = track.fareEndsAt {
            let left = Calendar.current.dateComponents([.day], from: .now, to: ends).day ?? 0
            parts.append(left < 0 ? "fare ran out" : "\(left) day\(left == 1 ? "" : "s") left")
        }
        return parts.joined(separator: " · ")
    }
}

/// Which tracks a Space's Tracks view draws, and in what order.
enum LaneSet {
    /// Tracks that can be drawn: top-level and not rejected. Active first, then exploring, paused, completed.
    static func candidates(in space: Space) -> [ProjectThread] {
        let rank: [ThreadStatus: Int] = [.active: 0, .exploring: 1, .paused: 2, .completed: 3, .rejected: 4]
        return space.threads
            .filter { $0.parent == nil && $0.status != .rejected }
            .sorted { lhs, rhs in
                let left = rank[lhs.status] ?? 9
                let right = rank[rhs.status] ?? 9
                if left != right { return left < right }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    /// Membrae's pick: the active track, the tracks joined to it, then other active tracks, up to six.
    static func defaultShown(in space: Space, from candidates: [ProjectThread]) -> [UUID] {
        var ids: [UUID] = []
        if let active = space.activeTrack {
            ids.append(active.id)
            for junction in active.junctions {
                if let other = junction.other(than: active) { ids.append(other.id) }
            }
        }
        for track in candidates where track.status == .active {
            ids.append(track.id)
        }
        var seen = Set<UUID>()
        let unique = ids.filter { id in seen.insert(id).inserted && candidates.contains { $0.id == id } }
        return Array(unique.prefix(6))
    }

    static func shownIDs(in space: Space, chosen: [UUID]?) -> [UUID] {
        let candidates = candidates(in: space)
        if let chosen {
            return chosen.filter { id in candidates.contains { $0.id == id } }
        }
        return defaultShown(in: space, from: candidates)
    }

    /// The lanes to draw, in candidate order, with each merge's folded-in side right after the side it continues as.
    static func lanes(in space: Space, chosen: [UUID]?) -> [LaneModel] {
        let candidates = candidates(in: space)
        let shown = Set(shownIDs(in: space, chosen: chosen))
        var tracks = candidates.filter { shown.contains($0.id) }
        for track in candidates where shown.contains(track.id) {
            for junction in track.junctions where junction.kind == .merge {
                guard let first = junction.first, let second = junction.second, first.id == track.id,
                      let from = tracks.firstIndex(where: { $0.id == second.id }) else { continue }
                let moved = tracks.remove(at: from)
                guard let to = tracks.firstIndex(where: { $0.id == first.id }) else {
                    tracks.insert(moved, at: from)
                    continue
                }
                tracks.insert(moved, at: to + 1)
            }
        }
        var lanes = tracks.map { LaneModel(track: $0, space: space) }
        for index in lanes.indices.dropLast() {
            if let merge = lanes[index].merge, merge.other(than: lanes[index].track)?.id == lanes[index + 1].track.id {
                lanes[index].mergesIntoNext = true
            }
        }
        return lanes
    }
}

/// How wide a lane's line area has to be to show every stop and label.
extension LaneModel {
    var neededWidth: CGFloat {
        guard !stops.isEmpty else { return LaneMetrics.firstStop + 120 }
        return lastStopX + LaneMetrics.labelWidth / 2 + LaneMetrics.trailing
    }
}

/// The left column of a lane: the track's name and a line on where it stands.
struct LaneHeader: View {
    var lane: LaneModel
    var compact = false
    var onTitle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: onTitle) {
                Text(LaneModel.title(lane.track))
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.2)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(lane.caption)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.trailing, 12)
        .frame(width: LaneMetrics.headerWidth, height: compact ? LaneMetrics.compactHeight : LaneMetrics.height, alignment: .leading)
    }
}

/// The line of a lane with its stops, labels, and signal. Sized by its parent; draws to its own width.
struct LaneLine: View {
    var lane: LaneModel
    var compact = false
    /// Where the line stops, from the left edge. Nil runs it to the edge.
    var lineEnd: CGFloat? = nil
    var selectedStop: UUID?
    var onStop: (TrackStop) -> Void
    var onJunction: (TrackJunction) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveringSignal = false
    @State private var hoveringCard = false

    private var tint: Color { lane.track.color.tint }
    private var showingCard: Bool { hoveringSignal || hoveringCard }

    var body: some View {
        GeometryReader { geo in
            let midY = geo.size.height / 2
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    drawLine(in: context, width: size.width, midY: midY)
                }
                ForEach(Array(lane.stops.enumerated()), id: \.element.id) { index, stop in
                    let isCurrent = lane.currentIndex == index
                    StopDot(
                        stop: stop,
                        tint: tint,
                        spins: lane.isActive && isCurrent,
                        isSelected: selectedStop == stop.id,
                        reduceMotion: reduceMotion
                    ) {
                        onStop(stop)
                    }
                    .position(x: LaneMetrics.stopX(index), y: midY)
                    Text(stop.displayTitle)
                        .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? tint : Color.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(width: LaneMetrics.labelWidth)
                        .fixedSize(horizontal: false, vertical: true)
                        .position(x: LaneMetrics.stopX(index), y: midY + 28)
                }
                if lane.stops.isEmpty {
                    Text("No stops yet")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .position(x: LaneMetrics.firstStop + 24, y: midY + 20)
                }
                if let wait = lane.wait {
                    let x = LaneMetrics.stopX(wait.index)
                    LaneSignal()
                        .position(x: x, y: midY - 18)
                        .onHover { hoveringSignal = $0 }
                        .onTapGesture { onJunction(wait.junction) }
                        .help("Waiting: click for what is holding it")
                    if showingCard {
                        JunctionCard(junction: wait.junction)
                            .onHover { hoveringCard = $0 }
                            .onTapGesture { onJunction(wait.junction) }
                            .position(x: x, y: midY + 100)
                            .transition(.opacity)
                    }
                }
            }
            .animation(Motion.quick, value: showingCard)
        }
        .frame(height: compact ? LaneMetrics.compactHeight : LaneMetrics.height)
        .zIndex(showingCard ? 2 : 0)
    }

    private func drawLine(in context: GraphicsContext, width: CGFloat, midY: CGFloat) {
        let start = LaneMetrics.lineStart
        let end = lineEnd ?? (width - LaneMetrics.trailing)
        guard end > start else { return }
        var solidEnd = end
        var dotted: ClosedRange<CGFloat>?
        if let wait = lane.wait {
            let x = LaneMetrics.stopX(wait.index)
            solidEnd = min(end, x)
            if x + 16 < end { dotted = (x + 16)...end }
        }
        var segments: [ClosedRange<CGFloat>] = solidEnd > start ? [start...solidEnd] : []
        if lane.isActive, let current = lane.currentIndex {
            let x = LaneMetrics.stopX(current)
            let gap: CGFloat = 14
            segments = segments.flatMap { range -> [ClosedRange<CGFloat>] in
                guard range.contains(x) else { return [range] }
                var out: [ClosedRange<CGFloat>] = []
                if x - gap > range.lowerBound { out.append(range.lowerBound...(x - gap)) }
                if x + gap < range.upperBound { out.append((x + gap)...range.upperBound) }
                return out
            }
        }
        let style = StrokeStyle(lineWidth: LaneMetrics.line, lineCap: .round)
        for segment in segments where segment.upperBound > segment.lowerBound {
            var path = Path()
            path.move(to: CGPoint(x: segment.lowerBound, y: midY))
            path.addLine(to: CGPoint(x: segment.upperBound, y: midY))
            context.stroke(path, with: .color(tint), style: style)
        }
        if let dotted {
            var path = Path()
            path.move(to: CGPoint(x: dotted.lowerBound, y: midY))
            path.addLine(to: CGPoint(x: dotted.upperBound, y: midY))
            context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: LaneMetrics.line, lineCap: .round, dash: [0.1, 8]))
        }
    }
}

/// One track as a lane on its own: the header pinned, the line scrolling sideways when it is longer than the page.
struct TrackLaneRow: View {
    var lane: LaneModel
    var compact = false
    var selectedStop: UUID?
    var onStop: (TrackStop) -> Void
    var onJunction: (TrackJunction) -> Void
    var onTitle: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            LaneHeader(lane: lane, compact: compact, onTitle: onTitle)
            GeometryReader { geo in
                ScrollView(.horizontal, showsIndicators: false) {
                    LaneLine(lane: lane, compact: compact, selectedStop: selectedStop, onStop: onStop, onJunction: onJunction)
                        .frame(width: max(geo.size.width, lane.neededWidth))
                }
            }
        }
        .frame(height: compact ? LaneMetrics.compactHeight : LaneMetrics.height)
    }
}

/// A stop on the line: solid in the track's colour, a check once done, a spinner while it is the one in hand.
private struct StopDot: View {
    var stop: TrackStop
    var tint: Color
    var spins: Bool
    var isSelected: Bool
    var reduceMotion: Bool
    var action: () -> Void

    @State private var turning = false

    var body: some View {
        let size = spins ? LaneMetrics.currentDot : LaneMetrics.dot
        Button(action: action) {
            ZStack {
                if isSelected {
                    Circle()
                        .stroke(tint.opacity(0.3), lineWidth: 3)
                        .frame(width: size + 10, height: size + 10)
                }
                Circle()
                    .fill(tint)
                    .frame(width: size, height: size)
                if stop.isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                } else if spins {
                    Circle()
                        .trim(from: 0, to: 0.75)
                        .stroke(.white, style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
                        .frame(width: 8, height: 8)
                        .rotationEffect(.degrees(turning ? 360 : 0))
                        .onAppear {
                            guard !reduceMotion else { return }
                            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
                                turning = true
                            }
                        }
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(stop.displayTitle)
    }
}

/// A red signal on a post above a stop: the track waits here.
private struct LaneSignal: View {
    var body: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(Color(red: 0.816, green: 0.271, blue: 0.247))
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(CraftColor.canvas, lineWidth: 1.5))
            Rectangle()
                .fill(Color.primary.opacity(0.85))
                .frame(width: 2.5, height: 15)
        }
        .frame(width: 22, height: 28)
        .contentShape(Rectangle())
    }
}

/// What a junction is waiting for, shown on hover.
struct JunctionCard: View {
    var junction: TrackJunction

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headline)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2)
            ForEach(junction.orderedRequirements) { requirement in
                HStack(alignment: .top, spacing: 8) {
                    TaskGlyph(state: requirement.isMet ? .done : .open, size: 12)
                        .padding(.top, 2)
                    Text(requirement.displayText)
                        .font(.system(size: 12))
                        .foregroundStyle(requirement.isMet ? Color.secondary : Color.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if junction.requirements.isEmpty {
                Text(emptyLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Click for details")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 214, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(CraftColor.elevated)
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        )
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(CraftColor.hairline))
    }

    private var headline: String {
        switch junction.kind {
        case .wait:
            "Waiting on \(junction.first.map(LaneModel.title) ?? "another track")"
        case .merge:
            "Merging \(junction.second.map(LaneModel.title) ?? "a track") into \(junction.first.map(LaneModel.title) ?? "another")"
        }
    }

    private var emptyLine: String {
        switch junction.kind {
        case .wait: "Met when \(junction.first.map(LaneModel.title) ?? "the other track") is completed."
        case .merge: "Nothing listed to reconcile."
        }
    }
}

/// Done, in progress, or open, drawn the way the task board draws it.
struct TaskGlyph: View {
    enum State { case done, inProgress, open }

    var state: State
    var size: CGFloat = 14

    var body: some View {
        ZStack {
            switch state {
            case .done:
                Circle().fill(Color.primary)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(CraftColor.canvas)
            case .inProgress:
                Circle().stroke(Color.primary, lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: 0.5)
                    .fill(Color.primary)
                    .rotationEffect(.degrees(-90))
                    .padding(2.5)
            case .open:
                Circle().stroke(Color.primary, lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
    }

    static func state(of task: AgendaItem) -> State {
        if task.isCompleted { return .done }
        return task.workflowStatus == .inProgress ? .inProgress : .open
    }
}

/// The Space's Tracks view: the chosen tracks as lanes, one above the other, merges bending into each other.
struct TrackLanesPage: View {
    var space: Space

    @Environment(AppModel.self) private var app

    var body: some View {
        let lanes = LaneSet.lanes(in: space, chosen: app.shownTracks[space.id])
        ScrollView {
            PageBody {
                VStack(alignment: .leading, spacing: 0) {
                    if lanes.isEmpty {
                        EmptyLine(
                            text: space.threads.isEmpty
                                ? "No tracks yet. Ask Membrae to start one."
                                : "No tracks shown. Pick some from the toolbar."
                        )
                        .padding(.horizontal, 24)
                        .padding(.top, 32)
                    } else {
                        LaneStack(lanes: lanes, space: space)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 140)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .scrollContentBackground(.hidden)
        .captureBar(project: space, placeholder: "Tell Membrae anything about \(space.name)")
        .onExitCommand {
            app.selectStop(nil)
            app.selectJunction(nil)
        }
        .onAppear { NavTrace.event("tracks.lanes appear count=\(lanes.count)") }
    }
}

/// The lanes stacked: headers pinned on the left, the lines scrolling sideways together, merges drawn across
/// the two lanes they join.
private struct LaneStack: View {
    var lanes: [LaneModel]
    var space: Space

    @Environment(AppModel.self) private var app
    @State private var hoveringMerge: UUID?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lanes.enumerated()), id: \.element.id) { index, lane in
                    LaneHeader(lane: lane) { app.open(lane.track, newTab: false) }
                        .overlay(alignment: .bottom) { separator(after: index) }
                }
            }
            GeometryReader { geo in
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lanes.enumerated()), id: \.element.id) { index, lane in
                            LaneLine(
                                lane: lane,
                                lineEnd: lineEnd(at: index),
                                selectedStop: app.selectedStopID,
                                onStop: { app.selectStop($0.id) },
                                onJunction: { app.selectJunction($0.id) }
                            )
                            .overlay(alignment: .bottom) { separator(after: index) }
                        }
                    }
                    .frame(width: max(geo.size.width, neededWidth))
                    .overlay(alignment: .topLeading) { merges }
                }
            }
        }
    }

    @ViewBuilder
    private func separator(after index: Int) -> some View {
        if index < lanes.count - 1, !lanes[index].mergesIntoNext {
            Hairline()
        }
    }

    private var merges: some View {
        GeometryReader { geo in
            Canvas { context, _ in
                drawMerges(in: context, width: geo.size.width)
            }
            .allowsHitTesting(false)
            ForEach(Array(lanes.enumerated()), id: \.element.id) { index, lane in
                if lane.mergesIntoNext, let merge = lane.merge {
                    let point = mergePoint(at: index)
                    mergeNode(merge, tint: continuingTint(at: index))
                        .position(point)
                    if hoveringMerge == merge.id {
                        JunctionCard(junction: merge)
                            .onHover { hoveringMerge = $0 ? merge.id : nil }
                            .onTapGesture { app.selectJunction(merge.id) }
                            .position(x: point.x, y: point.y + 72)
                    }
                }
            }
        }
    }

    /// Wide enough for the longest lane, and for any merge to bend and run on.
    private var neededWidth: CGFloat {
        var width = lanes.map(\.neededWidth).max() ?? 0
        for index in lanes.indices where lanes[index].mergesIntoNext {
            width = max(width, mergeStart(for: index) + LaneMetrics.mergeRun + 140)
        }
        return width
    }

    private func mergeNode(_ merge: TrackJunction, tint: Color) -> some View {
        let met = merge.orderedRequirements.filter(\.isMet).count
        let total = merge.requirements.count
        let selected = app.selectedJunctionID == merge.id
        return VStack(spacing: 6) {
            Text(total == 0 ? "Merge" : "\(met) of \(total) reconciled")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize()
            Button {
                app.selectJunction(merge.id)
            } label: {
                ZStack {
                    if selected {
                        Circle().stroke(tint.opacity(0.3), lineWidth: 3).frame(width: 26, height: 26)
                    }
                    Circle().fill(tint).frame(width: 16, height: 16)
                    Circle().stroke(.white, lineWidth: 1.7).frame(width: 8, height: 8)
                }
                .frame(width: 28, height: 28)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringMerge = $0 ? merge.id : nil }
        }
        .offset(y: -12)
    }

    /// Where the lane at `index` stops drawing its own line, when it bends into a merge.
    private func lineEnd(at index: Int) -> CGFloat? {
        if lanes[index].mergesIntoNext {
            return mergeStart(for: index)
        }
        if index > 0, lanes[index - 1].mergesIntoNext {
            return mergeStart(for: index - 1)
        }
        return nil
    }

    /// Past the later of the two lanes' last stops.
    private func mergeStart(for index: Int) -> CGFloat {
        max(lanes[index].lastStopX, lanes[index + 1].lastStopX) + LaneMetrics.mergeLead
    }

    private func laneMidY(_ index: Int) -> CGFloat {
        CGFloat(index) * LaneMetrics.height + LaneMetrics.height / 2
    }

    private func mergePoint(at index: Int) -> CGPoint {
        CGPoint(
            x: mergeStart(for: index) + LaneMetrics.mergeRun,
            y: (laneMidY(index) + laneMidY(index + 1)) / 2
        )
    }

    /// The colour the merged line continues in: the track the merge continues as.
    private func continuingTint(at index: Int) -> Color {
        let lane = lanes[index]
        if let merge = lane.merge, merge.first?.id == lanes[index + 1].track.id {
            return lanes[index + 1].track.color.tint
        }
        return lane.track.color.tint
    }

    private func drawMerges(in context: GraphicsContext, width: CGFloat) {
        let style = StrokeStyle(lineWidth: LaneMetrics.line, lineCap: .round, lineJoin: .round)
        for index in lanes.indices where lanes[index].mergesIntoNext {
            let startX = mergeStart(for: index)
            let point = mergePoint(at: index)
            for (lane, y) in [(lanes[index], laneMidY(index)), (lanes[index + 1], laneMidY(index + 1))] {
                var path = Path()
                path.move(to: CGPoint(x: startX, y: y))
                path.addCurve(
                    to: point,
                    control1: CGPoint(x: startX + LaneMetrics.mergeRun * 0.55, y: y),
                    control2: CGPoint(x: point.x - LaneMetrics.mergeRun * 0.45, y: point.y)
                )
                context.stroke(path, with: .color(lane.track.color.tint), style: style)
            }
            let end = width - LaneMetrics.trailing
            if end > point.x {
                var path = Path()
                path.move(to: point)
                path.addLine(to: CGPoint(x: end, y: point.y))
                context.stroke(path, with: .color(continuingTint(at: index)), style: style)
            }
        }
    }
}

/// The active track drawn on the Space's page. Click anything on it to land in the Tracks view.
struct CompactTrackLane: View {
    var track: ProjectThread
    var space: Space

    @Environment(AppModel.self) private var app

    var body: some View {
        let lane = LaneModel(track: track, space: space)
        let count = LaneSet.candidates(in: space).count
        VStack(alignment: .leading, spacing: 2) {
            TrackLaneRow(
                lane: lane,
                compact: true,
                selectedStop: nil,
                onStop: { app.open($0, newTab: false) },
                onJunction: { junction in
                    app.showTracks(in: space, newTab: false)
                    app.selectJunction(junction.id)
                },
                onTitle: { app.open(track, newTab: false) }
            )
            if count > 1 {
                Button {
                    app.showTracks(in: space, newTab: false)
                } label: {
                    Text("All \(count) tracks")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The toolbar's "4 of 13 tracks" control: a panel to search and pick which tracks the Tracks view draws.
struct ShownTracksMenu: View {
    var space: Space

    @Environment(AppModel.self) private var app
    @State private var isPresented = false

    var body: some View {
        let candidates = LaneSet.candidates(in: space)
        let shown = LaneSet.shownIDs(in: space, chosen: app.shownTracks[space.id])
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(shown.count) of \(candidates.count) tracks")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .glassEffect(.regular, in: Capsule())
        .help("Which tracks to draw")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ShownTracksPanel(space: space, candidates: candidates, shown: Set(shown))
        }
    }
}

/// Search by name, click to show or hide. The field has focus as soon as the panel opens.
private struct ShownTracksPanel: View {
    var space: Space
    var candidates: [ProjectThread]
    var shown: Set<UUID>

    @Environment(AppModel.self) private var app
    @State private var query = ""
    @FocusState private var searching: Bool

    private var matching: [ProjectThread] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return candidates }
        return candidates.filter { LaneModel.title($0).localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Find a track", text: $query)
                    .textFieldStyle(.plain)
                    .font(CraftFont.body)
                    .focused($searching)
                    .onSubmit {
                        if let first = matching.first { toggle(first) }
                    }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(CraftColor.field))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(CraftColor.hairline))

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if matching.isEmpty {
                        Text("No track by that name.")
                            .font(CraftFont.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                    }
                    ForEach(matching) { track in
                        ShownTrackRow(track: track, isShown: shown.contains(track.id)) {
                            toggle(track)
                        }
                    }
                }
            }
            .frame(maxHeight: 300)

            Hairline()

            HStack(spacing: 4) {
                footerButton("Show All") { app.shownTracks[space.id] = candidates.map(\.id) }
                footerButton("Membrae's Pick") { app.shownTracks[space.id] = nil }
            }
        }
        .padding(8)
        .frame(width: 280)
        .onAppear { searching = true }
    }

    private func toggle(_ track: ProjectThread) {
        var next = shown
        if next.contains(track.id) { next.remove(track.id) } else { next.insert(track.id) }
        app.shownTracks[space.id] = candidates.filter { next.contains($0.id) }.map(\.id)
    }

    private func footerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(CraftFont.body)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ShownTrackRow: View {
    var track: ProjectThread
    var isShown: Bool
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(track.color.tint)
                    .frame(width: 8, height: 8)
                Text(LaneModel.title(track))
                    .font(isShown ? .system(size: 13, weight: .medium) : CraftFont.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isShown {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? CraftColor.hover : Color.clear)
                    .animation(Motion.hover, value: hovering)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isShown ? .isSelected : [])
    }
}
