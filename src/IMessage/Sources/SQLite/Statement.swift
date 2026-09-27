import Logging
import Darwin
import SQLite3

public final class Statement {
    var handle: OpaquePointer
    var database: Database

    public static func prepare(escapedSQL sql: String, for database: Database, flags: PrepareFlags = []) throws -> Statement {
        precondition(!sql.isEmpty, "can't prepare an empty SQL statement")

        var statement: OpaquePointer?

        try sql.withCString { ptr in
            _ = try SQLiteError.check(sqlite3_prepare_v3(database.connection, ptr, Int32(strlen(ptr)), flags.rawValue, &statement, nil))
        }

        guard let statement else {
            preconditionFailure("sqlite3_prepare_v3 didn't give us a statement")
        }

        return Statement(handle: statement, database: database)
    }

    init(handle: OpaquePointer, database: Database) {
        self.handle = handle
        self.database = database
    }

    deinit {
        // sqlite3_finalize always releases the statement; its result only
        // repeats the most recent evaluation error (e.g. SQLITE_INTERRUPT),
        // which was already reported by the step that produced it.
        sqlite3_finalize(handle)
    }
}

public extension Statement {
    struct PrepareFlags: OptionSet {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        public static let persistent = Self(rawValue: UInt32(SQLITE_PREPARE_PERSISTENT))
    }
}

// MARK: - Accessing Counts

public extension Statement {
    var parameterCount: Int {
        Int(sqlite3_bind_parameter_count(handle))
    }

    var columnCount: Int {
        Int(sqlite3_column_count(handle))
    }

    var columnNames: [String] {
        (0 ..< columnCount).map { String(cString: sqlite3_column_name(handle, Int32($0))) }
    }
}

// MARK: - Resetting, Clearing, and Binding

public extension Statement {
    @discardableResult
    func reset() throws -> Self {
        try SQLiteError.check(sqlite3_reset(handle))
        return self
    }

    func clearBindings() throws {
        try SQLiteError.check(sqlite3_clear_bindings(handle))
    }

    func bind<each T: SQLiteBindable>(_ values: repeat each T) throws {
        var currentParameterIndex: Int32 = 1
        for binding in repeat each values {
            precondition(currentParameterIndex <= parameterCount, "tried to bind \(currentParameterIndex) value(s) (maximum is \(parameterCount))")
            defer { currentParameterIndex += 1 }
            try binding.unsafeBind(toPreparedStatement: handle, at: currentParameterIndex)
        }
    }

    func bind(_ values: [any SQLiteBindable]) throws {
        for (index, value) in values.enumerated() {
            precondition(index < parameterCount, "tried to bind \(index + 1) value(s) (maximum is \(parameterCount))")
            try value.unsafeBind(toPreparedStatement: handle, at: Int32(index + 1))
        }
    }
}

// MARK: - Stepping

public extension Statement {
    func stepUntilDone(handlingRows rowHandler: (_ selected: borrowing Row) throws -> Void) throws {
        try resettingAfterEvaluation {
            while try SQLiteError.check(sqlite3_step(handle), permitting: [SQLITE_ROW, SQLITE_DONE]) == SQLITE_ROW {
                try rowHandler(Row(accessingColumnsOf: self))
            }
        }
    }

    func stepUntilStopped(handlingRows rowHandler: (_ selected: borrowing Row) throws -> Bool) throws {
        try resettingAfterEvaluation {
            while try SQLiteError.check(sqlite3_step(handle), permitting: [SQLITE_ROW, SQLITE_DONE]) == SQLITE_ROW {
                guard try rowHandler(Row(accessingColumnsOf: self)) else {
                    return
                }
            }
        }
    }

    func mapRowsUntilDone<T>(_ transform: (_ row: borrowing Row) throws -> T) throws -> [T] {
        var results = [T]()
        try stepUntilDone(handlingRows: {
            try results.append(transform($0))
        })
        return results
    }

    func compactMapRowsUntilDone<T>(_ transform: (_ row: borrowing Row) throws -> T?) throws -> [T] {
        var results = [T]()
        try stepUntilDone(handlingRows: {
            if let result = try transform($0) {
                results.append(result)
            }
        })
        return results
    }
}

private extension Statement {
    /// Always resets the statement after `body`, so it can be evaluated again.
    ///
    /// When `body` fails, `sqlite3_reset` repeats the failing step's result
    /// (e.g. `SQLITE_INTERRUPT`), so the primary error is rethrown instead.
    /// When `body` succeeds or stops early, a reset failure is new information
    /// and is thrown.
    func resettingAfterEvaluation(_ body: () throws -> Void) throws {
        do {
            try body()
        } catch {
            sqlite3_reset(handle)
            throw error
        }
        try SQLiteError.check(sqlite3_reset(handle))
    }
}
