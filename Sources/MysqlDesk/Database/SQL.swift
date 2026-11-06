import Foundation

/// SQL text helpers: splitting into statements, quoting, keyword list and the ⇧⌘K formatter.
enum SQL {
    struct Statement {
        /// UTF-16 range of the statement text (no surrounding whitespace, no trailing semicolon),
        /// so it lines up with NSTextView selections.
        let range: NSRange
        /// End of the statement including its semicolon.
        let end: Int
        let text: String
    }

    // MARK: Splitting

    /// Splits on semicolons that aren't inside quotes or comments. Comment-only statements are dropped.
    static func statements(in sql: String) -> [Statement] {
        let chars = Array(sql.utf16)
        var statements: [Statement] = []
        var start = 0
        var i = 0

        func add(upTo end: Int, semicolon: Bool) {
            var from = start, to = end
            while from < to, isSpace(chars[from]) { from += 1 }
            while to > from, isSpace(chars[to - 1]) { to -= 1 }
            guard to > from else { return }
            let text = String(utf16CodeUnits: Array(chars[from..<to]), count: to - from)
            guard !stripComments(text).trimmed.isEmpty else { return }
            statements.append(Statement(range: NSRange(location: from, length: to - from), end: semicolon ? end + 1 : end, text: text))
        }

        while i < chars.count {
            let c = chars[i]
            if c == quote || c == doubleQuote || c == backtick {
                i = skipQuoted(chars, from: i)
            } else if startsComment(chars, i) {
                i = skipComment(chars, from: i)
            } else if c == semicolon {
                add(upTo: i, semicolon: true)
                i += 1
                start = i
            } else {
                i += 1
            }
        }
        add(upTo: chars.count, semicolon: false)
        return statements
    }

    /// The statement the cursor is in or just after, for "Run Current Statement".
    static func statement(at cursor: Int, in sql: String) -> Statement? {
        let all = statements(in: sql)
        let chars = Array(sql.utf16)
        // Cursor straight after a statement on the same line: run that one.
        if let previous = all.last(where: { $0.end <= cursor }),
           chars[previous.end..<min(cursor, chars.count)].allSatisfy({ $0 == 32 || $0 == 9 }) {
            return previous
        }
        return all.first { $0.end >= cursor } ?? all.last
    }

    /// Removes -- / # / /* */ comments (keeping quoted text intact).
    static func stripComments(_ sql: String) -> String {
        let chars = Array(sql.utf16)
        var kept: [UInt16] = []
        var i = 0
        while i < chars.count {
            if chars[i] == quote || chars[i] == doubleQuote || chars[i] == backtick {
                let end = skipQuoted(chars, from: i)
                kept += chars[i..<end]
                i = end
            } else if startsComment(chars, i) {
                i = skipComment(chars, from: i)
                kept.append(32)
            } else {
                kept.append(chars[i])
                i += 1
            }
        }
        return String(utf16CodeUnits: kept, count: kept.count)
    }

    /// The first keyword of a statement, upper-cased ("SELECT", "USE"…).
    static func verb(of statement: String) -> String {
        stripComments(statement).trimmed.prefix { $0.isLetter }.uppercased()
    }

    private static let quote: UInt16 = 39, doubleQuote: UInt16 = 34, backtick: UInt16 = 96
    private static let semicolon: UInt16 = 59, backslash: UInt16 = 92, newline: UInt16 = 10

