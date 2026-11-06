import SwiftUI

/// Left panel: each connected server (as in SQLPro), its favourites and schemas, and each schema's
/// tables. Views, procedures and functions are left out on purpose. Saved connections that aren't
/// open are listed underneath for one-click connecting.
///
/// The tree is flattened into rows and drawn in a LazyVStack rather than a SwiftUI List: List's
/// nested disclosure groups lose rows when data arrives while they're expanding, and a flat list
/// copes easily with thousands of tables. ⌃D focuses it; ↑ ↓ move, → ← expand/collapse, ↩ opens.
struct SidebarView: View {
    @Environment(AppStore.self) private var store
    @State private var filter = ""
    @State private var selection: String?
    @State private var showSaved = true
    @FocusState private var filterFocused: Bool
    @FocusState private var treeFocused: Bool

    enum SidebarItem: Hashable {
        case server(UUID)
        case favourites(UUID)
        case schema(UUID, String)
        case table(UUID, String, String)
        case favourite(UUID)
        case savedHeader
        case saved(UUID)
        case note(String, String, Bool) // id, text, is error
    }

    struct Row: Identifiable {
        let id: String
        let item: SidebarItem
        let depth: Int
    }

    private var query: String { filter.trimmed }

    var body: some View {
        let rows = rows()

        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                TextField("Filter schemas and tables", text: $filter)
                    .textFieldStyle(.plain)
                    .focused($filterFocused)
                    .onKeyPress(.escape) {
                        filter = ""
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        treeFocused = true
                        selection = rows.first { isSelectable($0.item) }?.id
                        return .handled
                    }
                if !filter.isEmpty {
                    Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12))
            .padding(8)
            .background(Theme.toolbar)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            rowView(row)
                                .id(row.id)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .focusable()
                .focusEffectDisabled()
                .focused($treeFocused)
                .onKeyPress(.downArrow) { move(1, in: rows, proxy: proxy) }
                .onKeyPress(.upArrow) { move(-1, in: rows, proxy: proxy) }
                .onKeyPress(.rightArrow) { setExpanded(true, rows: rows) }
                .onKeyPress(.leftArrow) { setExpanded(false, rows: rows) }
                .onKeyPress(.return) {
                    if let item = rows.first(where: { $0.id == selection })?.item { activate(item) }
                    return .handled
                }
            }
            .overlay {
                if store.connections.isEmpty {
                    ContentUnavailableView {
                        Label("No connections", systemImage: "server.rack")
                    } description: {
                        Text("Add your MySQL servers to get started.")
                    } actions: {
                        Button("Add Connection…") { store.showManager() }
                    }
                }
            }
        }
        .background(Theme.panel.opacity(0.6))
        .onChange(of: filter) {
            // Filtering needs every schema's tables, so fetch them all in one go.
            guard !query.isEmpty else { return }
            for server in store.servers where server.isConnected { Task { await server.loadAllTables() } }
        }
        .onChange(of: store.sidebarFilterFocus) { filterFocused = true }
        .onChange(of: store.sidebarTreeFocus) {
            treeFocused = true
            if selection == nil { selection = rows.first { isSelectable($0.item) }?.id }
        }
    }

    // MARK: Building the rows

    private func rows() -> [Row] {
        var rows: [Row] = []
        for server in store.servers {
            let id = server.id.uuidString
            rows.append(Row(id: id, item: .server(server.id), depth: 0))
            guard server.expanded || !query.isEmpty else { continue }

            switch server.state {
            case .connecting:
                rows.append(Row(id: id + "/note", item: .note(id + "/note", "Connecting…", false), depth: 1))
            case .failed(let message):
                rows.append(Row(id: id + "/note", item: .note(id + "/note", message, true), depth: 1))
            case .connected:
                let favourites = store.favourites(for: server.id).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
                if !favourites.isEmpty {
                    rows.append(Row(id: id + "/favourites", item: .favourites(server.id), depth: 1))
                    if server.showFavourites || !query.isEmpty {
                        rows += favourites.map { Row(id: $0.id.uuidString, item: .favourite($0.id), depth: 2) }
                    }
                }
                for schema in server.schemas where schemaMatches(schema) {
                    rows.append(Row(id: schema.id, item: .schema(server.id, schema.name), depth: 1))
                    let tables = (schema.tables ?? []).filter { tableMatches($0, in: schema) }
                    // While filtering, open schemas whose tables match (but not ones matched by name alone).
                    let open = schema.expanded || (!query.isEmpty && !tables.isEmpty && !schema.name.localizedCaseInsensitiveContains(query))
                    guard open else { continue }
                    if schema.tables == nil {
                        rows.append(Row(id: schema.id + "/note", item: .note(schema.id + "/note", "Loading…", false), depth: 2))
                    } else if tables.isEmpty && query.isEmpty {
                        rows.append(Row(id: schema.id + "/note", item: .note(schema.id + "/note", "No tables", false), depth: 2))
                    }
                    rows += tables.map { Row(id: schema.id + "/" + $0, item: .table(server.id, schema.name, $0), depth: 2) }
                }
            }
        }

        let saved = store.connections.filter { store.server($0.id) == nil }
        if !saved.isEmpty && query.isEmpty {
            rows.append(Row(id: "saved", item: .savedHeader, depth: 0))
            if showSaved {
                rows += saved.map { Row(id: "saved/" + $0.id.uuidString, item: .saved($0.id), depth: 0) }
            }
        }
        return rows
    }

    private func schemaMatches(_ schema: Schema) -> Bool {
        query.isEmpty || schema.name.localizedCaseInsensitiveContains(query)
            || (schema.tables ?? []).contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private func tableMatches(_ table: String, in schema: Schema) -> Bool {
        query.isEmpty || schema.name.localizedCaseInsensitiveContains(query) || table.localizedCaseInsensitiveContains(query)
    }

    // MARK: Drawing a row

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        let selected = selection == row.id
        Group {
            switch row.item {
            case .server(let id):
                if let server = store.server(id) {
                    TreeRow(depth: 0, expanded: server.expanded, selected: selected, toggle: { toggle(row.item) }) {
                        ServerHeader(server: server)
                    }
                    .padding(.top, row.id == store.servers.first?.id.uuidString ? 0 : 8)
                }
            case .favourites(let id):
                TreeRow(depth: row.depth, expanded: store.server(id)?.showFavourites == true || !query.isEmpty, selected: selected,
                        toggle: { toggle(row.item) }) {
                    Label("Favourites", systemImage: "star.fill").foregroundStyle(.yellow)
                }
            case .favourite(let id):
                if let favourite = store.favourites.first(where: { $0.id == id }) {
                    TreeRow(depth: row.depth, selected: selected) {
                        Label(favourite.name, systemImage: "star").lineLimit(1)
                    }
                    .help(favourite.sql)
                }
            case .schema(let id, let name):
                let schema = store.server(id)?.schemas.first { $0.name == name }
                TreeRow(depth: row.depth, expanded: schema?.expanded == true, selected: selected, toggle: { toggle(row.item) }) {
                    Label {
                        Text(name)
                    } icon: {
                        Image(systemName: "cylinder").foregroundStyle(.secondary)
                    }
                    if schema?.loading == true { Spacer(); ProgressView().controlSize(.mini) }
                }
            case .table(_, _, let table):
                TreeRow(depth: row.depth, selected: selected) {
                    Label {
                        Text(table).lineLimit(1)
                    } icon: {
                        Image(systemName: "tablecells").foregroundStyle(Theme.colour(.blue).opacity(0.8))
                    }
                }
            case .savedHeader:
                TreeRow(depth: 0, expanded: showSaved, selected: false, toggle: { showSaved.toggle() }) {
                    SectionHeader(title: "Connections", count: store.connections.filter { store.server($0.id) == nil }.count)
                }
                .padding(.top, 12)
            case .saved(let id):
                if let config = store.config(id) {
                    TreeRow(depth: 0, selected: selected) {
                        RoundedRectangle(cornerRadius: 2).fill(Theme.colour(config.colour)).frame(width: 3, height: 14)
                        Text(config.name)
                        Spacer()
                        Text(config.username).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    .help("Double-click to connect")
                }
            case .note(_, let text, let isError):
                TreeRow(depth: row.depth, selected: false) {
                    Text(text).font(.system(size: 11)).foregroundStyle(isError ? Color.red : Color.secondary).lineLimit(3)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard isSelectable(row.item) else { return }
            selection = row.id
            // One gesture for both: the second click of a double-click arrives with clickCount 2,
            // so single clicks select straight away instead of waiting to rule out a double-click.
            if NSApp.currentEvent?.clickCount == 2 { activate(row.item) }
        }
        .contextMenu { menu(for: row.item) }
    }

    private func isSelectable(_ item: SidebarItem) -> Bool {
        switch item {
        case .note, .savedHeader: false
        default: true
        }
    }

    // MARK: Keyboard

    private func move(_ offset: Int, in rows: [Row], proxy: ScrollViewProxy) -> KeyPress.Result {
        let selectable = rows.filter { isSelectable($0.item) }
        guard !selectable.isEmpty else { return .ignored }
        let index = selectable.firstIndex { $0.id == selection } ?? (offset > 0 ? -1 : selectable.count)
        let next = selectable[max(0, min(selectable.count - 1, index + offset))]
        selection = next.id
        proxy.scrollTo(next.id)
        return .handled
    }

    private func setExpanded(_ expand: Bool, rows: [Row]) -> KeyPress.Result {
        guard let row = rows.first(where: { $0.id == selection }) else { return .ignored }
        if isExpanded(row.item) != expand, isExpandable(row.item) {
            toggle(row.item)
        } else if !expand, let parent = parent(of: row, in: rows) {
            selection = parent.id // ← on a child jumps to its parent, as in Finder
        }
        return .handled
    }

    private func parent(of row: Row, in rows: [Row]) -> Row? {
        guard row.depth > 0, let index = rows.firstIndex(where: { $0.id == row.id }) else { return nil }
        return rows[..<index].last { $0.depth < row.depth }
    }

    private func isExpandable(_ item: SidebarItem) -> Bool {
        switch item {
        case .server, .favourites, .schema: true
        default: false
        }
    }

    private func isExpanded(_ item: SidebarItem) -> Bool {
        switch item {
        case .server(let id): store.server(id)?.expanded == true
        case .favourites(let id): store.server(id)?.showFavourites == true
        case .schema(let id, let name): store.server(id)?.schemas.first { $0.name == name }?.expanded == true
        default: false
        }
    }

    private func toggle(_ item: SidebarItem) {
        switch item {
        case .server(let id):
            store.server(id)?.expanded.toggle()
        case .favourites(let id):
            store.server(id)?.showFavourites.toggle()
        case .schema(let id, let name):
            guard let server = store.server(id), let schema = server.schemas.first(where: { $0.name == name }) else { return }
            schema.expanded.toggle()
            if schema.expanded && schema.tables == nil { Task { await server.loadTables(schema) } }
        default:
            break
        }
    }

    // MARK: Actions

    /// Double-click / Return: open tables, favourites and connections; expand or collapse the rest.
    private func activate(_ item: SidebarItem) {
        switch item {
        case .server, .favourites, .schema:
            toggle(item)
        case .table(let id, let schema, let table):
            if let server = store.server(id) { store.openTable(table, in: schema, on: server) }
        case .favourite(let id):
            if let favourite = store.favourites.first(where: { $0.id == id }) { store.openFavourite(favourite) }
        case .saved(let id):
            if let config = store.config(id) { store.connectAndOpen(config) }
        case .savedHeader, .note:
            break
        }
    }

    @ViewBuilder
    private func menu(for item: SidebarItem) -> some View {
        switch item {
        case .server(let id):
            if let server = store.server(id) {
                Button("New Query") { store.newTab(connectionID: id) }
                Button("Refresh") { store.refresh(server) }
                Divider()
                Button("Edit Connection…") { store.showManager(selecting: id) }
                Button("Disconnect") { store.disconnect(server) }
            }
        case .schema(let id, let schema):
            Button("New Query on \(schema)") { store.newTab(connectionID: id, database: schema) }
            if let tab = store.selectedTab {
                Button("Use in Current Tab") { store.setTarget(tab, connectionID: id, database: schema) }
            }
            Divider()
            Button("Refresh") {
                if let server = store.server(id), let found = server.schemas.first(where: { $0.name == schema }) {
                    Task { await server.loadTables(found) }
                }
            }
            Button("Copy Name") { copy(schema) }
        case .table(let id, let schema, let table):
            if let server = store.server(id) {
                Button("Select Rows (LIMIT)") { store.openTable(table, in: schema, on: server) }
                Button("Select All Rows") { store.openTable(table, in: schema, on: server, limit: false) }
                Button("Show Columns") { store.describeTable(table, in: schema, on: server) }
                Button("Show CREATE TABLE") { store.showCreateTable(table, in: schema, on: server) }
                Divider()
                Button("Insert Name into Query") { store.insertIntoEditor(SQL.identifier(table)) }
                Button("Copy Name") { copy(table) }
                Button("Copy Full Name") { copy("\(SQL.identifier(schema)).\(SQL.identifier(table))") }
            }
        case .favourite(let id):
            if let favourite = store.favourites.first(where: { $0.id == id }) {
                Button("Open") { store.openFavourite(favourite) }
                Button("Open and Run") { store.openFavourite(favourite, run: true) }
                Divider()
                Button("Edit…") { store.editFavourite(favourite) }
                Button("Copy SQL") { copy(favourite.sql) }
                Divider()
                Button("Delete", role: .destructive) { store.deleteFavourite(favourite) }
            }
        case .saved(let id):
            if let config = store.config(id) {
                Button("Connect") { store.connectAndOpen(config) }
                Button("Edit Connection…") { store.showManager(selecting: id) }
            }
        case .favourites, .savedHeader, .note:
            EmptyView()
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// One line of the tree: indent, optional disclosure chevron, content, selection highlight.
private struct TreeRow<Content: View>: View {
    let depth: Int
    var expanded: Bool?
    let selected: Bool
    var toggle: (() -> Void)?
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    init(depth: Int, expanded: Bool? = nil, selected: Bool, toggle: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.depth = depth
        self.expanded = expanded
        self.selected = selected
        self.toggle = toggle
        self.content = content
    }

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if let expanded, let toggle {
                    Button(action: toggle) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 14, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                } else {
                    Color.clear.frame(width: 14, height: 1)
                }
            }
            HStack(spacing: 6) { content() }
                .font(.system(size: 12))
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 14 + 6)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(selected ? Theme.selection : (hovering ? Theme.hover : .clear))
                .padding(.horizontal, 4)
        )
        .onHover { hovering = $0 }
    }
}

/// "PRODUCTION (REPORTING)" over "MySQL 8.4.11", with the connection's colour tag.
private struct ServerHeader: View {
    let server: Server

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack")
                .font(.system(size: 13))
                .foregroundStyle(Theme.colour(server.config.colour))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(server.config.name) (\(server.config.username))".uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .lineLimit(1)
                Text(server.versionLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Theme.colour(server.config.colour))
                    .frame(width: 24, height: 2)
            }
            Spacer(minLength: 4)
            if server.state == .connecting { ProgressView().controlSize(.mini) }
        }
    }
}
