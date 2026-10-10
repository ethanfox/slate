import AppKit
import ImageIO
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ComposerAttachment: Identifiable, Equatable {
    var id: UUID
    var filename: String
    var mimeType: String
    var kind: ChatAttachmentRef.Kind
    var status: Status
    var disclosure: String?

    enum Status: Equatable {
        case preparing
        case ready
        case failed(String)
    }

    var ref: ChatAttachmentRef {
        ChatAttachmentRef(id: id, kind: kind, filename: filename, mimeType: mimeType)
    }

    var isReady: Bool {
        if case .ready = status { return true }
        return false
    }
}

struct ComposerAttachmentStrip: View {
    var attachments: [ComposerAttachment]
    var onRemove: (UUID) -> Void

    var body: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachments) { item in
                        ComposerAttachmentChip(item: item, onRemove: { onRemove(item.id) })
                    }
                }
            }
            .accessibilityElement(children: .contain)
        }
    }
}

private struct ComposerAttachmentChip: View {
    var item: ComposerAttachment
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if item.kind == .image {
                AttachmentThumbnail(id: item.id, failed: itemFailed)
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 11, weight: .medium))
            }
            Text(item.filename)
                .font(CraftFont.caption)
                .lineLimit(1)
            if case .preparing = item.status {
                ProgressView().controlSize(.mini)
            }
            if case .failed(let message) = item.status {
                Image(systemName: "exclamationmark.triangle")
                    .help(message)
            }
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(item.filename)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(CraftColor.canvas, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(itemFailed ? Color.red.opacity(0.5) : CraftColor.hairline)
        )
        .foregroundStyle(itemFailed ? .red : .secondary)
    }

    private var itemFailed: Bool {
        if case .failed = item.status { return true }
        return false
    }
}

private struct AttachmentThumbnail: View {
    var id: UUID
    var failed = false
    var size: CGFloat = 28
    @Environment(\.modelContext) private var context
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
            } else {
                Image(systemName: failed ? "exclamationmark.triangle" : "photo")
                    .font(.system(size: 11, weight: .medium))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .task(id: id) {
            image = AttachmentPreview.thumbnail(id: id, context: context)
        }
    }
}

enum AttachmentPreview {
    static func thumbnail(id: UUID, context: ModelContext, maxPixelSize: Int = 72) -> NSImage? {
        let store = FileStore.default(context: context)
        guard let asset = store.asset(id: id) else { return nil }
        return thumbnail(url: store.resolve(asset), maxPixelSize: maxPixelSize)
    }

    static func thumbnail(url: URL, maxPixelSize: Int = 72) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            return NSImage(contentsOf: url)
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return NSImage(contentsOf: url)
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

struct HistoryAttachmentStrip: View {
    var attachments: [ChatAttachmentRef]
    @Environment(\.modelContext) private var context

    var body: some View {
        if !attachments.isEmpty {
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(attachments) { attachment in
                    HistoryAttachmentChip(attachment: attachment, context: context)
                }
            }
        }
    }
}

private struct HistoryAttachmentChip: View {
    var attachment: ChatAttachmentRef
    var context: ModelContext
    @State private var missing = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                if attachment.kind == .image {
                    AttachmentThumbnail(id: attachment.id, failed: missing, size: 32)
                } else {
                    Image(systemName: missing ? "exclamationmark.triangle" : "doc")
                }
                Text(missing ? "\(attachment.filename) is missing" : attachment.filename)
                    .lineLimit(1)
            }
            .font(CraftFont.caption)
            .foregroundStyle(missing ? .red : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(CraftColor.canvas, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(CraftColor.hairline))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(missing ? "\(attachment.filename) is missing" : "Open \(attachment.filename)")
        .onAppear { missing = !exists }
    }

    private var exists: Bool {
        let store = FileStore.default(context: context)
        guard let asset = store.asset(id: attachment.id) else { return false }
        return FileManager.default.fileExists(atPath: store.resolve(asset).path)
    }

    private func open() {
        let store = FileStore.default(context: context)
        guard let asset = store.asset(id: attachment.id) else {
            missing = true
            return
        }
        let url = store.resolve(asset)
        guard FileManager.default.fileExists(atPath: url.path) else {
            missing = true
            return
        }
        NSWorkspace.shared.open(url)
    }
}

enum ComposerImport {
    static let types: [UTType] = [
        .png, .jpeg, .gif, .pdf, .plainText, .commaSeparatedText,
        UTType(filenameExtension: "webp") ?? .image,
        UTType(filenameExtension: "xlsx") ?? .data,
        .sourceCode, .json
    ]

    @MainActor
    static func importURLs(
        _ urls: [URL],
        into attachments: inout [ComposerAttachment],
        ownerKind: AssetOwnerKind,
        ownerID: UUID,
        context: ModelContext
    ) {
        let store = FileStore.default(context: context)
        for url in urls {
            let placeholder = ComposerAttachment(
                id: UUID(),
                filename: url.lastPathComponent,
                mimeType: "application/octet-stream",
                kind: .file,
                status: .preparing
            )
            attachments.append(placeholder)
            do {
                let asset = try store.importFile(url: url, ownerKind: ownerKind, ownerID: ownerID, orderIndex: attachments.count - 1)
                if let index = attachments.firstIndex(where: { $0.id == placeholder.id }) {
                    attachments[index] = ComposerAttachment(
                        id: asset.id,
                        filename: asset.filename,
                        mimeType: asset.mediaType,
                        kind: asset.kind,
                        status: .ready,
                        disclosure: disclosure(for: asset)
                    )
                }
            } catch {
                if let index = attachments.firstIndex(where: { $0.id == placeholder.id }) {
                    attachments[index].status = .failed(error.localizedDescription)
                }
            }
        }
    }

    @MainActor
    static func importData(
        _ data: Data,
        filename: String,
        into attachments: inout [ComposerAttachment],
        ownerKind: AssetOwnerKind,
        ownerID: UUID,
        context: ModelContext
    ) {
        let store = FileStore.default(context: context)
        do {
            let asset = try store.importData(
                data,
                filename: filename,
                ownerKind: ownerKind,
                ownerID: ownerID,
                orderIndex: attachments.count
            )
            attachments.append(
                ComposerAttachment(
                    id: asset.id,
                    filename: asset.filename,
                    mimeType: asset.mediaType,
                    kind: asset.kind,
                    status: .ready,
                    disclosure: disclosure(for: asset)
                )
            )
        } catch {
            attachments.append(
                ComposerAttachment(
                    id: UUID(),
                    filename: filename,
                    mimeType: "application/octet-stream",
                    kind: .file,
                    status: .failed(error.localizedDescription)
                )
            )
        }
    }

    static func disclosure(for asset: StoredAsset) -> String? {
        if asset.kind == .image { return nil }
        if asset.mediaType == "application/pdf" {
            return "PDF text will be extracted unless this connection sends the file natively. Images and layout are not included when extracted."
        }
        if asset.mediaType.contains("spreadsheet") {
            return "Spreadsheet values will be extracted. Formatting, charts, and macros are excluded."
        }
        return "Membrae will send the text of \(asset.filename) when the connection has no native file input."
    }
}
