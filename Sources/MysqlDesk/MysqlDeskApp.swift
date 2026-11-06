import SwiftUI

@main
struct MysqlDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AppStore()

    var body: some Scene {
        Window("MysqlDesk", id: "main") {
            MainView()
                .environment(store)
                .frame(minWidth: 1000, minHeight: 600)
                .preferredColorScheme(.dark)
                #if DEBUG
                .task { await DebugHooks.run(store) }
                #endif
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 880)
        .commands { commands }

        Settings {
            SettingsView()
        }
    }

    /// Shortcuts follow SQLPro for MySQL's defaults where it has one.
    @CommandsBuilder
    private var commands: some Commands {
        let tab = store.showHome ? nil : store.selectedTab

        CommandGroup(replacing: .newItem) {
            Button("New Query Tab") { store.newTab() }
                .keyboardShortcut("t")
            Button("Manage Connections…") { store.showManager() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Connections Home") { store.showHome.toggle() }
                .keyboardShortcut("0")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") {
                if let tab = store.selectedTab { store.closeTab(tab) } else { NSApp.keyWindow?.performClose(nil) }
            }
            .keyboardShortcut("w")
            Divider()
            Button(tab?.favouriteID == nil ? "Save as Favourite…" : "Update Favourite") { store.saveFavourite(tab) }
                .keyboardShortcut("s")
                .disabled(tab == nil)
            Button("Save as New Favourite…") { store.saveFavourite(tab, asNew: true) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(tab == nil)
        }

        CommandMenu("Query") {
            Button("Run All (or Selection)") { store.run(tab, .all) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Run Current Statement") { store.run(tab, .current) }
                .keyboardShortcut(.return)
            Button("Stop") { store.cancel(tab) }
                .keyboardShortcut(".")
                .disabled(tab?.running != true)
            Divider()
            Button("Format Query") { tab?.editor.format() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Button("Comment / Uncomment") { tab?.editor.toggleComment() }
                .keyboardShortcut("-")
            Button("Make Uppercase") { tab?.editor.changeCase(upper: true) }
                .keyboardShortcut("u", modifiers: [.command, .control])
            Button("Make Lowercase") { tab?.editor.changeCase(upper: false) }
                .keyboardShortcut("l", modifiers: [.command, .control])
            Divider()
            Button(tab?.showResults == false ? "Show Results" : "Hide Results") { tab?.showResults.toggle() }
                .keyboardShortcut("k")
            Button("Find Column") {
                guard let tab else { return }
                tab.showResults = true
                tab.showColumnFilter = true
                tab.columnFilterFocus += 1
            }
            .keyboardShortcut("b")
            Button("Toggle Results / Messages") { tab?.showMessages.toggle() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Divider()
            Button("Copy Selected Rows as CSV") { store.copy(tab, as: .csv) }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Menu("Export Results") {
                ForEach(ExportFormat.allCases) { format in
                    Button("All Rows as \(format.title)…") { store.export(tab, as: format, selectedOnly: false) }
                }
                Divider()
                ForEach(ExportFormat.allCases) { format in
                    Button("Selected Rows as \(format.title)…") { store.export(tab, as: format, selectedOnly: true) }
                }
            }
            Button("Export All Rows as CSV…") { store.export(tab, as: .csv, selectedOnly: false) }
                .keyboardShortcut("e", modifiers: [.command, .option])
        }

        CommandMenu("Connection") {
            Button("Command Palette…") { store.showPalette.toggle() }
                .keyboardShortcut("p")
            Button("Choose Server and Schema…") { tab?.showTargetPicker = true }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(tab == nil)
            Divider()
            Button("Focus Database Tree") { store.sidebarTreeFocus += 1 }
                .keyboardShortcut("d", modifiers: .control)
            Button("Filter Database Tree") { store.sidebarFilterFocus += 1 }
                .keyboardShortcut("f", modifiers: .control)
            Button("Refresh") { store.refresh(store.server(tab?.connectionID) ?? store.servers.first) }
                .keyboardShortcut("r")
            Divider()
            Button("Disconnect") { if let server = store.server(tab?.connectionID) { store.disconnect(server) } }
                .disabled(store.server(tab?.connectionID) == nil)
        }

        CommandGroup(before: .windowList) {
            Button("Previous Tab") { store.selectTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next Tab") { store.selectTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            ForEach(1...9, id: \.self) { number in
                Button(number == 9 ? "Last Tab" : "Tab \(number)") { store.selectTab(number: number) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")))
            }
            Divider()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        #if DEBUG
        DebugHooks.scheduleSnapshotIfRequested()
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct SettingsView: View {
    @AppStorage("maxRows") private var maxRows = 50_000
    @AppStorage("tableRowLimit") private var tableRowLimit = 1000
    @AppStorage("editorFontSize") private var editorFontSize = 13.0
    @AppStorage("stopOnError") private var stopOnError = true

    var body: some View {
        Form {
            TextField("Rows kept per result", value: $maxRows, format: .number)
            Text("Larger results still report their full row count, but only this many rows are kept for viewing and exporting.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("LIMIT when opening a table", value: $tableRowLimit, format: .number)
            Stepper("Editor font size: \(Int(editorFontSize)) pt", value: $editorFontSize, in: 9...24)
            Toggle("Stop a script at the first error", isOn: $stopOnError)
            LabeledContent("Data folder", value: Storage.folder.path)
        }
        .padding(20)
        .frame(width: 480)
    }
}
