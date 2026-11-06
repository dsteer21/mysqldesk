#if DEBUG
import AppKit
import Foundation

/// Development aids, compiled out of release builds:
/// - `MYSQLDESK_DATA_DIR=/tmp/x` uses that folder instead of Application Support.
/// - `MYSQLDESK_TEST_PASSWORD=…` answers every password lookup, so tests never touch the Keychain.
/// - `MYSQLDESK_AUTORUN=1` connects the servers the open tabs use, opens the selected tab's schema in the
///   sidebar and runs the tab. Prints `MYSQLDESK_AUTORUN_FAILED` if a connection fails. Then, optionally:
///   - `MYSQLDESK_DEMO_EDITS="5=New note;3=paid"` makes pending edits: the nth `column=value` goes in row n.
///   - `MYSQLDESK_DEMO_PREVIEW=1` then opens the Apply preview.
///   - `MYSQLDESK_COLUMN_FILTER=text` fills in the ⌘B column filter.
///   - `MYSQLDESK_PALETTE=text` opens ⌘P and types that text.
/// - `MYSQLDESK_OPEN=manager` opens Manage Connections.
/// - `MYSQLDESK_SNAPSHOT=/tmp/shot.png` saves the window (or its open sheet) to a PNG after a few seconds, then quits.
/// - `MYSQLDESK_SELFTEST=host:port:user[:password]` runs driver/SQL/export checks against a
///   disposable server and prints PASS/FAIL. It creates and drops a `mysqldesk_selftest` schema.
@MainActor
enum DebugHooks {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static func run(_ store: AppStore) async {
        if let spec = environment["MYSQLDESK_SELFTEST"] {
            let passed = await SelfTest.run(spec)
            exit(passed ? 0 : 1)
        }
        if environment["MYSQLDESK_OPEN"] == "manager" {
            store.showManager(selecting: store.connections.first?.id)
        }
        guard environment["MYSQLDESK_AUTORUN"] != nil else { return }

        let used = Set(store.tabs.compactMap(\.connectionID))
        for config in store.connections where used.contains(config.id) {
            if await store.connect(config) == nil { print("MYSQLDESK_AUTORUN_FAILED") }
        }
        guard let tab = store.selectedTab else { return }
        if let server = store.server(tab.connectionID), let schema = server.schemas.first(where: { $0.name == tab.database }) {
            schema.expanded = true
            await server.loadTables(schema)
        }
        store.run(tab, .all)
        while tab.running || tab.outcomes.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }

        if let spec = environment["MYSQLDESK_DEMO_EDITS"], let result = tab.currentResult,
           case .success = await store.editContext(for: tab, result: result) {
            for (row, edit) in spec.split(separator: ";").enumerated() {
                let parts = edit.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, let column = Int(parts[0]), row < result.rows.count else { continue }
                tab.setEdit(parts[1], row: row, column: column, in: result)
            }
            if environment["MYSQLDESK_DEMO_PREVIEW"] != nil { store.previewEdits(tab) }
        }
        if let text = environment["MYSQLDESK_COLUMN_FILTER"] {
            tab.showColumnFilter = true
            tab.columnFilter = text
        }
        if let text = environment["MYSQLDESK_PALETTE"] {
            store.showPalette = true
            try? await Task.sleep(for: .seconds(1))
            (NSApp.keyWindow?.firstResponder as? NSTextView)?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    static func scheduleSnapshotIfRequested() {
        guard let path = environment["MYSQLDESK_SNAPSHOT"] else { return }
        let delay = Double(environment["MYSQLDESK_SNAPSHOT_DELAY"] ?? "") ?? 5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let main = NSApp.windows.first { $0.isVisible && $0.contentView != nil }
            guard let view = (main?.attachedSheet ?? main)?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            // exit rather than terminate: an open sheet would block a normal quit.
            exit(0)
        }
    }
}

extension Notification.Name {
    static let debugOpenPalette = Notification.Name("MysqlDesk.debugOpenPalette")
}

/// Checks the parts that talk to MySQL, plus the pure SQL/export helpers.
@MainActor
enum SelfTest {
    private static var failures = 0

