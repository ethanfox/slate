import AppKit
import SwiftUI

enum ObjectFind {
    struct Field: Hashable {
        var id: String
        var label: String

        static let title = Field(id: "title", label: "Title")
        static let summary = Field(id: "summary", label: "Summary")
        static let status = Field(id: "status", label: "Status")
        static let kind = Field(id: "kind", label: "Kind")
        static let track = Field(id: "track", label: "Track")
        static let parent = Field(id: "parent", label: "Parent")
        static let tags = Field(id: "tags", label: "Tags")
        static let source = Field(id: "source", label: "Source")
        static let date = Field(id: "date", label: "Date")
        static let superseded = Field(id: "superseded", label: "Replaced by")
        static let linked = Field(id: "linked", label: "Linked")
        static let body = Field(id: "body", label: "Text")
        static let rationale = Field(id: "rationale", label: "Why")

        static func child(_ id: UUID) -> Field {
            Field(id: "child-\(id.uuidString)", label: "Sub-track")
        }

        static func agenda(_ id: UUID) -> Field {
            Field(id: "agenda-\(id.uuidString)", label: "Task")
        }
    }

    struct Match: Hashable, Identifiable {
        var field: Field
        var range: NSRange

        var id: String { "\(field.id):\(range.location):\(range.length)" }
    }

    enum Mark: Equatable {
        case none
        case match
        case current

        var fill: Color {
            switch self {
            case .none: .clear
            case .match: Color(nsColor: .findHighlightColor).opacity(0.35)
            case .current: Color(nsColor: .findHighlightColor)
            }
        }
    }

    static func matches(query: String, in fields: [(Field, String)]) -> [Match] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var results: [Match] = []
        for (field, text) in fields {
            let haystack = text as NSString
            var search = 0
            while search < haystack.length {
                let found = haystack.range(
                    of: needle,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: NSRange(location: search, length: haystack.length - search)
                )
                guard found.location != NSNotFound else { break }
                results.append(Match(field: field, range: found))
                search = found.location + max(found.length, 1)
            }
        }
        return results
    }
}

@MainActor
@Observable
final class ObjectFindSession {
    var isOpen = false
    var query = ""
    private(set) var objectID: UUID?
    private(set) var matches: [ObjectFind.Match] = []
    private(set) var currentIndex = 0
    private(set) var revealToken = 0
    private var fields: [(ObjectFind.Field, String)] = []
    private(set) var focusNonce = 0
    @ObservationIgnored private var shortcutMonitor: Any?
    @ObservationIgnored private var canHandleShortcut: () -> Bool = { false }

    var isAvailable: Bool { objectID != nil }

