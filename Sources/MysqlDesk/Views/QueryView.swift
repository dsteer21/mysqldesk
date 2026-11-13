import SwiftUI

/// A query tab: toolbar, SQL editor and (⌘K to hide) the results below.
struct QueryView: View {
    @Environment(AppStore.self) private var store
    let tab: QueryTab
    @AppStorage("editorFontSize") private var fontSize = 13.0

    var body: some View {
        VStack(spacing: 0) {
            QueryToolbar(tab: tab)
            Divider()
            if tab.showResults {
                VSplitView {
                    editor.frame(minHeight: 80, idealHeight: 260)
                    ResultsPanel(tab: tab).frame(minHeight: 120, idealHeight: 420)
                }
            } else {
                editor
            }
        }
    }

    private var editor: some View {
        SQLEditor(tab: tab, fontSize: fontSize) { store.tabsChanged() }
    }
}

/// Above the editor: where the query runs (server — schema), favourites, history and Run.
private struct QueryToolbar: View {
    @Environment(AppStore.self) private var store
    let tab: QueryTab

    var body: some View {
        @Bindable var tab = tab
        let config = store.config(tab.connectionID)

        HStack(spacing: 10) {
            Button {
                tab.showTargetPicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "cylinder.split.1x2").font(.system(size: 11))
                    Text(targetTitle(config)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(config.map { Theme.colour($0.colour) } ?? Color.gray.opacity(0.5)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Change the server or schema. The query stays as it is.")
            .popover(isPresented: $tab.showTargetPicker, arrowEdge: .bottom) {
                TargetPicker(tab: tab) { tab.showTargetPicker = false }
            }

            if store.isModified(tab) {
                Text("Edited — ⌘S to update the favourite")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            Spacer()

            favouritesMenu
            historyMenu

            if tab.running {
                Button {
                    store.cancel(tab)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .tint(.red)
                .help("Stop the running query (⌘.)")
            } else {
                HStack(spacing: 0) {
                    Button {
                        store.run(tab, .all)
                    } label: {
                        Label("Run All", systemImage: "play.fill")
                    }
                    .help("Run everything, or just the selection (⇧⌘E)")
                    Menu {
                        Button("Run All / Selection   ⇧⌘E") { store.run(tab, .all) }
                        Button("Run Current Statement   ⌘↩") { store.run(tab, .current) }
                    } label: {
                        EmptyView()
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 18)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.panel)
    }

    private func targetTitle(_ config: ConnectionConfig?) -> String {
        guard let config else { return "Choose a connection" }
        return config.name + " — " + (tab.database ?? "no schema")
    }

    private var favouritesMenu: some View {
        Menu {
            Button(tab.favouriteID == nil ? "Save as Favourite…" : "Update Favourite") { store.saveFavourite(tab) }
            if tab.favouriteID != nil {
                Button("Save as New Favourite…") { store.saveFavourite(tab, asNew: true) }
            }
            let mine = store.favourites(for: tab.connectionID)
            if !mine.isEmpty {
                Divider()
                ForEach(mine) { favourite in
                    Button(favourite.name) { store.openFavourite(favourite) }
                }
            }
            let others = store.favourites.filter { $0.connectionID != tab.connectionID }
            if !others.isEmpty {
                Menu("Other Connections") {
                    ForEach(store.connections) { config in
                        let list = store.favourites(for: config.id)
                        if !list.isEmpty, config.id != tab.connectionID {
                            Section(config.name) {
                                ForEach(list) { favourite in Button(favourite.name) { store.openFavourite(favourite) } }
                            }
                        }
                    }
                }
            }
        } label: {
            Label("Favourites", systemImage: "star")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var historyMenu: some View {
        Menu {
            let entries = store.history(for: tab.connectionID).prefix(30)
            if entries.isEmpty { Text("No history for this connection yet") }
            ForEach(Array(entries)) { entry in
                Button {
                    store.openHistory(entry)
                } label: {
                    Text(entry.sql.replacingOccurrences(of: "\n", with: " ").prefix(90) + "  ·  " + Formats.dateTime.string(from: entry.date))
                }
            }
        } label: {
            Label("History", systemImage: "clock.arrow.circlepath")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// SQLPro-style picker: servers on the left, that server's schemas on the right.
struct TargetPicker: View {
    @Environment(AppStore.self) private var store
    let tab: QueryTab
    let dismiss: () -> Void
    @State private var serverID: UUID?
    @State private var filter = ""
    @FocusState private var filterFocused: Bool

    var body: some View {
        let server = store.server(serverID)
        let schemas = (server?.schemas.map(\.name) ?? []).filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) }

        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Server").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.connections) { config in
                            serverRow(config)
                        }
                    }
                }
            }
            .frame(width: 260)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Schema").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    TextField("Filter", text: $filter)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 140)
                        .focused($filterFocused)
                        .onSubmit { if let first = schemas.first, let serverID { choose(serverID, first) } }
                }
                if let server {
                    switch server.state {
                    case .connecting:
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .failed(let message):
                        Text(message).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .connected:
                        ScrollView {
                            VStack(spacing: 0) {
                                pickerRow("No schema", selected: tab.database == nil && tab.connectionID == serverID, italic: true) {
                                    choose(server.id, nil)
                                }
                                ForEach(schemas, id: \.self) { name in
                                    pickerRow(name, selected: tab.database == name && tab.connectionID == serverID) { choose(server.id, name) }
                                }
                            }
                        }
                    }
                } else {
                    Text("Choose a server").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 280)
        }
        .padding(14)
        .frame(height: 340)
        .onAppear {
            serverID = tab.connectionID ?? store.connections.first?.id
            if let config = store.config(serverID) { Task { await store.connect(config) } }
            filterFocused = true
        }
    }

    private func serverRow(_ config: ConnectionConfig) -> some View {
        let server = store.server(config.id)
        let selected = serverID == config.id
        return Button {
            serverID = config.id
            filter = ""
            Task { await store.connect(config) }
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.colour(config.colour)).frame(width: 4, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(config.displayName).font(.system(size: 12, weight: .medium))
                    Text(server?.isConnected == true ? "\(server?.schemas.count ?? 0) schemas" : config.address)
                        .font(.system(size: 10)).foregroundStyle(selected ? .white.opacity(0.8) : .secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Theme.selection : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pickerRow(_ title: String, selected: Bool, italic: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).italic(italic).foregroundStyle(italic ? .secondary : .primary)
                Spacer()
                if selected { Image(systemName: "checkmark").font(.system(size: 10)) }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(selected ? Theme.selection : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func choose(_ serverID: UUID, _ database: String?) {
        store.setTarget(tab, connectionID: serverID, database: database)
        dismiss()
    }
}

/// Results under the editor: one pill per result set plus Messages, the grid, and a status line.
/// When a run returns several results they're stacked one above another (or shown one at a time,
/// using the layout button); clicking a grid makes it the current result for export and copying.
struct ResultsPanel: View {
    @Environment(AppStore.self) private var store
    let tab: QueryTab
    @FocusState private var filterFocused: Bool
    @AppStorage("stackResults") private var stackResults = true
    /// Set by clicking a pill in the stacked layout, to scroll that result into view.
    @State private var scrollTarget: UUID?

    private var stacked: Bool { stackResults && tab.results.count > 1 }

    var body: some View {
        @Bindable var tab = tab

        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(Array(tab.results.enumerated()), id: \.element.id) { index, result in
                    pill(tab.results.count == 1 ? "Result" : "Result \(index + 1)", count: result.totalRows,
                         selected: !tab.showMessages && tab.selectedResult == index) {
                        select(index)
                        scrollTarget = result.id
                    }
                }
                pill("Messages", count: nil, selected: tab.showMessages || tab.results.isEmpty,
                     error: tab.outcomes.contains(where: \.isError),
                     warnings: tab.outcomes.reduce(0) { $0 + $1.warnings }) {
                    tab.showMessages = true
                }
                Spacer()
                if tab.results.count > 1 {
                    Button {
                        stackResults.toggle()
                    } label: {
                        Image(systemName: stackResults ? "rectangle" : "rectangle.split.1x2")
                    }
                    .buttonStyle(.borderless)
                    .help(stackResults ? "Show one result at a time" : "Show every result, one above another")
                }
                if tab.currentResult != nil {
                    Button {
                        tab.showColumnFilter.toggle()
                        if tab.showColumnFilter { tab.columnFilterFocus += 1 } else { tab.columnFilter = "" }
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help("Find column (⌘B)")
                    Menu {
                        Section("All rows") {
                            ForEach(ExportFormat.allCases) { format in
                                Button("Export as \(format.title)…") { store.export(tab, as: format, selectedOnly: false) }
                            }
                        }
                        Section("Selected rows (\(tab.selectedRows.count))") {
                            ForEach(ExportFormat.allCases) { format in
                                Button("Export as \(format.title)…") { store.export(tab, as: format, selectedOnly: true) }
                                    .disabled(tab.selectedRows.isEmpty)
                            }
                        }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.toolbar)

            if tab.showColumnFilter, let result = tab.currentResult {
                columnFilterBar(result)
            }

            Group {
                if tab.showMessages || (tab.results.isEmpty && !tab.outcomes.isEmpty) {
                    MessagesView(outcomes: tab.outcomes)
                } else if stacked {
                    stackedResults
                } else if let result = tab.currentResult {
                    grid(result, index: tab.selectedResult)
                } else if tab.running {
                    ProgressView("Running…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("Run all with ⇧⌘E, or the statement under the cursor with ⌘↩")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)

            statusLine
        }
        .onChange(of: tab.columnFilterFocus) { filterFocused = true }
    }

    private func select(_ index: Int) {
        if tab.selectedResult != index {
            tab.selectedResult = index
            tab.selectedRows = []
        }
        tab.showMessages = false
    }

    private func grid(_ result: ResultSet, index: Int, stacked: Bool = false) -> some View {
        let current = tab.selectedResult == index
        return ResultsTable(tab: tab, result: result, filter: current && tab.showColumnFilter ? tab.columnFilter : "",
                            editsVersion: tab.editsVersion, store: store, isCurrent: current,
                            forwardsScrolling: stacked) { select(index) }
            .overlay {
                if result.rows.isEmpty {
                    // An empty grid looks like nothing happened, so say so.
                    VStack(spacing: 4) {
                        Text("No rows returned").font(.system(size: 13, weight: .semibold))
                        Text("The query ran without errors, but nothing matched.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
                    .allowsHitTesting(false)
                }
            }
    }

    /// Every result one above another: up to three fill the panel, more scroll.
    private var stackedResults: some View {
        GeometryReader { geometry in
            let visible = CGFloat(min(tab.results.count, 3))
            let height = max(150, (geometry.size.height - visible * 24) / visible)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(Array(tab.results.enumerated()), id: \.element.id) { index, result in
                            VStack(spacing: 0) {
                                stackHeader(result, index: index)
                                grid(result, index: index, stacked: true).frame(height: height)
                            }
                            .id(result.id)
                        }
                    }
                }
                .onChange(of: scrollTarget) {
                    guard let scrollTarget else { return }
                    withAnimation { proxy.scrollTo(scrollTarget, anchor: .top) }
                    self.scrollTarget = nil
                }
            }
        }
    }

    private func stackHeader(_ result: ResultSet, index: Int) -> some View {
        let current = tab.selectedResult == index
        return HStack(spacing: 6) {
            Text("Result \(index + 1)").fontWeight(.semibold)
            Text("\(result.totalRows.formatted()) row\(result.totalRows == 1 ? "" : "s")").foregroundStyle(.secondary)
            Text(result.statement.replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(current ? Theme.selection.opacity(0.55) : Theme.panel)
        .contentShape(Rectangle())
        .onTapGesture { select(index) }
        .help(result.statement)
    }

    private func columnFilterBar(_ result: ResultSet) -> some View {
        @Bindable var tab = tab
        let matches = tab.columnFilter.trimmed.isEmpty
            ? result.columns.count
            : result.columns.filter { $0.name.localizedCaseInsensitiveContains(tab.columnFilter.trimmed) }.count

        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
            TextField("Find column — only matching columns are shown", text: $tab.columnFilter)
                .textFieldStyle(.plain)
                .focused($filterFocused)
                .onKeyPress(.escape) {
                    tab.columnFilter = ""
                    tab.showColumnFilter = false
                    return .handled
                }
            Text("\(matches) of \(result.columns.count) columns").foregroundStyle(.secondary)
            Button {
                tab.columnFilter = ""
                tab.showColumnFilter = false
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.panel)
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            if tab.running, let started = tab.runStarted {
                ProgressView().controlSize(.mini)
                TimelineView(.periodic(from: started, by: 0.1)) { context in
                    Text("Running… \(Formats.duration(context.date.timeIntervalSince(started)))")
                }
            } else if let result = tab.currentResult {
                Text(result.isTruncated
                     ? "Showing the first \(result.rows.count.formatted()) of \(result.totalRows.formatted()) records"
                     : "\(result.totalRows.formatted()) record\(result.totalRows == 1 ? "" : "s")")
                    .foregroundStyle(result.isTruncated ? .orange : .secondary)
                if !tab.selectedRows.isEmpty { Text("· \(tab.selectedRows.count) selected") }
                Text("· \(result.columns.count) columns · \(Formats.duration(result.duration))")
                let warnings = tab.outcomes.reduce(0) { $0 + $1.warnings }
                if warnings > 0 {
                    Button {
                        tab.showMessages = true
                    } label: {
                        Label("\(warnings) warning\(warnings == 1 ? "" : "s"): see Messages", systemImage: "exclamationmark.triangle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                }
            } else if let last = tab.outcomes.last {
                Text(last.summary).lineLimit(1)
            }
            Spacer()
            if tab.editCount > 0 {
                // Pending grid edits: nothing is written until Apply (after a preview).
                Text("\(tab.editCount) unsaved change\(tab.editCount == 1 ? "" : "s")")
                    .foregroundStyle(.orange)
                Button("Revert") { tab.revertEdits() }
                    .help("Discard all unsaved changes")
                Button("Apply…") { store.previewEdits(tab) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .help("Preview the UPDATE statements, then save the changes")
                    .disabled(tab.applying)
                if tab.applying { ProgressView().controlSize(.mini) }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: tab.editCount > 0 ? 30 : 22)
        .background(Theme.toolbar)
    }

    private func pill(_ title: String, count: Int?, selected: Bool, error: Bool = false, warnings: Int = 0,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if error {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                } else if warnings > 0 {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Text(title)
                if let count { Text(count.formatted()).foregroundStyle(.secondary) }
                if warnings > 0 && !error { Text(warnings.formatted()).foregroundStyle(.orange) }
            }
            .font(.system(size: 11, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Theme.selection : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One line per statement: ✓/✗, what happened, how long it took.
private struct MessagesView: View {
    let outcomes: [StatementOutcome]

    var body: some View {
        if outcomes.isEmpty {
            Text("No messages").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(outcomes) { outcome in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: outcome.isError ? "xmark.octagon.fill" : outcome.warnings > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(outcome.isError ? .red : outcome.warnings > 0 ? .orange : .green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(outcome.summary)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(outcome.isError ? .red : .primary)
                            .textSelection(.enabled)
                        Text(outcome.sql.replacingOccurrences(of: "\n", with: " "))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                        if let note = outcome.note {
                            Label(note, systemImage: "info.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(outcome.warningMessages.enumerated()), id: \.offset) { _, message in
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Formats.duration(outcome.duration))
                        if outcome.warnings > 0 { Text("\(outcome.warnings) warnings").foregroundStyle(.orange) }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }
}
