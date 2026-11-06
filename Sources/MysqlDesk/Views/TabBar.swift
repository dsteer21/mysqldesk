import SwiftUI

/// Query tabs across the top of the editor, each with its connection's colour along the top edge.
/// Drag to reorder; double-click to rename.
struct TabBar: View {
    @Environment(AppStore.self) private var store
    @State private var renaming: QueryTab?
    @State private var newName = ""

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 1) {
                        ForEach(Array(store.tabs.enumerated()), id: \.element.id) { index, tab in
                            TabItem(tab: tab, number: index + 1, selected: tab.id == store.selectedTabID && !store.showHome) {
                                renaming = tab
                                newName = tab.title
                            }
                            .id(tab.id)
                            .draggable(tab.id.uuidString)
                            .dropDestination(for: String.self) { items, _ in
                                guard let id = items.first.flatMap(UUID.init) else { return false }
                                store.moveTab(id, before: tab.id)
                                return true
                            }
                        }
                    }
                }
                .onChange(of: store.selectedTabID) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id) } }
                }
            }
            Button { store.newTab() } label: {
                Image(systemName: "plus").frame(width: 30, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New query tab (⌘T)")
        }
        .frame(height: 30)
        .background(Theme.toolbar)
        .alert("Rename Tab", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if !newName.trimmed.isEmpty { renaming?.title = newName.trimmed }
                store.tabsChanged()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct TabItem: View {
    @Environment(AppStore.self) private var store
    let tab: QueryTab
    let number: Int
    let selected: Bool
    let rename: () -> Void
    @State private var hovering = false

    var body: some View {
        let config = store.config(tab.connectionID)

        HStack(spacing: 6) {
            if tab.running {
                ProgressView().controlSize(.mini)
            } else if tab.favouriteID != nil {
                Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow)
            }
            Text(tab.title).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
            if store.isModified(tab) {
                Circle().fill(.orange).frame(width: 6, height: 6).help("Changed since the favourite was saved")
            }
            Button {
                store.closeTab(tab)
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .opacity(hovering || selected ? 1 : 0)
            .help("Close tab (⌘W)")
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 110, maxWidth: 220)
        .frame(height: 30)
        .background(selected ? Theme.background : (hovering ? Theme.panel : Theme.toolbar))
        .overlay(alignment: .top) {
            Rectangle().fill(config.map { Theme.colour($0.colour) } ?? .clear).frame(height: 2).opacity(selected ? 1 : 0.6)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: rename)
        .onTapGesture { store.selectedTabID = tab.id }
        .onHover { hovering = $0 }
        .help(config.map { "\($0.name) — \(tab.database ?? "no schema")" + (number <= 9 ? "  (⌘\(number))" : "") } ?? tab.title)
        .contextMenu {
            Button("Rename…", action: rename)
            Button("Duplicate") { store.duplicateTab(tab) }
            Divider()
            Button("Close Tab") { store.closeTab(tab) }
            Button("Close Other Tabs") { store.closeOtherTabs(tab) }
        }
    }
}