    private static func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }

    private static func startsComment(_ chars: [UInt16], _ i: Int) -> Bool {
        let c = chars[i]
        let next = i + 1 < chars.count ? chars[i + 1] : 0
        if c == 35 { return true } // #
        if c == 47 && next == 42 { return true } // /*
        // "--" only starts a comment when followed by whitespace (or the end).
        return c == 45 && next == 45 && (i + 2 >= chars.count || isSpace(chars[i + 2]))
    }

    private static func skipComment(_ chars: [UInt16], from i: Int) -> Int {
        if chars[i] == 47 {
            var j = i + 2
            while j + 1 < chars.count, !(chars[j] == 42 && chars[j + 1] == 47) { j += 1 }
            return min(j + 2, chars.count)
        }
        var j = i
        while j < chars.count, chars[j] != newline { j += 1 }
        return j
    }

    /// Index just past the closing quote; handles doubled quotes and backslash escapes.
    private static func skipQuoted(_ chars: [UInt16], from i: Int) -> Int {
        let q = chars[i]
        var j = i + 1
        while j < chars.count {
            if chars[j] == backslash && q != backtick {
                j += 2
            } else if chars[j] == q {
                if j + 1 < chars.count, chars[j + 1] == q { j += 2 } else { return j + 1 }
            } else {
                j += 1
            }
        }
        return chars.count
    }

    // MARK: Quoting

    static func identifier(_ name: String) -> String {
        "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
    }

    /// A string literal escaped the way mysqldump does it.
    static func literal(_ value: String) -> String {
        var out = "'"
        for character in value.unicodeScalars {
            switch character {
            case "\\": out += "\\\\"
            case "'": out += "\\'"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\0": out += "\\0"
            case "\u{1A}": out += "\\Z"
            default: out.unicodeScalars.append(character)
            }
        }
        return out + "'"
    }

    // MARK: Keywords

    static let keywords: Set<String> = [
        "ADD", "ALL", "ALTER", "AND", "AS", "ASC", "BETWEEN", "BY", "CALL", "CASE", "CREATE", "CROSS", "DATABASE",
        "DATABASES", "DEFAULT", "DELETE", "DESC", "DESCRIBE", "DISTINCT", "DROP", "DUPLICATE", "ELSE", "END", "EXISTS",
        "EXPLAIN", "FALSE", "FOR", "FROM", "FULL", "GROUP", "HAVING", "IF", "IGNORE", "IN", "INDEX", "INNER", "INSERT",
        "INTERVAL", "INTO", "IS", "JOIN", "KEY", "LEFT", "LIKE", "LIMIT", "NATURAL", "NOT", "NULL", "OFFSET", "ON",
        "OR", "ORDER", "OUTER", "OVER", "PARTITION", "PRIMARY", "PROCEDURE", "REGEXP", "REPLACE", "RIGHT", "ROLLUP",
        "SELECT", "SET", "SHOW", "STRAIGHT_JOIN", "TABLE", "TABLES", "THEN", "TRUE", "TRUNCATE", "UNION", "UNIQUE",
        "UPDATE", "USE", "USING", "VALUES", "WHEN", "WHERE", "WINDOW", "WITH", "XOR", "COLUMNS", "FIELDS", "STATUS",
        "VARIABLES", "PROCESSLIST", "GRANTS", "WARNINGS", "ERRORS", "BEGIN", "COMMIT", "ROLLBACK", "START",
        "TRANSACTION", "KILL", "QUERY", "DIV", "MOD", "RECURSIVE", "LATERAL", "COLLATE", "BINARY", "UNSIGNED",
    ]

    // MARK: Formatting

    private enum Token {
        case word(String), quoted(String), comment(String), symbol(String)

        var text: String {
            switch self {
            case .word(let s), .quoted(let s), .comment(let s), .symbol(let s): s
            }
        }
    }

    /// Lays out each statement with one clause per line and keywords in upper case.
    /// Quoted text and comments are left exactly as written.
    static func format(_ sql: String) -> String {
        let parts = statements(in: sql).map { formatStatement($0.text) }
        return parts.isEmpty ? sql : parts.joined(separator: ";\n\n") + ";"
    }

    private static func tokens(_ sql: String) -> [Token] {
        let chars = Array(sql.utf16)
        var tokens: [Token] = []
        var i = 0
        func text(_ from: Int, _ to: Int) -> String { String(utf16CodeUnits: Array(chars[from..<to]), count: to - from) }

        while i < chars.count {
            let c = chars[i]
            if isSpace(c) {
                i += 1
            } else if c == quote || c == doubleQuote || c == backtick {
                let end = skipQuoted(chars, from: i)
                tokens.append(.quoted(text(i, end)))
                i = end
            } else if startsComment(chars, i) {
                let end = skipComment(chars, from: i)
                tokens.append(.comment(text(i, end)))
                i = end
            } else if isWordChar(c) {
                var j = i
                while j < chars.count, isWordChar(chars[j]) { j += 1 }
                tokens.append(.word(text(i, j)))
                i = j
            } else {
                // Keep multi-character operators (->>, <=, :=, …) together.
                let ops = ["->>", "<=>", "->", "<=", ">=", "<>", "!=", ":=", "||", "&&", "<<", ">>"]
                let rest = text(i, min(i + 3, chars.count))
                let op = ops.first { rest.hasPrefix($0) } ?? text(i, i + 1)
                tokens.append(.symbol(op))
                i += op.utf16.count
            }
        }
        return tokens
    }

    private static func isWordChar(_ c: UInt16) -> Bool {
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 || c == 64 || c > 127
    }

    private static let clauseStarts: Set<String> = [
        "SELECT", "FROM", "WHERE", "HAVING", "LIMIT", "UNION", "SET", "VALUES", "INSERT", "UPDATE", "DELETE",
        "REPLACE", "WINDOW", "ON",
    ]
    private static let joinWords: Set<String> = ["LEFT", "RIGHT", "INNER", "CROSS", "NATURAL", "FULL", "OUTER", "JOIN", "STRAIGHT_JOIN"]
    private static let listClauses: Set<String> = ["SELECT", "SET", "GROUP", "ORDER"]

    private static func formatStatement(_ sql: String) -> String {
        let tokens = tokens(sql)
        let indentUnit = "    "
        var out = ""
        var base = 0 // indent level for the current (sub)query
        var clause = ""
        var parens: [Bool] = [] // true when the bracket opened a subquery
        var previous: Token?

        func newline(_ level: Int) {
            while out.last == " " { out.removeLast() }
            if !out.isEmpty { out += "\n" + String(repeating: indentUnit, count: level) }
        }
        func space() {
            if let last = out.last, last != " ", last != "\n", last != "(" { out += " " }
        }
        func upper(_ token: Token?) -> String? {
            if case .word(let w)? = token { return w.uppercased() }
            return nil
        }

        for (index, token) in tokens.enumerated() {
            let next = tokens.indices.contains(index + 1) ? tokens[index + 1] : nil
            let previousWasDot = previous?.text == "." || previous?.text == "@"

            switch token {
            case .comment(let text):
                space()
                out += text
                if !text.hasPrefix("/*") { newline(base + (clause.isEmpty ? 0 : 1)) }

            case .quoted(let text):
                if !previousWasDot { space() }
                out += text

            case .word(let word):
                let keyword = word.uppercased()
                let isKeyword = keywords.contains(keyword) && !previousWasDot && previous?.text != "`"
                if isKeyword {
                    let startsClause = clauseStarts.contains(keyword)
                        || ((keyword == "GROUP" || keyword == "ORDER") && upper(next) == "BY")
                        || (joinWords.contains(keyword) && !joinWords.contains(upper(previous) ?? ""))
                    if startsClause && keyword == "ON" {
                        newline(base + 1)
                    } else if startsClause && !(keyword == "SELECT" && upper(previous) == "UNION") && !(keyword == "SELECT" && upper(previous) == "ALL") {
                        newline(base)
                    } else if (keyword == "AND" || keyword == "OR") && ["WHERE", "HAVING", "ON"].contains(clause) && upper(previous) != "BETWEEN" {
                        newline(base + 1)
                    } else {
                        space()
                    }
                    if startsClause { clause = joinWords.contains(keyword) ? "JOIN" : keyword }
                    out += keyword
                } else {
                    if !previousWasDot { space() }
                    out += word
                }

            case .symbol(let symbol):
                switch symbol {
                case "(":
                    let isSubquery = upper(next) == "SELECT"
                    if case .word(let w)? = previous, !keywords.contains(w.uppercased()) {
                        // function call: no space before the bracket
                    } else {
                        space()
                    }
                    out += "("
                    parens.append(isSubquery)
                    if isSubquery {
                        base += 1
                        newline(base)
                    }
                case ")":
                    if parens.popLast() == true {
                        base = max(base - 1, 0)
                        newline(base)
                    }
                    while out.last == " " { out.removeLast() }
                    out += ")"
                case ",":
                    out += ","
                    if listClauses.contains(clause) && parens.last != false {
                        newline(base + 1)
                    }
                case ".":
                    while out.last == " " { out.removeLast() }
                    out += "."
                case "@":
                    if previous?.text != "@" { space() }
                    out += "@"
                default:
                    if !previousWasDot { space() }
                    out += symbol
                }
            }
            previous = token
        }
        return out.trimmed
    }
}
