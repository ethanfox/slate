import AppKit
import UniformTypeIdentifiers

enum ComposerPaste {
    enum Payload: Equatable {
        case files([URL])
        case image(Data, filename: String)
    }

    static func payload(from board: NSPasteboard) -> Payload? {
        let files = localFileURLs(from: board)
        if !files.isEmpty {
            return .files(files)
        }
        if let image = image(from: board) {
            return .image(image.data, filename: image.filename)
        }
        return nil
    }

    static func localFileURLs(from board: NSPasteboard) -> [URL] {
        let urls = board.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL] ?? []
        return urls.filter { url in
            url.isFileURL && FileManager.default.fileExists(atPath: url.path)
        }
    }

    static func image(from board: NSPasteboard) -> (data: Data, filename: String)? {
        if let data = board.data(forType: .png), isAcceptedImage(data) {
            return (data, "pasted-image.png")
        }
        if let data = board.data(forType: UTType.jpeg.pasteboardType), isAcceptedImage(data) {
            return (data, "pasted-image.jpg")
        }
        if let data = board.data(forType: UTType.webP.pasteboardType), isAcceptedImage(data) {
            return (data, "pasted-image.webp")
        }
        if let data = board.data(forType: UTType.gif.pasteboardType), isAcceptedImage(data) {
            return (data, "pasted-image.gif")
        }
        if let data = board.data(forType: .tiff), let png = pngData(from: data) {
            return (png, "pasted-image.png")
        }
        if let images = board.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let image = images.first,
           let png = pngData(from: image) {
            return (png, "pasted-image.png")
        }
        return nil
    }

    private static func isAcceptedImage(_ data: Data) -> Bool {
        if case .image = FileTypeDetector.inspect(filename: "pasted-image", data: data) {
            return true
        }
        return false
    }

    static func pngData(from data: Data) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        return pngData(from: image)
    }

    static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        return png
    }
}

private extension UTType {
    var pasteboardType: NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType(identifier)
    }
}
