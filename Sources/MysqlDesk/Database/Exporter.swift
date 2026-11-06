import Foundation

/// Turns a result set (or some of its rows) into CSV, JSON or SQL INSERT statements.
enum ExportFormat: String, CaseIterable, Identifiable {
    case csv, json, sql

    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var fileExtension: String { rawValue }
}

enum Exporter {
    /// `rows` are indexes into `result.rows`; nil exports everything.
    static func export(_ result: ResultSet, rows: [Int]? = nil, as format: ExportFormat) -> String {
        let selected = rows.map { $0.map { result.rows[$0] } } ?? result.rows
        switch format {
        case .csv: return csv(result.columns, selected, header: true)
        case .json: return json(result.columns, selected)
        case .sql: return sql(result.columns, selected, table: result.sourceTable ?? "export")
        }
    }

    /// RFC 4180 CSV. NULL becomes an empty field.
    static func csv(_ columns: [ResultColumn], _ rows: [[String?]], header: Bool) -> String {
        func field(_ value: String?) -> String {
            guard let value else { return "" }
            guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var lines: [String] = []
        if header { lines.append(columns.map { field($0.name) }.joined(separator: ",")) }
        for row in rows { lines.append(row.map(field).joined(separator: ",")) }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Tab-separated values, for pasting into Excel or Numbers.
    static func tsv(_ columns: [ResultColumn], _ rows: [[String?]], header: Bool) -> String {
        func field(_ value: String?) -> String {
            (value ?? "NULL").replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        }
        var lines: [String] = []
        if header { lines.append(columns.map(\.name).joined(separator: "\t")) }
        for row in rows { lines.append(row.map(field).joined(separator: "\t")) }
        return lines.joined(separator: "\n")
    }

    /// An array of objects, keeping the column order. Numbers and JSON columns aren't quoted.
    static func json(_ columns: [ResultColumn], _ rows: [[String?]]) -> String {
        let keys = columns.map { jsonString($0.name) }
        let objects = rows.map { row in
            let fields = zip(keys, zip(columns, row)).map { key, pair in
                "    \(key): \(jsonValue(pair.1, kind: pair.0.kind))"
            }
            return "  {\n" + fields.joined(separator: ",\n") + "\n  }"
        }
        return objects.isEmpty ? "[]\n" : "[\n" + objects.joined(separator: ",\n") + "\n]\n"
    }

    /// INSERT statements in batches of 500 rows, like mysqldump's extended inserts.
    static func sql(_ columns: [ResultColumn], _ rows: [[String?]], table: String) -> String {
        guard !rows.isEmpty else { return "" }
        let head = "INSERT INTO \(SQL.identifier(table)) (\(columns.map { SQL.identifier($0.name) }.joined(separator: ", "))) VALUES\n"
        let values = rows.map { row in
            "(" + zip(columns, row).map { sqlValue($1, kind: $0.kind) }.joined(separator: ", ") + ")"
        }
        return stride(from: 0, to: values.count, by: 500).map { start in
            head + values[start..<min(start + 500, values.count)].joined(separator: ",\n") + ";\n"
        }.joined(separator: "\n")
    }

    static func sqlValue(_ value: String?, kind: ColumnKind) -> String {
        guard let value else { return "NULL" }
        switch kind {
        case .number where Double(value) != nil: return value
        case .binary where value.hasPrefix("0x"): return value
        default: return SQL.literal(value)
        }
    }

    private static func jsonValue(_ value: String?, kind: ColumnKind) -> String {
        guard let value else { return "null" }
        switch kind {
        case .number where isJSONNumber(value):
            return value
        case .json where (try? JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed)) != nil:
            return value
        default:
            return jsonString(value)
        }
    }

    private static func isJSONNumber(_ value: String) -> Bool {
        value.range(of: #"^-?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?$"#, options: .regularExpression) != nil
    }

    private static func jsonString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let s where s.value < 0x20: out += String(format: "\\u%04X", s.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
