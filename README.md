# MysqlDesk

A lightweight, native macOS MySQL client that takes the bits we use from MySQL Workbench and SQLPro for MySQL — and nothing else. The companion to [GitDesk](https://github.com/dsteer21/gitdesk), with the same look.

**Website:** https://www.dave-steer.co.uk/mysqldesk/

Built with Swift and SwiftUI on [MySQLNIO](https://github.com/vapor/mysql-nio), a pure-Swift driver, so there's nothing else to install (no `mysql` client or libmysqlclient). Works with MySQL 5.7–8.4 and MariaDB 10.x, including MySQL 8's `caching_sha2_password` with TLS on or off.

## Features

- **Connections** — Workbench-style *Manage Connections* window (⇧⌘C): New, Delete, Duplicate, Move Up/Down and **Test Connection**. Each connection has a name, host, port, user, optional default schema, TLS setting and a colour tag so production stands out.
- **Passwords in the Keychain** — never written to MysqlDesk's files. Leave one unset and you're asked when connecting (with the option to save it).
- **Connections home** — a tile per server, as in Workbench; double-click to connect (⌘0 to come back).
- **Sidebar** — every connected server listed SQLPro-style (`PRODUCTION (REPORTING)` / `MySQL 8.4.11`), then its schemas, then just the **tables** (no views, procedures or functions). Tables load when a schema is opened. The filter (⌃F) searches schema and table names across every server. Double-click a table to open its rows; right-click for columns, `CREATE TABLE`, copy name, etc.
- **Query tabs** — each tab has its own connection to the server, so a long query never blocks another tab. **Change a tab's server or schema without losing the query** using the coloured picker above the editor (⌥⌘D). Tabs come back after relaunching.
- **Editor** — SQL highlighting, line numbers, auto-indent, comment toggle, upper/lower case and a formatter. ⇧⌘E runs everything (or the selection); ⌘↩ runs the statement under the cursor. ⌘. stops a running query (`KILL QUERY`).
- **Results** — fast grid for wide and long results: click headers to sort, NULLs shown distinctly, right-click ▸ *View Value* for the full value (JSON pretty-printed). Several statements give one result tab each, plus a Messages tab with rows affected, timings and errors.
- **Editing results** — double-click a cell to edit it; ENUM columns get a drop-down of their options, and long, multi-line or JSON values open in an editor. Right-click for *Set to NULL* and *Revert This Cell*. Changed cells are highlighted and nothing is saved until you click **Apply…** at the bottom, which shows the `UPDATE` statements first and runs them in one transaction (all or nothing). **Revert** discards every change. Editing needs the result to come from a single table and include its primary key; joins, calculated and binary columns stay read-only.
- **Find column** (⌘B) — type part of a column name and only matching columns are shown. Handy for tables with hundreds of columns.
- **Favourites** — save a query against a connection (and schema) with ⌘S. Open it from the sidebar or the Favourites menu; edit it and ⌘S again to update it (the tab shows an orange dot until you do).
- **History** — the last 500 runs, per connection, under History.
- **Export** — the whole result or just the selected rows, as **CSV, JSON or SQL** `INSERT` statements. Copy as CSV/JSON/SQL from the right-click menu too.
- **⌘P command palette** — type part of a table name to find it on **any connected server**, including schemas you haven't opened in the sidebar (exact matches first; add a schema or server name to narrow it down), then press ↩ to open its rows. Also finds favourites, connections and actions.

## Keyboard shortcuts

These follow SQLPro for MySQL's defaults where it has one.

| Shortcut | Action |
| --- | --- |
| ⇧⌘E | Run all (or the selection) |
| ⌘↩ | Run the current statement |
| ⌘. | Stop the running query |
| ⇧⌘K | Format query |
| ⌘- | Comment / uncomment lines |
| ⌃⌘U / ⌃⌘L | Make uppercase / lowercase |
| ⌘K | Hide / show results |
| ⌘B | Find column |
| ⇧⌘M | Toggle results / messages |
| ⌥⌘C | Copy selected rows as CSV (with headers) |
| ⌥⌘E | Export all rows as CSV |
| ⌘S / ⇧⌘S | Save or update favourite / save as a new favourite |
| ⇧⌘C | Manage connections |
| ⌥⌘D | Choose server and schema for this tab |
| ⌃D | Focus the database tree (↑ ↓ move, → ← expand/collapse, ↩ open) |
| ⌃F | Filter the database tree |
| ⌘T / ⌘W | New tab / close tab |
| ⇧⌘[ / ⇧⌘] | Previous / next tab |
| ⌘1 – ⌘9 | Go to tab 1–8, ⌘9 last tab |
| ⌘P | Command palette |
| ⌘R | Refresh schemas and tables |
| ⌘0 | Connections home |
| ⌘C | Copy selected rows (tab-separated) |

## Building

Requires macOS 14+ and Xcode (or the Swift toolchain).

```sh
./scripts/build-app.sh            # builds build/MysqlDesk.app (universal)
./scripts/build-app.sh --install  # also copies it to /Applications
./scripts/make-dmg.sh             # builds build/MysqlDesk-1.0.0.dmg for other Macs
./scripts/release.sh 1.0.0        # tags the pushed HEAD and uploads the DMG to GitHub Releases
```

For development, `swift run` launches it straight from the package. The app icon is generated by `swift scripts/make-icon.swift`.

The app isn't notarised, so the first launch on another Mac is blocked: open **System Settings → Privacy & Security** and click **Open Anyway**, or run `xattr -dr com.apple.quarantine /Applications/MysqlDesk.app`.

### Debug-only helpers

Debug builds (`swift build`) include these; release builds compile them out:

- `MYSQLDESK_SELFTEST=host:port:user:password swift run` — checks the driver (types, binary data, NULLs, UTF-8, affected rows, errors, row cap, `KILL QUERY`, per-tab sessions), the SQL splitter and formatter, the CSV/JSON/SQL exporters and, with `MYSQLDESK_TEST_PASSWORD` set to the same password, editing (ENUM options, UPDATE preview, apply, rollback on error, read-only joins), then prints PASS/FAIL. It creates and drops a `mysqldesk_selftest` schema, so **only point it at a disposable server**, e.g. `docker run -e MYSQL_ROOT_PASSWORD=x -p 33084:3306 mysql:8.4`. Add `MYSQLDESK_SELFTEST_TLS=off` to test without TLS.
- `MYSQLDESK_DATA_DIR=/tmp/x` — use another data folder; `MYSQLDESK_TEST_PASSWORD=…` — answer password lookups without touching the Keychain.
- `MYSQLDESK_AUTORUN=1` connects every saved connection and runs the selected tab; `MYSQLDESK_SNAPSHOT=/tmp/shot.png` saves the window (or its open sheet) to a PNG, then quits.

## Data

Stored in `~/Library/Application Support/MysqlDesk/`: `connections.json`, `favourites.json`, `history.json` and `tabs.json`. Passwords are Keychain items named *MysqlDesk: &lt;connection&gt;* (service `uk.co.llexeter.mysqldesk`). Deleting a connection removes its Keychain item and its favourites.

Because the app is signed ad hoc, macOS may ask to allow Keychain access again after you install a new build. Click **Always Allow**.

## Known limitations

- Stored procedures that **return rows** can't be `CALL`ed. MySQLNIO doesn't request `CLIENT_MULTI_RESULTS`, so the server refuses with error 1312. Procedures that don't return rows work.
- `LOAD DATA LOCAL INFILE` isn't supported.
- Results keep the first 50,000 rows by default (*Settings → Rows kept per result*). The full row count is still shown, and exports warn when rows were left out.
- No creating or altering tables, and no inserting or deleting rows from the grid: editing is limited to changing existing values.

## Project layout

```
Sources/MysqlDesk/
  MysqlDeskApp.swift      App entry, menus/shortcuts, settings
  Database/               MySQL connection + text-protocol query command, SQL helpers, exporters, Keychain, models
  Store/                  AppStore (connections, tabs, favourites, running queries, applying edits), Server, QueryTab, debug hooks
  Views/                  SwiftUI views; the editor and results grid are AppKit (NSTextView / NSTableView)
scripts/                  build-app.sh, make-dmg.sh, release.sh, make-icon.swift
```
