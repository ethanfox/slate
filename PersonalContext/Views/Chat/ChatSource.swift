import AppKit
import Foundation
import LinkPresentation
import SwiftData
import UniformTypeIdentifiers

struct ChatSource: Identifiable, Equatable, Codable, Hashable {
    enum Kind: String, Codable {
        case url, note, thread, decision, project, conversation
    }

    var id: String
    var title: String
    var url: String?
    var kind: Kind
    var pin: Bool

    var host: String? {
        guard let url, let parsed = URL(string: url) else { return nil }
        return parsed.host()?.replacingOccurrences(of: "www.", with: "")
    }

    var shortName: String {
        switch kind {
        case .url: return host ?? title
        case .note, .thread, .decision, .project, .conversation:
            return title.isEmpty ? kindLabel : title
        }
    }

    var kindLabel: String {
        switch kind {
        case .url: return "Link"
        case .note: return "Note"
        case .thread: return "Track"
        case .decision: return "Decision"
        case .project: return "Project"
        case .conversation: return "Chat"
        }
    }

    var symbol: String {
        switch kind {
        case .url: return "globe"
        case .note: return "eyeglasses"
        case .thread: return TrackStyle.symbol
        case .decision: return "checkmark.seal"
        case .project: return "square.stack"
        case .conversation: return "bubble.left"
        }
    }

    func matches(_ sentence: String) -> Bool {
        if title.count >= 3, sentence.localizedStandardContains(title) { return true }
        if let host, host.count >= 3, sentence.localizedStandardContains(host) { return true }
        return false
    }

    func isSame(as other: ChatSource) -> Bool {
        if id == other.id { return true }
        if let url, url == other.url { return true }
        return kind == other.kind && !title.isEmpty && title == other.title
    }

    @MainActor
    func open(app: AppModel, context: ModelContext) {
        presented(in: context).source.openResolved(app: app, context: context)
    }

    func presented(in context: ModelContext?) -> (source: ChatSource, title: String, subtitle: String) {
        guard let context else {
            return (self, title.isEmpty ? kindLabel : title, kind == .url ? host ?? "Link" : kindLabel)
        }
        switch kind {
        case .url:
            return (self, title.isEmpty ? (host ?? "Link") : title, host ?? "Link")
        case .note:
            guard let note = note(in: context) else { return missing(kindLabel) }
            return live(id: note.id, title: note.displayTitle, kindLabel: kindLabel)
        case .thread:
            guard let thread = thread(in: context) else { return missing(kindLabel) }
            return live(id: thread.id, title: thread.title.isEmpty ? "Untitled" : thread.title, kindLabel: kindLabel)
        case .decision:
            guard let decision = decision(in: context) else { return missing(kindLabel) }
            return live(id: decision.id, title: decision.title, kindLabel: kindLabel)
        case .project:
            guard let project = project(in: context) else { return missing(kindLabel) }
            return live(id: project.id, title: project.displayName, kindLabel: kindLabel)
        case .conversation:
            guard let conversation = conversation(in: context) else { return missing(kindLabel) }
            return live(id: conversation.id, title: conversation.title.isEmpty ? "Chat" : conversation.title, kindLabel: kindLabel)
        }
    }

    private func live(id: UUID, title liveTitle: String, kindLabel: String) -> (source: ChatSource, title: String, subtitle: String) {
        var source = self
        source.id = id.uuidString
        source.title = liveTitle
        let renamed = !title.isEmpty && title != liveTitle
        return (source, liveTitle, renamed ? "Was \(title)" : kindLabel)
    }

    private func missing(_ kindLabel: String) -> (source: ChatSource, title: String, subtitle: String) {
        (self, title.isEmpty ? kindLabel : title, "Missing")
    }

    @MainActor
    private func openResolved(app: AppModel, context: ModelContext) {
        switch kind {
        case .url:
            if let url, let parsed = URL(string: url) {
                NSWorkspace.shared.open(parsed)
            }
        case .note:
            if let note = note(in: context) { app.open(note) }
        case .thread:
            if let thread = thread(in: context) { app.open(thread) }
        case .decision:
            if let decision = decision(in: context) { app.open(decision) }
        case .project:
            if let project = project(in: context) { app.open(project) }
        case .conversation:
            if let conversation = conversation(in: context) { app.open(conversation) }
        }
    }

    func note(in context: ModelContext) -> Note? {
        if let uuid = UUID(uuidString: id) {
            let found = try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == uuid }))
            if let note = found?.first { return note }
        }
        let match = title.isEmpty ? id : title
        guard !match.isEmpty else { return nil }
        let found = try? context.fetch(FetchDescriptor<Note>())
        return found?.first { $0.title == match || $0.displayTitle == match }
    }

    func thread(in context: ModelContext) -> ProjectThread? {
        if let uuid = UUID(uuidString: id) {
            let found = try? context.fetch(FetchDescriptor<ProjectThread>(predicate: #Predicate { $0.id == uuid }))
            if let thread = found?.first { return thread }
        }
        let match = title
        guard !match.isEmpty else { return nil }
        let found = try? context.fetch(FetchDescriptor<ProjectThread>(predicate: #Predicate { $0.title == match }))
        return found?.first
    }

    func decision(in context: ModelContext) -> Decision? {
        if let uuid = UUID(uuidString: id) {
            let found = try? context.fetch(FetchDescriptor<Decision>(predicate: #Predicate { $0.id == uuid }))
            if let decision = found?.first { return decision }
        }
        let match = title
        guard !match.isEmpty else { return nil }
        let found = try? context.fetch(FetchDescriptor<Decision>(predicate: #Predicate { $0.title == match }))
        return found?.first
    }

    func project(in context: ModelContext) -> Project? {
        if let uuid = UUID(uuidString: id) {
            let found = try? context.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.id == uuid }))
            if let project = found?.first { return project }
        }
        let match = title
        guard !match.isEmpty else { return nil }
        let found = try? context.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.name == match }))
        return found?.first
    }

    func conversation(in context: ModelContext) -> Conversation? {
        if let uuid = UUID(uuidString: id) {
            let found = try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == uuid }))
            if let conversation = found?.first { return conversation }
        }
        let match = title
        guard !match.isEmpty else { return nil }
        let found = try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.title == match }))
        return found?.first
    }

    func snippet(in context: ModelContext?) -> String {
        guard let context else { return "" }
        switch kind {
        case .url:
            return host ?? ""
        case .note:
            return firstLine(note(in: context)?.content)
        case .thread:
            return firstLine(thread(in: context)?.summary)
        case .decision:
            return firstLine(decision(in: context)?.decision)
        case .project:
            return firstLine(project(in: context)?.summary)
        case .conversation:
            return ""
        }
    }

    private func firstLine(_ text: String?) -> String {
        let line = text?
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        if line.count <= 90 { return line }
        return String(line.prefix(89)) + "…"
    }
}