    private static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        print(condition ? "PASS" : "FAIL", name, condition ? "" : detail())
        if !condition { failures += 1 }
    }

    static func run(_ spec: String) async -> Bool {
        setvbuf(stdout, nil, _IONBF, 0)
        let parts = spec.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else {
            print("FAIL bad MYSQLDESK_SELFTEST, expected host:port:user[:password]")
            return false
        }
        var config = ConnectionConfig()
        config.name = "Self-test"
        config.host = parts[0]
        config.port = Int(parts[1]) ?? 3306
        config.username = parts[2]
        let password = parts.count > 3 ? parts[3] : nil
        config.tls = environment("MYSQLDESK_SELFTEST_TLS") == "off" ? .disabled : .preferred

        sqlHelpers()
        editorCommands()

        do {
            let connection = try await DatabaseConnection.open(config, password: password)
            print("Connected to", connection.serverVersion, "thread", connection.threadID)
            check("server version reported", !connection.serverVersion.isEmpty)
            do {
                try await database(connection, config: config, password: password)
            } catch {
                check("database checks", false, error.localizedDescription)
            }
            _ = try? await connection.execute("DROP DATABASE IF EXISTS mysqldesk_selftest", maxRows: 0)
            await connection.close()
        } catch {
            check("database checks", false, error.localizedDescription)
        }

        var wrong = config
        wrong.username = "no_such_user_\(Int.random(in: 1000...9999))"
        do {
            _ = try await DatabaseConnection.open(wrong, password: "nope")
            check("bad login is refused", false, "it connected")
        } catch {
            check("bad login gives a readable error", error.localizedDescription.contains("Access denied"), error.localizedDescription)
        }

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return failures == 0
    }

    private static func environment(_ key: String) -> String? { ProcessInfo.processInfo.environment[key] }

    private static func sqlHelpers() {
        let script = """
            -- leading comment
            SELECT 'a;b' AS x, `we;ird` FROM t; # trailing
            SELECT "q\\";" ;
            /* block ; */ UPDATE t SET a = 1;
            -- only a comment;
            SELECT 3
            """
        let statements = SQL.statements(in: script)
        check("splits on real semicolons only", statements.count == 4, "\(statements.map(\.text))")
        check("keeps the quoted semicolon", statements.first?.text.contains("'a;b'") == true)
        let cursor = (script as NSString).range(of: "UPDATE").location + 3
        check("statement at cursor", SQL.statement(at: cursor, in: script)?.text.contains("UPDATE t SET a = 1") == true)
        let end = (script as NSString).range(of: "FROM t;").location + 7
        check("statement just before the cursor", SQL.statement(at: end, in: script)?.text.contains("'a;b'") == true)
        check("verb ignores comments", SQL.verb(of: "/* x */ use foo") == "USE")

        let formatted = SQL.format("select a.id, b.name, count(*) from a left join b on a.id = b.a_id and b.x = 'select from' where a.x->>'$.k' = 1 group by a.id order by 2 desc limit 5")
        print(formatted)
        check("formatter upper-cases keywords", formatted.contains("SELECT") && formatted.contains("LEFT JOIN"))
        check("formatter leaves strings alone", formatted.contains("'select from'"))
        check("formatter keeps ->> together", formatted.contains("->>"))
        check("formatter keeps a.* and count(*)", SQL.format("select a.*, count(*) from a").contains("a.*") && SQL.format("select count(*) from a").contains("count(*)"))

        let columns = [ResultColumn(name: "id", table: "t", kind: .number), ResultColumn(name: "note", table: "t", kind: .text),
                       ResultColumn(name: "doc", table: "t", kind: .json)]
        let rows: [[String?]] = [["1", "he said \"hi\", then left\nnext", "{\"a\":1}"], ["2", nil, nil]]
        let result = ResultSet(statement: "", columns: columns, rows: rows, totalRows: 2, duration: 0)
        let csv = Exporter.export(result, as: .csv)
        check("CSV quotes commas, quotes and new lines", csv.contains("\"he said \"\"hi\"\", then left\nnext\""), csv)
        let json = Exporter.export(result, as: .json)
        check("JSON numbers unquoted, JSON columns embedded", json.contains("\"id\": 1") && json.contains("\"doc\": {\"a\":1}") && json.contains("\"note\": null"), json)
        check("JSON parses", (try? JSONSerialization.jsonObject(with: Data(json.utf8))) != nil)
        let sql = Exporter.export(result, rows: [0], as: .sql)
        check("SQL export escapes and names the table", sql.hasPrefix("INSERT INTO `t` (`id`, `note`, `doc`) VALUES") && sql.contains("'he said \"hi\", then left\\nnext'"), sql)
    }

    private static func editorCommands() {
        let tab = QueryTab(title: "Test", sql: "select 1;\n  select 2;\nselect 3;")
        let editor = tab.editor
        let text = { editor.textView.string }
        editor.textView.setSelectedRange(NSRange(location: 2, length: 12)) // across lines 1 and 2
        editor.toggleComment()
        check("comment adds -- to each selected line", text() == "-- select 1;\n--   select 2;\nselect 3;", text())
        check("tab SQL follows the editor", tab.sql == text())
        editor.toggleComment()
        check("comment toggles back off", text() == "select 1;\n  select 2;\nselect 3;", text())
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        editor.format()
        check("format works on the whole editor", text() == "SELECT 1;\n\nSELECT 2;\n\nSELECT 3;", text())
    }

    /// Editing through the store, as the grid does: needs MYSQLDESK_TEST_PASSWORD so no Keychain is used.
    private static func editing(config: ConnectionConfig) async throws {
        check("ENUM options parsed", EditContext.enumOptions(from: "enum('new','paid','it''s')") == ["new", "paid", "it's"])
        guard environment("MYSQLDESK_TEST_PASSWORD") != nil else {
            print("SKIP editing checks: set MYSQLDESK_TEST_PASSWORD to the same password")
            return
        }
        let store = AppStore()
        store.saveConnection(config)

        func runTab(_ sql: String) async -> QueryTab {
            let tab = store.newTab(connectionID: config.id, database: "mysqldesk_selftest", sql: sql)
            store.run(tab, .all)
            while tab.running || tab.outcomes.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
            return tab
        }

        let tab = await runTab("SELECT id, name AS label, price, status, price * 2 AS doubled FROM items ORDER BY id")
        guard let result = tab.currentResult else {
            check("editable query returns rows", false, tab.outcomes.map(\.summary).joined())
            return
        }
        guard case .success(let context) = await store.editContext(for: tab, result: result) else {
            check("single-table result with its key is editable", false)
            return
        }
        check("key column found", context.keyColumns == [0])
        check("aliased column is editable, calculated one isn't", context.editable.contains(1) && !context.editable.contains(4))
        check("ENUM drop-down options", context.enumOptions[3] == ["new", "paid", "it's"], "\(context.enumOptions)")
        check("NOT NULL vs nullable", context.nullable.contains(2) && !context.nullable.contains(3))

        tab.setEdit("Brake pads (front)", row: 0, column: 1, in: result)
        tab.setEdit("it's", row: 0, column: 3, in: result)
        tab.setEdit(nil, row: 2, column: 2, in: result)
        tab.setEdit("Chain; 428", row: 1, column: 1, in: result) // same as before: not a change
        check("edits counted (unchanged values ignored)", tab.editCount == 3, "\(tab.editCount)")

        store.previewEdits(tab)
        guard let preview = store.applyPreview else {
            check("Apply shows a preview", false)
            return
        }
        print(preview.statements.joined(separator: "\n"))
        check("one UPDATE per changed row", preview.statements.count == 2)
        check("UPDATE uses the real column name and the key",
              preview.statements[0] == "UPDATE `mysqldesk_selftest`.`items`\nSET `name` = 'Brake pads (front)', `status` = 'it\\'s'\nWHERE `id` = 1 LIMIT 1;",
              preview.statements[0])
        check("NULL written as NULL", preview.statements[1].contains("`price` = NULL") && preview.statements[1].contains("`id` = 3"))

        await store.applyEdits(preview)
        check("edits cleared after Apply", tab.editCount == 0)
        check("grid shows the saved value", result.rows[0][1] == "Brake pads (front)" && result.rows[2][2] == nil)
        let check1 = await runTab("SELECT name, status, price FROM items WHERE id IN (1, 3) ORDER BY id")
        let saved = check1.currentResult?.rows ?? []
        check("database has the changes", saved.count == 2 && saved[0][0] == "Brake pads (front)" && saved[0][1] == "it's" && saved[1][2] == nil,
              "\(saved)")

        // A bad value fails the whole transaction and keeps the edits.
        let again = await runTab("SELECT id, name, status FROM items ORDER BY id")
        if let result = again.currentResult, case .success = await store.editContext(for: again, result: result) {
            again.setEdit("Renamed", row: 1, column: 1, in: result)
            again.setEdit("not-an-option", row: 0, column: 2, in: result)
            store.previewEdits(again)
            if let preview = store.applyPreview { await store.applyEdits(preview) }
            check("failed Apply keeps the edits", again.editCount == 2)
            let after = await runTab("SELECT name FROM items WHERE id = 2")
            check("failed Apply rolls everything back", after.currentResult?.rows.first?.first == "Chain; 428",
                  "\(String(describing: after.currentResult?.rows))")
        }

        let warnedTab = await runTab("SELECT CAST('12abc' AS UNSIGNED) AS n")
        check("warning text shown in Messages", warnedTab.outcomes.first?.warningMessages.first?.contains("1292") == true,
              "\(warnedTab.outcomes.first?.warningMessages ?? [])")
        let failed = await runTab("SELECT * FROM no_such_table")
        check("error shown in Messages", failed.showMessages && failed.outcomes.first?.isError == true
              && failed.outcomes.first?.summary.contains("1146") == true, failed.outcomes.first?.summary ?? "")

        let join = await runTab("SELECT a.id, b.name FROM items a JOIN items b ON b.id = a.id")
        if let result = join.currentResult, case .failure(let error) = await store.editContext(for: join, result: result) {
            check("join without a single table's key is refused", error.message.contains("primary key") || error.message.contains("more than one"), error.message)
        } else {
            check("join is refused", false)
        }
        let noKey = await runTab("SELECT name, price FROM items")
        if let result = noKey.currentResult, case .failure(let error) = await store.editContext(for: noKey, result: result) {
            check("result without the primary key is refused", error.message.contains("Include the primary key"), error.message)
        } else {
            check("result without the primary key is refused", false)
        }
        for tab in store.tabs { await tab.closeSession() }
        for server in store.servers { await server.disconnect() }
    }

    private static func database(_ connection: DatabaseConnection, config: ConnectionConfig, password: String?) async throws {
        let isMariaDB = connection.serverVersion.localizedCaseInsensitiveContains("mariadb")
        _ = try await connection.execute("DROP DATABASE IF EXISTS mysqldesk_selftest", maxRows: 0)
        _ = try await connection.execute("CREATE DATABASE mysqldesk_selftest", maxRows: 0)
        _ = try await connection.execute("USE mysqldesk_selftest", maxRows: 0)

        _ = try await connection.execute("""
            CREATE TABLE items (
                id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
                name VARCHAR(50),
                price DECIMAL(10,2),
                data BLOB,
                flags BIT(8),
                created DATETIME,
                doc \(isMariaDB ? "LONGTEXT" : "JSON"),
                status ENUM('new', 'paid', 'it''s') NOT NULL DEFAULT 'new'
            )
            """, maxRows: 0)

        let insert = try await connection.execute("""
            INSERT INTO items (name, price, data, flags, created, doc) VALUES
            ('Brake pads', 24.99, UNHEX('00FF10'), b'00000101', '2026-11-06 09:30:00', '{"fits": ["Talaria"]}'),
            ('Chain; 428', NULL, 'plain text', NULL, NULL, NULL),
            ('Ünïcödé ✓', 3.50, NULL, NULL, NULL, NULL)
            """, maxRows: 0)
        if case .ok(let affected, let insertID, _, _)? = insert.first {
            check("insert reports affected rows", affected == 3, "\(affected)")
            check("insert reports the insert ID", insertID == 1, "\(insertID)")
        } else {
            check("insert returns OK", false, "\(insert)")
        }

        let select = try await connection.execute("SELECT * FROM items ORDER BY id", maxRows: 100)
        guard case .rows(let columns, let rows, let total, _)? = select.first else {
            check("select returns rows", false)
            return
        }
        check("3 rows and 8 columns", rows.count == 3 && total == 3 && columns.count == 8, "\(rows.count)/\(columns.count)")
        check("number kinds", columns[0].kind == .number && columns[2].kind == .number)
        check("datetime kind", columns[5].kind == .dateTime)
        check("binary data becomes hex", rows[0][3] == "0x00FF10", rows[0][3] ?? "nil")
        check("readable binary stays text", rows[1][3] == "plain text", rows[1][3] ?? "nil")
        check("BIT shown as a number", rows[0][4] == "5", rows[0][4] ?? "nil")
        check("NULL is nil", rows[1][2] == nil)
        check("UTF-8 survives", rows[2][1] == "Ünïcödé ✓", rows[2][1] ?? "nil")
        check("decimal text", rows[0][2] == "24.99")
        check("column table name", columns[1].table == "items", columns[1].table)

        let warned = try await connection.execute("SELECT CAST('12abc' AS UNSIGNED) AS n", maxRows: 1)
        if case .rows(_, let rows, _, let warnings)? = warned.first {
            check("warnings counted on a result set", warnings == 1 && rows.first?.first == "12", "\(warnings)")
        } else {
            check("warning query returns rows", false)
        }

        let empty = try await connection.execute("SELECT id, name FROM items WHERE 1 = 0", maxRows: 100)
        if case .rows(let columns, let rows, _, _)? = empty.first {
            check("empty result keeps its columns", columns.map(\.name) == ["id", "name"] && rows.isEmpty)
        } else {
            check("empty result returns a result set", false)
        }

        let capped = try await connection.execute("SELECT a.id FROM items a, items b, items c", maxRows: 10)
        if case .rows(_, let rows, let total, _)? = capped.first {
            check("rows past the cap are counted, not kept", rows.count == 10 && total == 27, "\(rows.count)/\(total)")
        }

        do {
            _ = try await connection.execute("SELEC 1", maxRows: 1)
            check("bad SQL fails", false)
        } catch {
            check("syntax error is readable", (error as? QueryError)?.code == 1064, error.localizedDescription)
        }
        let after = try await connection.execute("SELECT 1", maxRows: 1)
        check("connection still usable after an error", { if case .rows(_, let r, _, _)? = after.first { return r.first?.first == "1" }; return false }())

        let shown = try await connection.strings("SHOW FULL TABLES FROM `mysqldesk_selftest` WHERE Table_type = 'BASE TABLE'")
        check("SHOW FULL TABLES lists base tables", shown == ["items"], "\(shown)")

        // A second session, as a query tab would open, and cancelling its query from the first.
        let tab = try await DatabaseConnection.open(config, password: password, database: "mysqldesk_selftest")
        let started = Date()
        let sleeper = Task { try await tab.execute("SELECT SLEEP(10) AS s", maxRows: 1) }
        try await Task.sleep(for: .milliseconds(600))
        _ = try await connection.execute("KILL QUERY \(tab.threadID)", maxRows: 0)
        _ = try? await sleeper.value
        check("KILL QUERY stops a running query", Date().timeIntervalSince(started) < 4, "\(Date().timeIntervalSince(started)) s")
        let still = try? await tab.execute("SELECT DATABASE()", maxRows: 1)
        check("session opened on the requested schema", { if case .rows(_, let r, _, _)? = still?.first { return r.first?.first == "mysqldesk_selftest" }; return false }())
        await tab.close()

        try await editing(config: config)

        // MySQLNIO doesn't ask for CLIENT_MULTI_RESULTS, so the server refuses CALLs that return rows (1312).
        _ = try await connection.execute("CREATE PROCEDURE two() BEGIN SELECT 1 AS a; SELECT 2 AS b, 3 AS c; END", maxRows: 0)
        do {
            let call = try await connection.execute("CALL two()", maxRows: 10)
            let sets = call.compactMap { if case .rows(let c, _, _, _) = $0 { return c.map(\.name) } else { return nil } }
            check("CALL returns both result sets", sets == [["a"], ["b", "c"]], "\(call)")
        } catch {
            check("CALL with result sets gives the known 1312 limitation", (error as? QueryError)?.code == 1312, error.localizedDescription)
        }
    }
}
#endif
