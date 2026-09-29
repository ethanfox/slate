import SwiftUI

struct EventKitAccessLine: View {
    var text: String
    var actionTitle: String
    var action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            EmptyLine(text: text)
            Button(actionTitle, action: action)
        }
    }
}
