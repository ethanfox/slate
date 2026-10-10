import Foundation

enum CapabilityValue: String, Codable, Equatable, Sendable, Hashable {
    case supported
    case unsupported
    case unknown
}

enum CapabilitySource: String, Codable, Equatable, Sendable {
    case adapter
    case endpoint
    case user
    case unknown
}

struct CapabilitySnapshot: Equatable, Sendable {
    var image: CapabilityValue
    var document: CapabilityValue
    var imageSource: CapabilitySource
    var documentSource: CapabilitySource
    var checkedAt: Date?
    var isOpenRouter = false
    var openRouterPDFParser = false

    static let unknown = CapabilitySnapshot(
        image: .unknown,
        document: .unknown,
        imageSource: .unknown,
        documentSource: .unknown
    )
}

struct AdapterCapabilities: Equatable, Sendable {
    var images: Bool
    var nativeDocuments: Bool
    var extraction: Bool
}

enum AttachmentCapabilityStore {
    static func adapter(for provider: TalkProvider, endpoint: String = "") -> AdapterCapabilities {
        switch provider {
        case .chatgpt:
            return AdapterCapabilities(images: true, nativeDocuments: true, extraction: true)
        case .cursor:
            return AdapterCapabilities(images: true, nativeDocuments: false, extraction: true)
        case .compatible:
            return AdapterCapabilities(
                images: true,
                nativeDocuments: isOpenRouter(endpoint),
                extraction: true
            )
        case .unconfigured:
            return AdapterCapabilities(images: false, nativeDocuments: false, extraction: false)
        }
    }

    static func snapshot(
        provider: TalkProvider,
        model: String,
        endpoint: String = "",
        defaults: UserDefaults = .standard
    ) -> CapabilitySnapshot {
        var snapshot = CapabilitySnapshot.unknown
        snapshot.isOpenRouter = isOpenRouter(endpoint)
        if let stored = load(provider: provider, model: model, endpoint: endpoint, defaults: defaults) {
            snapshot = stored
        }
        return snapshot
    }

    static func setUser(
        provider: TalkProvider,
        model: String,
        endpoint: String = "",
        image: CapabilityValue? = nil,
        document: CapabilityValue? = nil,
        defaults: UserDefaults = .standard
    ) {
        var current = snapshot(provider: provider, model: model, endpoint: endpoint, defaults: defaults)
        if let image {
            current.image = image
            current.imageSource = .user
        }
        if let document {
            current.document = document
            current.documentSource = .user
        }
        current.checkedAt = .now
        save(current, provider: provider, model: model, endpoint: endpoint, defaults: defaults)
    }

    static func applyEndpoint(
        provider: TalkProvider,
        model: String,
        endpoint: String,
        image: CapabilityValue,
        document: CapabilityValue,
        pdfParser: Bool,
        defaults: UserDefaults = .standard
    ) {
        var current = snapshot(provider: provider, model: model, endpoint: endpoint, defaults: defaults)
        if current.imageSource != .user {
            current.image = image
            current.imageSource = .endpoint
        }
        if current.documentSource != .user {
            current.document = document
            current.documentSource = .endpoint
        }
        current.isOpenRouter = isOpenRouter(endpoint)
        current.openRouterPDFParser = pdfParser
        current.checkedAt = .now
        save(current, provider: provider, model: model, endpoint: endpoint, defaults: defaults)
    }

    static func isOpenRouter(_ endpoint: String) -> Bool {
        let host = URL(string: endpoint)?.host?.lowercased() ?? endpoint.lowercased()
        return host.contains("openrouter.ai")
    }

    private static func key(provider: TalkProvider, model: String, endpoint: String) -> String {
        let endpointKey = endpoint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "capability.\(provider.rawValue).\(endpointKey).\(model.lowercased())"
    }

    private static func load(
        provider: TalkProvider,
        model: String,
        endpoint: String,
        defaults: UserDefaults
    ) -> CapabilitySnapshot? {
        guard let data = defaults.data(forKey: key(provider: provider, model: model, endpoint: endpoint)),
              let decoded = try? JSONDecoder().decode(Record.self, from: data)
        else { return nil }
        return CapabilitySnapshot(
            image: decoded.image,
            document: decoded.document,
            imageSource: decoded.imageSource,
            documentSource: decoded.documentSource,
            checkedAt: decoded.checkedAt,
            isOpenRouter: decoded.isOpenRouter,
            openRouterPDFParser: decoded.openRouterPDFParser
        )
    }

    private static func save(
        _ snapshot: CapabilitySnapshot,
        provider: TalkProvider,
        model: String,
        endpoint: String,
        defaults: UserDefaults
    ) {
        let record = Record(
            image: snapshot.image,
            document: snapshot.document,
            imageSource: snapshot.imageSource,
            documentSource: snapshot.documentSource,
            checkedAt: snapshot.checkedAt,
            isOpenRouter: snapshot.isOpenRouter,
            openRouterPDFParser: snapshot.openRouterPDFParser
        )
        if let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: key(provider: provider, model: model, endpoint: endpoint))
        }
    }

    private struct Record: Codable {
        var image: CapabilityValue
        var document: CapabilityValue
        var imageSource: CapabilitySource
        var documentSource: CapabilitySource
        var checkedAt: Date?
        var isOpenRouter: Bool
        var openRouterPDFParser: Bool
    }
}
