import Foundation

enum DetectedFile {
    case image(mime: String, animated: Bool)
    case pdf
    case text(mime: String)
    case spreadsheet
    case rejected(AttachmentError)
}

enum FileTypeDetector {
    static func inspect(filename: String, data: Data) -> DetectedFile {
        if isPNG(data) { return .image(mime: "image/png", animated: false) }
        if isJPEG(data) { return .image(mime: "image/jpeg", animated: false) }
        if isWebP(data) { return .image(mime: "image/webp", animated: false) }
        if isGIF(data) {
            return .image(mime: "image/gif", animated: isAnimatedGIF(data))
        }
        if data.starts(with: Array("%PDF".utf8)) { return .pdf }
        if isXLSX(data) { return .spreadsheet }
        if isLegacyXLS(data) {
            return .rejected(.unsupportedType(filename))
        }
        if let mime = textMIME(filename: filename, data: data) {
            return .text(mime: mime)
        }
        return .rejected(.unsupportedType(filename))
    }

    static func kind(for detected: DetectedFile) -> ChatAttachmentRef.Kind {
        if case .image = detected { return .image }
        return .file
    }

    static func mimeType(for detected: DetectedFile) -> String {
        switch detected {
        case .image(let mime, _): mime
        case .pdf: "application/pdf"
        case .text(let mime): mime
        case .spreadsheet: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case .rejected: "application/octet-stream"
        }
    }

    private static func isPNG(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    private static func isJPEG(_ data: Data) -> Bool {
        data.count >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF
    }

    private static func isWebP(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        return data.starts(with: Array("RIFF".utf8))
            && data[8..<12].elementsEqual(Array("WEBP".utf8))
    }

    private static func isGIF(_ data: Data) -> Bool {
        data.starts(with: Array("GIF87a".utf8)) || data.starts(with: Array("GIF89a".utf8))
    }

    private static func isAnimatedGIF(_ data: Data) -> Bool {
        if data.range(of: Data("NETSCAPE2.0".utf8)) != nil { return true }
        var frames = 0
        var index = 6
        while index < data.count {
            if data[index] == 0x2C {
                frames += 1
                if frames > 1 { return true }
            }
            index += 1
        }
        return false
    }

    private static func isLegacyXLS(_ data: Data) -> Bool {
        data.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
    }

    private static func isXLSX(_ data: Data) -> Bool {
        guard data.starts(with: [0x50, 0x4B, 0x03, 0x04]) else { return false }
        guard let names = try? ZipMemory.entryNames(in: data) else { return false }
        return names.contains { $0.hasPrefix("xl/") } && names.contains("[Content_Types].xml")
    }

    private static func textMIME(filename: String, data: Data) -> String? {
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        let allowed = [
            "txt": "text/plain",
            "md": "text/markdown",
            "markdown": "text/markdown",
            "csv": "text/csv",
            "json": "application/json",
            "swift": "text/plain",
            "ts": "text/plain",
            "tsx": "text/plain",
            "js": "text/plain",
            "jsx": "text/plain",
            "py": "text/plain",
            "rb": "text/plain",
            "go": "text/plain",
            "rs": "text/plain",
            "java": "text/plain",
            "kt": "text/plain",
            "c": "text/plain",
            "h": "text/plain",
            "cc": "text/plain",
            "cpp": "text/plain",
            "m": "text/plain",
            "mm": "text/plain",
            "html": "text/plain",
            "css": "text/plain",
            "yml": "text/plain",
            "yaml": "text/plain",
            "toml": "text/plain",
            "xml": "text/plain",
            "sh": "text/plain"
        ]
        guard let mime = allowed[ext] else { return nil }
        if String(data: data, encoding: .utf8) != nil { return mime }
        if String(data: data, encoding: .utf16LittleEndian) != nil { return mime }
        if String(data: data, encoding: .utf16BigEndian) != nil { return mime }
        return nil
    }
}
