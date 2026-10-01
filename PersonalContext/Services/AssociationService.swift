import Foundation
import SwiftData

enum TagStore {
    static func all(in context: ModelContext) -> [Tag] {
        let descriptor = FetchDescriptor<Tag>(sortBy: [SortDescriptor(\.name)])
        return (try? context.fetch(descriptor)) ?? []
    }

    static func existing(named raw: String, in context: ModelContext) -> Tag? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return all(in: context).first { $0.name.caseInsensitiveCompare(key) == .orderedSame }
    }

    static func create(named raw: String, in context: ModelContext) -> Tag? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if let existing = existing(named: name, in: context) { return existing }
        let tag = Tag(name: name)
        context.insert(tag)
        try? context.save()
        return tag
    }

    static func rename(_ tag: Tag, to raw: String, in context: ModelContext) -> Bool {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        if let other = existing(named: name, in: context), other.id != tag.id { return false }
        tag.name = name
        try? context.save()
        return true
    }

    static func delete(_ tag: Tag, in context: ModelContext) {
        context.delete(tag)
        try? context.save()
    }
}

enum AgendaStore {
    static func item(kind: AgendaKind, eventKitID: String, in context: ModelContext) -> AgendaItem? {
        guard !eventKitID.isEmpty else { return nil }
        let kindRaw = kind.rawValue
        let descriptor = FetchDescriptor<AgendaItem>(
            predicate: #Predicate { $0.eventKitID == eventKitID && $0.kindRaw == kindRaw }
        )
        return try? context.fetch(descriptor).first
    }

    static func findOrCreate(kind: AgendaKind, eventKitID: String, title: String, in context: ModelContext) -> AgendaItem {
        if let existing = item(kind: kind, eventKitID: eventKitID, in: context) {
            if !title.isEmpty { existing.title = title }
            return existing
        }
        let item = AgendaItem(kind: kind, eventKitID: eventKitID, title: title)
        context.insert(item)
        return item
    }

