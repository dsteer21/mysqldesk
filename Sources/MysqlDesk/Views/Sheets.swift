import SwiftUI

/// Asked when connecting to a server with no password in the Keychain.
struct PasswordSheet: View {
    @Environment(AppStore.self) private var store
    let request: AppStore.PasswordRequest
    @State private var password = ""
    @State private var remember = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to \(request.config.name)").font(.title2.bold())
            Text("\(request.config.username)@\(request.config.address)").foregroundStyle(.secondary)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { store.resolvePassword(password, remember: remember) }
            Toggle("Store in Keychain", isOn: $remember)
            HStack {
                Spacer()
                Button("Cancel") { store.resolvePassword(nil, remember: false) }.keyboardShortcut(.cancelAction)
                Button("Connect") { store.resolvePassword(password, remember: remember) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        // Closing the sheet any other way counts as Cancel, so the waiting connect() always resumes.
        .onDisappear { if store.passwordRequest?.id == request.id { store.resolvePassword(nil, remember: false) } }
    }
}

/// Name a favourite (and pick its connection/schema) when saving or editing it.
struct FavouriteSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var draft: AppStore.FavouriteDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.favouriteID == nil ? "Save Favourite" : "Edit Favourite").font(.title2.bold())
            Form {
                TextField("Name", text: $draft.name, prompt: Text("e.g. Today's orders"))
                Picker("Connection", selection: $draft.connectionID) {
                    ForEach(store.connections) { Text($0.displayName).tag($0.id) }
                }
                TextField("Schema", text: Binding(get: { draft.database ?? "" }, set: { draft.database = $0.isEmpty ? nil : $0 }),
                          prompt: Text("Optional"))
            }
            .formStyle(.columns)

            TextEditor(text: $draft.sql)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 160)
                .scrollContentBackground(.hidden)
                .background(Theme.background)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.1)))

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    store.commitFavourite(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// Double-click a cell: the full value, with JSON pretty-printed.
struct ValueViewerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: AppStore.ValueViewerItem

    private var text: String {
        guard let value = item.value else { return "NULL" }
        if let data = value.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            return String(decoding: pretty, as: UTF8.self)
        }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(item.column).font(.title3.bold())
                Spacer()
                Text("\(item.value?.count ?? 0) characters").foregroundStyle(.secondary)
            }
            ScrollView {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(item.value == nil ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Theme.background)
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.value ?? "NULL", forType: .string)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 620, height: 440)
    }
}

/// Editing a long or multi-line value (or JSON) that doesn't fit in a grid cell.
struct CellEditorSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let item: AppStore.CellEditorItem
    @State private var text = ""
    @State private var isNull = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Edit \(item.columnName)").font(.title3.bold())
                Spacer()
                if item.nullable { Toggle("NULL", isOn: $isNull) }
            }
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(Theme.background)
                .disabled(isNull)
                .opacity(isNull ? 0.4 : 1)
            HStack {
                Text("The change is applied when you click Apply under the results.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Done") {
                    if let tab = store.tabs.first(where: { $0.id == item.tabID }),
                       let result = tab.results.first(where: { $0.id == item.resultID }) {
                        tab.setEdit(isNull ? nil : text, row: item.row, column: item.column, in: result)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 620, height: 440)
        .onAppear {
            text = item.value ?? ""
            isNull = item.value == nil
        }
    }
}

/// The UPDATE statements Apply is about to run, for a final check.
struct ApplyPreviewSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let preview: AppStore.ApplyPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Apply \(preview.statements.count) Update\(preview.statements.count == 1 ? "" : "s")?").font(.title2.bold())
            Text("These run in a single transaction: if any fails, none are saved.")
                .foregroundStyle(.secondary)
            ScrollView {
                Text(preview.statements.joined(separator: "\n\n"))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Theme.background)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.1)))
            HStack {
                Button("Copy SQL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(preview.statements.joined(separator: "\n\n"), forType: .string)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply Changes") {
                    let preview = preview
                    dismiss()
                    Task { await store.applyEdits(preview) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
        }
        .padding(20)
        .frame(width: 680, height: 460)
    }
}
