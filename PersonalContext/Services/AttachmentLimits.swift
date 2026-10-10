import Foundation

/// Membrae safety defaults. Not claims about provider limits.
enum AttachmentLimits {
    static let maxFiles = 10
    static let maxFileBytes = 20 * 1_048_576
    static let maxTotalBytes = 50 * 1_048_576
    static let maxExtractedCharacters = 200_000
    static let abandonedGrace: TimeInterval = 24 * 60 * 60
    static let maxZipEntryBytes = 40 * 1_048_576
    static let maxZipEntries = 200
    static let maxXlsxRowsPerSheet = 5_000
    static let maxXlsxSheets = 20

    static let allowedImageTypes: Set<String> = [
        "image/png",
        "image/jpeg",
        "image/webp",
        "image/gif"
    ]

    static let allowedDocumentTypes: Set<String> = [
        "application/pdf",
        "text/plain",
        "text/csv",
        "text/markdown",
        "application/json",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    ]
}

enum AttachmentError: LocalizedError, Equatable {
    case emptySubmission
    case tooManyFiles(Int)
    case fileTooLarge(String, Int)
    case totalTooLarge(Int)
    case extractedTooLarge(String)
    case unsupportedType(String)
    case animatedGIF(String)
    case unreadable(String, String)
    case missingAsset(String)
    case preparing
    case unknownImageSupport
    case unknownDocumentSupport
    case imagesNotSupported
    case documentsNotSupported
    case incompatibleModel(String)
    case oneInvalid

    var errorDescription: String? {
        switch self {
        case .emptySubmission:
            return "Type a message or attach a file."
        case .tooManyFiles(let max):
            return "You can attach up to \(max) files in one message."
        case .fileTooLarge(let name, let bytes):
            return "\(name) is larger than \(Self.megabytes(bytes)). Choose a smaller file."
        case .totalTooLarge(let bytes):
            return "These files add up to more than \(Self.megabytes(bytes)). Remove one and try again."
        case .extractedTooLarge(let name):
            return "\(name) is too large to extract. Attach a smaller file."
        case .unsupportedType(let name):
            return "\(name) isn’t a supported attachment. Use PNG, JPEG, WebP, GIF, PDF, text, CSV, or xlsx."
        case .animatedGIF(let name):
            return "\(name) is an animated GIF. Attach a still image instead."
        case .unreadable(let name, let reason):
            return "Couldn’t read \(name). \(reason)"
        case .missingAsset(let name):
            return "\(name) is missing from Membrae’s file storage. Remove it and attach the file again."
        case .preparing:
            return "Wait for attachments to finish preparing."
        case .unknownImageSupport:
            return "This model’s image support isn’t configured. Set it in Settings before sending images."
        case .unknownDocumentSupport:
            return "This model’s file support isn’t configured. Set it in Settings, or use a connection that extracts the file."
        case .imagesNotSupported:
            return "This model or connection can’t accept images."
        case .documentsNotSupported:
            return "This connection can’t accept that file. Remove it or use a connection that can extract it."
        case .incompatibleModel(let detail):
            return detail
        case .oneInvalid:
            return "Fix or remove the file that failed before sending."
        }
    }

    private static func megabytes(_ bytes: Int) -> String {
        "\(bytes / 1_048_576) MB"
    }
}
