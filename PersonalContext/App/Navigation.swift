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
    case list
    case table

    var id: String { rawValue }

    var label: String {
        switch self {
        case .list: "List"
        case .table: "Table"
        }
    }

    var symbol: String {
        switch self {
        case .list: "list.bullet"
        case .table: "tablecells"
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
