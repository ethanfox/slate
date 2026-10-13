import AppKit
import SwiftData
import SwiftUI

/// One thing the user's context is made of: a row on the context page and a cell in the membrane.
struct ContextItem: Identifiable, Equatable {
    var id: String
    var name: String
    var detail: String
    var hex: String
    /// How much it holds, which sets the size of its cell.
    var count: Int
    var destination: Destination
    var kind = Kind.you

    enum Kind: String, CaseIterable {
        case you, project, area, library, assistant

        /// The color for everything of this kind when the membrane is too small to show each thing.
        var hex: String {
            switch self {
            case .you: ""
            case .project: "007AFF"
            case .area: "E8643A"
            case .library: "EDAD38"
            case .assistant: "10A37F"
            }
        }
    }
    /// What Membrae knows about the user. The logo's own cells stand for it.
    var isYou = false

    /// Colors for things that have none of their own.
    private static let palette = ["E8643A", "4A55D8", "1F5E63", "007AFF", "EDAD38", "C74585", "54A16B"]

    static func color(for id: UUID) -> String {
        palette[Int(id.uuid.0 ^ id.uuid.15) % palette.count]
    }

    var thing: MembraneThing {
        Self.thing(id: id, hex: hex, count: count)
    }

    private static func thing(id: String, hex: String, count: Int) -> MembraneThing {
        let value = UInt32(hex, radix: 16) ?? 0
        let color = SIMD3(Double(value >> 16 & 0xFF), Double(value >> 8 & 0xFF), Double(value & 0xFF)) / 255
        return MembraneThing(id: id, color: color, weight: min(0.55 + 0.22 * log2(1 + Double(count)), 1.7))
    }

    /// One cell for each kind of thing, sized by how many there are.
    static func grouped(_ items: [ContextItem]) -> [MembraneThing] {
        Kind.allCases.compactMap { kind in
            let count = items.count { $0.kind == kind }
            guard kind != .you, count > 0 else { return nil }
            return thing(id: kind.rawValue, hex: kind.hex, count: count)
        }
    }
}

/// Reads everything Membrae holds for the user and lists it.
struct ContextItems: DynamicProperty {
    @Environment(AppModel.self) private var app
    @Query(sort: \Project.createdAt) private var projects: [Project]
    @Query private var titles: [TitleIndex]
    @Query(sort: \Space.createdAt) private var spaces: [Space]
    @Query private var records: [SpaceRecord]
    @Query private var facts: [PersonalFact]
    @Query private var sources: [SavedSource]

    @MainActor var all: [ContextItem] {
        var items = [ContextItem(
            id: "you", name: "About you", detail: Self.counted(facts.count, "thing") + " Membrae knows",
            hex: "", count: facts.count, destination: .aboutYou, isYou: true
        )]

        var held: [String: [TitleIndexKind: Int]] = [:]
        for title in titles where !title.projectIDString.isEmpty {
            held[title.projectIDString, default: [:]][title.kind, default: 0] += 1
        }
        for project in projects {
            let counts = held[project.id.uuidString.lowercased()] ?? [:]
            let parts = [(TitleIndexKind.note, "note"), (.decision, "decision"), (.task, "task")]
                .compactMap { kind, word in counts[kind].map { Self.counted($0, word) } }
            items.append(ContextItem(
                id: project.id.uuidString, name: project.name,
                detail: (["Project"] + [parts.joined(separator: ", ")].filter { !$0.isEmpty }).joined(separator: " · "),
                hex: ContextItem.color(for: project.id), count: counts.values.reduce(0, +),
                destination: .project(project.id), kind: .project
            ))
        }

        let filed = Dictionary(grouping: records, by: \.spaceIDString).mapValues(\.count)
        for space in spaces {
            let count = filed[space.id.uuidString] ?? filed[space.id.uuidString.lowercased()] ?? 0
            items.append(ContextItem(
                id: space.id.uuidString, name: space.displayName, detail: "Area · " + Self.counted(count, "thing"),
                hex: space.gradient.accent.hexString, count: count, destination: .space(space.id),
                kind: .area
            ))
        }

        if !sources.isEmpty {
            items.append(ContextItem(
                id: "library", name: "Library", detail: Self.counted(sources.count, "saved source"),
                hex: "B08A4A", count: sources.count, destination: .library, kind: .library
            ))
        }

        let assistants: [(String, String, String)] = [
            (TalkProvider.chatgpt.rawValue, TalkProvider.chatgpt.title, "10A37F"),
            (TalkProvider.cursor.rawValue, TalkProvider.cursor.title, "7A7A85"),
            (TalkProvider.compatible.rawValue, TalkProvider.compatible.title, "8E6AD8"),
            (LocalAgent.claudeCode.rawValue, LocalAgent.claudeCode.title, "D97757"),
            (LocalAgent.codex.rawValue, LocalAgent.codex.title, "2E9E8F"),
        ]
        for (id, name, hex) in assistants where app.providerConnected(id) {
            items.append(ContextItem(
                id: "ai-" + id, name: name, detail: "Your AI · connected", hex: hex, count: 3, destination: .settings,
                kind: .assistant
            ))
        }
        return items
    }

