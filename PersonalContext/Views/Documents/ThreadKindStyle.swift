import SwiftUI

enum TrackStyle {
    static let symbol = "arrow.triangle.branch"
}

extension ThreadKind {
    var symbol: String {
        switch self {
        case .direction: "location.north"
        case .feature: "puzzlepiece"
        case .problem: "exclamationmark.triangle"
        case .experiment: "flask"
        case .topic: "tag"
        }
    }
}

extension ThreadStatus {
    var symbol: String {
        switch self {
        case .exploring: "binoculars"
        case .active: "play.circle"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle"
        case .rejected: "xmark.circle"
        }
    }
}