    static func all(in context: ModelContext) -> [AgendaItem] {
        let descriptor = FetchDescriptor<AgendaItem>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    static func items(in project: Project) -> [AgendaItem] {
        project.agendaItems.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func items(on thread: ProjectThread, includingChildren: Bool) -> [AgendaItem] {
        var threads = [thread]
        if includingChildren {
            collectChildren(of: thread, into: &threads)
        }
        let ids = Set(threads.map(\.id))
        var seen = Set<UUID>()
        var result: [AgendaItem] = []
        for candidate in threads.flatMap(\.agendaTrackLinks).compactMap(\.item) {
            guard seen.insert(candidate.id).inserted else { continue }
            if candidate.trackLinks.contains(where: { $0.thread.map { ids.contains($0.id) } ?? ids.contains($0.threadID) }) {
                result.append(candidate)
            }
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func collectChildren(of thread: ProjectThread, into bag: inout [ProjectThread]) {
        for child in thread.orderedChildren {
            bag.append(child)
            collectChildren(of: child, into: &bag)
        }
    }
}

struct AssociationConflict {
    var incoming: Project
    var current: Project
}

enum AssociationService {
    static func setProject(_ project: Project?, on item: AgendaItem, userSet: Bool) {
        item.project = project
        item.projectIsInherited = project != nil && !userSet
        item.touch()
    }

    static func assignUserProject(_ project: Project?, on item: AgendaItem) {
        setProject(project, on: item, userSet: project != nil)
    }

    static func conflict(linking project: Project, onto item: AgendaItem) -> AssociationConflict? {
        guard let current = item.project, current.id != project.id else { return nil }
        return AssociationConflict(incoming: project, current: current)
    }

    static func switchProject(_ project: Project, on item: AgendaItem) {
        dropForeignLinks(on: item, keeping: project)
        setProject(project, on: item, userSet: true)
    }

    static func link(note: Note, onto item: AgendaItem) -> AssociationConflict? {
        guard let project = note.project else { return nil }
        if let conflict = conflict(linking: project, onto: item) { return conflict }
        applyLink(note: note, onto: item)
        return nil
    }

    static func applyLink(note: Note, onto item: AgendaItem) {
        if item.noteLinks.contains(where: { $0.noteID == note.id }) { return }
        let link = AgendaNoteLink(note: note)
        item.noteLinks.append(link)
        inheritProject(from: projectOf(note), onto: item)
        if let thread = note.thread {
            attach(thread: thread, onto: item, inherited: true, fromNote: note.id)
        }
        item.touch()
    }

    static func unlink(noteID: UUID, from item: AgendaItem, in context: ModelContext) {
        for link in item.noteLinks.filter({ $0.noteID == noteID }) {
            context.delete(link)
        }
        for link in item.trackLinks.filter({ $0.isInherited && $0.inheritedFromNoteID == noteID && !stillJustified($0, on: item) }) {
            context.delete(link)
        }
        clearInheritedProjectIfNeeded(on: item)
        item.touch()
    }

    static func clearNotes(from item: AgendaItem, in context: ModelContext) {
        for link in item.noteLinks { context.delete(link) }
        for link in item.trackLinks where link.isInherited {
            context.delete(link)
        }
        clearInheritedProjectIfNeeded(on: item)
        item.touch()
    }

    static func link(thread: ProjectThread, onto item: AgendaItem) -> AssociationConflict? {
        guard let project = thread.project else { return nil }
        if let conflict = conflict(linking: project, onto: item) { return conflict }
        applyLink(thread: thread, onto: item)
        return nil
    }

    static func applyLink(thread: ProjectThread, onto item: AgendaItem) {
        attach(thread: thread, onto: item, inherited: false, fromNote: nil)
        inheritProject(from: thread.project, onto: item)
        item.touch()
    }

    static func unlink(threadID: UUID, from item: AgendaItem, in context: ModelContext) {
        for link in item.trackLinks.filter({ $0.threadID == threadID }) {
            context.delete(link)
        }
        clearInheritedProjectIfNeeded(on: item)
        item.touch()
    }

    static func clearTracks(from item: AgendaItem, in context: ModelContext) {
        for link in item.trackLinks { context.delete(link) }
        clearInheritedProjectIfNeeded(on: item)
        item.touch()
    }

    static func clearProject(from item: AgendaItem) {
        setProject(nil, on: item, userSet: true)
    }

    static func apply(tags: [Tag], to item: AgendaItem) {
        item.tags = tags
        item.touch()
    }

    static func dropLink(_ link: AgendaNoteLink, from item: AgendaItem, in context: ModelContext) {
        unlink(noteID: link.noteID, from: item, in: context)
    }

    static func dropLink(_ link: AgendaTrackLink, from item: AgendaItem, in context: ModelContext) {
        unlink(threadID: link.threadID, from: item, in: context)
    }

    static func replaceNote(_ existing: AgendaNoteLink, with note: Note, on item: AgendaItem, in context: ModelContext) -> AssociationConflict? {
        unlink(noteID: existing.noteID, from: item, in: context)
        return link(note: note, onto: item)
    }

    static func replaceTrack(_ existing: AgendaTrackLink, with thread: ProjectThread, on item: AgendaItem, in context: ModelContext) -> AssociationConflict? {
        unlink(threadID: existing.threadID, from: item, in: context)
        return link(thread: thread, onto: item)
    }

    static func cascade(moving thread: ProjectThread, to project: Project, in context: ModelContext) -> MovePlan {
        var tracks: [ProjectThread] = []
        collect(thread, into: &tracks)
        var notes = Set(tracks.flatMap(\.notes).map(\.id))
        var decisions = Set(tracks.flatMap(\.decisions).map(\.id))
        var conversations = Set(tracks.flatMap(\.conversations).map(\.id))
        var agenda = Set(tracks.flatMap { AgendaStore.items(on: $0, includingChildren: false) }.map(\.id))
        expand(agenda: &agenda, notes: &notes, tracks: &tracks, from: thread.project, in: context)
        return MovePlan(
            project: project,
            tracks: tracks,
            notes: notes,
            decisions: decisions,
            conversations: conversations,
            agenda: agenda
        )
    }

    static func cascade(moving note: Note, to project: Project, in context: ModelContext) -> MovePlan {
        var tracks: [ProjectThread] = []
        if let thread = note.thread { collect(thread, into: &tracks) }
        var notes: Set<UUID> = [note.id]
        var decisions = Set(tracks.flatMap(\.decisions).map(\.id))
        var conversations = Set(tracks.flatMap(\.conversations).map(\.id))
        var agenda = Set(note.agendaNoteLinks.compactMap(\.item?.id))
        for track in tracks {
            for item in AgendaStore.items(on: track, includingChildren: false) {
                agenda.insert(item.id)
            }
        }
        expand(agenda: &agenda, notes: &notes, tracks: &tracks, from: note.project, in: context)
        return MovePlan(
            project: project,
            tracks: tracks,
            notes: notes,
            decisions: decisions,
            conversations: conversations,
            agenda: agenda
        )
    }

    static func apply(_ plan: MovePlan, in context: ModelContext) {
        for thread in plan.tracks {
            thread.project = plan.project
            thread.updatedAt = .now
        }
        for note in plan.notes.compactMap({ lookupNote($0, in: context) }) {
            note.project = plan.project
            note.updatedAt = .now
        }
        for decision in plan.decisions.compactMap({ lookupDecision($0, in: context) }) {
            decision.project = plan.project
        }
        for conversation in plan.conversations.compactMap({ lookupConversation($0, in: context) }) {
            conversation.project = plan.project
            conversation.updatedAt = .now
        }
        for item in plan.agenda.compactMap({ lookupAgenda($0, in: context) }) {
            item.project = plan.project
            item.touch()
        }
        plan.project.touch()
        try? context.save()
    }

    static func deletedEntries(eventKitIDs: Set<String>, in context: ModelContext) -> [DeletedAssociation] {
        var rows: [DeletedAssociation] = []
        for item in AgendaStore.all(in: context) {
            if !item.eventKitID.isEmpty, !eventKitIDs.contains(item.eventKitID) {
                rows.append(DeletedAssociation(id: item.id, item: item, kind: .missingEventKit, title: item.displayTitle, detail: "No longer in Calendar or Reminders"))
            }
            for link in item.noteLinks where link.note == nil {
                rows.append(DeletedAssociation(id: link.id, item: item, kind: .missingNote, title: item.displayTitle, detail: "Linked note was deleted", noteLink: link))
            }
            for link in item.trackLinks where link.thread == nil {
                rows.append(DeletedAssociation(id: link.id, item: item, kind: .missingTrack, title: item.displayTitle, detail: "Linked track was deleted", trackLink: link))
            }
        }
        return rows
    }

    private static func inheritProject(from project: Project?, onto item: AgendaItem) {
        guard let project else { return }
        if item.project == nil {
            setProject(project, on: item, userSet: false)
        }
    }

    private static func attach(thread: ProjectThread, onto item: AgendaItem, inherited: Bool, fromNote: UUID?) {
        if let existing = item.trackLinks.first(where: { $0.threadID == thread.id }) {
            if existing.isInherited, !inherited {
                existing.isInherited = false
                existing.inheritedFromNoteID = nil
            } else if existing.isInherited, inherited {
                existing.inheritedFromNoteID = existing.inheritedFromNoteID ?? fromNote
            }
            return
        }
        let link = AgendaTrackLink(thread: thread, inherited: inherited, fromNoteID: fromNote)
        item.trackLinks.append(link)
    }

    private static func stillJustified(_ link: AgendaTrackLink, on item: AgendaItem) -> Bool {
        item.liveNotes.contains { $0.thread?.id == link.threadID }
    }

    private static func clearInheritedProjectIfNeeded(on item: AgendaItem) {
        guard item.projectIsInherited else { return }
        let hasBroken = item.noteLinks.contains { $0.note == nil } || item.trackLinks.contains { $0.thread == nil }
        if hasBroken { return }
        let justified = item.liveNotes.contains { $0.project?.id == item.project?.id }
            || item.liveTracks.contains { $0.project?.id == item.project?.id }
        if !justified {
            setProject(nil, on: item, userSet: false)
        }
    }

    private static func dropForeignLinks(on item: AgendaItem, keeping project: Project) {
        item.noteLinks.removeAll { $0.note?.project?.id != project.id }
        item.trackLinks.removeAll { $0.thread?.project?.id != project.id }
    }

    private static func projectOf(_ note: Note) -> Project? { note.project }

    private static func collect(_ thread: ProjectThread, into bag: inout [ProjectThread]) {
        if bag.contains(where: { $0.id == thread.id }) { return }
        bag.append(thread)
        for child in thread.orderedChildren {
            collect(child, into: &bag)
        }
    }

    private static func expand(
        agenda: inout Set<UUID>,
        notes: inout Set<UUID>,
        tracks: inout [ProjectThread],
        from old: Project?,
        in context: ModelContext
    ) {
        guard let old else { return }
        let items = agenda.compactMap { lookupAgenda($0, in: context) }
        for item in items {
            for note in item.liveNotes where note.project?.id == old.id {
                notes.insert(note.id)
                if let thread = note.thread { collect(thread, into: &tracks) }
            }
            for thread in item.liveTracks where thread.project?.id == old.id {
                collect(thread, into: &tracks)
            }
        }
    }

    private static func lookupNote(_ id: UUID, in context: ModelContext) -> Note? {
        try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == id })).first
    }

    private static func lookupDecision(_ id: UUID, in context: ModelContext) -> Decision? {
        try? context.fetch(FetchDescriptor<Decision>(predicate: #Predicate { $0.id == id })).first
    }

    private static func lookupConversation(_ id: UUID, in context: ModelContext) -> Conversation? {
        try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })).first
    }

