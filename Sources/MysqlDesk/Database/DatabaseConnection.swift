import Foundation
import MySQLNIO
import NIOSSL

/// A readable error from the server or the network.
struct QueryError: LocalizedError {
    let message: String
    var code: UInt16?

    var errorDescription: String? { code.map { "Error \($0): \(message)" } ?? message }
}

/// What the server sent back for one statement.
enum QueryResponse {
    case rows(columns: [ResultColumn], rows: [[String?]], total: Int, warnings: Int)
    case ok(affected: UInt64, insertID: UInt64, warnings: Int, info: String)
}

/// One open MySQL/MariaDB session. Each query tab gets its own, so a long query in one tab
/// never blocks another, and `USE` in one tab doesn't change the schema in the others.
actor DatabaseConnection {
    private let connection: MySQLConnection
    nonisolated let serverVersion: String
    /// The server's thread ID, used to cancel a running query with `KILL QUERY`.
    nonisolated let threadID: Int

    private init(connection: MySQLConnection, serverVersion: String, threadID: Int) {
        self.connection = connection
        self.serverVersion = serverVersion
        self.threadID = threadID
    }

    nonisolated var isClosed: Bool { connection.isClosed }

    static func open(_ config: ConnectionConfig, password: String?, database: String? = nil) async throws -> DatabaseConnection {
        let address: SocketAddress
        do {
            // Name lookups block, so keep them off the main thread.
            address = try await Task.detached { try SocketAddress.makeAddressResolvingHost(config.host, port: config.port) }.value
        } catch {
            throw QueryError(message: "Couldn't find the host “\(config.host)”.")
        }

        var tls: TLSConfiguration?
        if config.tls == .preferred {
            // Internal servers mostly use self-signed certificates, so encrypt without verifying.
            var configuration = TLSConfiguration.makeClientConfiguration()
            configuration.certificateVerification = .none
            tls = configuration
        }
        var logger = Logger(label: "uk.co.dave-steer.mysqldesk")
        logger.logLevel = .critical

        let connection: MySQLConnection
        do {
            connection = try await MySQLConnection.connect(
                to: address,
                username: config.username,
                database: database ?? config.defaultSchema.trimmed,
                password: password?.isEmpty == false ? password : nil,
                tlsConfiguration: tls,
                logger: logger,
                on: MultiThreadedEventLoopGroup.singleton.any()
            ).get()
        } catch {
            throw friendly(error)
        }

        let info: [QueryResponse]
        do {
            info = try await run(TextQueryCommand(sql: "SELECT VERSION(), CONNECTION_ID()", maxRows: 1), on: connection)
        } catch {
            try? await connection.close().get()
            throw error
        }
        guard case .rows(_, let rows, _, _)? = info.first, let row = rows.first else {
            try? await connection.close().get()
            throw QueryError(message: "The server didn't report its version.")
        }
        return DatabaseConnection(connection: connection, serverVersion: row[0] ?? "", threadID: Int(row[1] ?? "") ?? 0)
    }

    /// Runs one statement (or a CALL that returns several result sets).
    func execute(_ sql: String, maxRows: Int) async throws -> [QueryResponse] {
        try await Self.run(TextQueryCommand(sql: sql, maxRows: maxRows), on: connection)
    }

    /// First column of every row, for SHOW DATABASES and similar lists.
    func strings(_ sql: String) async throws -> [String] {
        guard case .rows(_, let rows, _, _)? = try await execute(sql, maxRows: .max).first else { return [] }
        return rows.compactMap { $0.first ?? nil }
    }

    func close() async {
        try? await connection.close().get()
    }

    private static func run(_ command: TextQueryCommand, on connection: MySQLConnection) async throws -> [QueryResponse] {
        do {
            try await connection.send(command, logger: connection.logger).get()
        } catch {
            throw friendly(error)
        }
        return command.responses
    }

    private static func friendly(_ error: Error) -> Error {
        switch error {
        case let error as QueryError:
            return error
        case MySQLError.server(let packet):
            return QueryError(message: packet.errorMessage, code: packet.errorCode.rawValue)
        case MySQLError.unsupportedAuthPlugin(let name) where name == "sha256_password":
            // MySQL 8 switches unknown users to sha256_password when TLS is off.
            return QueryError(message: "Access denied: check the username and password.")
        case let error as MySQLError:
            return QueryError(message: error.message)
        case MySQLError.closed, ChannelError.ioOnClosedChannel, ChannelError.alreadyClosed:
            return QueryError(message: "The connection was closed.")
        default:
            let text = String(describing: error)
            if text.contains("connectTimeout") { return QueryError(message: "Timed out connecting to the server.") }
            if text.localizedCaseInsensitiveContains("refused") { return QueryError(message: "Connection refused: is MySQL running on that host and port?") }
            return QueryError(message: text)
        }
    }
}

