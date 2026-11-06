import SwiftUI

struct MainView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 0) {
            TopBar()
            Divider()
            HSplitView {
                SidebarView()
                    .frame(minWidth: 200, idealWidth: 260, maxWidth: 420)

                VStack(spacing: 0) {
                    if !store.tabs.isEmpty { TabBar() }
                    if let tab = store.selectedTab, !store.showHome {
                        QueryView(tab: tab)
                    } else {
                        WelcomeView()
                    }
                }
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            }
            StatusBar()
        }
        .background(Theme.background)
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .bottomTrailing) { BannerView().padding(.bottom, 34).padding(.trailing, 16) }
        .overlay {
            if store.showPalette { CommandPalette() }
        }
        .sheet(isPresented: $store.showConnectionManager) { ConnectionManager().sheetStyle() }
        .sheet(item: $store.passwordRequest) { PasswordSheet(request: $0).sheetStyle() }
        .sheet(item: $store.favouriteDraft) { FavouriteSheet(draft: $0).sheetStyle() }
        .sheet(item: $store.valueViewer) { ValueViewerSheet(item: $0).sheetStyle() }
        .sheet(item: $store.cellEditor) { CellEditorSheet(item: $0).sheetStyle() }
        .sheet(item: $store.applyPreview) { ApplyPreviewSheet(preview: $0).sheetStyle() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            store.saveTabs()
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .debugOpenPalette)) { _ in store.showPalette = true }
        #endif
    }
}

struct StatusBar: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 8) {
            if let tab = store.selectedTab, let config = store.config(tab.connectionID), !store.showHome {
                Circle().fill(Theme.colour(config.colour)).frame(width: 7, height: 7)
                Text("\(config.username)@\(config.address)")
                if let server = store.server(config.id), server.isConnected {
                    Text("· \(server.versionLabel)")
                }
                if let database = tab.database { Text("· \(database)") }
            } else {
                Text("\(store.connections.count) connections")
            }
            Spacer()
            Text("\(store.servers.filter(\.isConnected).count) connected")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Theme.toolbar)
    }
}

struct BannerView: View {
    @State private var banner = Banner.shared

    var body: some View {
        if let item = banner.current {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.isError ? "exclamationmark.octagon.fill" : "checkmark.circle.fill")
                    .foregroundStyle(item.isError ? .red : .green)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.text).font(.system(size: 12, weight: .semibold))
                    if let detail = item.detail {
                        Text(detail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(8)
                            .textSelection(.enabled)
                    }
                }
                Button {
                    banner.current = nil
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10))
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .frame(maxWidth: 460, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel).shadow(radius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(item.isError ? Color.red.opacity(0.6) : Color.white.opacity(0.1)))
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(item.id)
        }
    }
}

extension View {
    /// Sheets get their own window, so they need the app's dark look applied again.
    func sheetStyle() -> some View {
        background(Theme.panel).preferredColorScheme(.dark)
    }
}
