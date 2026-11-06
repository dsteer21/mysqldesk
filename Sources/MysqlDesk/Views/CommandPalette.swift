import SwiftUI

/// ⌘P: fuzzy search over every table on the connected servers, plus favourites, connections and actions.
struct CommandPalette: View {
    @Environment(AppStore.self) private var store
    @State private var query = ""
    @State private var highlighted = 0
    @State private var items: [AppStore.PaletteItem] = []
    @State private var loadingTables = false
    @FocusState private var focused: Bool

    /// Items containing every typed word (in any order) win; loose fuzzy matching is only a fallback.
    /// Within those, a title (e.g. table name) that is, starts with or contains the first word ranks higher,
    /// so "orders" puts the `orders` tables above `orders_archive`, and "archive ord" finds `orders_archive`.
    private var results: [AppStore.PaletteItem] {
        let trimmed = query.trimmed
        guard !trimmed.isEmpty else { return items }
        let words = trimmed.split(separator: " ").map(String.init)
        let first = words[0].lowercased()
        let text = { (item: AppStore.PaletteItem) in item.title + " " + item.subtitle }

        func titleBonus(_ item: AppStore.PaletteItem) -> Int {
            let title = item.title.lowercased()
            return title == first ? 300 : title.hasPrefix(first) ? 200 - min(title.count, 60) : title.contains(first) ? 100 : 0
        }

        let exact = items.filter { item in words.allSatisfy { text(item).localizedCaseInsensitiveContains($0) } }
        let scored: [(AppStore.PaletteItem, Int)] = exact.isEmpty
            // Fallback: letters in the typed order, anywhere in the text.
            ? items.compactMap { item in Fuzzy.score(trimmed, in: text(item)).map { (item, $0 + titleBonus(item)) } }
            // Every word is there: score each word on its own, so word order doesn't matter.
            : exact.map { item in (item, words.reduce(0) { $0 + (Fuzzy.score($1, in: text(item)) ?? 0) } + titleBonus(item)) }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }

    var body: some View {
        let results = results
        ZStack(alignment: .top) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search tables, favourites, connections and actions…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .focused($focused)
                        .onSubmit { run(results) }
                        .onKeyPress(.downArrow) {
                            highlighted = min(highlighted + 1, max(min(results.count, 60) - 1, 0))
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            highlighted = max(highlighted - 1, 0)
                            return .handled
                        }
                        .onKeyPress(.escape) {
                            close()
                            return .handled
                        }
                    if loadingTables {
                        ProgressView().controlSize(.small)
                        Text("Loading tables…").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(14)

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.prefix(60).enumerated()), id: \.element.id) { index, item in
                                // Identify rows by item, not position, or SwiftUI keeps showing stale rows as the list filters.
                                row(item, highlighted: index == highlighted)
                                    .id(item.id)
                                    .onTapGesture {
                                        highlighted = index
                                        run(results)
                                    }
                            }
                            if results.isEmpty {
                                Text("No matches").foregroundStyle(.secondary).padding(20)
                            }
                        }
                    }
                    .frame(maxHeight: 380)
                    .onChange(of: highlighted) { _, index in
                        if results.indices.contains(index) { proxy.scrollTo(results[index].id) }
                    }
                }
                if results.count > 60 {
                    Divider()
                    Text("Showing 60 of \(results.count.formatted()) — keep typing to narrow it down")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
            }
            .frame(width: 600)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel).shadow(radius: 24))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.12)))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.top, 70)
        }
        .onAppear {
            items = store.paletteItems()
            focused = true
            guard store.paletteNeedsTables else { return }
            // Fetch every table on the connected servers, then refresh the list (keeping what's typed).
            loadingTables = true
            Task {
                await store.loadTablesForPalette()
                items = store.paletteItems()
                loadingTables = false
            }
        }
        .onChange(of: query) { highlighted = 0 }
    }

    private func row(_ item: AppStore.PaletteItem, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon).frame(width: 20).foregroundStyle(.secondary)
            Text(item.title).font(.system(size: 13))
            Spacer()
            Text(item.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(highlighted ? Theme.selection : .clear)
        .contentShape(Rectangle())
    }

    private func run(_ results: [AppStore.PaletteItem]) {
        guard results.indices.contains(highlighted) else { return }
        let item = results[highlighted]
        close()
        item.action()
    }

    private func close() {
        store.showPalette = false
    }
}
