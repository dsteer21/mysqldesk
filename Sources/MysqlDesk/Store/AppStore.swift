import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// App-wide state: saved connections, connected servers, query tabs, favourites and history.
@MainActor @Observable
final class AppStore {
    var connections: [ConnectionConfig] = [] {
        didSet { Storage.save(connections, to: "connections.json") }
    }
    var favourites: [Favourite] = [] {
        didSet { Storage.save(favourites, to: "favourites.json") }
    }
    var history: [HistoryEntry] = [] {
        didSet { Storage.save(history, to: "history.json") }
    }

    var servers: [Server] = []
    var tabs: [QueryTab] = []
    var selectedTabID: UUID? {
        didSet { if selectedTabID != nil { showHome = false } }
    }

    // UI state shared between views and menu commands.
    var showHome = false
    var showConnectionManager = false
    var managerSelection: UUID?
    var showPalette = false
    var passwordRequest: PasswordRequest?
    var favouriteDraft: FavouriteDraft?
    var valueViewer: ValueViewerItem?
    var cellEditor: CellEditorItem?
    var applyPreview: ApplyPreview?
    /// Bumped to move focus to the sidebar filter (⌃F) or the schema tree (⌃D).
    var sidebarFilterFocus = 0
    var sidebarTreeFocus = 0

    @ObservationIgnored private var saveTabsTask: Task<Void, Never>?

    struct PasswordRequest: Identifiable {
        let id = UUID()
        let config: ConnectionConfig
        let continuation: CheckedContinuation<String?, Never>
    }

    struct FavouriteDraft: Identifiable {
        let id = UUID()
        var favouriteID: UUID?
        var name: String
        var sql: String
        var connectionID: UUID
        var database: String?
        var tabID: UUID?
    }

    struct ValueViewerItem: Identifiable {
        let id = UUID()
        let column: String
        let value: String?
    }

    /// Multi-line or long values are edited in a sheet rather than in the grid.
    struct CellEditorItem: Identifiable {
        let id = UUID()
        let tabID: UUID
        let resultID: UUID
        let row: Int
        let column: Int
        let columnName: String
        let value: String?
        let nullable: Bool
    }

    /// The UPDATE statements shown for confirmation before they're run.
    struct ApplyPreview: Identifiable {
        let id = UUID()
        let tabID: UUID
        let statements: [String]
    }

    enum RunMode {
        case all, current
    }

    init() {
        connections = Storage.load([ConnectionConfig].self, from: "connections.json") ?? []
        favourites = Storage.load([Favourite].self, from: "favourites.json") ?? []
        history = Storage.load([HistoryEntry].self, from: "history.json") ?? []
        tabs = (Storage.load([SavedTab].self, from: "tabs.json") ?? []).map {
            QueryTab(title: $0.title, sql: $0.sql, connectionID: $0.connectionID, database: $0.database, favouriteID: $0.favouriteID)
        }
        selectedTabID = tabs.first?.id
    }

    // MARK: Settings

    private var maxRows: Int { max(UserDefaults.standard.object(forKey: "maxRows") as? Int ?? 50_000, 100) }
    private var tableRowLimit: Int { UserDefaults.standard.object(forKey: "tableRowLimit") as? Int ?? 1000 }
    private var stopOnError: Bool { UserDefaults.standard.object(forKey: "stopOnError") as? Bool ?? true }

    // MARK: Lookups

    var selectedTab: QueryTab? { tabs.first { $0.id == selectedTabID } }

    func config(_ id: UUID?) -> ConnectionConfig? { connections.first { $0.id == id } }

    func server(_ id: UUID?) -> Server? { servers.first { $0.id == id } }

    func favourites(for connectionID: UUID?) -> [Favourite] {
        favourites.filter { $0.connectionID == connectionID }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Connections

    func saveConnection(_ config: ConnectionConfig) {
        if let index = connections.firstIndex(where: { $0.id == config.id }) {
            connections[index] = config
        } else {
            connections.append(config)
        }
        // Takes effect for new sessions; existing ones keep running.
        server(config.id)?.config = config
    }

    func deleteConnection(_ id: UUID) {
        if let server = server(id) { disconnect(server) }
        Keychain.deletePassword(for: id)
        favourites.removeAll { $0.connectionID == id }
        connections.removeAll { $0.id == id }
    }

    func moveConnection(_ id: UUID, by offset: Int) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard connections.indices.contains(target) else { return }
        connections.swapAt(index, target)
        sortServers()
    }

