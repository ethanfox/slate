import Foundation

enum DecisionListLayout {
    static let noTrackTitle = "No track"

    struct Group: Identifiable {
        var id: String
        var trackID: UUID?
        var title: String
        var decisions: [Decision]
    }

    struct Snapshot {
        var active: [Group]
        var history: [Group]
        var historyCount: Int
        var revealsHistory: Bool
        var revealedHistoryGroupIDs: Set<String>
    }

    static func snapshot(decisions: [Decision], roots: [ProjectThread], query: String) -> Snapshot {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = needle.isEmpty ? decisions : decisions.filter { matches($0, query: needle) }
        let order = flattenedTracks(roots)
        let active = groups(in: matching.filter { $0.status == .active }, order: order)
        let historyItems = matching.filter { $0.status == .superseded }
        let history = groups(in: historyItems, order: order)
        return Snapshot(
            active: active,
            history: history,
            historyCount: historyItems.count,
            revealsHistory: !needle.isEmpty && !historyItems.isEmpty,
            revealedHistoryGroupIDs: Set(history.map(\.id))
        )
    }

    static func flattenedTracks(_ roots: [ProjectThread]) -> [ProjectThread] {
        roots.flatMap { [$0] + flattenedTracks($0.orderedChildren) }
    }

    static func matches(_ decision: Decision, query: String) -> Bool {
        let fields = [
            decision.title,
            decision.decision,
            decision.rationale,
            decision.status.label,
            decision.tags.map(\.displayName).joined(separator: " "),
            trackTitle(decision.thread),
        ]
        return fields.contains { contains($0, query) }
    }

    private static func groups(in decisions: [Decision], order: [ProjectThread]) -> [Group] {
        let newestFirst = decisions.sorted { $0.createdAt > $1.createdAt }
        var buckets: [String: [Decision]] = [:]
        for decision in newestFirst {
            buckets[groupID(decision.thread), default: []].append(decision)
        }

        var result: [Group] = []
        for track in order {
            let id = groupID(track)
            guard let items = buckets.removeValue(forKey: id), !items.isEmpty else { continue }
            result.append(Group(id: id, trackID: track.id, title: trackTitle(track), decisions: items))
        }
        if let untracked = buckets.removeValue(forKey: groupID(nil)), !untracked.isEmpty {
            result.append(Group(id: groupID(nil), trackID: nil, title: noTrackTitle, decisions: untracked))
        }
        return result
    }

    private static func groupID(_ track: ProjectThread?) -> String {
        track?.id.uuidString ?? "no-track"
    }

    private static func trackTitle(_ track: ProjectThread?) -> String {
        guard let track else { return noTrackTitle }
        return track.title.isEmpty ? "Untitled" : track.title
    }

    private static func contains(_ text: String, _ query: String) -> Bool {
        (text as NSString).range(of: query, options: [.caseInsensitive, .diacriticInsensitive]).location != NSNotFound
    }
}
