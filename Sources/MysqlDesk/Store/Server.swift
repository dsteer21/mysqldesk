import Foundation
import Observation

/// A schema in the sidebar. Its tables load the first time it's expanded.
@MainActor @Observable
final class Schema: Identifiable {
    let name: String
    /// Unique across servers: two servers both have `mysql`, and the sidebar is one list.
    nonisolated let id: String
    var tables: [String]?
    var expanded = false
    var loading = false

    init(name: String, serverID: UUID) {
        self.name = name
        id = serverID.uuidString + "/" + name
    }
}

/// A connected server shown in the sidebar. It keeps one "meta" connection for the schema tree
/// and for cancelling queries; query tabs open their own sessions through `openSession`.
@MainActor @Observable
final class Server: Identifiable {
    enum State: Equatable {
        case connecting, connected
        case failed(String)
    }

    nonisolated let id: UUID
    var config: ConnectionConfig
    var state = State.connecting
    var version = ""
    var schemas: [Schema] = []
    var expanded = true
    var showFavourites = false
    /// True once every schema's tables are loaded (done when the sidebar filter is used).
    var allTablesLoaded = false

    /// Held in memory for this session only so tabs can open connections; the saved copy is in the Keychain.
    @ObservationIgnored var password: String?
    @ObservationIgnored private var meta: DatabaseConnection?

    init(config: ConnectionConfig, password: String?) {
        id = config.id
        self.config = config
        self.password = password
    }

    var isConnected: Bool { state == .connected }

    /// "MySQL 8.4.11" or "MariaDB 10.3.28".
    var versionLabel: String {
        guard !version.isEmpty else { return config.address }
        let number = version.split(separator: "-").first.map(String.init) ?? version
        return version.localizedCaseInsensitiveContains("mariadb") ? "MariaDB \(number)" : "MySQL \(number)"
    }

    func connect() async throws {
        state = .connecting
        do {
            let connection = try await DatabaseConnection.open(config, password: password, database: "")
            meta = connection
            version = connection.serverVersion
            state = .connected
            await loadSchemas()
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func disconnect() async {
        await meta?.close()
        meta = nil
        schemas = []
        state = .failed("Disconnected")
    }

    /// A new connection for a query tab.
    func openSession(database: String?) async throws -> DatabaseConnection {
        try await DatabaseConnection.open(config, password: password, database: database ?? "")
    }

    func loadSchemas() async {
        do {
            let names = try await metaConnection().strings("SHOW DATABASES")
            let existing = Dictionary(schemas.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            schemas = names.map { existing[$0] ?? Schema(name: $0, serverID: id) }
            allTablesLoaded = false
            // Refresh any schemas that were open so new tables show up.
            for schema in schemas where schema.tables != nil {
                await loadTables(schema)
            }
        } catch {
            Banner.shared.error("Couldn't list schemas on \(config.name)", detail: error.localizedDescription)
        }
    }

    func loadTables(_ schema: Schema) async {
        schema.loading = true
        defer { schema.loading = false }
        do {
            // Base tables only: views, procedures and functions aren't needed here.
            schema.tables = try await metaConnection().strings(
                "SHOW FULL TABLES FROM \(SQL.identifier(schema.name)) WHERE Table_type = 'BASE TABLE'")
        } catch {
            Banner.shared.error("Couldn't list tables in \(schema.name)", detail: error.localizedDescription)
        }
    }

    /// Loads every schema's tables in one query so the sidebar filter can find tables in closed schemas.
    func loadAllTables() async {
        guard !allTablesLoaded else { return }
        allTablesLoaded = true
        do {
            let sql = """
                SELECT TABLE_SCHEMA, TABLE_NAME
                FROM information_schema.TABLES
                WHERE TABLE_TYPE = 'BASE TABLE'
                ORDER BY TABLE_SCHEMA, TABLE_NAME
                """
            guard case .rows(_, let rows, _, _)? = try await metaConnection().execute(sql, maxRows: .max).first else { return }
            let grouped = Dictionary(grouping: rows, by: { $0[0] ?? "" })
            for schema in schemas {
                schema.tables = grouped[schema.name]?.compactMap { $0[1] } ?? []
            }
        } catch {
            allTablesLoaded = false
        }
    }

    /// Stops the query running on another connection (the tab's session).
    func killQuery(threadID: Int) async {
        do {
            _ = try await metaConnection().execute("KILL QUERY \(threadID)", maxRows: 0)
        } catch {
            Banner.shared.error("Couldn't cancel the query", detail: error.localizedDescription)
        }
    }

    /// The sidebar connection, reopened if the server dropped it (e.g. wait_timeout).
    private func metaConnection() async throws -> DatabaseConnection {
        if let meta, !meta.isClosed { return meta }
        let connection = try await DatabaseConnection.open(config, password: password, database: "")
        meta = connection
        state = .connected
        return connection
    }
}
