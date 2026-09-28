import Foundation

extension Date {
    var relativeLabel: String {
        formatted(.relative(presentation: .named))
    }
}
func clip(_ text: String, _ limit: Int) -> String {
    let collapsed = text
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    guard collapsed.count > limit else { return collapsed }
    let index = collapsed.index(collapsed.startIndex, offsetBy: limit)
    return String(collapsed[..<index]).trimmingCharacters(in: .whitespaces) + "…"
}
func conversationTitle(from text: String) -> String {
    let line = text
        .components(separatedBy: .newlines)
        .first?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? text
    if line.count <= 48 { return line.isEmpty ? "New chat" : line }
    let index = line.index(line.startIndex, offsetBy: 48)
    return String(line[..<index]).trimmingCharacters(in: .whitespaces) + "…"
}
