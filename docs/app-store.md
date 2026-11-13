# Mac App Store

MysqlDesk is sold on the Mac App Store and stays free on GitHub. Both are built from the same code:

| | GitHub (`release.sh`) | Mac App Store (`build-appstore.sh`) |
|---|---|---|
| Signed with | Developer ID, notarised | Apple Distribution + installer certificate |
| Sandboxed | No | Yes (`Resources/AppStore.entitlements`) |
| Connections, favourites, history | `~/Library/Application Support/MysqlDesk` | `~/Library/Containers/uk.co.dave-steer.mysqldesk/…` |
| Updates | Download from GitHub | App Store |

Because the App Store version is sandboxed, it keeps its own connections. Someone moving from the GitHub version adds their servers again.

The sandbox allows only outgoing network connections and files the user picks or drops (Open, Export, `.sql` files). `./scripts/build-appstore.sh --sandbox-test` builds a sandboxed debug copy under a separate bundle ID, so the self-test can be run inside the sandbox:

```sh
./scripts/build-appstore.sh --sandbox-test
MYSQLDESK_TEST_PASSWORD=… MYSQLDESK_SELFTEST="127.0.0.1:33084:root:…" build/sandbox-test/MysqlDesk.app/Contents/MacOS/MysqlDesk
```

## One-off setup

1. **Certificates:** Xcode → Settings → Accounts → your team → **Manage Certificates…** → **+** → *Apple Distribution*, then **+** → *Mac Installer Distribution*.
2. **App ID:** [developer.apple.com → Identifiers](https://developer.apple.com/account/resources/identifiers/list) → **+** → App IDs → App. Platform macOS, description `MysqlDesk`, explicit bundle ID `uk.co.dave-steer.mysqldesk`. No capabilities are needed.
3. **Provisioning profile:** Profiles → **+** → Distribution → *Mac App Store Connect* → the MysqlDesk App ID → your Apple Distribution certificate → name it `MysqlDesk App Store`. Download it; it lands in `~/Downloads/MysqlDesk_App_Store.provisionprofile`, where the script looks (or set `PROFILE`). Keep it out of the repo.
4. **Agreements:** App Store Connect → Business → accept the **Paid Apps** agreement and fill in tax and bank details. Paid apps can't go on sale until this is done.
5. **App record:** App Store Connect → Apps → **+** → New App → macOS, the name below, primary language English (UK), bundle ID `uk.co.dave-steer.mysqldesk`, SKU `mysqldesk`.

## Each release

1. Bump `VERSION`, commit and push (the build number is the commit count, so it goes up by itself).
2. `./scripts/release.sh` for GitHub, then `./scripts/build-appstore.sh` for `build/MysqlDesk-<version>-appstore.pkg`.
3. Upload the package with **Transporter** (free on the Mac App Store), signed in with your developer Apple ID.
4. In App Store Connect, add the new version, pick the build once it has processed (10–30 minutes), add "What's New" and submit for review.

## Listing

| Field | Value |
|---|---|
| Name (30) | MysqlDesk |
| Subtitle (30) | Fast, native MySQL client |
| Category | Developer Tools (secondary: Productivity) |
| Price | £2.99, UK as the base country (other countries follow automatically; you receive £2.11 per UK sale) |
| Support URL | https://www.dave-steer.co.uk/mysqldesk/ |
| Marketing URL | https://www.dave-steer.co.uk/mysqldesk/ |
| Privacy Policy URL | https://www.dave-steer.co.uk/mysqldesk/privacy.html |
| App Privacy | Data Not Collected |
| Age rating | Answer "None" to every question |
| Copyright | 2026 David Steer |
| Encryption | Already answered in the app (`ITSAppUsesNonExemptEncryption` = NO: standard TLS only) |
| Screenshots | `~/Sites/dave-steer/website-files/mysqldesk/scripts/take-screenshots.sh --appstore` → `build/appstore-screenshots/` (2880×1800) |

**Keywords (100):** `mariadb,sql,database,query,editor,dba,export,csv,json,tables,schema,developer,server,client`

**Promotional text (170):**
> Every MySQL server in one window. Query tabs that can each point at any server, results you can edit with a preview of the exact SQL, and column search for wide tables.

**Description:**

> MysqlDesk is a fast, native MySQL and MariaDB client for macOS. It does the things you do every day, and nothing else.
>
> EVERY SERVER IN ONE PLACE
> • All your connections in one sidebar, colour-tagged so production stands out
> • Passwords stored only in your Mac's Keychain
> • Query tabs that can each point at any server and schema
>
> WRITE AND RUN SQL
> • Syntax highlighting, and ⌥⇧↓ to duplicate a line
> • Run the statement under the cursor, a selection or the whole tab
> • Run All shows every result at once, up to 10
> • Open .sql files straight from Finder
> • Favourites and history for every connection
>
> EDIT WITH CONFIDENCE
> • Edit cells and delete rows right in the results
> • Review the exact UPDATE and DELETE statements before anything is saved
> • Changes are applied in a single transaction, so it's all or nothing
>
> FIND THINGS FAST
> • ⌘P to jump to any table on any server
> • ⌘B column search for tables with hundreds of columns
> • Export results to CSV, JSON or SQL INSERTs
>
> Works with MySQL 5.7 to 8.4 and MariaDB 10.x, with or without TLS. Nothing else to install.
>
> MysqlDesk collects no data: it talks only to the servers you add.

**Notes for App Review:**
> MysqlDesk is a client for the user's own MySQL or MariaDB servers, so it needs a database server to connect to. The attached video shows the full flow against a local test server with made-up data. To try it yourself, any MySQL or MariaDB server works, for example `docker run -e MYSQL_ROOT_PASSWORD=test -p 3306:3306 mysql:8.4`. Press ⇧⌘C (Manage Connections), add the server, click Test Connection, then double-click it in the sidebar to connect. The app collects no data and makes no network connections other than to servers the user adds.

App Review usually asks for a working way to test apps like this, so version 1.3.1 was submitted with a 43-second walk-through video as the review attachment. Make it with `~/Sites/dave-steer/website-files/mysqldesk/scripts/take-screenshots.sh --video` (Docker and ffmpeg): it plays a scripted tour against a throwaway server with made-up data and saves `build/app-review-demo.mp4`. Only the app's own window is recorded, never the screen.

## Possible review issues

- **"MySQL" is an Oracle trademark.** Guideline 5.2.1 lets Apple reject names containing someone else's trademark. If they do, rename the App Store listing only (for example "Desk for MySQL" or a new name); the bundle ID doesn't change.
- **The free GitHub version.** Selling an app that is also free elsewhere is allowed, but the App Store version must not link to the free download. It doesn't: the app has no links to GitHub.
