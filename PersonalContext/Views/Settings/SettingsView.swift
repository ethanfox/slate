import AppKit
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \Project.name) private var projects: [Project]

    @State private var showingConnect = false
    @State private var previewProjectID: UUID?

    var body: some View {
        @Bindable var app = app
        PageBody {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                group("Cursor") {
                    row {
                        Text("Cursor API Key")
                        Spacer(minLength: 16)
                        if app.hasAPIKey {
                            connectionLabel
                                .lineLimit(1)
                            Button("Remove") { removeKey() }
                        } else {
                            Button("Connect…") { showingConnect = true }
                        }
                    }
                    if app.hasAPIKey {
                        Hairline().padding(.horizontal, 16)
                        row {
                            Text("Model")
                            Spacer(minLength: 16)
                            Picker("Model", selection: $app.defaultModelID) {
                                Text("Account default").tag("")
                                ForEach(app.models) { model in
                                    Text(model.displayName).tag(model.id)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                }

                group("Appearance") {
                    row {
                        Text("Appearance")
                        Spacer(minLength: 16)
                        Picker("Appearance", selection: $app.appearance) {
                            ForEach(AppearancePreference.allCases) { preference in
                                Text(preference.label).tag(preference)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }

                group("Developer") {
                    row {
                        Text("Show Cursor agent IDs")
                        Spacer(minLength: 16)
                        Toggle("Show Cursor agent IDs", isOn: $app.showAgentIDs)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    if !projects.isEmpty {
                        Hairline().padding(.horizontal, 16)
                        row {
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
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 12)
                        }
                    }
                }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
        }
        .onAppear {
            if previewProjectID == nil {
                previewProjectID = projects.first?.id
            }
        }
        .sheet(isPresented: $showingConnect) {
            ConnectCursorSheet()
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(CraftFont.section)
            VStack(spacing: 0) {
                content()
            }
            .background(CraftColor.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func row<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            content()
        }
        .font(CraftFont.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var connectionLabel: some View {
        switch app.connection {
        case .missing:
            Text("Not connected")
                .foregroundStyle(.secondary)
        case .checking:
            Text("Checking")
                .foregroundStyle(.secondary)
        case .connected(let label):
            Text(label)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private func removeKey() {
        try? app.removeAPIKey()
    }
}
