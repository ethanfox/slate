import SwiftUI

extension ThreadKind {
    var symbol: String {
        switch self {
        case .direction: "signpost.right"
        case .feature: "square.stack.3d.up"
        case .problem: "exclamationmark.triangle"
        case .experiment: "flask"
        case .topic: "number"
        }
    }
}