struct ChatSourcePlacement: Equatable {
    var utf16: Int
    var sources: [ChatSource]
}

enum ChatSourceMatcher {
    static func place(_ sources: [ChatSource], in text: String, pinUnused: Bool) -> [ChatSourcePlacement] {
        guard !sources.isEmpty, !text.isEmpty else { return [] }
        let sentences = sentenceRanges(in: text)
        var unused = sources
        var grouped: [Int: [ChatSource]] = [:]

        for (index, range) in sentences.enumerated() {
            let sentence = String(text[range])
            let hits = unused.filter { $0.matches(sentence) }
            guard !hits.isEmpty else { continue }
            unused.removeAll { candidate in hits.contains { $0.id == candidate.id } }
            grouped[index, default: []].append(contentsOf: hits)
        }

        if pinUnused {
            let pins = unused.filter(\.pin)
            if !pins.isEmpty {
                grouped[max(sentences.count - 1, 0), default: []].append(contentsOf: pins)
            }
        }

        return grouped.keys.sorted().compactMap { index in
            guard let sources = grouped[index], !sources.isEmpty else { return nil }
            let end: Int
            if sentences.indices.contains(index) {
                let utf16 = NSRange(sentences[index], in: text)
                end = utf16.location + utf16.length
            } else {
                end = (text as NSString).length
            }
            return ChatSourcePlacement(utf16: end, sources: sources)
        }
    }

    private static func sentenceRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .localized]) { substring, range, _, _ in
            if substring?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                ranges.append(range)
            }
        }
        return ranges
    }
}

struct ChatWork: Equatable, Codable {
    var seconds: Int
    var thinking: String
    var tools: [ChatToolActivity]

    var hasContent: Bool {
        seconds > 0 || !thinking.isEmpty || !tools.isEmpty
    }
}

enum ChatTranscript {
    private static let start = "\n\n<!--slate:"
    private static let end = "-->"

    struct Payload: Codable {
        var sources: [ChatSource]
        var work: ChatWork?
    }

    struct Unpacked: Equatable {
        var text: String
        var sources: [ChatSource]
        var work: ChatWork?
    }

    static func pack(text: String, sources: [ChatSource], work: ChatWork?) -> String {
        let clean = unpack(text).text
        let payload = Payload(sources: sources, work: work)
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8),
              !sources.isEmpty || work?.hasContent == true
        else { return clean }
        return clean + start + json + end
    }

    static func unpack(_ raw: String) -> Unpacked {
        guard let start = raw.range(of: start, options: .backwards),
              let end = raw.range(of: end, range: start.upperBound..<raw.endIndex)
        else {
            return Unpacked(text: raw, sources: [], work: nil)
        }
        let json = String(raw[start.upperBound..<end.lowerBound])
        let payload = (try? JSONDecoder().decode(Payload.self, from: Data(json.utf8))) ?? Payload(sources: [], work: nil)
        return Unpacked(
            text: String(raw[..<start.lowerBound]),
            sources: payload.sources,
            work: payload.work
        )
    }
}

extension NSAttributedString.Key {
    static let chatSources = NSAttributedString.Key("slate.chatSources")
}

actor FaviconStore {
    static let shared = FaviconStore()
    private var images: [String: NSImage] = [:]
    private var metadata: [URL: LPLinkMetadata] = [:]

    func image(for url: URL) async -> NSImage? {
        let key = url.host() ?? url.absoluteString
        if let cached = images[key] { return cached }
        if let fetched = await fetch(url) {
            images[key] = fetched
            return fetched
        }
        return nil
    }

    func metadata(for url: URL) -> LPLinkMetadata? { metadata[url] }

    func store(_ value: LPLinkMetadata, for url: URL) {
        metadata[url] = value
    }

    private func fetch(_ url: URL) async -> NSImage? {
        if let cached = metadata[url], let icon = await icon(from: cached) { return icon }
        let provider = LPMetadataProvider()
        if let value = try? await provider.startFetchingMetadata(for: url) {
            metadata[url] = value
            if let icon = await icon(from: value) { return icon }
        }
        guard let host = url.host(),
              let favicon = URL(string: "https://\(host)/favicon.ico")
        else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(from: favicon),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = NSImage(data: data),
              image.size.width > 1
        else { return nil }
        return image
    }

    private func icon(from metadata: LPLinkMetadata) async -> NSImage? {
        await withCheckedContinuation { continuation in
            guard let provider = metadata.iconProvider else {
                continuation.resume(returning: nil)
                return
            }
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                continuation.resume(returning: data.flatMap(NSImage.init(data:)))
            }
        }
    }
}
