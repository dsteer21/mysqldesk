import Foundation

/// A saved server. The password is kept in the macOS Keychain (see `Keychain`), never in this struct or on disk.
struct ConnectionConfig: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = "New Connection"
    var host = "localhost"
    var port = 3306
    var username = "root"
    var defaultSchema = ""
    var tls: TLSMode = .preferred
    var colour: ConnectionColour = .none

    /// "Production (reporting)", as shown in tab pickers.
    var displayName: String { "\(name) (\(username))" }
    var address: String { "\(host):\(port)" }
}

enum TLSMode: String, Codable, CaseIterable, Identifiable {
    case preferred, disabled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preferred: "Use TLS when the server offers it"
        case .disabled: "Off"
        }
    }
}

/// Optional colour tag so production servers stand out in the sidebar and tab bar.
enum ConnectionColour: String, Codable, CaseIterable, Identifiable {
    case none, green, blue, purple, orange, red

    var id: String { rawValue }
    var title: String { self == .none ? "None" : rawValue.capitalized }
}

/// A saved query, tied to the connection (and optionally the schema) it runs against.
struct Favourite: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var sql: String
    var connectionID: UUID
    var database: String?
    var updated = Date()
}

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var sql: String
    var connectionID: UUID
    var database: String?
    var date = Date()
}

/// Enough of a query tab to bring it back after a relaunch.
struct SavedTab: Codable {
    var title: String
    var sql: String
    var connectionID: UUID?
    var database: String?
    var favouriteID: UUID?
}

// MARK: - Results

enum ColumnKind {
    case number, text, dateTime, json, binary
}

struct ResultColumn: Hashable {
    let name: String
    /// The underlying table, when the column maps straight onto one (used to name SQL exports).
    let table: String
    let kind: ColumnKind
    /// The real schema and column name behind an alias; empty for calculated columns. Used for editing.
    var schema = ""
    var orgName = ""
    /// The table's name or alias in the query (`b` in `JOIN items b`), so a self-join counts as two sources.
    var tableAlias = ""
}

/// One result set. A class so SwiftUI never copies large row arrays around.
final class ResultSet: Identifiable {
    let id = UUID()
    let statement: String
    let columns: [ResultColumn]
    /// Changes only when edits are applied to the database.
    private(set) var rows: [[String?]]
    /// Rows the server returned; more than `rows.count` when the result was capped.
    let totalRows: Int
    let duration: TimeInterval

    init(statement: String, columns: [ResultColumn], rows: [[String?]], totalRows: Int, duration: TimeInterval) {
        self.statement = statement
        self.columns = columns
        self.rows = rows
        self.totalRows = totalRows
        self.duration = duration
    }

    var isTruncated: Bool { totalRows > rows.count }

    /// Records a value written back to the database.
    func setValue(_ value: String?, row: Int, column: Int) {
        rows[row][column] = value
    }

    /// The source table if every column comes from the same one, for naming exports.
    var sourceTable: String? {
        let tables = Set(columns.map(\.table))
        guard tables.count == 1, let table = tables.first, !table.isEmpty else { return nil }
        return table
    }
}

/// What happened to each statement in a run, for the Messages pane.
struct StatementOutcome: Identifiable {
    enum Kind {
        case rows(Int)
        case affected(rows: UInt64, insertID: UInt64?, info: String)
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let sql: String
    let kind: Kind
    let duration: TimeInterval
    let warnings: Int
    let date = Date()

    var isError: Bool {
        switch kind {
        case .failed, .cancelled: true
        default: false
        }
    }

    var summary: String {
        switch kind {
        case .rows(let count): "\(count.formatted()) row\(count == 1 ? "" : "s") returned"
        case .affected(let rows, let insertID, let info):
            [
                "\(rows.formatted()) row\(rows == 1 ? "" : "s") affected",
                insertID.flatMap { $0 > 0 ? "last insert ID \($0)" : nil },
                info.isEmpty ? nil : info,
            ].compactMap { $0 }.joined(separator: " · ")
        case .failed(let message): message
        case .cancelled: "Cancelled"
        }
    }
}

// MARK: - Editing results

/// What's needed to turn grid edits into UPDATE statements for a result that comes from one table.
struct EditContext {
    let schema: String
    let table: String
    /// Result column indexes of the primary key, used in each WHERE clause.
    let keyColumns: [Int]
    /// Result column indexes that map onto real, non-binary columns of the table.
    let editable: Set<Int>
    let nullable: Set<Int>
    /// ENUM options by result column index, for the drop-down.
    let enumOptions: [Int: [String]]

    /// One UPDATE per changed row. `edits` is row → column → new value (nil means NULL).
    func updates(for result: ResultSet, edits: [Int: [Int: String?]]) -> [String] {
        edits.keys.sorted().compactMap { row in
            guard let changes = edits[row], !changes.isEmpty else { return nil }
            let original = result.rows[row]
            let assignments = changes.keys.sorted().map { column in
                let value = changes[column] ?? nil
                return "\(SQL.identifier(result.columns[column].orgName)) = \(Exporter.sqlValue(value, kind: result.columns[column].kind))"
            }
            let conditions = keyColumns.map { column in
                "\(SQL.identifier(result.columns[column].orgName)) = \(Exporter.sqlValue(original[column], kind: result.columns[column].kind))"
            }
            return "UPDATE \(SQL.identifier(schema)).\(SQL.identifier(table))\nSET \(assignments.joined(separator: ", "))\n"
                + "WHERE \(conditions.joined(separator: " AND ")) LIMIT 1;"
        }
    }

    /// Values from a column type such as `enum('new','paid','it''s')`.
    static func enumOptions(from type: String) -> [String]? {
        guard type.lowercased().hasPrefix("enum(") else { return nil }
        let pattern = try! NSRegularExpression(pattern: "'((?:[^']|'')*)'")
        let range = NSRange(type.startIndex..., in: type)
        return pattern.matches(in: type, range: range).compactMap { match in
            Range(match.range(at: 1), in: type).map { type[$0].replacingOccurrences(of: "''", with: "'") }
        }
    }
}
