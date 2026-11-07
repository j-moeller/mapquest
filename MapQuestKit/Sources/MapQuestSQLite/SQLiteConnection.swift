import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// Errors reported by SQLite.
public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public var code: Int32
    public var message: String
    public var sql: String?

    public var description: String {
        if let sql { return "SQLite error \(code): \(message) (\(sql))" }
        return "SQLite error \(code): \(message)"
    }
}

/// `SQLITE_TRANSIENT` is a C macro that Swift cannot import.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A minimal SQLite connection wrapper. Not thread-safe by itself: the owner
/// serialises all access (`SQLiteDataStore` uses a serial queue), hence
/// `@unchecked Sendable`.
final class SQLiteConnection: @unchecked Sendable {
    private(set) var handle: OpaquePointer?
    private var statementCache: [String: SQLiteStatement] = [:]

    /// Opens (and creates) a database. Use `":memory:"` for a private in-memory database.
    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            sqlite3_close_v2(db)
            throw SQLiteError(code: rc, message: message, sql: nil)
        }
        handle = db
        sqlite3_busy_timeout(db, 5_000)
    }

    deinit {
        statementCache.removeAll()
        sqlite3_close_v2(handle)
    }

    var lastErrorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed"
    }

    func check(_ rc: Int32, sql: String? = nil) throws {
        guard rc == SQLITE_OK || rc == SQLITE_ROW || rc == SQLITE_DONE else {
            throw SQLiteError(code: rc, message: lastErrorMessage, sql: sql)
        }
    }

    /// Executes one or more statements without parameters.
    func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        if rc != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errorPointer)
            throw SQLiteError(code: rc, message: message, sql: sql)
        }
    }

    /// Returns a prepared, reset statement. Statements are cached per SQL string.
    func prepare(_ sql: String) throws -> SQLiteStatement {
        if let cached = statementCache[sql] {
            cached.reset()
            return cached
        }
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, sql, -1, &statement, nil), sql: sql)
        guard let statement else { throw SQLiteError(code: SQLITE_MISUSE, message: "empty statement", sql: sql) }
        let wrapped = SQLiteStatement(statement: statement, connection: self, sql: sql)
        statementCache[sql] = wrapped
        return wrapped
    }

    /// Runs `body` in a transaction; rolls back if it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let result = try body()
            try execute("COMMIT TRANSACTION")
            return result
        } catch {
            try? execute("ROLLBACK TRANSACTION")
            throw error
        }
    }

    var userVersion: Int {
        get throws {
            let statement = try prepare("PRAGMA user_version")
            defer { statement.reset() } // an unfinished read would block VACUUM and checkpoints
            guard try statement.step() else { return 0 }
            return Int(statement.int64(at: 0))
        }
    }

    func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version)")
    }
}

/// A prepared statement. Parameter and column indices are 1-based for binding
/// (SQLite convention) and 0-based for reading columns.
final class SQLiteStatement {
    private let statement: OpaquePointer
    private unowned let connection: SQLiteConnection
    let sql: String

    init(statement: OpaquePointer, connection: SQLiteConnection, sql: String) {
        self.statement = statement
        self.connection = connection
        self.sql = sql
    }

    deinit {
        sqlite3_finalize(statement)
    }

    func reset() {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    // MARK: Binding

    func bind(_ value: Int64, at index: Int32) throws {
        try connection.check(sqlite3_bind_int64(statement, index, value), sql: sql)
    }

    func bind(_ value: Int, at index: Int32) throws {
        try bind(Int64(value), at: index)
    }

    func bind(_ value: Double, at index: Int32) throws {
        try connection.check(sqlite3_bind_double(statement, index, value), sql: sql)
    }

    func bind(_ value: String, at index: Int32) throws {
        try connection.check(sqlite3_bind_text(statement, index, value, -1, sqliteTransient), sql: sql)
    }

    func bind(_ value: Data, at index: Int32) throws {
        let rc: Int32 = value.withUnsafeBytes { buffer in
            if let base = buffer.baseAddress, buffer.count > 0 {
                return sqlite3_bind_blob(statement, index, base, Int32(buffer.count), sqliteTransient)
            }
            return sqlite3_bind_zeroblob(statement, index, 0)
        }
        try connection.check(rc, sql: sql)
    }

    func bindNull(at index: Int32) throws {
        try connection.check(sqlite3_bind_null(statement, index), sql: sql)
    }

    /// Binds values in order starting at parameter 1.
    func bind(_ values: [SQLiteValue]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .integer(let v): try bind(v, at: index)
            case .real(let v): try bind(v, at: index)
            case .text(let v): try bind(v, at: index)
            case .blob(let v): try bind(v, at: index)
            case .null: try bindNull(at: index)
            }
        }
    }

    // MARK: Stepping

    /// Advances the statement. Returns `true` if a row is available.
    @discardableResult
    func step() throws -> Bool {
        let rc = sqlite3_step(statement)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError(code: rc, message: connection.lastErrorMessage, sql: sql)
        }
    }

    /// Binds `values`, runs the statement to completion and resets it.
    func run(_ values: [SQLiteValue] = []) throws {
        reset()
        try bind(values)
        while try step() {}
        reset()
    }

    // MARK: Columns

    func int64(at column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func int(at column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
    func double(at column: Int32) -> Double { sqlite3_column_double(statement, column) }
    func isNull(at column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }

    func string(at column: Int32) -> String {
        guard let text = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: text)
    }

    func data(at column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
}

/// A value that can be bound to a statement parameter.
enum SQLiteValue {
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
    case null
}
