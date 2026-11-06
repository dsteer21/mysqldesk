import SwiftUI

/// GitDesk-style top bar: connection actions on the left, search on the right.
/// Query actions (run, stop, format, favourites, export) live above the editor and in the menus.
struct TopBar: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 2) {
            ToolButton(title: "Connect", icon: "bolt.horizontal", help: "Manage connections (⇧⌘C)") { store.showManager() }
            ToolButton(title: "Home", icon: "square.grid.2x2", help: "Connections home (⌘0)") { store.showHome.toggle() }
                .disabled(store.tabs.isEmpty)
            ToolButton(title: "New Query", icon: "plus.square", help: "New query tab (⌘T)") { store.newTab() }

            Spacer(minLength: 16)

            Button {
                store.showPalette = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                    Text("Search")
                    Text("⌘P").foregroundStyle(.tertiary)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .padding(.leading, 6)
        }
        .padding(.leading, 78) // clear the window's traffic-light buttons
        .padding(.trailing, 10)
        .padding(.vertical, 5)
        .background(Theme.toolbar)
    }
}