    func showManager(selecting id: UUID? = nil) {
        managerSelection = id ?? selectedTab?.connectionID ?? connections.first?.id
        showConnectionManager = true
    }

    /// Connects (asking for the password if the Keychain doesn't have one) and adds the server to the sidebar.
    @discardableResult
    func connect(_ config: ConnectionConfig) async -> Server? {
        if let existing = server(config.id) {
            if existing.isConnected || existing.state == .connecting { return existing }
            servers.removeAll { $0.id == config.id }
        }
        var password = Keychain.password(for: config.id)
        if password == nil {
            guard let entered = await requestPassword(for: config) else { return nil }
            password = entered
        }
        if let existing = server(config.id) { return existing } // connected while the prompt was open

        let server = Server(config: config, password: password)
        servers.append(server)
        sortServers()
        do {
            try await server.connect()
            return server
        } catch {
            servers.removeAll { $0.id == config.id }
            Banner.shared.error("Couldn't connect to \(config.name)", detail: error.localizedDescription)
            return nil
        }
    }

    func connectAndOpen(_ config: ConnectionConfig) {
        Task {
            guard await connect(config) != nil else { return }
            if let tab = selectedTab, tab.connectionID == nil, tab.sql.trimmed.isEmpty {
                setTarget(tab, connectionID: config.id, database: config.defaultSchema.isEmpty ? nil : config.defaultSchema)
            } else {
                newTab(connectionID: config.id, database: config.defaultSchema.isEmpty ? nil : config.defaultSchema)
            }
        }
    }

    func disconnect(_ server: Server) {
        servers.removeAll { $0.id == server.id }
        Task {
            for tab in tabs where tab.sessionServerID == server.id { await tab.closeSession() }
            await server.disconnect()
        }
    }

    func refresh(_ server: Server?) {
        guard let server else { return }
        Task { await server.loadSchemas() }
    }

