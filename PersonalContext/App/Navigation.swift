import SwiftUI

struct NavSelection: Equatable {
    var destination: Destination = .home
    var thread: UUID?
    var note: UUID?
    var decision: UUID?
    var conversation: UUID?
    var run: UUID?
}

enum Destination: Hashable, Codable {
    case home
    case spaces
    case tasks
    case calendar
    case chats
    case runs
    case settings
    /// A Space, on whichever of its sections the tab holds.
    case space(UUID)
    case quickAsk(UUID)
    case run(UUID)
    case aboutYou
    case context
    case spaceRecord(space: UUID, record: UUID)
    case library
}

/// What a Space's tab shows: its page, or one kind of thing in it.
enum SpaceTab: String, CaseIterable, Identifiable, Hashable, Codable {
    case overview
    case tasks
    case threads
    case sessions
    case notes
    case decisions
    case chat
    case runs

    var id: String { rawValue }

    /// The icon a window tab shows while this section is open.
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .tasks: "checklist"
        case .threads: TrackSymbol.name
        case .sessions: "clock"
        case .notes: "note.text"
        case .decisions: "checkmark.seal"
        case .chat: "bubble.left"
        case .runs: "play.circle"
        }
    }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .tasks: "Tasks"
        case .threads: "Tracks"
        case .sessions: "Sessions"
        case .notes: "Notes"
        case .decisions: "Decisions"
        case .chat: "Chat"
        case .runs: "Runs"
        }
    }
}

enum OverviewWidth: String, CaseIterable, Identifiable, Hashable {
    case oneThird
    case twoThirds
    case full

    var id: String { rawValue }

    var fraction: CGFloat {
        switch self {
        case .oneThird: 1.0 / 3.0
        case .twoThirds: 2.0 / 3.0
        case .full: 1
        }
    }

    var label: String {
        switch self {
        case .oneThird: "One Third"
        case .twoThirds: "Two Thirds"
        case .full: "Full"
        }
    }

    var compactLabel: String {
        switch self {
        case .oneThird: "1/3"
        case .twoThirds: "2/3"
        case .full: "Full"
        }
    }
}

/// Which track's tasks a Space's board shows.
enum TaskTrackFilter: Hashable {
    /// The Space's active track, or every task when it has none.
    case active
    case all
    case track(UUID)
}

enum SpaceTasksLayout: String, CaseIterable, Identifiable, Hashable {
    case kanban
    case list

    var id: String { rawValue }

    var label: String {
        switch self {
        case .kanban: "Kanban"
        case .list: "List"
        }
    }

    var symbol: String {
        switch self {
        case .kanban: "rectangle.split.3x1"
        case .list: "list.bullet"
        }
    }
}

enum SpacesLayout: String, CaseIterable, Identifiable, Hashable {
    case table
    case card

    var id: String { rawValue }

    var label: String {
        switch self {
        case .table: "Table"
        case .card: "Cards"
        }
    }

    var symbol: String {
        switch self {
        case .table: "tablecells"
        case .card: "square.grid.2x2"
        }
    }
}

enum SpaceSort: String, CaseIterable, Identifiable, Hashable {
    case name
    case status
    case updated
    case created

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: "Name"
        case .status: "Status"
        case .updated: "Updated"
        case .created: "Created"
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case account
    case chatgpt
    case cursor
    case compatible
    case claudeCode
    case codex
    case importRelay
    case sources
    case mcp
    case browser
    case calendar
    case tags
    case appearance
    case model
    case orb
    case developer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .account: "Account"
        case .chatgpt: "ChatGPT"
        case .cursor: "Cursor"
        case .compatible: "Compatible endpoint"
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .importRelay: "Import"
        case .sources: "Sources"
        case .mcp: "MCP"
        case .browser: "Browser"
        case .calendar: "Calendar"
        case .tags: "Tags"
        case .appearance: "Appearance"
        case .model: "Chat model"
        case .orb: "Orb"
        case .developer: "Developer"
        }
    }

    var symbol: String {
        switch self {
        case .account: "person.crop.circle"
        case .chatgpt: "bubble.left"
        case .cursor: "sparkle"
        case .compatible: "link.circle"
        case .claudeCode, .codex: "terminal"
        case .importRelay: "square.and.arrow.down"
        case .sources: "link"
        case .mcp: "cable.connector"
        case .browser: "globe"
        case .calendar: "calendar"
        case .tags: "tag"
        case .appearance: "circle.lefthalf.filled"
        case .model: "cpu"
        case .orb: "circle.circle"
        case .developer: "hammer"
        }
    }

    var mark: BrandMark? {
        switch self {
        case .chatgpt: .chatgpt
        case .cursor: .cursor
        default: nil
        }
    }

    /// The AIs a user connects. The rest of Settings is always there.
    static let providers: [SettingsSection] = [.chatgpt, .cursor, .compatible, .claudeCode, .codex]

    var localAgent: LocalAgent? {
        switch self {
        case .claudeCode: .claudeCode
        case .codex: .codex
        default: nil
        }
    }
}

enum TalkProvider: String, CaseIterable, Identifiable, Hashable {
    case unconfigured
    case chatgpt
    case cursor
    case compatible
    /// Apple's on-device model. Free and on from the start where the Mac has it.
    case apple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unconfigured: "Choose provider"
        case .chatgpt: "ChatGPT"
        case .cursor: "Cursor"
        case .compatible: "Compatible endpoint"
        case .apple: "Apple Intelligence"
        }
    }

    var mark: BrandMark? {
        switch self {
        case .unconfigured: nil
        case .chatgpt: .chatgpt
        case .cursor: .cursor
        case .compatible, .apple: nil
        }
    }
}

enum AppearancePreference: String, CaseIterable, Identifiable, Hashable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AccentPreference: String, CaseIterable, Identifiable, Hashable {
    case system
    case blue
    case purple
    case pink
    case red
    case orange
    case yellow
    case green
    case graphite

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .blue: "Blue"
        case .purple: "Purple"
        case .pink: "Pink"
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .graphite: "Graphite"
        }
    }

    var color: Color {
        switch self {
        case .system: Color(nsColor: .controlAccentColor)
        case .blue: Color(red: 0, green: 0.478, blue: 1)
        case .purple: Color(red: 0.686, green: 0.322, blue: 0.871)
        case .pink: Color(red: 1, green: 0.176, blue: 0.333)
        case .red: Color(red: 1, green: 0.231, blue: 0.188)
        case .orange: Color(red: 1, green: 0.584, blue: 0)
        case .yellow: Color(red: 1, green: 0.8, blue: 0)
        case .green: Color(red: 0.157, green: 0.804, blue: 0.255)
        case .graphite: Color(red: 0.557, green: 0.557, blue: 0.576)
        }
    }
}

enum AccentedView: String, CaseIterable, Identifiable, Hashable {
    case calendar

    var id: String { rawValue }

    var label: String {
        switch self {
        case .calendar: "Calendar"
        }
    }

    var defaultLabel: String {
        switch self {
        case .calendar: "Off keeps the header and today marker red"
        }
    }

    var defaultColor: Color {
        switch self {
        case .calendar: AccentPreference.red.color
        }
    }
}

/// The tracks icon, in one place for the tab strip, the pills, and the lists.
enum TrackSymbol {
    static let name = "point.topleft.down.to.point.bottomright.curvepath"
}

extension TitleIndexKind {
    /// The Space section that lists this kind.
    var sectionTab: SpaceTab {
        switch self {
        case .track: .threads
        case .note: .notes
        case .decision: .decisions
        case .chat: .chat
        case .run: .runs
        default: .overview
        }
    }
}
