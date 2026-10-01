import SwiftData
import SwiftUI

struct OverviewPage: View {
    @Bindable var project: Project

    var body: some View {
        VStack(spacing: 0) {
            OverviewCanvas(project: project)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            PinnedComposer(project: project)
        }
    }
}
