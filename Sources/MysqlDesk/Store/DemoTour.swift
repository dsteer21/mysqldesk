#if DEBUG
import AppKit
import Foundation

/// A scripted walk-through for the App Review video, plus a recorder that saves the window as frames.
/// Debug builds only; driven by `mysqldesk-webpage/scripts/take-screenshots.sh --video`.
/// - `MYSQLDESK_DEMO_TOUR=host:port:user` starts with no connections, then types a new connection into
///   Manage Connections, tests it, connects, types and runs a query, edits and deletes rows, applies them and quits.
/// - `MYSQLDESK_RECORD=/tmp/frames` saves the window (with any open sheet) as numbered PNGs, 10 a second.
@MainActor
enum DemoTour {
    static func run(_ store: AppStore, spec: String) async {
        let parts = spec.split(separator: ":").map(String.init)
        guard parts.count >= 3, let port = Int(parts[1]) else { return log("DEMO_TOUR_FAILED bad spec \(spec)") }
        let (host, user) = (parts[0], parts[2])

        log("DEMO_TOUR_START \(host):\(port)")
        await pause(2)
        caption("Add a connection: ⇧⌘C opens Manage Connections")
        store.showManager()
        await pause(2)
        press("new")
        await pause(1.2)
        await type("Demo Shop", into: "name")
        await type(host, into: "host")
        await type(String(port), into: "port")
        await type(user, into: "user")
        await pause(1)

        caption("Test Connection checks the details")
        press("test")
        await pause(3.5)
        press("close")
        await pause(1.5)

        guard let config = store.connections.first else { return log("DEMO_TOUR_FAILED no connection") }
        caption("Connect, then browse schemas and tables in the sidebar")
        guard let server = await store.connect(config) else { return log("DEMO_TOUR_FAILED connect") }
        await pause(1)
        if let schema = server.schemas.first(where: { $0.name == "shop" }) {
            schema.expanded = true
            await server.loadTables(schema)
        }
        await pause(2)

        caption("Write a query in a new tab")
        let tab = store.newTab(connectionID: config.id, database: "shop", title: "Orders")
        await pause(1)
        let editor = tab.editor.textView
        editor.window?.makeFirstResponder(editor)
        for character in "SELECT id, order_ref, status, total, notes, placed_at\nFROM orders\nORDER BY id DESC;" {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
            await pause(0.045)
        }
        await pause(1)

        caption("Run it: ⌘↩")
        store.run(tab, .all)
        while tab.running || tab.outcomes.isEmpty { await pause(0.1) }
        await pause(3)

        guard let result = tab.currentResult, case .success = await store.editContext(for: tab, result: result) else {
            return log("DEMO_TOUR_FAILED not editable")
        }
        caption("Edit cells and mark rows for deletion")
        tab.setEdit("dispatched", row: 1, column: 2, in: result)
        await pause(1.5)
        tab.setEdit("Leave with neighbour", row: 2, column: 4, in: result)
        await pause(1.5)
        tab.toggleDeletion(rows: [3], in: result)
        await pause(2.5)

        caption("Apply shows the exact SQL first")
        store.previewEdits(tab)
        await pause(5)
        guard let preview = store.applyPreview else { return log("DEMO_TOUR_FAILED no preview") }
        store.applyPreview = nil
        await store.applyEdits(preview)
        await pause(4)
        log("DEMO_TOUR_DONE")
        exit(0)
    }

    /// Printed for take-screenshots.sh, flushed straight away in case the app is stopped.
    private static func log(_ message: String) {
        print(message)
        fflush(stdout)
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func caption(_ text: String) {
        Banner.shared.info(text)
    }

    /// Presses New, Test Connection or Close in Manage Connections.
    private static func press(_ action: String) {
        NotificationCenter.default.post(name: .debugManagerAction, object: action)
    }

    /// Fills in a Manage Connections field one character at a time, as if typed.
    private static func type(_ text: String, into field: String) async {
        for count in 1...text.count {
            NotificationCenter.default.post(name: .debugFormField, object: field, userInfo: ["value": String(text.prefix(count))])
            await pause(0.08)
        }
        await pause(0.5)
    }
}

/// Saves the main window, with any sheet drawn over it, as numbered PNG frames.
@MainActor
enum Recorder {
    private static var frame = 0

    static func start(to folder: String) {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let started = Date()
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let data = windowImage() else { return }
                // Frames follow the clock: if the app was busy, repeat this one to fill the gap, so the video plays in real time.
                let due = Int(Date().timeIntervalSince(started) * 10) + 1
                while frame < due {
                    frame += 1
                    try? data.write(to: URL(fileURLWithPath: folder).appendingPathComponent(String(format: "%05d.png", frame)))
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func windowImage() -> Data? {
        guard let main = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil && $0.contentView != nil }),
              let view = main.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let sheet = main.attachedSheet, let sheetView = sheet.contentView,
           let sheetRep = sheetView.bitmapImageRepForCachingDisplay(in: sheetView.bounds) {
            sheetView.cacheDisplay(in: sheetView.bounds, to: sheetRep)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.black.withAlphaComponent(0.3).setFill()
            view.bounds.fill(using: .sourceOver)
            let origin = NSPoint(x: sheet.frame.minX - main.frame.minX, y: sheet.frame.minY - main.frame.minY)
            sheetRep.draw(in: NSRect(origin: origin, size: sheetView.bounds.size))
            NSGraphicsContext.restoreGraphicsState()
        }
        return rep.representation(using: .png, properties: [:])
    }
}
#endif
