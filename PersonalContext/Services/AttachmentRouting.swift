import Foundation

enum AttachmentRoute: Equatable, Sendable {
    case nativeImage
    case nativeFile
    case extracted(ExtractedAttachment)
}

struct PreparedAttachment: Equatable, Sendable {
    var ref: ChatAttachmentRef
    var data: Data
    var route: AttachmentRoute
}

struct ChatTurnOptions: Sendable, Equatable {
    var attachments: [PreparedAttachment] = []

    init(attachments: [PreparedAttachment] = []) {
        self.attachments = attachments
    }

    func payload(for id: UUID) -> PreparedAttachment? {
        attachments.first { $0.ref.id == id }
    }
}

enum AttachmentPrep {
    static func validateCountAndSize(_ refs: [ChatAttachmentRef], store: FileStore) throws -> [StoredAsset] {
        if refs.count > AttachmentLimits.maxFiles {
            throw AttachmentError.tooManyFiles(AttachmentLimits.maxFiles)
        }
        var assets: [StoredAsset] = []
        var total = 0
        for ref in refs {
            guard let asset = store.asset(id: ref.id) else {
                throw AttachmentError.missingAsset(ref.filename)
            }
            total += asset.byteSize
            if asset.byteSize > AttachmentLimits.maxFileBytes {
                throw AttachmentError.fileTooLarge(asset.filename, AttachmentLimits.maxFileBytes)
            }
            assets.append(asset)
        }
        if total > AttachmentLimits.maxTotalBytes {
            throw AttachmentError.totalTooLarge(AttachmentLimits.maxTotalBytes)
        }
        return assets
    }

    static func prepare(
        refs: [ChatAttachmentRef],
        history: [TalkMessage],
        provider: TalkProvider,
        model: String,
        endpoint: String,
        store: FileStore,
        includeHistory: Bool,
        defaults: UserDefaults = .standard
    ) throws -> [PreparedAttachment] {
        var needed = refs
        if includeHistory {
            for message in history {
                needed.append(contentsOf: message.attachments)
            }
        }
        var seen = Set<UUID>()
        needed = needed.filter { seen.insert($0.id).inserted }
        let assets = try validateCountAndSize(needed, store: store)
        let capability = AttachmentCapabilityStore.snapshot(
            provider: provider,
            model: model,
            endpoint: endpoint,
            defaults: defaults
        )
        let adapter = AttachmentCapabilityStore.adapter(for: provider, endpoint: endpoint)
        var prepared: [PreparedAttachment] = []
        var extractedCharacters = 0
        for asset in assets {
            let data = try store.read(asset)
            let route = try route(
                asset: asset,
                data: data,
                provider: provider,
                adapter: adapter,
                capability: capability
            )
            if case .extracted(let extracted) = route {
                extractedCharacters += extracted.text.count
                if extractedCharacters > AttachmentLimits.maxExtractedCharacters {
                    throw AttachmentError.extractedTooLarge(asset.filename)
                }
            }
            prepared.append(PreparedAttachment(ref: asset.reference, data: data, route: route))
        }
        return prepared
    }

    static func disclosures(in prepared: [PreparedAttachment]) -> [String] {
        prepared.compactMap { item in
            if case .extracted(let extracted) = item.route { return extracted.disclosure }
            return nil
        }
    }

    static func labelledExtraction(in prepared: [PreparedAttachment]) -> String {
        prepared.compactMap { item -> String? in
            guard case .extracted(let extracted) = item.route else { return nil }
            return "Attached file: \(extracted.filename)\n\(extracted.text)"
        }.joined(separator: "\n\n")
    }

    private static func route(
        asset: StoredAsset,
        data: Data,
        provider: TalkProvider,
        adapter: AdapterCapabilities,
        capability: CapabilitySnapshot
    ) throws -> AttachmentRoute {
        if asset.kind == .image {
            guard adapter.images else { throw AttachmentError.imagesNotSupported }
            switch capability.image {
            case .supported:
                return .nativeImage
            case .unsupported:
                throw AttachmentError.imagesNotSupported
            case .unknown:
                throw AttachmentError.unknownImageSupport
            }
        }

        let wantsNative = adapter.nativeDocuments && capability.document == .supported
        if wantsNative {
            return .nativeFile
        }
        if capability.document == .unknown, adapter.nativeDocuments, !adapter.extraction {
            throw AttachmentError.unknownDocumentSupport
        }
        if adapter.extraction {
            let extracted = try FileExtraction.extract(
                filename: asset.filename,
                mimeType: asset.mediaType,
                data: data
            )
            return .extracted(extracted)
        }
        if capability.document == .unknown {
            throw AttachmentError.unknownDocumentSupport
        }
        throw AttachmentError.documentsNotSupported
    }
}
