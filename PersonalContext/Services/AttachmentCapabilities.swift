import Foundation

enum CapabilityValue: String, Codable, Equatable, Sendable, Hashable {
    case supported
    case unsupported
    case unknown
}

enum CapabilitySource: String, Codable, Equatable, Sendable {
    case adapter
    case endpoint
    case maintained
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
        applyMaintained(to: &snapshot, provider: provider, model: model)
        return snapshot
    }

    private static func applyMaintained(
        to snapshot: inout CapabilitySnapshot,
        provider: TalkProvider,
        model: String
    ) {
        guard let known = MaintainedModelCapabilities.lookup(provider: provider, model: model) else { return }
        if snapshot.imageSource != .user, snapshot.image == .unknown {
            snapshot.image = known.image
            snapshot.imageSource = .maintained
        }
        if snapshot.documentSource != .user, snapshot.document == .unknown {
            snapshot.document = known.document
            snapshot.documentSource = .maintained
        }
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

enum MaintainedModelCapabilities {
    struct Record: Equatable, Sendable {
        var image: CapabilityValue
        var document: CapabilityValue
    }

    static func lookup(provider: TalkProvider, model: String) -> Record? {
        let key = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch provider {
        case .chatgpt:
            return chatGPT[key] ?? datedFamily(key, in: chatGPT)
        case .cursor:
            return cursor[key] ?? datedFamily(key, in: cursor)
        case .compatible, .unconfigured:
            return nil
        }
    }

    private static func datedFamily(_ key: String, in table: [String: Record]) -> Record? {
        guard let range = key.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) else {
            return nil
        }
        return table[String(key[..<range.lowerBound])]
    }

    private static let visionFiles = Record(image: .supported, document: .supported)
    private static let textOnly = Record(image: .unsupported, document: .unsupported)
    private static let cursorImages = Record(image: .supported, document: .unsupported)

    private static let chatGPT: [String: Record] = {
        var table: [String: Record] = [
            "gpt-3.5-turbo": textOnly,
            "gpt-3.5-turbo-16k": textOnly,
            "gpt-3.5-turbo-0125": textOnly,
            "gpt-3.5-turbo-1106": textOnly,
            "gpt-4": textOnly,
            "gpt-4-0314": textOnly,
            "gpt-4-0613": textOnly,
            "gpt-4-32k": textOnly,
            "o1-preview": textOnly,
            "o1-mini": textOnly,
        ]
        for id in [
            "auto",
            "chatgpt-4o-latest",
            "chatgpt-latest",
            "gpt-4-turbo",
            "gpt-4-turbo-preview",
            "gpt-4-vision-preview",
            "gpt-4.1",
            "gpt-4.1-mini",
            "gpt-4.1-nano",
            "gpt-4.5",
            "gpt-4.5-preview",
            "gpt-4o",
            "gpt-4o-mini",
            "gpt-5",
            "gpt-5-chat",
            "gpt-5-codex",
            "gpt-5-mini",
            "gpt-5-nano",
            "gpt-5-pro",
            "gpt-5-thinking",
            "gpt-5.1",
            "gpt-5.1-codex",
            "gpt-5.1-thinking",
            "gpt-5.2",
            "gpt-5.2-thinking",
            "gpt-5.4",
            "gpt-5.5",
            "gpt-5.5-thinking",
            "gpt-6",
            "gpt-6.1",
            "gpt-6.1-sol",
            "gpt-6.1-thinking",
            "gpt-6-1-sol",
            "o1",
            "o3",
            "o3-deep-research",
            "o3-mini",
            "o3-pro",
            "o4-mini",
            "o4-mini-high",
        ] {
            table[id] = visionFiles
        }
        return table
    }()

    private static let cursor: [String: Record] = {
        var table: [String: Record] = [
            "": cursorImages,
        ]
        for id in [
            "claude-4-opus",
            "claude-4-sonnet",
            "claude-4.5-haiku",
            "claude-4.5-opus",
            "claude-4.5-sonnet",
            "claude-4.6-opus",
            "claude-4.6-sonnet",
            "claude-4.6-sonnet-medium-thinking",
            "claude-opus-4",
            "claude-opus-4-1",
            "claude-opus-4-6",
            "claude-sonnet-4",
            "claude-sonnet-4-5",
            "claude-sonnet-4-6",
            "composer-1",
            "composer-1.5",
            "composer-2",
            "cursor-fast",
            "cursor-small",
            "gemini-2.5-flash",
            "gemini-2.5-pro",
            "gemini-3-flash",
            "gemini-3-pro",
            "gpt-4.1",
            "gpt-5",
            "gpt-5-codex",
            "gpt-5-mini",
            "gpt-5.1",
            "gpt-5.1-codex",
            "gpt-5.2",
            "gpt-5.3",
            "gpt-5.4",
            "gpt-5.5",
            "grok-4",
            "grok-4-fast",
            "grok-code",
            "grok-code-fast-1",
        ] {
            table[id] = cursorImages
        }
        return table
    }()
}
