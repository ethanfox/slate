import AppKit
import EventKit
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \Project.name) private var projects: [Project]

    @State private var showingConnect = false
    @State private var previewProjectID: UUID?

    var body: some View {
        @Bindable var app = app
        ScrollView {
            PageBody {
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
                    Hairline().padding(.horizontal, 16)
                    row {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cursor app")
                            Text("Lets agents in Cursor read and update this knowledge base.")
                                .font(CraftFont.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 16)
                        Button("Connect to Cursor") { connectCursorApp() }
                    }
                }

                group("Calendar and Reminders") {
                    accessRow(
                        title: "Calendar",
                        status: app.eventKit.eventsAccess,
                        request: { await app.eventKit.requestEventsAccess() },
                        entity: .event
                    )
                    Hairline().padding(.horizontal, 16)
                    accessRow(
                        title: "Reminders",
                        status: app.eventKit.remindersAccess,
                        request: { await app.eventKit.requestRemindersAccess() },
                        entity: .reminder
                    )
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
        }
        .scrollContentBackground(.hidden)
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

    private func accessRow(
        title: String,
        status: EKAuthorizationStatus,
        request: @escaping () async -> Void,
        entity: EKEntityType
    ) -> some View {
        row {
            Text(title)
            Spacer(minLength: 16)
            Text(app.eventKit.statusLabel(for: status))
                .foregroundStyle(.secondary)
            if let action = accessAction(for: status) {
                Button(action.title) {
                    if action.opensSettings {
                        app.eventKit.openSettings(for: entity)
                    } else {
                        Task { await request() }
                    }
                }
            }
        }
    }

    private func accessAction(for status: EKAuthorizationStatus) -> (title: String, opensSettings: Bool)? {
        switch status {
        case .fullAccess:
            nil
        case .notDetermined, .writeOnly:
            ("Allow…", false)
        case .denied, .restricted:
            ("Open Settings", true)
        @unknown default:
            ("Open Settings", true)
        }
    }

    private func removeKey() {
        try? app.removeAPIKey()
    }

    private func connectCursorApp() {
        guard let mcp = Bundle.main.url(forAuxiliaryExecutable: "slate-mcp"),
              let config = try? JSONSerialization.data(withJSONObject: ["command": mcp.path], options: .withoutEscapingSlashes),
              let encoded = config.base64EncodedString().addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "cursor://anysphere.cursor-deeplink/mcp/install?name=slate&config=\(encoded)")
        else { return }
        guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
            app.flash("Cursor isn’t installed on this Mac.")
            return
        }
        NSWorkspace.shared.open(url)
    }
}
