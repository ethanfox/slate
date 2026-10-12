import Foundation
import PDFKit
import SwiftData

/// Fetches the text of saved links that do not have it yet, so the Library can be searched and the
/// agent can answer from what was saved.
enum SourceFetcher {
    struct Page: Equatable {
        var title: String
        var text: String
    }

    static let textLimit = 200_000

    @MainActor private static var fetching: Set<UUID> = []

    /// A lone web address, which the one input saves without opening a chat.
    static func link(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host() != nil else { return nil }
        return url
    }

    /// Fetches every saved link that has no text and has not been tried.
    @MainActor
    static func fillPending(container: ModelContainer) {
        let context = ModelContext(container)
        let waiting = (try? context.fetch(FetchDescriptor<SavedSource>(
            predicate: #Predicate { $0.text == "" && $0.fetchedAt == nil && $0.url != "" }
        ))) ?? []
        for source in waiting where !fetching.contains(source.id) {
            guard let url = URL(string: source.url) else { continue }
            let id = source.id
            fetching.insert(id)
            Task {
                let page = await fetch(url)
                await MainActor.run {
                    fetching.remove(id)
                    store(page, for: id, container: container)
                }
            }
        }
    }

    @MainActor
    private static func store(_ page: Page?, for id: UUID, container: ModelContainer) {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let source = try? context.fetch(FetchDescriptor<SavedSource>(predicate: #Predicate { $0.id == id })).first else { return }
        source.fetchedAt = .now
        if let page {
            if source.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { source.title = page.title }
            if source.text.isEmpty { source.text = page.text }
            source.updatedAt = .now
        }
        try? context.persist()
    }

    static func fetch(_ url: URL) async -> Page? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Mozilla/5.0 (Macintosh) AppleWebKit/605.1.15 (KHTML, like Gecko) Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if type.contains("pdf") || url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(data: data) else { return nil }
            let text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n\n")
            let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String) ?? url.deletingPathExtension().lastPathComponent
            return Page(title: title, text: String(text.prefix(textLimit)))
        }
        guard type.isEmpty || type.contains("html") || type.contains("text") else { return nil }
        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return readable(html: html)
    }

    /// The title and the readable text of a page, without its scripts, menus, and markup.
    static func readable(html: String) -> Page {
        let title = meta("og:title", in: html) ?? first("<title[^>]*>(.*?)</title>", in: html) ?? ""
        var body = first("<article[^>]*>(.*?)</article>", in: html)
            ?? first("<main[^>]*>(.*?)</main>", in: html)
            ?? first("<body[^>]*>(.*?)</body>", in: html)
            ?? html
        for tag in ["script", "style", "noscript", "svg", "nav", "header", "footer", "aside", "form", "iframe", "template"] {
            body = replace("<\(tag)\\b[^>]*>.*?</\(tag)>", in: body, with: " ")
        }
        body = replace("<!--.*?-->", in: body, with: " ")
        body = replace("<(br|/p|/div|/li|/h[1-6]|/tr|/blockquote|/section)\\b[^>]*>", in: body, with: "\n")
        body = replace("<[^>]+>", in: body, with: " ")
        body = decode(body)
        let lines = body.components(separatedBy: .newlines)
            .map { replace("[ \\t\\u{00A0}]+", in: $0, with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Page(
            title: decode(replace("\\s+", in: title, with: " ")).trimmingCharacters(in: .whitespacesAndNewlines),
            text: String(lines.joined(separator: "\n").prefix(textLimit))
        )
    }

    private static func meta(_ property: String, in html: String) -> String? {
        first("<meta[^>]+property=[\"']\(property)[\"'][^>]+content=[\"']([^\"']*)[\"']", in: html)
            ?? first("<meta[^>]+content=[\"']([^\"']*)[\"'][^>]+property=[\"']\(property)[\"']", in: html)
    }

    private static let options: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]

    private static func first(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        let found = String(text[range])
        return found.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : found
    }

    private static func replace(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
    }

    private static let entities = [
        "&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
        "&mdash;": "\u{2014}", "&ndash;": "\u{2013}", "&hellip;": "\u{2026}",
        "&rsquo;": "\u{2019}", "&lsquo;": "\u{2018}", "&rdquo;": "\u{201D}", "&ldquo;": "\u{201C}"
    ]

    private static func decode(_ text: String) -> String {
        var result = text
        for (entity, value) in entities {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        if let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
            for match in matches {
                guard let whole = Range(match.range, in: result),
                      let hex = Range(match.range(at: 1), in: result),
                      let digits = Range(match.range(at: 2), in: result),
                      let code = UInt32(result[digits], radix: result[hex].isEmpty ? 10 : 16),
                      let scalar = Unicode.Scalar(code) else { continue }
                result.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}
