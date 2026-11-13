import Foundation
import Observation

/// Transient toast messages shown at the bottom of the window.
@MainActor @Observable
final class Banner {
    static let shared = Banner()

    struct Item: Identifiable {
        let id = UUID()
        let text: String
        let detail: String?
        let isError: Bool
    }

    var current: Item?

    func info(_ text: String) { show(Item(text: text, detail: nil, isError: false)) }

    func error(_ text: String, detail: String? = nil) { show(Item(text: text, detail: detail, isError: true)) }

    private func show(_ item: Item) {
        current = item
        Task {
            try? await Task.sleep(for: .seconds(item.isError ? 10 : 3))
            if current?.id == item.id { current = nil }
        }
    }
}

/// Settings saved with @AppStorage. They're stored under the bundle ID, so the move from
/// uk.co.llexeter.mysqldesk to uk.co.dave-steer.mysqldesk copies them across once.
enum Preferences {
    static let keys = ["maxRows", "tableRowLimit", "editorFontSize", "stopOnError", "stackResults"]

    static func migrateFromOldBundleID() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromLlexeter"),
              let old = UserDefaults(suiteName: "uk.co.llexeter.mysqldesk") else { return }
        for key in keys where defaults.object(forKey: key) == nil {
            if let value = old.object(forKey: key) { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: "migratedFromLlexeter")
    }
}

/// JSON files in ~/Library/Application Support/MysqlDesk.
enum Storage {
    static let folder: URL = {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["MYSQLDESK_DATA_DIR"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MysqlDesk", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func load<T: Decodable>(_ type: T.Type, from file: String) -> T? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(file)) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to file: String) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: folder.appendingPathComponent(file), options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Simple fuzzy matcher for the command palette: every query character must
/// appear in order. Higher scores for prefix, word-start and contiguous matches.
enum Fuzzy {
    static func score(_ query: String, in text: String) -> Int? {
        let query = query.lowercased().filter { !$0.isWhitespace }
        guard !query.isEmpty else { return 0 }
        let haystack = Array(text.lowercased())
        var score = 0
        var position = 0
        var previous: Int?

        for character in query {
            guard let found = haystack[position...].firstIndex(of: character) else { return nil }
            score += 1
            if found == 0 { score += 8 }
            if found > 0, " /-_.:".contains(haystack[found - 1]) { score += 5 }
            if let previous, found == previous + 1 { score += 4 }
            previous = found
            position = found + 1
        }
        if text.lowercased().contains(query) { score += 15 }
        return score - haystack.count / 12
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// UK-style dates for file names and lists.
enum Formats {
    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "dd/MM/yyyy HH:mm"
        return f
    }()

    static let fileDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "dd-MM-yyyy"
        return f
    }()

    static func duration(_ seconds: TimeInterval) -> String {
        seconds < 1 ? String(format: "%.0f ms", seconds * 1000) : String(format: "%.2f s", seconds)
    }
}