    /// Keep the sidebar in the same order as the connection list.
    private func sortServers() {
        let order = connections.map(\.id)
        servers.sort { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
    }

    private func requestPassword(for config: ConnectionConfig) async -> String? {
        await withCheckedContinuation { continuation in
            passwordRequest = PasswordRequest(config: config, continuation: continuation)
        }
    }

    func resolvePassword(_ password: String?, remember: Bool) {
        guard let request = passwordRequest else { return }
        passwordRequest = nil
        if let password, remember {
            Keychain.setPassword(password, for: request.config.id, label: request.config.name)
        }
        request.continuation.resume(returning: password)
    }

    // MARK: Tabs

    @discardableResult
    func newTab(connectionID: UUID? = nil, database: String? = nil, sql: String = "", title: String? = nil, favouriteID: UUID? = nil) -> QueryTab {
        let target = connectionID ?? selectedTab?.connectionID ?? servers.first?.id
        let schema = connectionID == nil && target == selectedTab?.connectionID ? selectedTab?.database : database
        let tab = QueryTab(title: title ?? nextTitle(), sql: sql, connectionID: target, database: schema, favouriteID: favouriteID)
        if let index = tabs.firstIndex(where: { $0.id == selectedTabID }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        selectedTabID = tab.id
        tabsChanged()
        DispatchQueue.main.async { tab.editor.focus() }
        return tab
    }

    private func nextTitle() -> String {
        let used = Set(tabs.map(\.title))
        return (1...).lazy.map { "Query \($0)" }.first { !used.contains($0) }!
    }

    func closeTab(_ tab: QueryTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if tab.running { cancel(tab) }
        tabs.remove(at: index)
        if selectedTabID == tab.id {
            selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
        Task { await tab.closeSession() }
        tabsChanged()
    }

    func closeOtherTabs(_ tab: QueryTab) {
        for other in tabs where other.id != tab.id { closeTab(other) }
    }

    func duplicateTab(_ tab: QueryTab) {
        newTab(connectionID: tab.connectionID, database: tab.database, sql: tab.sql, title: tab.title + " copy")
    }

    /// ⇧⌘] / ⇧⌘[
    func selectTab(offset: Int) {
        guard !tabs.isEmpty else { return }
        let index = tabs.firstIndex { $0.id == selectedTabID } ?? 0
        selectedTabID = tabs[(index + offset + tabs.count) % tabs.count].id
    }

    /// ⌘1…⌘9 (⌘9 is always the last tab, as in Safari).
    func selectTab(number: Int) {
        guard !tabs.isEmpty else { return }
        selectedTabID = number == 9 ? tabs.last?.id : tabs[safe: number - 1]?.id ?? selectedTabID
    }

    func moveTab(_ id: UUID, before target: UUID) {
        guard id != target, let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: from)
        let to = tabs.firstIndex { $0.id == target } ?? tabs.count
        tabs.insert(tab, at: to)
        tabsChanged()
    }

    /// Point a tab at another server and/or schema. The SQL stays as it is.
    func setTarget(_ tab: QueryTab, connectionID: UUID, database: String?) {
        if tab.connectionID != connectionID {
            Task { await tab.closeSession() }
            tab.connectionID = connectionID
        }
        tab.database = database
        tabsChanged()
        if let config = config(connectionID), server(connectionID) == nil {
            Task { await connect(config) }
        }
    }

    /// Saves open tabs shortly after the last change, so they come back after a relaunch.
    func tabsChanged() {
        saveTabsTask?.cancel()
        saveTabsTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            saveTabs()
        }
    }

    func saveTabs() {
        Storage.save(tabs.map(\.saved), to: "tabs.json")
    }

    // MARK: Sidebar actions

    func openTable(_ table: String, in schema: String, on server: Server, limit: Bool = true) {
        let sql = "SELECT * FROM \(SQL.identifier(schema)).\(SQL.identifier(table))" + (limit ? " LIMIT \(tableRowLimit)" : "") + ";"
        let tab = newTab(connectionID: server.id, database: schema, sql: sql, title: table)
        run(tab, .all)
    }

    func describeTable(_ table: String, in schema: String, on server: Server) {
        let sql = "SHOW FULL COLUMNS FROM \(SQL.identifier(schema)).\(SQL.identifier(table));"
        let tab = newTab(connectionID: server.id, database: schema, sql: sql, title: "\(table) columns")
        run(tab, .all)
    }

    func showCreateTable(_ table: String, in schema: String, on server: Server) {
        Task {
            let config = server.config
            do {
                let session = try await server.openSession(database: schema)
                let responses: [QueryResponse]
                do {
                    responses = try await session.execute("SHOW CREATE TABLE \(SQL.identifier(schema)).\(SQL.identifier(table))", maxRows: 1)
                } catch {
                    await session.close()
                    throw error
                }
                await session.close()
                guard case .rows(_, let rows, _, _)? = responses.first, let create = rows.first?[1] else { return }
                newTab(connectionID: config.id, database: schema, sql: create + ";", title: "\(table) create")
            } catch {
                Banner.shared.error("Couldn't read the table definition", detail: error.localizedDescription)
            }
        }
    }

    /// Typing into the current editor, e.g. a table name from the sidebar.
    func insertIntoEditor(_ text: String) {
        guard let tab = selectedTab else { return }
        tab.editor.insert(text)
    }

    // MARK: Running queries

    func run(_ tab: QueryTab?, _ mode: RunMode) {
        guard let tab, !tab.running else { return }
        let text: String
        if let selection = tab.editor.selectedText, !selection.trimmed.isEmpty {
            text = selection
        } else if mode == .current, let statement = SQL.statement(at: tab.editor.cursor, in: tab.sql) {
            text = statement.text
            tab.editor.flash(statement.range)
        } else {
            text = tab.sql
        }
        let statements = SQL.statements(in: text).map(\.text)
        guard !statements.isEmpty else { return }
        Task { await execute(statements, in: tab) }
    }

    private func execute(_ statements: [String], in tab: QueryTab) async {
        guard let connectionID = tab.connectionID, let config = config(connectionID) else {
            Banner.shared.error("Choose a connection for this tab first")
            tab.showTargetPicker = true
            return
        }
        // A new run replaces the results, so unapplied edits go too.
        tab.revertEdits()
        tab.running = true
        tab.runStarted = Date()
        tab.cancelled = false
        tab.results = []
        tab.outcomes = []
        tab.selectedResult = 0
        tab.selectedRows = []
        tab.showMessages = false
        tab.showResults = true
        defer {
            tab.running = false
            tab.runStarted = nil
        }

        guard let server = await connect(config) else { return }
        let session: DatabaseConnection
        do {
            session = try await tab.session(on: server)
        } catch {
            tab.outcomes = [StatementOutcome(sql: statements[0], kind: .failed(error.localizedDescription), duration: 0, warnings: 0)]
            tab.showMessages = true
            return
        }

        for statement in statements {
            if tab.cancelled { break }
            let started = Date()
            do {
                let responses = try await session.execute(statement, maxRows: maxRows)
                let duration = Date().timeIntervalSince(started)
                // MySQL reports many problems as warnings, not errors (e.g. comparing a number column with
                // text). Fetch their text straight away, before another statement clears them.
                let warningMessages = await warnings(for: responses, on: session)
                for response in responses {
                    switch response {
                    case .rows(let columns, let rows, let total, let warnings):
                        tab.results.append(ResultSet(statement: statement, columns: columns, rows: rows, totalRows: total, duration: duration))
                        tab.outcomes.append(StatementOutcome(sql: statement, kind: .rows(total), duration: duration, warnings: warnings,
                                                             warningMessages: warnings > 0 ? warningMessages : []))
                    case .ok(let affected, let insertID, let warnings, let info):
                        // A CALL ends with a bare OK after its result sets; it adds nothing to show.
                        if responses.count > 1 && affected == 0 { continue }
                        tab.outcomes.append(StatementOutcome(sql: statement, kind: .affected(rows: affected, insertID: insertID, info: info),
                                                             duration: duration, warnings: warnings,
                                                             warningMessages: warnings > 0 ? warningMessages : []))
                    }
                }
                if SQL.verb(of: statement) == "USE" {
                    tab.noteSessionDatabase(try? await session.strings("SELECT DATABASE()").first)
                }
            } catch {
                let interrupted = (error as? QueryError)?.code == 1317
                tab.outcomes.append(StatementOutcome(sql: statement, kind: tab.cancelled || interrupted ? .cancelled : .failed(error.localizedDescription),
                                                     duration: Date().timeIntervalSince(started), warnings: 0))
                if session.isClosed { await tab.closeSession() }
                if stopOnError || tab.cancelled { break }
            }
        }

        tab.showMessages = tab.results.isEmpty || tab.outcomes.contains(where: \.isError)
        addHistory(statements.joined(separator: ";\n") + ";", connectionID: connectionID, database: tab.database)
        tabsChanged()
    }

    /// The text of a statement's warnings ("Warning 1292: Truncated incorrect DECIMAL value: 'abc'").
    private func warnings(for responses: [QueryResponse], on session: DatabaseConnection) async -> [String] {
        let count = responses.reduce(0) { total, response in
            switch response {
            case .rows(_, _, _, let warnings), .ok(_, _, let warnings, _): total + warnings
            }
        }
        guard count > 0, case .rows(_, let rows, _, _)? = try? await session.execute("SHOW WARNINGS", maxRows: 100).first else { return [] }
        // SHOW WARNINGS columns: Level, Code, Message
        return rows.map { "\($0[0] ?? "Warning") \($0[1] ?? ""): \($0[2] ?? "")" }
    }

    func cancel(_ tab: QueryTab?) {
        guard let tab, tab.running else { return }
        tab.cancelled = true
        guard let session = tab.session, let server = server(tab.sessionServerID) else { return }
        Task { await server.killQuery(threadID: session.threadID) }
    }

    private func addHistory(_ sql: String, connectionID: UUID, database: String?) {
        if history.first?.sql == sql && history.first?.connectionID == connectionID { return }
        history.insert(HistoryEntry(sql: sql, connectionID: connectionID, database: database), at: 0)
        if history.count > 500 { history.removeLast(history.count - 500) }
    }

    func history(for connectionID: UUID?) -> [HistoryEntry] {
        history.filter { $0.connectionID == connectionID }
    }

    func openHistory(_ entry: HistoryEntry) {
        if let tab = selectedTab, tab.sql.trimmed.isEmpty {
            tab.editor.replaceAll(entry.sql)
            setTarget(tab, connectionID: entry.connectionID, database: entry.database)
        } else {
            newTab(connectionID: entry.connectionID, database: entry.database, sql: entry.sql)
        }
    }

    // MARK: Editing results

    /// Whether (and how) a result can be edited: every edited column must come from one table,
    /// and the result must include that table's primary key. Cached per result.
    func editContext(for tab: QueryTab, result: ResultSet) async -> Result<EditContext, EditError> {
        if let cached = tab.editContexts[result.id] { return cached }
        let context = await loadEditContext(for: tab, result: result)
        tab.editContexts[result.id] = context
        return context
    }

    private func loadEditContext(for tab: QueryTab, result: ResultSet) async -> Result<EditContext, EditError> {
        // Every real column must come from the same table under the same alias: in a self-join
        // (`items a JOIN items b`) b's columns can't be updated using a's key.
        let sources = Set(result.columns.filter { !$0.table.isEmpty && !$0.orgName.isEmpty }
            .map { "\($0.schema)\u{0}\($0.table)\u{0}\($0.tableAlias)" })
        guard sources.count == 1, let source = sources.first?.split(separator: "\u{0}", omittingEmptySubsequences: false) else {
            return .failure(EditError(message: sources.isEmpty
                ? "These columns don't come straight from a table."
                : "The columns come from more than one table. Query a single table to edit its rows."))
        }
        let table = String(source[1])
        guard let schema = source[0].isEmpty ? tab.database : String(source[0]) else {
            return .failure(EditError(message: "Choose a schema for this tab first."))
        }
        guard let config = config(tab.connectionID), let server = await connect(config) else {
            return .failure(EditError(message: "Not connected."))
        }

        let rows: [[String?]]
        do {
            let session = try await tab.session(on: server)
            let response = try await session.execute("SHOW COLUMNS FROM \(SQL.identifier(schema)).\(SQL.identifier(table))", maxRows: .max)
            guard case .rows(_, let found, _, _)? = response.first else { return .failure(EditError(message: "Couldn't read the table's columns.")) }
            rows = found
        } catch {
            return .failure(EditError(message: error.localizedDescription))
        }

        // SHOW COLUMNS: Field, Type, Null, Key, Default, Extra
        func resultIndex(of field: String) -> Int? {
            result.columns.firstIndex { $0.table == table && $0.orgName.caseInsensitiveCompare(field) == .orderedSame }
        }
        let keyFields = rows.filter { $0[3] == "PRI" }.compactMap { $0[0] }
        guard !keyFields.isEmpty else {
            return .failure(EditError(message: "`\(table)` has no primary key, so its rows can't be identified safely."))
        }
        let keyColumns = keyFields.compactMap(resultIndex)
        guard keyColumns.count == keyFields.count else {
            return .failure(EditError(message: "Include the primary key (\(keyFields.joined(separator: ", "))) in the query to edit its rows."))
        }

        var nullable = Set<Int>()
        var enumOptions: [Int: [String]] = [:]
        for row in rows {
            guard let field = row[0], let index = resultIndex(of: field) else { continue }
            if row[2] == "YES" { nullable.insert(index) }
            if let options = EditContext.enumOptions(from: row[1] ?? "") { enumOptions[index] = options }
        }
        let editable = Set(result.columns.indices.filter {
            result.columns[$0].table == table && !result.columns[$0].orgName.isEmpty && result.columns[$0].kind != .binary
        })
        return .success(EditContext(schema: schema, table: table, keyColumns: keyColumns, editable: editable,
                                    nullable: nullable, enumOptions: enumOptions))
    }

    /// Apply button: show the UPDATE statements first.
    func previewEdits(_ tab: QueryTab?) {
        guard let tab, let result = tab.editedResult, case .success(let context)? = tab.editContexts[result.id] else { return }
        let statements = context.updates(for: result, edits: tab.edits)
        guard !statements.isEmpty else { return }
        applyPreview = ApplyPreview(tabID: tab.id, statements: statements)
    }

    /// Runs the previewed UPDATEs in one transaction, so either every change is saved or none is.
    func applyEdits(_ preview: ApplyPreview) async {
        guard let tab = tabs.first(where: { $0.id == preview.tabID }), let result = tab.editedResult,
              let config = config(tab.connectionID), let server = await connect(config) else { return }
        tab.applying = true
        defer { tab.applying = false }
        var session: DatabaseConnection?
        do {
            let connection = try await tab.session(on: server)
            session = connection
            _ = try await connection.execute("START TRANSACTION", maxRows: 0)
            for statement in preview.statements {
                _ = try await connection.execute(statement, maxRows: 0)
            }
            _ = try await connection.execute("COMMIT", maxRows: 0)
        } catch {
            _ = try? await session?.execute("ROLLBACK", maxRows: 0)
            Banner.shared.error("Changes weren't saved", detail: error.localizedDescription + "\nNothing was changed. Your edits are still here to fix or revert.")
            return
        }

        for (row, changes) in tab.edits {
            for (column, value) in changes { result.setValue(value, row: row, column: column) }
        }
        let count = tab.edits.count
        tab.revertEdits()
        addHistory(preview.statements.joined(separator: "\n"), connectionID: config.id, database: tab.database)
        Banner.shared.info("Updated \(count) row\(count == 1 ? "" : "s")")
    }

    // MARK: Favourites

    /// ⌘S: update the tab's favourite, or ask for a name if it isn't one yet.
    func saveFavourite(_ tab: QueryTab?, asNew: Bool = false) {
        guard let tab else { return }
        guard let connectionID = tab.connectionID else {
            Banner.shared.error("Choose a connection for this tab before saving it as a favourite")
            return
        }
        if !asNew, let id = tab.favouriteID, let index = favourites.firstIndex(where: { $0.id == id }) {
            favourites[index].sql = tab.sql
            favourites[index].database = tab.database
            favourites[index].connectionID = connectionID
            favourites[index].updated = Date()
            Banner.shared.info("Saved “\(favourites[index].name)”")
            return
        }
        let name = tab.title.hasPrefix("Query ") ? "" : tab.title
        favouriteDraft = FavouriteDraft(name: name, sql: tab.sql, connectionID: connectionID, database: tab.database, tabID: tab.id)
    }

    func commitFavourite(_ draft: FavouriteDraft) {
        if let id = draft.favouriteID, let index = favourites.firstIndex(where: { $0.id == id }) {
            favourites[index].name = draft.name
            favourites[index].connectionID = draft.connectionID
            favourites[index].database = draft.database
            favourites[index].sql = draft.sql
            favourites[index].updated = Date()
            for tab in tabs where tab.favouriteID == id { tab.title = draft.name }
        } else {
            let favourite = Favourite(name: draft.name, sql: draft.sql, connectionID: draft.connectionID, database: draft.database)
            favourites.append(favourite)
            if let tab = tabs.first(where: { $0.id == draft.tabID }) {
                tab.favouriteID = favourite.id
                tab.title = favourite.name
            }
            Banner.shared.info("Added “\(favourite.name)” to favourites")
        }
        tabsChanged()
    }

    func editFavourite(_ favourite: Favourite) {
        favouriteDraft = FavouriteDraft(favouriteID: favourite.id, name: favourite.name, sql: favourite.sql,
                                        connectionID: favourite.connectionID, database: favourite.database)
    }

    func deleteFavourite(_ favourite: Favourite) {
        favourites.removeAll { $0.id == favourite.id }
        for tab in tabs where tab.favouriteID == favourite.id { tab.favouriteID = nil }
    }

    func openFavourite(_ favourite: Favourite, run: Bool = false) {
        let tab: QueryTab
        if let open = tabs.first(where: { $0.favouriteID == favourite.id }) {
            tab = open
            selectedTabID = tab.id
        } else if let current = selectedTab, current.sql.trimmed.isEmpty, current.favouriteID == nil {
            tab = current
            tab.title = favourite.name
            tab.favouriteID = favourite.id
            tab.editor.replaceAll(favourite.sql)
            tab.sql = favourite.sql
            setTarget(tab, connectionID: favourite.connectionID, database: favourite.database)
        } else {
            tab = newTab(connectionID: favourite.connectionID, database: favourite.database, sql: favourite.sql,
                         title: favourite.name, favouriteID: favourite.id)
        }
        if run { self.run(tab, .all) }
    }

    /// True when the tab's SQL differs from the favourite it was opened from.
    func isModified(_ tab: QueryTab) -> Bool {
        guard let id = tab.favouriteID, let favourite = favourites.first(where: { $0.id == id }) else { return false }
        return favourite.sql != tab.sql
    }

    // MARK: Copy and export

    func copy(_ tab: QueryTab?, as format: ExportFormat?, selectedOnly: Bool = true) {
        guard let tab, let result = tab.currentResult else { return }
        let rows = selectedOnly && !tab.selectedRows.isEmpty ? tab.selectedRows : nil
        let text: String
        if let format {
            text = Exporter.export(result, rows: rows, as: format)
        } else {
            text = Exporter.tsv(result.columns, (rows ?? Array(result.rows.indices)).map { result.rows[$0] }, header: false)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Saves the whole result, or just the selected rows, as CSV/JSON/SQL.
    func export(_ tab: QueryTab?, as format: ExportFormat, selectedOnly: Bool) {
        guard let tab, let result = tab.currentResult else {
            Banner.shared.error("There's no result to export")
            return
        }
        let rows = selectedOnly ? tab.selectedRows : nil
        if selectedOnly && tab.selectedRows.isEmpty {
            Banner.shared.error("Select some rows to export first")
            return
        }
        let panel = NSSavePanel()
        let base = result.sourceTable ?? tab.title.replacingOccurrences(of: " ", with: "-").lowercased()
        panel.nameFieldStringValue = "\(base)-\(Formats.fileDate.string(from: Date())).\(format.fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let count = rows?.count ?? result.rows.count
        Task.detached(priority: .userInitiated) {
            let text = Exporter.export(result, rows: rows, as: format)
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                await Banner.shared.info("Exported \(count.formatted()) rows to \(url.lastPathComponent)")
            } catch {
                await Banner.shared.error("Export failed", detail: error.localizedDescription)
            }
        }
        if result.isTruncated && !selectedOnly {
            Banner.shared.error("Only the first \(result.rows.count.formatted()) of \(result.totalRows.formatted()) rows were kept",
                                detail: "Raise “Rows kept per result” in Settings, or add a LIMIT, to export the rest.")
        }
    }

    // MARK: Command palette

    struct PaletteItem: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let action: () -> Void
    }

    /// ⌘P searches every table on the connected servers, not just schemas opened in the sidebar,
    /// so fetch their table lists (one query per server, run side by side). Cached until ⌘R.
    func loadTablesForPalette() async {
        await withTaskGroup(of: Void.self) { group in
            for server in servers where server.isConnected && !server.allTablesLoaded {
                group.addTask { await server.loadAllTables() }
            }
        }
    }

    var paletteNeedsTables: Bool { servers.contains { $0.isConnected && !$0.allTablesLoaded } }

    func paletteItems() -> [PaletteItem] {
        var items: [PaletteItem] = [
            PaletteItem(id: "a-new", title: "New Query Tab", subtitle: "⌘T", icon: "plus.square") { [weak self] in self?.newTab() },
            PaletteItem(id: "a-manage", title: "Manage Connections…", subtitle: "⇧⌘C", icon: "server.rack") { [weak self] in self?.showManager() },
            PaletteItem(id: "a-home", title: "Connections Home", subtitle: "⌘0", icon: "square.grid.2x2") { [weak self] in self?.showHome = true },
            PaletteItem(id: "a-format", title: "Format Query", subtitle: "⇧⌘K", icon: "text.alignleft") { [weak self] in self?.selectedTab?.editor.format() },
            PaletteItem(id: "a-fav", title: "Save as Favourite…", subtitle: "⌘S", icon: "star") { [weak self] in self?.saveFavourite(self?.selectedTab) },
        ]
        for format in ExportFormat.allCases {
            items.append(PaletteItem(id: "a-export-\(format.rawValue)", title: "Export Results as \(format.title)…", subtitle: "",
                                     icon: "square.and.arrow.up") { [weak self] in self?.export(self?.selectedTab, as: format, selectedOnly: false) })
        }
        for config in connections {
            items.append(PaletteItem(id: "c-\(config.id)", title: config.name, subtitle: "Connect · \(config.username)@\(config.address)",
                                     icon: "bolt.horizontal") { [weak self] in self?.connectAndOpen(config) })
        }
        for favourite in favourites {
            let server = config(favourite.connectionID)?.name ?? "?"
            items.append(PaletteItem(id: "f-\(favourite.id)", title: favourite.name, subtitle: "Favourite · \(server)",
                                     icon: "star.fill") { [weak self] in self?.openFavourite(favourite) })
        }
        for server in servers where server.isConnected {
            for schema in server.schemas {
                for table in schema.tables ?? [] {
                    items.append(PaletteItem(id: "t-\(server.id)-\(schema.name)-\(table)", title: table, subtitle: "\(server.config.name) · \(schema.name)",
                                             icon: "tablecells") { [weak self] in self?.openTable(table, in: schema.name, on: server) })
                }
            }
        }
        return items
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