    private static func counted(_ count: Int, _ word: String) -> String {
        "\(count) \(word)\(count == 1 ? "" : "s")"
    }
}

/// The user's own membrane: the logo's cells for them, and one cell for each thing they have.
struct ContextMembrane: View {
    var items: [ContextItem]
    /// Small: one cell for each kind of thing, and nearly still. Otherwise a cell for each thing, drifting slowly.
    var isCompact = false
    @State private var model = MembraneModel()

    private var things: [MembraneThing] {
        isCompact ? ContextItem.grouped(items) : items.filter { !$0.isYou }.map(\.thing)
    }

    var body: some View {
        MembraneView(model: model, frameInterval: isCompact ? 1.0 / 30 : nil)
            .onChange(of: things, initial: true) { _, things in
                model.motion = isCompact ? 0.16 : 0.4
                model.grain = 0.14
                model.sync(things)
            }
    }
}

/// How much room the user's context takes on this Mac.
struct ContextStorage: Equatable, Sendable {
    var database: Int64 = 0
    var files: Int64 = 0

    var total: Int64 { database + files }

    static func measure(_ folder: URL) -> ContextStorage {
        var storage = ContextStorage()
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else {
            return storage
        }
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                continue
            }
            let size = Int64(values.totalFileAllocatedSize ?? 0)
            if file.lastPathComponent.hasPrefix("default.store") {
                storage.database += size
            } else {
                storage.files += size
            }
        }
        return storage
    }

    static func label(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// What the user's context consists of, and how much room it takes. Opened from the membrane on You.
struct ContextView: View {
    @Environment(AppModel.self) private var app
    private var context = ContextItems()
    @State private var storage: ContextStorage?

    private var folder: URL? {
        Store.applicationGroupStoreURL?.deletingLastPathComponent()
    }

    var body: some View {
        let items = context.all
        ScrollView {
            PageBody {
                HStack(alignment: .top, spacing: 56) {
                    ContextMembrane(items: items)
                        .frame(width: 300, height: 300)
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Your context")
                                .font(.system(size: 28, weight: .semibold))
                            Text("Everything Membrae holds for you. Each cell is one of these.")
                                .font(CraftFont.body)
                                .foregroundStyle(.secondary)
                        }
                        list(items)
                        storageSection
                    }
                    .frame(maxWidth: 560, alignment: .leading)
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity)
            }
        }
        .scrollContentBackground(.hidden)
        .task {
            guard let folder else { return }
            storage = await Task.detached(priority: .utility) { ContextStorage.measure(folder) }.value
        }
    }

    private func list(_ items: [ContextItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                Button {
                    app.navigate(to: item.destination)
                } label: {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(item.isYou ? Color.primary : Color(hex: item.hex))
                            .frame(width: 14, height: 14)
                        Text(item.name)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .frame(width: 150, alignment: .leading)
                        Text(item.detail)
                            .font(CraftFont.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if item.id != items.last?.id {
                    Hairline()
                }
            }
        }
        .background(CraftColor.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(CraftColor.hairline))
    }

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Storage")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if let storage {
                    Text("\(ContextStorage.label(storage.total)) on this Mac")
                        .font(CraftFont.body)
                        .foregroundStyle(.secondary)
                }
            }
            if let storage, storage.total > 0 {
                GeometryReader { proxy in
                    HStack(spacing: 2) {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: max(proxy.size.width * Double(storage.database) / Double(storage.total) - 1, 2))
                        Rectangle()
                            .fill(Color.secondary.opacity(0.5))
                    }
                }
                .frame(height: 10)
                .clipShape(Capsule())
            }
            HStack(alignment: .center) {
                if let storage {
                    Text("Notes, decisions, tasks and chats \(ContextStorage.label(storage.database)) · Files and pictures \(ContextStorage.label(storage.files))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if let folder {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                }
            }
        }
    }
}
