import SwiftUI

struct PinnedComposer: View {
    var project: Project

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            ProjectComposer(project: project)
                .frame(maxWidth: 680)
                .padding(.horizontal, 32)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
        }
    }
}