// MARK: - Text protocol query

/// COM_QUERY using the text protocol. Unlike MySQLNIO's built-in `simpleQuery`, it keeps the
/// column names when no rows come back, reports affected rows, follows CALL's extra result sets,
/// and stops keeping rows after `maxRows` (while still counting them).
private final class TextQueryCommand: MySQLCommand, @unchecked Sendable {
    private enum State {
        case ready
        case columns(Int)
        case columnsEOF
        case rows
    }

    private static let moreResultsExist: UInt16 = 0x0008

    let sql: String
    let maxRows: Int
    private(set) var responses: [QueryResponse] = []

    private var state = State.ready
    private var definitions: [MySQLProtocol.ColumnDefinition41] = []
    private var rows: [[String?]] = []
    private var total = 0

    init(sql: String, maxRows: Int) {
        self.sql = sql
        self.maxRows = maxRows
    }

    func activate(capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        var payload = ByteBufferAllocator().buffer(capacity: sql.utf8.count + 1)
        payload.writeInteger(UInt8(0x03)) // COM_QUERY
        payload.writeString(sql)
        return MySQLCommandState(response: [MySQLPacket(payload: payload)])
    }

    func handle(packet: inout MySQLPacket, capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        if packet.isError {
            let error = try MySQLProtocol.ERR_Packet.decode(from: &packet, capabilities: capabilities)
            var message = error.errorMessage
            if error.errorCode.rawValue == 1312 {
                message += " (MysqlDesk can't yet run procedures that return rows.)"
            }
            throw QueryError(message: message, code: error.errorCode.rawValue)
        }

        switch state {
        case .ready:
            if packet.isOK {
                // Statements without a result set (INSERT, UPDATE, SET, USE…).
                var payload = packet.payload
                payload.moveReaderIndex(forwardBy: 1)
                let affected = payload.readLengthEncoded() ?? 0
                let insertID = payload.readLengthEncoded() ?? 0
                let status = payload.readInteger(endianness: .little, as: UInt16.self) ?? 0
                let warnings = payload.readInteger(endianness: .little, as: UInt16.self) ?? 0
                let info = payload.readString(length: payload.readableBytes) ?? ""
                responses.append(.ok(affected: affected, insertID: insertID, warnings: Int(warnings), info: info))
                return MySQLCommandState(done: status & Self.moreResultsExist == 0)
            }
            guard let count = packet.payload.readLengthEncoded(), count > 0 else {
                throw QueryError(message: "Unsupported response from the server (LOAD DATA LOCAL isn't supported).")
            }
            definitions = []
            state = .columns(Int(count))
            return MySQLCommandState()

        case .columns(let count):
            definitions.append(try MySQLProtocol.ColumnDefinition41.decode(from: &packet, capabilities: capabilities))
            if definitions.count == count {
                // Servers without CLIENT_DEPRECATE_EOF send an EOF packet after the column definitions.
                state = capabilities.contains(.CLIENT_DEPRECATE_EOF) ? .rows : .columnsEOF
            }
            return MySQLCommandState()

        case .columnsEOF:
            state = .rows
            return MySQLCommandState()

        case .rows:
            if packet.isEOF && packet.payload.readableBytes < 0xFF_FFFF {
                let (status, warnings) = terminator(packet, capabilities: capabilities)
                let more = status & Self.moreResultsExist != 0
                responses.append(.rows(columns: definitions.map(Self.column), rows: rows, total: total, warnings: warnings))
                rows = []
                total = 0
                state = .ready
                return MySQLCommandState(done: !more)
            }
            let row = try MySQLProtocol.TextResultSetRow.decode(from: &packet, columnCount: definitions.count)
            total += 1
            if rows.count < maxRows {
                rows.append(zip(row.values, definitions).map(Self.cell))
            }
            return MySQLCommandState()
        }
    }

