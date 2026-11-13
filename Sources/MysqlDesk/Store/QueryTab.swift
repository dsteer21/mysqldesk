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
    /// Rows marked for deletion in that same result (result row indexes), deleted on Apply.
    private(set) var deletions: Set<Int> = []
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

    /// Pending changes: each edited cell plus each row marked for deletion.
    var editCount: Int { edits.values.reduce(0) { $0 + $1.count } + deletions.count }

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

    func isDeleted(row: Int, in result: ResultSet) -> Bool {
        result.id == editsResultID && deletions.contains(row)
    }

    /// Pending changes belong to one result at a time; starting on another drops the old ones.
    private func beginChanges(in result: ResultSet) {
        guard editsResultID != result.id else { return }
        edits = [:]
        deletions = []
        editsResultID = result.id
    }

    func setEdit(_ value: String?, row: Int, column: Int, in result: ResultSet) {
        beginChanges(in: result)
        var changes = edits[row] ?? [:]
        if value == result.rows[row][column] {
            changes.removeValue(forKey: column) // back to the original: no longer a change
        } else {
            changes.updateValue(value, forKey: column) // updateValue keeps a nil (NULL) value
        }
        edits[row] = changes.isEmpty ? nil : changes
        editsVersion += 1
    }

    /// Marks rows for deletion, or unmarks them if they're all marked already.
    func toggleDeletion(rows: [Int], in result: ResultSet) {
        beginChanges(in: result)
        if rows.allSatisfy(deletions.contains) {
            deletions.subtract(rows)
        } else {
            deletions.formUnion(rows)
        }
        editsVersion += 1
    }

    func revertEdits() {
        guard !edits.isEmpty || !deletions.isEmpty else { return }
        edits = [:]
        deletions = []
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
