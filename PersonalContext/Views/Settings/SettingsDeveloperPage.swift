import SwiftData
import SwiftUI

struct SettingsDeveloperPage: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \Project.name) private var projects: [Project]
    @State private var previewProjectID: UUID?

    var body: some View {
        @Bindable var app = app
        SettingsPage {
            SettingsGroup("Developer") {
                SettingsRow {
                    Text("Show Cursor agent IDs")
                    Spacer(minLength: 16)
                    Toggle("Show Cursor agent IDs", isOn: $app.showAgentIDs)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                if !projects.isEmpty {
                    Hairline().padding(.horizontal, 16)
                    SettingsRow {
                        Text("Project context")
                        Spacer(minLength: 16)
                        Picker("Project context", selection: $previewProjectID) {
                            Text("None").tag(UUID?.none)
                            ForEach(projects) { project in
                                Text(project.name).tag(Optional(project.id))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    if let project = projects.first(where: { $0.id == previewProjectID }) {
                        Text(ContextBuilder.package(for: project))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                    }
                }
            }
        }
        .onAppear {
            if previewProjectID == nil {
                previewProjectID = projects.first?.id
            }
        }
    }
}
