import SwiftUI

/// MySQL Workbench-style home screen: a tile per saved connection. Double-click to connect.
struct WelcomeView: View {
    @Environment(AppStore.self) private var store
    @State private var filter = ""

    private var filtered: [ConnectionConfig] {
        let query = filter.trimmed
        guard !query.isEmpty else { return store.connections }
        return store.connections.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.host.localizedCaseInsensitiveContains(query)
                || $0.username.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("MySQL Connections").font(.title2.bold())
                Button(action: addConnection) { Image(systemName: "plus.circle") }
                    .buttonStyle(.plain)
                    .help("Add a connection")
                Button { store.showManager() } label: { Image(systemName: "wrench.and.screwdriver") }
                    .buttonStyle(.plain)
                    .help("Manage connections (⇧⌘C)")
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter connections", text: $filter).textFieldStyle(.plain)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(width: 220)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.07)))
            }
            .font(.system(size: 16))
            .padding(20)

            if store.connections.isEmpty {
                ContentUnavailableView {
                    Label("No connections yet", systemImage: "server.rack")
                } description: {
                    Text("Add each MySQL or MariaDB server you use. Passwords are stored in your Keychain.")
                } actions: {
                    Button("Add Connection…", action: addConnection)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 300), spacing: 12)], alignment: .leading, spacing: 12) {
                        ForEach(filtered) { config in
                            ConnectionTile(config: config, server: store.server(config.id))
                                .onTapGesture(count: 2) { store.connectAndOpen(config) }
                                .contextMenu {
                                    Button("Connect") { store.connectAndOpen(config) }
                                    Button("Edit Connection…") { store.showManager(selecting: config.id) }
                                }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
                Text("Double-click a connection to open it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
    }

    private func addConnection() {
        let config = ConnectionConfig()
        store.saveConnection(config)
        store.showManager(selecting: config.id)
    }
}

private struct ConnectionTile: View {
    let config: ConnectionConfig
    let server: Server?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(config.name).font(.system(size: 15, weight: .medium)).lineLimit(1)
                Spacer()
                if server?.isConnected == true {
                    Circle().fill(.green).frame(width: 7, height: 7).help("Connected")
                }
            }
            Label(config.username, systemImage: "person.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Label(config.address, systemImage: "network")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
        .background(alignment: .bottomTrailing) {
            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: 46))
                .foregroundStyle(.white.opacity(0.05))
                .padding(10)
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.panel.opacity(1.4) : Theme.panel))
        .overlay(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6)
                .fill(Theme.colour(config.colour))
                .frame(height: config.colour == .none ? 0 : 3)
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(hovering ? 0.18 : 0.08)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
