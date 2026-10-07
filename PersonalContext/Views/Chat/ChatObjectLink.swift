import Foundation

struct ChatContentBlock: Identifiable, Equatable {
    var id: String
    var content: Content

    enum Content: Equatable {
        case text(String)
        case object(ChatSource)
    }
}

enum ChatObjectLink {
    static let scheme = "slate"

    static func blocks(in text: String) -> [ChatContentBlock] {
        var result: [ChatContentBlock] = []
        var cursor = text.startIndex
        var order = 0

        while cursor < text.endIndex {
            guard let match = nextMatch(in: text, from: cursor) else {
                appendText(String(text[cursor...]), order: &order, into: &result)
                break
            }
            appendText(String(text[cursor..<match.range.lowerBound]), order: &order, into: &result)
            result.append(
                ChatContentBlock(
                    id: "o-\(order)-\(match.source.kind.rawValue)-\(match.source.id)",
                    content: .object(match.source)
                )
            )
            order += 1
            cursor = match.range.upperBound
        }

        return result
    }

    static func unlinked(_ sources: [ChatSource], in text: String) -> [ChatSource] {
        let linked = blocks(in: text).compactMap { block -> ChatSource? in
            if case .object(let source) = block.content { return source }
            return nil
        }
        return sources.filter { source in
            !linked.contains { $0.isSame(as: source) }
        }
    }

    static func parse(_ url: URL, title: String = "") -> ChatSource? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        guard let kind = kind(from: url.host() ?? "") else { return nil }
        let id = url.path.split(separator: "/").map(String.init).first { !$0.isEmpty } ?? ""
        guard UUID(uuidString: id) != nil else { return nil }
        return ChatSource(
            id: id,
            title: title,
            url: href(kind: kind, id: id),
            kind: kind,
            pin: false
        )
    }

    static func parse(_ raw: String, title: String = "") -> ChatSource? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return nil }
        return parse(url, title: title)
    }

    static func href(kind: ChatSource.Kind, id: String) -> String {
        "\(scheme)://\(kind.rawValue)/\(id)"
    }

    private static func appendText(_ raw: String, order: inout Int, into result: inout [ChatContentBlock]) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        result.append(ChatContentBlock(id: "t-\(order)", content: .text(trimmed)))
        order += 1
    }

    private static func nextMatch(
        in text: String,
        from start: String.Index
    ) -> (range: Range<String.Index>, source: ChatSource)? {
        var index = start
        while index < text.endIndex {
            if text[index] == "[",
               let link = takeMarkdownLink(text, from: index),
               let source = parse(link.url, title: link.label) {
                return (index..<link.end, source)
            }
            if let bare = takeBare(text, from: index) {
                return bare
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func takeMarkdownLink(
        _ text: String,
        from start: String.Index
    ) -> (label: String, url: String, end: String.Index)? {
        guard text[start] == "[", let close = text[start...].range(of: "](") else { return nil }
        let labelStart = text.index(after: start)
        guard close.lowerBound > labelStart else { return nil }
        let urlStart = close.upperBound
        guard let end = text[urlStart...].firstIndex(of: ")") else { return nil }
        let label = String(text[labelStart..<close.lowerBound])
        let raw = String(text[urlStart..<end])
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        guard !raw.isEmpty else { return nil }
        return (label, raw, text.index(after: end))
    }

    private static func takeBare(
        _ text: String,
        from start: String.Index
    ) -> (range: Range<String.Index>, source: ChatSource)? {
        let prefix = "slate://"
        guard let prefixEnd = text.index(start, offsetBy: prefix.count, limitedBy: text.endIndex),
              String(text[start..<prefixEnd]).lowercased() == prefix
        else { return nil }
        var index = prefixEnd
        let kindStart = index
        while index < text.endIndex, text[index].isLetter {
            index = text.index(after: index)
        }
        let kindRaw = String(text[kindStart..<index])
        guard let kind = kind(from: kindRaw), index < text.endIndex, text[index] == "/" else { return nil }
        index = text.index(after: index)
        let idStart = index
        var count = 0
        while index < text.endIndex, count < 36 {
            let character = text[index]
            if character.isHexDigit || character == "-" {
                index = text.index(after: index)
                count += 1
            } else {
                break
            }
        }
        let id = String(text[idStart..<index])
        guard UUID(uuidString: id) != nil else { return nil }
        let source = ChatSource(
            id: id,
            title: "",
            url: href(kind: kind, id: id),
            kind: kind,
            pin: false
        )
        return (start..<index, source)
    }

    private static func kind(from raw: String) -> ChatSource.Kind? {
        switch raw.lowercased() {
        case "note", "notes": return .note
        case "thread", "threads", "track", "tracks": return .thread
        case "decision", "decisions": return .decision
        case "project", "projects": return .project
        case "conversation", "conversations", "chat", "chats": return .conversation
        default: return nil
        }
    }
}
