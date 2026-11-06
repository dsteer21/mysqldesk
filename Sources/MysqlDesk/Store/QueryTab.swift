import Foundation
import Observation

/// One query tab: the SQL, which connection/schema it runs against, and its last results.
/// Changing the connection keeps the SQL in place, as in SQLPro.
@MainActor @Observable
final class QueryTab: Identifiable {
    let id = UUID()
    var title: String
    var sql: String
    var connectionID: UUID?
    var database: String?
    /// Set when the tab was opened from (or saved as) a favourite; ⌘S then updates that favourite.
    var favouriteID: UUID?

    var results: [ResultSet] = []
    var outcomes: [StatementOutcome] = []
    var selectedResult = 0
    var showMessages = false
    var running = false
    var runStarted: Date?

    var showResults = true
    var showColumnFilter = false
    var columnFilter = ""
    /// Bumped to move keyboard focus into the column filter (⌘B).
    var columnFilterFocus = 0
    var showTargetPicker = false
    /// Rows selected in the results grid, as indexes into the current result's rows.
    var selectedRows: [Int] = []

    /// Unapplied grid edits: result row → column → new value (nil means NULL), for `editsResultID`.
    private(set) var edits: [Int: [Int: String?]] = [:]
    private(set) var editsResultID: UUID?
    /// Bumped on every edit so the grid knows to redraw.
    private(set) var editsVersion = 0
    var applying = false
    /// Per result: how to write edits back, or why it can't be edited.
    @ObservationIgnored var editContexts: [UUID: Result<EditContext, EditError>] = [:]

    @ObservationIgnored let editor = EditorBridge()
    @ObservationIgnored var cancelled = false
    @ObservationIgnored private(set) var session: DatabaseConnection?
    @ObservationIgnored private(set) var sessionServerID: UUID?
    @ObservationIgnored private var sessionDatabase: String?

    init(title: String, sql: String = "", connectionID: UUID? = nil, database: String? = nil, favouriteID: UUID? = nil) {
        self.title = title
        self.sql = sql
        self.connectionID = connectionID
        self.database = database
        self.favouriteID = favouriteID
        editor.tab = self
        editor.load(sql)
    }

    var currentResult: ResultSet? {
        guard !showMessages, results.indices.contains(selectedResult) else { return nil }
        return results[selectedResult]
    }

    var editCount: Int { edits.values.reduce(0) { $0 + $1.count } }

    /// The result the pending edits belong to.
    var editedResult: ResultSet? { results.first { $0.id == editsResultID } }

    /// The value to show: the pending edit if there is one, else what the server returned.
    func value(row: Int, column: Int, in result: ResultSet) -> String? {
        if result.id == editsResultID, let edit = edits[row]?[column] { return edit }
        return result.rows[row][column]
    }

    func isEdited(row: Int, column: Int, in result: ResultSet) -> Bool {
        result.id == editsResultID && edits[row]?[column] != nil
    }

    func setEdit(_ value: String?, row: Int, column: Int, in result: ResultSet) {
        if editsResultID != result.id {
            edits = [:]
            editsResultID = result.id
        }
        var changes = edits[row] ?? [:]
        if value == result.rows[row][column] {
            changes.removeValue(forKey: column) // back to the original: no longer a change
        } else {
            changes.updateValue(value, forKey: column) // updateValue keeps a nil (NULL) value
        }
        edits[row] = changes.isEmpty ? nil : changes
        editsVersion += 1
    }

    func revertEdits() {
        guard !edits.isEmpty else { return }
        edits = [:]
        editsVersion += 1
    }

    var saved: SavedTab {
        SavedTab(title: title, sql: sql, connectionID: connectionID, database: database, favouriteID: favouriteID)
    }

    /// This tab's own connection, opened on first use and switched to the chosen schema.
    func session(on server: Server) async throws -> DatabaseConnection {
        if let session, sessionServerID == server.id, !session.isClosed {
            if let database, !database.isEmpty, database != sessionDatabase {
                _ = try await session.execute("USE \(SQL.identifier(database))", maxRows: 0)
                sessionDatabase = database
            }
            return session
        }
        await closeSession()
        let session = try await server.openSession(database: database)
        self.session = session
        sessionServerID = server.id
        sessionDatabase = database
        return session
    }

    /// Record a schema change made by a USE statement in the SQL.
    func noteSessionDatabase(_ name: String?) {
        sessionDatabase = name
        database = name
    }

    func closeSession() async {
        await session?.close()
        session = nil
        sessionServerID = nil
        sessionDatabase = nil
    }
}

struct EditError: Error {
    let message: String
}
