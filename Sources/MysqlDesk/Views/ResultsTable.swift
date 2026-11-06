import AppKit
import SwiftUI

/// The results grid. AppKit's NSTableView copes with thousands of rows and hundreds of columns
/// far better than a SwiftUI Table. Click a header to sort; the column filter (⌘B) hides
/// columns whose names don't match. Double-click a cell to edit it (ENUMs get a drop-down);
/// changes stay pending, highlighted, until Apply or Revert.
struct ResultsTable: NSViewRepresentable {
    let tab: QueryTab
    let result: ResultSet
    let filter: String
    /// Passed in so SwiftUI updates the grid whenever an edit is made or reverted.
    let editsVersion: Int
    let store: AppStore

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ResultsTableView()
        table.coordinator = context.coordinator
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.usesAlternatingRowBackgroundColors = true
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.gridColor = NSColor(white: 1, alpha: 0.06)
        table.rowHeight = 20
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.style = .plain
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        context.coordinator.table = table
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.tab = tab
        coordinator.store = store
        if coordinator.result !== result {
            coordinator.load(result)
            coordinator.filter = nil
        }
        if coordinator.filter != filter {
            coordinator.applyFilter(filter)
        }
        if coordinator.editsVersion != editsVersion {
            coordinator.editsVersion = editsVersion
            coordinator.table?.reloadData()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
        weak var table: NSTableView?
        weak var tab: QueryTab?
        weak var store: AppStore?
        var result: ResultSet?
        var filter: String?
        var editsVersion = -1
        /// The cell being edited in place, and whether Esc cancelled it.
        private var editing: (row: Int, column: Int)?
        private var editCancelled = false
        /// Display order of the result's rows (changes when sorted).
        private var order: [Int] = []

        private static let rowNumberID = NSUserInterfaceItemIdentifier("row#")
        private static let cellID = NSUserInterfaceItemIdentifier("cell")
        private let cellFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        private let nullFont = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 11), toHaveTrait: .italicFontMask)

        func load(_ result: ResultSet) {
            guard let table else { return }
            self.result = result
            order = Array(result.rows.indices)
            table.tableColumns.forEach(table.removeTableColumn)

            let digits = max(String(result.rows.count).count, 2)
            let number = NSTableColumn(identifier: Self.rowNumberID)
            number.title = ""
            number.width = CGFloat(digits * 8 + 12)
            number.minWidth = 24
            number.isEditable = false
            table.addTableColumn(number)

            let sample = result.rows.prefix(60)
            for (index, column) in result.columns.enumerated() {
                let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(index)"))
                tableColumn.title = column.name
                tableColumn.headerToolTip = "\(column.name) · \(describe(column.kind))"
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: "\(index)", ascending: true)
                tableColumn.isEditable = false
                // Size from the header and the first few values.
                let longest = sample.map { min($0[index]?.count ?? 4, 60) }.max() ?? 4
                tableColumn.width = min(max(CGFloat(max(longest, column.name.count)) * 7.4 + 18, 50), 420)
                tableColumn.minWidth = 30
                table.addTableColumn(tableColumn)
            }
            table.sortDescriptors = []
            table.reloadData()
            if !order.isEmpty { table.scrollRowToVisible(0) }
            table.scrollColumnToVisible(0)
        }

        func applyFilter(_ text: String) {
            guard let table, let result else { return }
            filter = text
            let query = text.trimmed
            var first: Int?
            for (index, column) in result.columns.enumerated() {
                guard let tableColumn = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("c\(index)")) else { continue }
                let match = query.isEmpty || column.name.localizedCaseInsensitiveContains(query)
                tableColumn.isHidden = !match
                if match && first == nil { first = table.column(withIdentifier: tableColumn.identifier) }
            }
            if let first, !query.isEmpty { table.scrollColumnToVisible(first) }
        }

        private func describe(_ kind: ColumnKind) -> String {
            switch kind {
            case .number: "number"
            case .text: "text"
            case .dateTime: "date/time"
            case .json: "JSON"
            case .binary: "binary"
            }
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int { order.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let result, let tableColumn, order.indices.contains(row) else { return nil }
            let field = (tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? NSTextField) ?? makeField()

            if tableColumn.identifier == Self.rowNumberID {
                field.stringValue = "\(row + 1)"
                field.font = cellFont
                field.textColor = .tertiaryLabelColor
                field.alignment = .right
                return field
            }
            let index = Int(tableColumn.identifier.rawValue.dropFirst()) ?? 0
            let column = result.columns[index]
            let edited = tab?.isEdited(row: order[row], column: index, in: result) == true
            field.drawsBackground = edited
            field.backgroundColor = edited ? NSColor.systemOrange.withAlphaComponent(0.28) : .clear
            if let value = tab?.value(row: order[row], column: index, in: result) ?? result.rows[order[row]][index] {
                // One line per cell: long values are cut short and new lines shown as ⏎.
                var text = value.count > 400 ? String(value.prefix(400)) + "…" : value
                if text.contains(where: \.isNewline) { text = text.replacingOccurrences(of: "\r\n", with: "⏎").replacingOccurrences(of: "\n", with: "⏎") }
                field.stringValue = text
                field.font = cellFont
                field.textColor = column.kind == .binary && value.hasPrefix("0x") ? .secondaryLabelColor : .labelColor
            } else {
                field.stringValue = "NULL"
                field.font = nullFont
                field.textColor = .tertiaryLabelColor
            }
            field.alignment = column.kind == .number ? .right : .left
            return field
        }

        private func makeField() -> NSTextField {
            let field = NSTextField(labelWithString: "")
            field.identifier = Self.cellID
            field.lineBreakMode = .byTruncatingTail
            field.cell?.truncatesLastVisibleLine = true
            field.allowsDefaultTighteningForTruncation = false
            return field
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let result, let descriptor = tableView.sortDescriptors.first, let key = descriptor.key, let index = Int(key) else { return }
            let numeric = result.columns[index].kind == .number
            let rows = result.rows
            let selected = Set(tableView.selectedRowIndexes.map { order[$0] })
            order.sort { a, b in
                let ordered: Bool
                switch (rows[a][index], rows[b][index]) {
                case (nil, nil): return a < b
                case (nil, _): ordered = true // NULLs first when ascending
                case (_, nil): ordered = false
                case (let x?, let y?):
                    if x == y { return a < b }
                    if numeric, let dx = Double(x), let dy = Double(y) {
                        ordered = dx < dy
                    } else {
                        ordered = x.localizedStandardCompare(y) == .orderedAscending
                    }
                }
                return descriptor.ascending ? ordered : !ordered
            }
            tableView.reloadData()
            tableView.selectRowIndexes(IndexSet(order.indices.filter { selected.contains(order[$0]) }), byExtendingSelection: false)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table else { return }
            tab?.selectedRows = table.selectedRowIndexes.map { order[$0] }
        }

        // MARK: Actions

        @objc func doubleClicked(_ sender: NSTableView) {
            guard sender.clickedRow >= 0, sender.clickedColumn >= 0 else { return }
            beginEdit(row: sender.clickedRow, tableColumn: sender.clickedColumn)
        }

        // MARK: Editing

        /// Checks the result can be edited (loading its table details the first time), then calls `body`.
        private func withContext(column index: Int, _ body: @escaping (EditContext, ResultSet, QueryTab) -> Void) {
            guard let tab, let store, let result else { return }
            Task { @MainActor in
                switch await store.editContext(for: tab, result: result) {
                case .failure(let error):
                    Banner.shared.error("These results can't be edited", detail: error.message)
                case .success(let context):
                    guard context.editable.contains(index) else {
                        Banner.shared.error("“\(result.columns[index].name)” can't be edited",
                                            detail: "It's calculated, binary, or from another table.")
                        return
                    }
                    body(context, result, tab)
                }
            }
        }

        func beginEdit(row: Int, tableColumn: Int) {
            guard let index = columnIndex(tableColumn), order.indices.contains(row) else { return }
            let resultRow = order[row]
            withContext(column: index) { [weak self] context, result, tab in
                guard let self, let table = self.table else { return }
                let current = tab.value(row: resultRow, column: index, in: result)

                if let options = context.enumOptions[index] {
                    self.showEnumMenu(options, nullable: context.nullable.contains(index), current: current,
                                      row: row, tableColumn: tableColumn) { value in
                        tab.setEdit(value, row: resultRow, column: index, in: result)
                    }
                } else if let current, current.contains(where: \.isNewline) || current.count > 200 || result.columns[index].kind == .json {
                    // Long or multi-line text is easier to edit in a sheet.
                    self.store?.cellEditor = .init(tabID: tab.id, resultID: result.id, row: resultRow, column: index,
                                                   columnName: result.columns[index].name, value: current,
                                                   nullable: context.nullable.contains(index))
                } else if let field = table.view(atColumn: tableColumn, row: row, makeIfNecessary: true) as? NSTextField {
                    table.scrollColumnToVisible(tableColumn)
                    self.editing = (resultRow, index)
                    self.editCancelled = false
                    field.isEditable = true
                    field.isSelectable = true
                    field.drawsBackground = true
                    field.backgroundColor = .textBackgroundColor
                    field.textColor = .labelColor
                    field.font = self.cellFont
                    field.stringValue = current ?? ""
                    field.delegate = self
                    table.window?.makeFirstResponder(field)
                    field.currentEditor()?.selectAll(nil)
                }
            }
        }

        /// ENUM columns: a drop-down of the allowed values at the cell.
        private func showEnumMenu(_ options: [String], nullable: Bool, current: String?, row: Int, tableColumn: Int,
                                  choose: @escaping (String?) -> Void) {
            guard let table else { return }
            let menu = NSMenu()
            var selected: NSMenuItem?
            for option in options {
                let item = self.item(option.isEmpty ? "(empty)" : option) { choose(option) }
                if option == current { item.state = .on; selected = item }
                menu.addItem(item)
            }
            if nullable {
                menu.addItem(.separator())
                let null = self.item("NULL") { choose(nil) }
                if current == nil { null.state = .on; selected = null }
                menu.addItem(null)
            }
            let cell = table.frameOfCell(atColumn: tableColumn, row: row)
            menu.minimumWidth = cell.width
            menu.popUp(positioning: selected, at: NSPoint(x: cell.minX, y: cell.maxY), in: table)
        }

        /// Esc cancels an in-place edit.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            editCancelled = true
            table?.window?.makeFirstResponder(table)
            return true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, let editing, let result, let tab else { return }
            self.editing = nil
            field.isEditable = false
            field.isSelectable = false
            field.delegate = nil
            if !editCancelled {
                tab.setEdit(field.stringValue, row: editing.row, column: editing.column, in: result)
            }
            table?.reloadData()
            table?.window?.makeFirstResponder(table)
        }

        private func columnIndex(_ tableColumnIndex: Int) -> Int? {
            guard let table, table.tableColumns.indices.contains(tableColumnIndex) else { return nil }
            let identifier = table.tableColumns[tableColumnIndex].identifier
            guard identifier != Self.rowNumberID else { return nil }
            return Int(identifier.rawValue.dropFirst())
        }

        /// ⌘C: selected rows as tab-separated text.
        func copyRows() {
            store?.copy(tab, as: nil)
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, let result else { return }
            // Right-clicking outside the selection selects that row first, like Finder.
            if table.clickedRow >= 0, !table.selectedRowIndexes.contains(table.clickedRow) {
                table.selectRowIndexes([table.clickedRow], byExtendingSelection: false)
            }
            let hasSelection = !table.selectedRowIndexes.isEmpty

            if table.clickedRow >= 0, let index = columnIndex(table.clickedColumn) {
                let value = result.rows[order[table.clickedRow]][index]
                let row = table.clickedRow, tableColumn = table.clickedColumn, resultRow = order[table.clickedRow]
                let shown = tab?.value(row: resultRow, column: index, in: result) ?? value
                menu.addItem(item("Edit Value") { [weak self] in self?.beginEdit(row: row, tableColumn: tableColumn) })
                menu.addItem(item("Set to NULL") { [weak self] in
                    self?.withContext(column: index) { context, result, tab in
                        guard context.nullable.contains(index) else {
                            Banner.shared.error("“\(result.columns[index].name)” can't be NULL")
                            return
                        }
                        tab.setEdit(nil, row: resultRow, column: index, in: result)
                    }
                })
                if tab?.isEdited(row: resultRow, column: index, in: result) == true {
                    menu.addItem(item("Revert This Cell") { [weak self] in
                        self?.tab?.setEdit(value, row: resultRow, column: index, in: result)
                    })
                }
                menu.addItem(.separator())
                menu.addItem(item("Copy Value") { Self.setPasteboard(shown ?? "NULL") })
                menu.addItem(item("View Value…") { [weak self] in
                    self?.store?.valueViewer = .init(column: result.columns[index].name, value: shown)
                })
                menu.addItem(item("Copy Column Name") { Self.setPasteboard(result.columns[index].name) })
                menu.addItem(.separator())
            }
            if hasSelection {
                menu.addItem(item("Copy Rows") { [weak self] in self?.store?.copy(self?.tab, as: nil) })
                for format in ExportFormat.allCases {
                    menu.addItem(item("Copy Rows as \(format.title)") { [weak self] in self?.store?.copy(self?.tab, as: format) })
                }
                menu.addItem(.separator())
                for format in ExportFormat.allCases {
                    menu.addItem(item("Export Selected Rows as \(format.title)…") { [weak self] in
                        self?.store?.export(self?.tab, as: format, selectedOnly: true)
                    })
                }
                menu.addItem(.separator())
            }
            for format in ExportFormat.allCases {
                menu.addItem(item("Export All Rows as \(format.title)…") { [weak self] in
                    self?.store?.export(self?.tab, as: format, selectedOnly: false)
                })
            }
        }

        private func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
            let item = ClosureMenuItem(title: title, action: #selector(ClosureMenuItem.run), keyEquivalent: "")
            item.handler = action
            item.target = item
            return item
        }

        static func setPasteboard(_ text: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

/// Lets ⌘C (Edit ▸ Copy) copy the selected rows.
final class ResultsTableView: NSTableView {
    weak var coordinator: ResultsTable.Coordinator?

    @objc func copy(_ sender: Any?) {
        MainActor.assumeIsolated { coordinator?.copyRows() }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !selectedRowIndexes.isEmpty }
        return super.validateUserInterfaceItem(item)
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    var handler: (() -> Void)?

    @objc func run() { handler?() }
}
