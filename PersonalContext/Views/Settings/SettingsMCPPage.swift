import SwiftUI

struct SettingsMCPPage: View {
    @Environment(AppModel.self) private var app
    @State private var selectedID: UUID?
    @State private var editor: MCPConnectionDraft?
    @State private var pasteJSON = false
    @State private var jsonText = ""
    @State private var jsonError = ""
    @State private var testMessage = ""
    @State private var testing = false

    private var mcp: MCPRuntime { app.mcp }

    var body: some View {
        SettingsPage {
            SettingsGroup("MCP connections") {
                SettingsRow {
                    Text("Connect an external MCP server here, then enable it on a Space. Chat can use only that Space’s servers. Compatible endpoints cannot run these tools.")
                        .font(CraftFont.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if mcp.store.connections.isEmpty {
                    Hairline().padding(.horizontal, 16)
                    SettingsRow {
                        Text("No connections yet.")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 16)
                        Button("Add Connection") { editor = .blank }
                        Button("Paste JSON") { pasteJSON = true }
                    }
                } else {
                    ForEach(mcp.store.connections) { record in
                        Hairline().padding(.horizontal, 16)
                        connectionRow(record)
                    }
                    Hairline().padding(.horizontal, 16)
                    SettingsRow {
                        Spacer(minLength: 0)
                        Button("Add Connection") { editor = .blank }
                        Button("Paste JSON") { pasteJSON = true }
                    }
                }
            }

            if let selected, let record = mcp.store.connection(id: selected) {
                detail(record)
            }
        }
        .sheet(item: $editor) { draft in
            MCPConnectionEditor(draft: draft) { saved in
                selectedID = saved.id
                editor = nil
            }
            .environment(app)
            .environment(\.modalDismiss, ModalDismissAction(action: { editor = nil }))
        }
        .sheet(isPresented: $pasteJSON) {
            MCPPasteJSONSheet(
                text: $jsonText,
                error: $jsonError,
                onCancel: { pasteJSON = false },
                onImport: importJSON
            )
            .environment(app)
        }
    }

    private var selected: UUID? {
        if let selectedID, mcp.store.connection(id: selectedID) != nil { return selectedID }
        return mcp.store.connections.first?.id
    }

    private func connectionRow(_ record: MCPConnectionRecord) -> some View {
        let status = mcp.clients.status(for: record.id)
        return SettingsRow {
            Button {
                selectedID = record.id
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.name)
                    Text("\(record.transportLabel) · \(status.label)\(status.toolCount > 0 ? " · \(status.toolCount) tools" : "")")
                        .font(CraftFont.caption)
                        .foregroundStyle(status.errorMessage == nil ? Color.secondary : Color.red)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Toggle("Enabled", isOn: Binding(
                get: { record.enabled },
                set: { try? mcp.setEnabled(record.id, enabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
    }

    private func detail(_ record: MCPConnectionRecord) -> some View {
        let status = mcp.clients.status(for: record.id)
        let tools = mcp.clients.tools(for: record.id)
        return SettingsGroup(record.name) {
            SettingsRow {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.configurationSummary)
                        .font(CraftFont.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(status.label)
                        .foregroundStyle(status.errorMessage == nil ? Color.secondary : Color.red)
                    if let error = status.errorMessage ?? mcp.clients.lastError(for: record.id) {
                        Text(error)
                            .font(CraftFont.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !testMessage.isEmpty {
                        Text(testMessage)
                            .font(CraftFont.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Hairline().padding(.horizontal, 16)
            SettingsRow {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Always allow tools")
                    Text("Chat can run this server’s tools without asking each time.")
                        .font(CraftFont.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                Toggle("Always allow tools", isOn: Binding(
                    get: { record.skipsConfirmation },
                    set: { try? mcp.setAutoApprove(record.id, enabled: $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            Hairline().padding(.horizontal, 16)
            SettingsRow {
                Spacer(minLength: 0)
                Button(record.enabled ? (status.toolCount > 0 ? "Retry" : "Connect") : "Disabled") {
                    Task { await mcp.clients.connect(record.id) }
                }
                .disabled(!record.enabled || testing)
                Button(testing ? "Testing…" : "Test Connection") {
                    Task { await test(record) }
                }
                .disabled(testing)
                Button("Edit") { editor = MCPConnectionDraft(record) }
                Button("Remove", role: .destructive) {
                    mcp.remove(record.id)
                    selectedID = mcp.store.connections.first?.id
                }
            }
            if !tools.isEmpty {
                Hairline().padding(.horizontal, 16)
                ForEach(tools) { tool in
                    SettingsRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.name)
                            if !tool.description.isEmpty {
                                Text(tool.description)
                                    .font(CraftFont.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    private func test(_ record: MCPConnectionRecord) async {
        testing = true
        testMessage = ""
        let result = await mcp.clients.test(record)
        testing = false
        switch result {
        case .success(let tools):
            testMessage = tools.isEmpty ? "Connected. No tools advertised." : "Found \(tools.count) tools."
        case .failure(let error):
            testMessage = error.localizedDescription
        }
    }

    private func importJSON() {
        do {
            let result = try mcp.importServers(json: jsonText, replace: false)
            if result.contains("already exist") {
                jsonError = result
                return
            }
            jsonText = ""
            jsonError = ""
            pasteJSON = false
            if let first = mcp.store.connections.first {
                selectedID = first.id
            }
        } catch {
            jsonError = error.localizedDescription
        }
    }
}

struct MCPConnectionDraft: Identifiable {
    var id: UUID
    var name: String
    var transport: MCPTransportKind
    var command: String
    var argumentsText: String
    var workingDirectory: String
    var environment: [MCPKeyValue]
    var url: String
    var headers: [MCPKeyValue]
    var enabled: Bool
    var autoApprove: Bool?
    var createdAt: Date
    var isNew: Bool
    var executableBookmark: Data?
    var workingDirectoryBookmark: Data?

    static var blank: MCPConnectionDraft {
        MCPConnectionDraft(
            id: UUID(),
            name: "",
            transport: .stdio,
            command: "",
            argumentsText: "",
            workingDirectory: "",
            environment: [],
            url: "",
            headers: [],
            enabled: true,
            autoApprove: nil,
            createdAt: .now,
            isNew: true,
            executableBookmark: nil,
            workingDirectoryBookmark: nil
        )
    }

    init(_ record: MCPConnectionRecord) {
        id = record.id
        name = record.name
        transport = record.transport
        command = record.command
        argumentsText = record.arguments.joined(separator: " ")
        workingDirectory = record.workingDirectory
        environment = record.environmentKeys.map {
            MCPKeyValue(key: $0, value: KeychainStore.read(account: MCPSecrets.environmentAccount(connectionID: record.id, key: $0)) ?? "")
        }
        url = record.url
        headers = record.headerKeys.map {
            MCPKeyValue(key: $0, value: KeychainStore.read(account: MCPSecrets.headerAccount(connectionID: record.id, key: $0)) ?? "")
        }
        enabled = record.enabled
        autoApprove = record.autoApprove
        createdAt = record.createdAt
        isNew = false
        executableBookmark = record.executableBookmark
        workingDirectoryBookmark = record.workingDirectoryBookmark
    }

    init(
        id: UUID,
        name: String,
        transport: MCPTransportKind,
        command: String,
        argumentsText: String,
        workingDirectory: String,
        environment: [MCPKeyValue],
        url: String,
        headers: [MCPKeyValue],
        enabled: Bool,
        autoApprove: Bool?,
        createdAt: Date,
        isNew: Bool,
        executableBookmark: Data?,
        workingDirectoryBookmark: Data?
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.command = command
        self.argumentsText = argumentsText
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.url = url
        self.headers = headers
        self.enabled = enabled
        self.autoApprove = autoApprove
        self.createdAt = createdAt
        self.isNew = isNew
        self.executableBookmark = executableBookmark
        self.workingDirectoryBookmark = workingDirectoryBookmark
    }

    func record() -> MCPConnectionRecord {
        MCPConnectionRecord(
            id: id,
            name: name,
            enabled: enabled,
            transport: transport,
            command: command,
            arguments: argumentsText.split(whereSeparator: \.isWhitespace).map(String.init),
            workingDirectory: workingDirectory,
            environmentKeys: environment.map(\.key).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
            url: url,
            headerKeys: headers.map(\.key).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
            executableBookmark: executableBookmark,
            workingDirectoryBookmark: workingDirectoryBookmark,
            autoApprove: autoApprove,
            createdAt: createdAt
        )
    }
}

struct MCPKeyValue: Identifiable, Equatable {
    var id = UUID()
    var key: String
    var value: String
}

struct MCPConnectionEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var draft: MCPConnectionDraft
    var onSave: (MCPConnectionRecord) -> Void
    @State private var error = ""
    @State private var testing = false
    @State private var testMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.isNew ? "Add MCP connection" : "Edit MCP connection")
                .font(CraftFont.title)
            ModalScroll {
                VStack(alignment: .leading, spacing: 14) {
                    ModalField("Name") {
                        TextField("Paper", text: $draft.name)
                            .textFieldStyle(.plain)
                    }
                    ModalControlRow("Transport") {
                        Picker("Transport", selection: $draft.transport) {
                            ForEach(MCPTransportKind.allCases) { kind in
                                Text(kind.label).tag(kind)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    if draft.transport == .stdio {
                        ModalField("Executable") {
                            HStack {
                                TextField("/Users/you/.paper/bin/paper", text: $draft.command)
                                    .textFieldStyle(.plain)
                                Button("Choose…") { pickExecutable() }
                            }
                        }
                        ModalField("Arguments") {
                            TextField("mcp", text: $draft.argumentsText)
                                .textFieldStyle(.plain)
                        }
                        ModalField("Working directory") {
                            HStack {
                                TextField("Optional", text: $draft.workingDirectory)
                                    .textFieldStyle(.plain)
                                Button("Choose…") { pickDirectory() }
                            }
                        }
                        keyValues("Environment", items: $draft.environment, secret: true)
                    } else {
                        ModalField("Server URL") {
                            TextField("https://example.com/mcp", text: $draft.url)
                                .textFieldStyle(.plain)
                        }
                        keyValues("Headers", items: $draft.headers, secret: true)
                    }
                    if !error.isEmpty {
                        Text(error)
                            .font(CraftFont.caption)
                            .foregroundStyle(.red)
                    }
                    if !testMessage.isEmpty {
                        Text(testMessage)
                            .font(CraftFont.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ModalFooter(actionTitle: "Save", actionEnabled: canSave, action: save) {
                ModalFooterButton(title: testing ? "Testing…" : "Test Connection", enabled: canSave && !testing) {
                    Task { await test() }
                }
            }
        }
        .padding(4)
        .frame(width: 480)
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func keyValues(_ title: String, items: Binding<[MCPKeyValue]>, secret: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(CraftFont.section)
                Spacer()
                Button("Add") { items.wrappedValue.append(MCPKeyValue(key: "", value: "")) }
            }
            ForEach(items) { $item in
                HStack {
                    TextField("Name", text: $item.key)
                        .textFieldStyle(.plain)
                    if secret {
                        SecureField("Value", text: $item.value)
                            .textFieldStyle(.plain)
                    } else {
                        TextField("Value", text: $item.value)
                            .textFieldStyle(.plain)
                    }
                    Button("Remove", role: .destructive) {
                        items.wrappedValue.removeAll { $0.id == item.id }
                    }
                }
                .padding(10)
                .background(CraftColor.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func save() {
        do {
            let saved = try app.mcp.save(
                draft.record(),
                environment: Dictionary(uniqueKeysWithValues: draft.environment.compactMap {
                    let key = $0.key.trimmingCharacters(in: .whitespaces)
                    return key.isEmpty ? nil : (key, $0.value)
                }),
                headers: Dictionary(uniqueKeysWithValues: draft.headers.compactMap {
                    let key = $0.key.trimmingCharacters(in: .whitespaces)
                    return key.isEmpty ? nil : (key, $0.value)
                })
            )
            onSave(saved)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func test() async {
        testing = true
        testMessage = ""
        error = ""
        let result = await app.mcp.clients.test(draft.record())
        testing = false
        switch result {
        case .success(let tools):
            testMessage = tools.isEmpty ? "Connected. No tools advertised." : "Found \(tools.count) tools."
        case .failure(let error):
            self.error = error.localizedDescription
        }
    }

    private func pickExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.command = url.path
        draft.executableBookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.workingDirectory = url.path
        draft.workingDirectoryBookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}

struct MCPPasteJSONSheet: View {
    @Binding var text: String
    @Binding var error: String
    var onCancel: () -> Void
    var onImport: () -> Void
    @State private var replace = false
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Paste mcpServers JSON")
                .font(CraftFont.title)
            Text("Saves the connection. It does not launch the server or enable it on a Space.")
                .font(CraftFont.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 180)
                .padding(8)
                .background(CraftColor.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(CraftColor.hairline))
            if !error.isEmpty {
                Text(error)
                    .font(CraftFont.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Replace existing names when settings differ", isOn: $replace)
            HStack {
                ModalFooterButton(title: "Cancel", action: onCancel)
                ModalFooterButton(title: "Import", role: .primary, enabled: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    importJSON()
                }
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func importJSON() {
        do {
            _ = try app.mcp.importServers(json: text, replace: replace)
            error = ""
            text = ""
            onCancel()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
