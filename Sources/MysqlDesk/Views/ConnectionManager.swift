import SwiftUI

/// MySQL Workbench-style "Manage Server Connections": list on the left, details on the right.
/// Changes save as you type; passwords go straight into the Keychain.
struct ConnectionManager: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete: ConnectionConfig?
    @State private var testState: TestState?
    /// Typed in the form but not yet stored, so Test Connection can try it first.
    @State private var pendingPassword = ""

    enum TestState {
        case running
        case passed(String)
        case failed(String)
    }

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 0) {
            HSplitView {
                List(selection: $store.managerSelection) {
                    Section("MySQL Connections") {
                        ForEach(store.connections) { config in
                            HStack(spacing: 8) {
                                Circle().fill(Theme.colour(config.colour)).frame(width: 8, height: 8)
                                Text(config.name)
                            }
                            .tag(Optional(config.id))
                        }
                    }
                }
                .listStyle(.sidebar)
                .frame(minWidth: 180, idealWidth: 200, maxWidth: 260)

                Group {
                    if let id = store.managerSelection, store.config(id) != nil {
                        ConnectionForm(id: id, testState: $testState, password: $pendingPassword)
                            .id(id)
                    } else {
                        ContentUnavailableView("No connection selected", systemImage: "server.rack",
                                               description: Text("Click New to add a server."))
                    }
                }
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            HStack {
                Button("New") { add(ConnectionConfig()) }
                Button("Delete") { confirmDelete = store.config(store.managerSelection) }
                    .disabled(store.managerSelection == nil)
                Button("Duplicate") { duplicate() }
                    .disabled(store.managerSelection == nil)
                Button("Move Up") { if let id = store.managerSelection { store.moveConnection(id, by: -1) } }
                    .disabled(store.managerSelection == nil)
                Button("Move Down") { if let id = store.managerSelection { store.moveConnection(id, by: 1) } }
                    .disabled(store.managerSelection == nil)
                Spacer()
                testResult
                Button("Test Connection") { test() }
                    .disabled(store.managerSelection == nil)
                Button("Close") {
                    storePendingPassword(for: store.managerSelection)
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 860, height: 520)
        // A password typed but not yet saved is stored when you switch connection or close the window.
        .onChange(of: store.managerSelection) { previous, _ in
            storePendingPassword(for: previous)
            testState = nil
        }
        .onDisappear { storePendingPassword(for: store.managerSelection) }
        .confirmationDialog("Delete “\(confirmDelete?.name ?? "")”?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let config = confirmDelete {
                    let index = store.connections.firstIndex { $0.id == config.id } ?? 0
                    store.deleteConnection(config.id)
                    store.managerSelection = store.connections[safe: min(index, store.connections.count - 1)]?.id
                }
            }
        } message: {
            let count = store.favourites(for: confirmDelete?.id).count
            Text("Its saved password is removed from the Keychain" + (count > 0 ? ", and its \(count) favourite\(count == 1 ? "" : "s") are deleted." : "."))
        }
    }

    @ViewBuilder
    private var testResult: some View {
        switch testState {
        case .running:
            ProgressView().controlSize(.small)
            Text("Testing…").foregroundStyle(.secondary)
        case .passed(let message):
            Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green).lineLimit(1)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(2).help(message)
        case nil:
            EmptyView()
        }
    }

    /// Saves a newly typed password to the Keychain. Nothing happens if the field was left empty,
    /// so editing other settings never touches the saved password.
    private func storePendingPassword(for id: UUID?) {
        guard !pendingPassword.isEmpty, let id, let config = store.config(id) else { return }
        if Keychain.setPassword(pendingPassword, for: id, label: config.name) {
            pendingPassword = ""
        } else {
            Banner.shared.error("Couldn't save the password to the Keychain")
        }
    }

    private func add(_ config: ConnectionConfig) {
        store.saveConnection(config)
        store.managerSelection = config.id
    }

    private func duplicate() {
        guard let original = store.config(store.managerSelection) else { return }
        var copy = original
        copy.id = UUID()
        copy.name += " copy"
        add(copy)
        if let password = Keychain.password(for: original.id) {
            Keychain.setPassword(password, for: copy.id, label: copy.name)
        }
    }

    private func test() {
        guard let config = store.config(store.managerSelection) else { return }
        testState = .running
        let started = Date()
        Task {
            do {
                let password = pendingPassword.isEmpty ? Keychain.password(for: config.id) : pendingPassword
                let connection = try await DatabaseConnection.open(config, password: password)
                let version = connection.serverVersion
                await connection.close()
                testState = .passed("Connected to \(version) in \(Formats.duration(Date().timeIntervalSince(started)))")
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }
}

private struct ConnectionForm: View {
    @Environment(AppStore.self) private var store
    let id: UUID
    @Binding var testState: ConnectionManager.TestState?
    @Binding var password: String
    @State private var config = ConnectionConfig()
    @State private var hasPassword = false
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                TextField("Connection Name", text: $config.name)
                Picker("Colour", selection: $config.colour) {
                    ForEach(ConnectionColour.allCases) { colour in
                        Label {
                            Text(colour.title)
                        } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(Theme.colour(colour))
                        }
                        .tag(colour)
                    }
                }
            }

            Section("Parameters") {
                HStack {
                    TextField("Hostname", text: $config.host, prompt: Text("e.g. db.example.com or 192.168.1.20"))
                    TextField("Port", value: $config.port, format: .number.grouping(.never))
                        .frame(width: 130)
                }
                TextField("Username", text: $config.username)
                LabeledContent("Password") {
                    HStack {
                        SecureField("", text: $password, prompt: Text(hasPassword ? "Saved in Keychain" : "Not set"))
                            .help(hasPassword ? "Type a new password to replace the saved one" : "Leave empty to be asked when connecting")
                            .onSubmit(savePassword)
                        Button("Save", action: savePassword)
                            .help("Save this password to your Keychain")
                            .disabled(password.isEmpty)
                        Button("Clear") {
                            Keychain.deletePassword(for: id)
                            password = ""
                            hasPassword = false
                        }
                        .disabled(!hasPassword)
                    }
                }
                TextField("Default Schema", text: $config.defaultSchema, prompt: Text("Optional"))
            }

            Section("Security") {
                Picker("TLS", selection: $config.tls) {
                    ForEach(TLSMode.allCases) { Text($0.title).tag($0) }
                }
                Text("Passwords are kept in your macOS Keychain, never in MysqlDesk's files. MySQL 8's caching_sha2_password works with TLS on or off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            config = store.config(id) ?? ConnectionConfig()
            hasPassword = Keychain.hasPassword(for: id)
            loaded = true
        }
        .onChange(of: config) {
            if loaded { store.saveConnection(config) }
            testState = nil
        }
    }

    private func savePassword() {
        guard !password.isEmpty else { return }
        if Keychain.setPassword(password, for: id, label: config.name) {
            hasPassword = true
            password = ""
            testState = nil
        } else {
            Banner.shared.error("Couldn't save the password to the Keychain")
        }
    }
}
