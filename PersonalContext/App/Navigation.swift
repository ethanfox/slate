import SwiftUI

enum Destination: Hashable, Codable {
    case home
    case projects
    case tasks
    case calendar
    case chats
    case runs
    case settings
    case project(UUID)
    case quickAsk(UUID)
    case run(UUID)
}
enum ProjectTab: String, CaseIterable, Identifiable, Hashable, Codable {
    case overview
    case tasks
    case threads
    case notes
    case decisions
    case chat
    case runs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .tasks: "Tasks"
        case .threads: "Tracks"
        case .notes: "Notes"
        case .decisions: "Decisions"
        case .chat: "Chat"
        case .runs: "Runs"
        }
    }
}

enum ProjectColumnSection: String, CaseIterable, Identifiable, Hashable {
    case runs
    case chats
    case tracks
    case notes
    case decisions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .runs: "Runs"
        case .chats: "Chats"
        case .tracks: "Tracks"
        case .notes: "Notes"
        case .decisions: "Decisions"
        }
    }

    var symbol: String {
        switch self {
        case .runs: "play.circle"
        case .chats: "bubble.left"
        case .tracks: TrackStyle.symbol
        case .notes: "note.text"
        case .decisions: "checkmark.seal"
        }
    }

    var tab: ProjectTab {
        switch self {
        case .runs: .runs
        case .chats: .chat
        case .tracks: .threads
        case .notes: .notes
        case .decisions: .decisions
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

enum ProjectTasksLayout: String, CaseIterable, Identifiable, Hashable {
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

enum ProjectsLayout: String, CaseIterable, Identifiable, Hashable {
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

enum ProjectSort: String, CaseIterable, Identifiable, Hashable {
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
    case chatgpt
    case cursor
    case sources
    case calendar
    case tags
    case appearance
    case model
    case orb
    case developer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chatgpt: "ChatGPT"
        case .cursor: "Cursor"
        case .sources: "Sources"
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
        case .chatgpt: "bubble.left"
        case .cursor: "sparkle"
        case .sources: "link"
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
}

enum TalkProvider: String, CaseIterable, Identifiable, Hashable {
    case unconfigured
    case chatgpt
    case cursor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unconfigured: "Choose provider"
        case .chatgpt: "ChatGPT"
        case .cursor: "Cursor"
        }
    }

    var mark: BrandMark? {
        switch self {
        case .unconfigured: nil
        case .chatgpt: .chatgpt
        case .cursor: .cursor
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
