import SwiftUI

enum OrbState: String, CaseIterable, Identifiable, Hashable {
    case idle
    case thinking
    case streaming
    case working
    case error

    var id: String { rawValue }

    var title: String {
        switch self {
        case .idle: "Ready"
        case .thinking: "Thinking"
        case .streaming: "Writing"
        case .working: "Working"
        case .error: "Error"
        }
    }

    var status: String {
        switch self {
        case .idle: "Ready"
        case .thinking: "Thinking…"
        case .streaming: "Writing…"
        case .working: "Working…"
        case .error: "Something went wrong"
        }
    }

    var isBusy: Bool {
        switch self {
        case .thinking, .streaming, .working: true
        case .idle, .error: false
        }
    }

}

