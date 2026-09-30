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
    case appearance
    case orb
    case developer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cursor: "Cursor"
        case .calendar: "Calendar"
        case .appearance: "Appearance"
        case .orb: "Orb"
        case .developer: "Developer"
        }
    }

    var symbol: String {
        switch self {
        case .cursor: "sparkle"
        case .calendar: "calendar"
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