    /// Status flags and warning count from the packet that ends a result set
    /// (an OK packet when EOF is deprecated, else a legacy EOF, which has them the other way round).
    private func terminator(_ packet: MySQLPacket, capabilities: MySQLProtocol.CapabilityFlags) -> (status: UInt16, warnings: Int) {
        var payload = packet.payload
        payload.moveReaderIndex(forwardBy: 1)
        if capabilities.contains(.CLIENT_DEPRECATE_EOF) {
            _ = payload.readLengthEncoded()
            _ = payload.readLengthEncoded()
            let status = payload.readInteger(endianness: .little, as: UInt16.self) ?? 0
            let warnings = payload.readInteger(endianness: .little, as: UInt16.self) ?? 0
            return (status, Int(warnings))
        }
        let warnings = payload.readInteger(endianness: .little, as: UInt16.self) ?? 0
        let status = payload.readInteger(endianness: .little, as: UInt16.self) ?? 0
        return (status, Int(warnings))
    }

    private static func column(_ definition: MySQLProtocol.ColumnDefinition41) -> ResultColumn {
        ResultColumn(name: definition.name,
                     table: definition.orgTable.isEmpty ? definition.table : definition.orgTable,
                     kind: kind(of: definition),
                     schema: definition.schema,
                     orgName: definition.orgName,
                     tableAlias: definition.table)
    }

    private static func kind(of definition: MySQLProtocol.ColumnDefinition41) -> ColumnKind {
        switch definition.columnType {
        case .decimal, .newdecimal, .tiny, .short, .long, .longlong, .int24, .float, .double, .year, .bit:
            return .number
        case .timestamp, .timestamp2, .date, .newdate, .time, .time2, .datetime, .datetime2:
            return .dateTime
        case .json:
            return .json
        case .tinyBlob, .mediumBlob, .longBlob, .blob, .varchar, .varString, .string, .geometry:
            return definition.characterSet == .binary ? .binary : .text
        default:
            return .text
        }
    }

    /// Text-protocol value → display string. Binary data that isn't readable text becomes a 0x… hex literal.
    private static func cell(_ value: ByteBuffer?, _ definition: MySQLProtocol.ColumnDefinition41) -> String? {
        guard let value else { return nil }
        let bytes = value.readableBytesView
        if definition.columnType == .bit {
            return String(bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        }
        if kind(of: definition) == .binary {
            if let text = String(bytes: bytes, encoding: .utf8), !text.contains(where: { $0.asciiValue.map { $0 < 9 } ?? false }) {
                return text
            }
            return "0x" + bytes.map { String(format: "%02X", $0) }.joined()
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

private extension ByteBuffer {
    /// MySQL length-encoded integer.
    mutating func readLengthEncoded() -> UInt64? {
        guard let first = readInteger(as: UInt8.self) else { return nil }
        switch first {
        case 0xFC: return readInteger(endianness: .little, as: UInt16.self).map(UInt64.init)
        case 0xFD:
            guard let bytes = readBytes(length: 3) else { return nil }
            return UInt64(bytes[0]) | UInt64(bytes[1]) << 8 | UInt64(bytes[2]) << 16
        case 0xFE: return readInteger(endianness: .little, as: UInt64.self)
        default: return UInt64(first)
        }
    }
}
