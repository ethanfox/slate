import SwiftData
import SwiftUI

struct ProjectHost: View {
    var id: UUID
    @Query private var projects: [Project]

    init(id: UUID) {
        self.id = id
        let projectID = id
        _projects = Query(filter: #Predicate<Project> { $0.id == projectID })
    }

    var body: some View {
        if let project = projects.first {
            ProjectView(project: project)
                .onAppear {
                    NavTrace.event("project.host appear id=\(id) name=\(project.name)")
                }
                .onAppear {
                    NavTrace.afterTurn("project.host.runloop id=\(id)")
                }
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
