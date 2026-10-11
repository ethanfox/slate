import SwiftUI

struct BrowserVerificationBanner: View {
    var challenge: BrowserChallenge
    var onOpen: () -> Void
    var onSkip: () -> Void
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Verification required")
                .font(CraftFont.section)
            Text("The browser encountered a verification challenge on \(challenge.host).")
                .font(CraftFont.body)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Open verification", action: onOpen)
                Button("Skip website", action: onSkip)
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(maxWidth: 420, alignment: .leading)
        .background(CraftColor.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