    func installShortcuts(canHandle: @escaping () -> Bool) {
        canHandleShortcut = canHandle
        guard shortcutMonitor == nil else { return }
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            var consumed = false
            let apply = {
                consumed = self.consumeShortcut(event)
            }
            if Thread.isMainThread {
                apply()
            } else {
                DispatchQueue.main.sync(execute: apply)
            }
            return consumed ? nil : event
        }
    }

    var current: ObjectFind.Match? {
        matches.indices.contains(currentIndex) ? matches[currentIndex] : nil
    }

    var status: String {
        guard isOpen, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        guard let current else { return "No results" }
        return "\(current.field.label) · \(currentIndex + 1) of \(matches.count)"
    }

    func open() {
        guard canHandleShortcut() || isAvailable else { return }
        isOpen = true
        focusNonce += 1
        reveal()
    }

    func toggle() {
        if isOpen {
            close()
        } else {
            open()
        }
    }

    func close() {
        isOpen = false
        query = ""
        matches = []
        currentIndex = 0
    }

    func setQuery(_ text: String) {
        query = text
        recompute(resetIndex: true)
        reveal()
    }

    func next() {
        guard isOpen else {
            open()
            return
        }
        guard !matches.isEmpty else { return }
        currentIndex = (currentIndex + 1) % matches.count
        reveal()
    }

    func previous() {
        guard isOpen else {
            open()
            return
        }
        guard !matches.isEmpty else { return }
        currentIndex = (currentIndex - 1 + matches.count) % matches.count
        reveal()
    }

    func attach(_ id: UUID) {
        objectID = id
    }

    func detach(_ id: UUID) {
        guard objectID == id else { return }
        objectID = nil
        fields = []
        close()
    }

    func setFields(_ fields: [(ObjectFind.Field, String)]) {
        self.fields = fields
        recompute(resetIndex: false)
    }

    func mark(for field: ObjectFind.Field) -> ObjectFind.Mark {
        guard isOpen else { return .none }
        if current?.field == field { return .current }
        if matches.contains(where: { $0.field == field }) { return .match }
        return .none
    }

    func ranges(in field: ObjectFind.Field) -> [NSRange] {
        guard isOpen else { return [] }
        return matches.filter { $0.field == field }.map(\.range)
    }

    func currentRange(in field: ObjectFind.Field) -> NSRange? {
        guard isOpen, current?.field == field else { return nil }
        return current?.range
    }

    private func consumeShortcut(_ event: NSEvent) -> Bool {
        guard canHandleShortcut() else { return false }
        if event.window?.title == "Settings" { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (event.keyCode, modifiers) {
        case (3, .command):
            toggle()
            return true
        case (5, .command):
            next()
            return true
        case (5, [.command, .shift]):
            previous()
            return true
        default:
            return false
        }
    }

    private func recompute(resetIndex: Bool) {
        let previous = current
        matches = ObjectFind.matches(query: query, in: fields)
        if resetIndex {
            currentIndex = 0
            return
        }
        if let previous, let index = matches.firstIndex(of: previous) {
            currentIndex = index
        } else if currentIndex >= matches.count {
            currentIndex = max(0, matches.count - 1)
        }
    }

    private func reveal() {
        revealToken += 1
    }
}

private struct ObjectFindSessionKey: EnvironmentKey {
    static var defaultValue: ObjectFindSession?
}

extension EnvironmentValues {
    var objectFind: ObjectFindSession? {
        get { self[ObjectFindSessionKey.self] }
        set { self[ObjectFindSessionKey.self] = newValue }
    }
}

struct ObjectFindAttach: ViewModifier {
    var id: UUID
    var fields: [(ObjectFind.Field, String)]
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content
            .onAppear { sync() }
            .onDisappear { scheduleDetach() }
            .onChange(of: id) { _, newID in
                app.objectFind.attach(newID)
                app.objectFind.setFields(fields)
            }
            .onChange(of: signature) { _, _ in
                app.objectFind.setFields(fields)
            }
    }

    private var signature: String {
        fields.map { "\($0.0.id):\($0.1)" }.joined(separator: "\u{1e}")
    }

    private func sync() {
        app.objectFind.attach(id)
        app.objectFind.setFields(fields)
    }

    private func scheduleDetach() {
        let leaving = id
        DispatchQueue.main.async {
            let selected = app.selectedNote ?? app.selectedDecision ?? app.selectedThread
            guard selected != leaving else { return }
            app.objectFind.detach(leaving)
        }
    }
}

extension View {
    func objectFindable(id: UUID, fields: [(ObjectFind.Field, String)]) -> some View {
        modifier(ObjectFindAttach(id: id, fields: fields))
    }

    func findAnchor(_ field: ObjectFind.Field) -> some View {
        id(field.id)
    }

    func findHighlight(_ field: ObjectFind.Field) -> some View {
        modifier(ObjectFindHighlight(field: field))
    }
}

struct FindAnchorIfNeeded: ViewModifier {
    var field: ObjectFind.Field?

    func body(content: Content) -> some View {
        if let field {
            content.findAnchor(field)
        } else {
            content
        }
    }
}

private struct ObjectFindHighlight: ViewModifier {
    var field: ObjectFind.Field
    @Environment(\.objectFind) private var find

    func body(content: Content) -> some View {
        content
            .background(find?.mark(for: field).fill ?? .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .findAnchor(field)
    }
}
