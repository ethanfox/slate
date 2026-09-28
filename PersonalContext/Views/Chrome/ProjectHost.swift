import SwiftData
import SwiftUI

struct ProjectHost: View {
    var id: UUID
    @Query private var projects: [Project]

    var body: some View {
        if let project = projects.first(where: { $0.id == id }) {
            ProjectView(project: project)
        } else {
            ScrollView {
                PageBody {
                    EmptyLine(text: "This project is no longer here.")
                        .padding(28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .scrollContentBackground(.hidden)
        }
    }
}
