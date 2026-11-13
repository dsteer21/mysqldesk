# MysqlDesk

A lightweight, native macOS MySQL client that takes the bits we use from MySQL Workbench and SQLPro for MySQL — and nothing else. The companion to [GitDesk](https://github.com/dsteer21/gitdesk), with the same look.

**Website:** https://www.dave-steer.co.uk/mysqldesk/

Built with Swift and SwiftUI on [MySQLNIO](https://github.com/vapor/mysql-nio), a pure-Swift driver, so there's nothing else to install (no `mysql` client or libmysqlclient). Works with MySQL 5.7–8.4 and MariaDB 10.x, including MySQL 8's `caching_sha2_password` with TLS on or off.

## Features

- **Connections** — Workbench-style *Manage Connections* window (⇧⌘C): New, Delete, Duplicate, Move Up/Down and **Test Connection**. Each connection has a name, host, port, user, optional default schema, TLS setting and a colour tag so production stands out.
- **Passwords in the Keychain** — never written to MysqlDesk's files. Leave one unset and you're asked when connecting (with the option to save it). Each password is read from the Keychain at most once per launch.
- **Connections home** — a tile per server, as in Workbench; double-click to connect (⌘0 to come back).
- **Sidebar** — every connected server listed SQLPro-style (`PRODUCTION (REPORTING)` / `MySQL 8.4.11`), then its schemas, then just the **tables** (no views, procedures or functions). Tables load when a schema is opened. The filter (⌃F) searches schema and table names across every server. Double-click a table to open its rows; right-click for columns, `CREATE TABLE`, copy name, etc.
- **Query tabs** — each tab has its own connection to the server, so a long query never blocks another tab. **Change a tab's server or schema without losing the query** using the coloured picker above the editor (⌥⌘D). Tabs come back after relaunching.
- **Editor** — SQL highlighting, line numbers, auto-indent, comment toggle, upper/lower case and a formatter. ⌥⇧↓ / ⌥⇧↑ duplicate the current line (or the selection) below or above, as in VS Code. ⇧⌘E runs everything (or the selection); ⌘↩ runs the statement under the cursor. ⌘. stops a running query (`KILL QUERY`).
- **Open .sql files** — drop a `.sql` file on the app icon, use *Open With ▸ MysqlDesk* in Finder, or ⌘O. It opens in a new tab with no connection chosen and the server picker open, so you choose where it runs before running it. (Files over 10 MB are refused; run those with the `mysql` client.)
- **Results** — fast grid for wide and long results: click headers to sort, NULLs shown distinctly, right-click ▸ *View Value* for the full value (JSON pretty-printed). Several statements show their results **one above another** (up to 10 per run; later statements still run and are listed in Messages), or one at a time with the layout button; clicking a grid makes it the one that Export and Copy use. There's also a Messages tab with rows affected, timings, errors and MySQL's **warnings** (e.g. *Truncated incorrect DECIMAL value*), which are fetched automatically and flagged in orange. A query that matches nothing says *No rows returned* rather than showing an empty grid.
- **Editing results** — double-click a cell to edit it; ENUM columns get a drop-down of their options, and long, multi-line or JSON values open in an editor. Right-click for *Set to NULL* and *Revert This Cell*. To **delete rows**, select one or more and press ⌫ (or right-click ▸ *Delete Row* / *Delete Selected Rows*); they're struck through in red, and pressing ⌫ again restores them. Nothing is saved until you click **Apply…** at the bottom, which shows the `UPDATE` and `DELETE` statements first and runs them in one transaction (all or nothing). **Revert** discards every change. Editing needs the result to come from a single table and include its primary key; joins, calculated and binary columns stay read-only.
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
| ⌥⇧↓ / ⌥⇧↑ | Duplicate the line (or selection) down / up |
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
| ⌫ | Mark the selected rows for deletion (again to restore) |
| ⌘O | Open a .sql file |

## Building

Requires macOS 14+ and Xcode (or the Swift toolchain).

```sh
./scripts/build-app.sh            # builds build/MysqlDesk.app (universal)
./scripts/build-app.sh --install  # also copies it to /Applications
./scripts/make-dmg.sh             # builds build/MysqlDesk-<version>.dmg for other Macs
./scripts/release.sh              # tags the pushed HEAD and uploads the DMG to GitHub Releases
./scripts/build-appstore.sh       # builds the sandboxed Mac App Store package (see docs/app-store.md)
```

The version number lives in `VERSION`; change it (and commit) before releasing.

The scripts sign the app with the **Developer ID Application** certificate in your login keychain, falling back to Apple Development and then ad hoc (set `SIGN_IDENTITY` to choose another). Signing with the same certificate every time is what lets Keychain *Always Allow* survive updates: an ad-hoc signature changes with every build, so macOS treats each new build as a different app and asks for your password again.

`make-dmg.sh` notarises and staples the DMG using the `gitdesk-notary` notarytool profile (shared with GitDesk; set `NOTARY_PROFILE` for another), and `release.sh` refuses to publish a DMG that isn't notarised. The build number (`CFBundleVersion`) is the commit count.

For development, `swift run` launches it straight from the package. The app icon is generated by `swift scripts/make-icon.swift`.

Release DMGs are signed with a Developer ID and notarised by Apple, so they open on any Mac without a security warning.

### Debug-only helpers

Debug builds (`swift build`) include these; release builds compile them out:

- `MYSQLDESK_SELFTEST=host:port:user:password swift run` — checks the driver (types, binary data, NULLs, UTF-8, affected rows, errors, row cap, `KILL QUERY`, per-tab sessions), the SQL splitter and formatter, the CSV/JSON/SQL exporters and, with `MYSQLDESK_TEST_PASSWORD` set to the same password, editing (ENUM options, UPDATE and DELETE preview, apply, rollback on error, read-only joins), the 10-result limit, opening .sql files and line duplication, then prints PASS/FAIL. It creates and drops a `mysqldesk_selftest` schema, so **only point it at a disposable server**, e.g. `docker run -e MYSQL_ROOT_PASSWORD=x -p 33084:3306 mysql:8.4`. Add `MYSQLDESK_SELFTEST_TLS=off` to test without TLS.
- `MYSQLDESK_DATA_DIR=/tmp/x` — use another data folder; `MYSQLDESK_TEST_PASSWORD=…` — answer password lookups without touching the Keychain.
- `MYSQLDESK_AUTORUN=1` connects every saved connection and runs the selected tab (then `MYSQLDESK_DEMO_EDITS`, `MYSQLDESK_DEMO_DELETE="2,4"` and `MYSQLDESK_DEMO_PREVIEW=1` make pending changes for screenshots); `MYSQLDESK_SNAPSHOT=/tmp/shot.png` saves the window (or its open sheet) to a PNG, then quits (`MYSQLDESK_WINDOW_SIZE=1440x900` and `MYSQLDESK_SNAPSHOT_SCALE=2` for App Store screenshots). `MYSQLDESK_DEMO_TOUR` and `MYSQLDESK_RECORD` play and record the App Review video (`Store/DemoTour.swift`).

### Mac App Store

MysqlDesk is also sold on the Mac App Store as a sandboxed build of the same code. Setup, each release's steps, the listing text and the sandbox differences are in [docs/app-store.md](docs/app-store.md).

## Data

Stored in `~/Library/Application Support/MysqlDesk/`: `connections.json`, `favourites.json`, `history.json` and `tabs.json`. Passwords are Keychain items named *MysqlDesk: &lt;connection&gt;* (service `uk.co.llexeter.mysqldesk`, the original bundle ID; the app's bundle ID is now `uk.co.dave-steer.mysqldesk`, and 1.3.1 copies settings across from the old one). Deleting a connection removes its Keychain item and its favourites.

The first time each password is read, macOS asks to allow MysqlDesk access: click **Always Allow** and it won't ask again, even after updates (see *Building* for why). 1.3.1 is the first build signed with the Developer ID (and under the new bundle ID), so after moving to it you'll be asked once more per connection.

## Known limitations

- Stored procedures that **return rows** can't be `CALL`ed. MySQLNIO doesn't request `CLIENT_MULTI_RESULTS`, so the server refuses with error 1312. Procedures that don't return rows work.
- `LOAD DATA LOCAL INFILE` isn't supported.
- Results keep the first 50,000 rows by default (*Settings → Rows kept per result*). The full row count is still shown, and exports warn when rows were left out.
- No creating or altering tables, and no inserting rows from the grid: editing is limited to changing values and deleting rows.

## Project layout

```
Sources/MysqlDesk/
  MysqlDeskApp.swift      App entry, menus/shortcuts, settings
  Database/               MySQL connection + text-protocol query command, SQL helpers, exporters, Keychain, models
  Store/                  AppStore (connections, tabs, favourites, running queries, applying edits), Server, QueryTab, debug hooks
  Views/                  SwiftUI views; the editor and results grid are AppKit (NSTextView / NSTableView)
scripts/                  build-app.sh, make-dmg.sh, release.sh, make-icon.swift
```
