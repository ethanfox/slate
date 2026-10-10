import Foundation
import PDFKit

struct ExtractedAttachment: Equatable, Sendable {
    var filename: String
    var text: String
    var disclosure: String
}

enum FileExtraction {
    static func extract(filename: String, mimeType: String, data: Data) throws -> ExtractedAttachment {
        if mimeType == "application/pdf" {
            return try pdf(filename: filename, data: data)
        }
        if mimeType == "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" {
            return try spreadsheet(filename: filename, data: data)
        }
        if mimeType.hasPrefix("text/") || mimeType == "application/json" {
            return try text(filename: filename, data: data)
        }
        throw AttachmentError.unsupportedType(filename)
    }

    private static func text(filename: String, data: Data) throws -> ExtractedAttachment {
        guard let decoded = decodeText(data) else {
            throw AttachmentError.unreadable(filename, "The file isn’t valid UTF-8 or UTF-16 text.")
        }
        try bound(decoded, filename: filename)
        return ExtractedAttachment(
            filename: filename,
            text: decoded,
            disclosure: "Slate extracted the text of \(filename)."
        )
    }

    private static func pdf(filename: String, data: Data) throws -> ExtractedAttachment {
        guard let document = PDFDocument(data: data) else {
            throw AttachmentError.unreadable(filename, "The PDF could not be opened.")
        }
        var pages: [String] = []
        for index in 0..<document.pageCount {
            let page = document.page(at: index)?.string?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !page.isEmpty { pages.append(page) }
        }
        let text = pages.joined(separator: "\n\n")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AttachmentError.unreadable(
                filename,
                "This PDF has no extractable text. It may be scanned images."
            )
        }
        try bound(text, filename: filename)
        return ExtractedAttachment(
            filename: filename,
            text: text,
            disclosure: "Slate extracted text from \(filename). Images and layout are not included."
        )
    }

    private static func spreadsheet(filename: String, data: Data) throws -> ExtractedAttachment {
        do {
            let text = try XLSXReader.text(from: data)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw AttachmentError.unreadable(filename, "The spreadsheet has no readable cell values.")
            }
            try bound(text, filename: filename)
            return ExtractedAttachment(
                filename: filename,
                text: text,
                disclosure: "Slate read cell values from \(filename). Formatting, charts, and macros are excluded. Formulas are not executed."
            )
        } catch let error as AttachmentError {
            throw error
        } catch {
            throw AttachmentError.unreadable(filename, "The spreadsheet could not be read.")
        }
    }

    private static func bound(_ text: String, filename: String) throws {
        if text.count > AttachmentLimits.maxExtractedCharacters {
            throw AttachmentError.extractedTooLarge(filename)
        }
    }

    private static func decodeText(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .utf16LittleEndian) { return text }
        if let text = String(data: data, encoding: .utf16BigEndian) { return text }
        return nil
    }
}

enum XLSXReader {
    static func text(from data: Data) throws -> String {
        let strings = try sharedStrings(in: data)
        let sheets = try ZipMemory.entries(in: data) { name in
            name.hasPrefix("xl/worksheets/sheet") && name.hasSuffix(".xml")
        }
        let names = try sheetNames(in: data)
        if sheets.count > AttachmentLimits.maxXlsxSheets {
            throw AttachmentError.extractedTooLarge("workbook")
        }
        var blocks: [String] = []
        for (index, sheet) in sheets.sorted(by: { $0.name < $1.name }).enumerated() {
            let title = names[index] ?? "Sheet \(index + 1)"
            let rows = try rows(in: sheet.data, strings: strings)
            if rows.isEmpty { continue }
            blocks.append("### \(title)\n\(rows.joined(separator: "\n"))")
        }
        return blocks.joined(separator: "\n\n")
    }

    private static func sharedStrings(in data: Data) throws -> [String] {
        guard let xml = try? ZipMemory.data(named: "xl/sharedStrings.xml", in: data),
              let text = String(data: xml, encoding: .utf8)
        else { return [] }
        var values: [String] = []
        var remaining = text[...]
        while let start = remaining.range(of: "<si") {
            remaining = remaining[start.upperBound...]
            guard let end = remaining.range(of: "</si>") else { break }
            let item = remaining[..<end.lowerBound]
            values.append(plainText(in: String(item)))
            remaining = remaining[end.upperBound...]
        }
        return values
    }

    private static func sheetNames(in data: Data) throws -> [String] {
        guard let xml = try? ZipMemory.data(named: "xl/workbook.xml", in: data),
              let text = String(data: xml, encoding: .utf8)
        else { return [] }
        var names: [String] = []
        var remaining = text[...]
        while let start = remaining.range(of: "name=\"") {
            remaining = remaining[start.upperBound...]
            guard let end = remaining.range(of: "\"") else { break }
            names.append(String(remaining[..<end.lowerBound]))
            remaining = remaining[end.upperBound...]
        }
        return names
    }

    private static func rows(in data: Data, strings: [String]) throws -> [String] {
        guard let xml = String(data: data, encoding: .utf8) else { return [] }
        var lines: [String] = []
        var remaining = xml[...]
        while let start = remaining.range(of: "<row") {
            remaining = remaining[start.upperBound...]
            guard let end = remaining.range(of: "</row>") else { break }
            let row = remaining[..<end.lowerBound]
            let cells = cells(in: String(row), strings: strings)
            if !cells.isEmpty { lines.append(cells.joined(separator: "\t")) }
            remaining = remaining[end.upperBound...]
            if lines.count > AttachmentLimits.maxXlsxRowsPerSheet {
                throw AttachmentError.extractedTooLarge("spreadsheet")
            }
        }
        return lines
    }

    private static func cells(in row: String, strings: [String]) -> [String] {
        var values: [String] = []
        var remaining = row[...]
        while let start = remaining.range(of: "<c") {
            remaining = remaining[start.upperBound...]
            guard let close = remaining.range(of: ">") else { break }
            let header = remaining[..<close.lowerBound]
            let shared = header.contains("t=\"s\"")
            remaining = remaining[close.upperBound...]
            guard let valueStart = remaining.range(of: "<v>") else { continue }
            remaining = remaining[valueStart.upperBound...]
            guard let valueEnd = remaining.range(of: "</v>") else { continue }
            let raw = String(remaining[..<valueEnd.lowerBound])
            remaining = remaining[valueEnd.upperBound...]
            if shared, let index = Int(raw), strings.indices.contains(index) {
                values.append(strings[index])
            } else {
                values.append(raw)
            }
        }
        return values
    }

    private static func plainText(in xml: String) -> String {
        var remaining = xml[...]
        var parts: [String] = []
        while let start = remaining.range(of: "<t") {
            remaining = remaining[start.upperBound...]
            guard let open = remaining.range(of: ">") else { break }
            remaining = remaining[open.upperBound...]
            guard let end = remaining.range(of: "</t>") else { break }
            parts.append(String(remaining[..<end.lowerBound]))
            remaining = remaining[end.upperBound...]
        }
        return parts.joined()
    }
}
