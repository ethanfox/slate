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
        case .threads: "Threads"
        case .notes: "Notes"
        case .decisions: "Decisions"
        case .chat: "Chat"
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