    private static func lookupAgenda(_ id: UUID, in context: ModelContext) -> AgendaItem? {
        try? context.fetch(FetchDescriptor<AgendaItem>(predicate: #Predicate { $0.id == id })).first
    }
}

struct MovePlan {
    var project: Project
    var tracks: [ProjectThread]
    var notes: Set<UUID>
    var decisions: Set<UUID>
    var conversations: Set<UUID>
    var agenda: Set<UUID>

    var summary: [String] {
        var rows: [String] = []
        for thread in tracks {
            rows.append(thread.title.isEmpty ? "Untitled track" : thread.title)
        }
        if notes.count > tracks.flatMap(\.notes).count {
            rows.append("\(notes.count) notes")
        }
        if !agenda.isEmpty {
            rows.append("\(agenda.count) reminder\(agenda.count == 1 ? "" : "s") or events")
        }
        if !decisions.isEmpty {
            rows.append("\(decisions.count) decision\(decisions.count == 1 ? "" : "s")")
        }
        return rows
    }
}

struct DeletedAssociation: Identifiable {
    enum Kind {
        case missingNote
        case missingTrack
        case missingEventKit
    }

    var id: UUID
    var item: AgendaItem
    var kind: Kind
    var title: String
    var detail: String
    var noteLink: AgendaNoteLink?
    var trackLink: AgendaTrackLink?
}
