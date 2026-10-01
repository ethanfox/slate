import SwiftUI

enum Destination: Hashable {
    case home
    case projects
    case tasks
    case calendar
    case settings
    case project(UUID)
    case quickAsk(UUID)
}
enum ProjectTab: String, CaseIterable, Identifiable, Hashable {
    case overview
    case threads
    case notes
    case decisions
    case chat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .threads: "Tracks"
        case .notes: "Notes"
        case .decisions: "Decisions"
        case .chat: "Chat"
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

    var symbol: String {
        switch self {
        case .oneThird: "rectangle.portrait"
        case .twoThirds: "rectangle.lefthalf.inset.filled"
        case .full: "rectangle"
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
    case cursor
    case calendar
    case tags
    case appearance
    case orb
    case developer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cursor: "Cursor"
        case .calendar: "Calendar"
        case .tags: "Tags"
        case .appearance: "Appearance"
        case .orb: "Orb"
        case .developer: "Developer"
        }
    }

    var symbol: String {
        switch self {
        case .cursor: "sparkle"
        case .calendar: "calendar"
        case .tags: "tag"
        case .appearance: "circle.lefthalf.filled"
        case .orb: "circle.circle"
        case .developer: "hammer"
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
