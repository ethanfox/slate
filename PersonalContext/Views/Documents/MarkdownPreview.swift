import Foundation

func renderedMarkdown(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
    if let parsed = try? AttributedString(markdown: text, options: options) {
        return parsed
    }
    return AttributedString(text)
}
func inlineMarkdown(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
}
func plainPreview(_ text: String, _ limit: Int = 160) -> String {
    clip(String(inlineMarkdown(text).characters), limit)
}
