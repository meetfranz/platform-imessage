import Darwin
import SQLite3

/// A finite work allowance for the SQLite work done inside
/// ``Database/withOperationLimits(_:_:)``.
///
/// These bound VM work and elapsed time; they are not a hard memory limit and
/// can't preempt a single blocking filesystem read.
public struct OperationLimits: Equatable, Sendable {
    /// Approximate number of SQLite VM instructions the scope may execute.
    public let instructionAllowance: Int
    /// Monotonic elapsed-time budget, measured from the start of the scope.
    public let timeoutNanoseconds: UInt64
    /// How often (in VM instructions) the progress handler checks the limits.
    public let instructionsPerCheck: Int32

    public init(instructionAllowance: Int, timeoutNanoseconds: UInt64, instructionsPerCheck: Int32 = 1_000) {
        precondition(instructionAllowance > 0, "instruction allowance must be positive")
        precondition(instructionsPerCheck > 0, "instructions per check must be positive")
        self.instructionAllowance = instructionAllowance
        self.timeoutNanoseconds = timeoutNanoseconds
        self.instructionsPerCheck = instructionsPerCheck
    }
}

public enum OperationLimitError: Error, Equatable, Sendable {
    case instructionAllowanceExhausted
    case deadlineExceeded
    /// Another limit scope is already active on this connection.
    case nestedScope
}

public final class OperationLimitScope {
    private let instructionAllowance: Int
    private let instructionsPerCheck: Int
    private let deadline: UInt64
    private var instructionsUsed = 0
    private(set) var exceededLimit: OperationLimitError?

    init(_ limits: OperationLimits) {
        instructionAllowance = limits.instructionAllowance
        instructionsPerCheck = Int(limits.instructionsPerCheck)
        let (deadline, overflowed) = monotonicNanoseconds().addingReportingOverflow(limits.timeoutNanoseconds)
        self.deadline = overflowed ? .max : deadline
    }

    /// Throws once the deadline has passed. Call this around work the progress
    /// handler may not observe: non-SQL work, and statement preparation on
    /// SQLite versions that don't invoke the handler during prepare.
    public func checkDeadline() throws {
        if let exceededLimit {
            throw exceededLimit
        }
        if monotonicNanoseconds() >= deadline {
            exceededLimit = .deadlineExceeded
            throw OperationLimitError.deadlineExceeded
        }
    }

    // called from the progress handler; must not touch the connection
    fileprivate func shouldInterrupt() -> Bool {
        guard exceededLimit == nil else { return true }

        instructionsUsed += instructionsPerCheck
        if instructionsUsed > instructionAllowance {
            exceededLimit = .instructionAllowanceExhausted
            return true
        }
        if monotonicNanoseconds() >= deadline {
            exceededLimit = .deadlineExceeded
            return true
        }
        return false
    }
}

public enum DatabaseTransactionError: Error, Equatable, Sendable {
    /// The connection is already inside a transaction.
    case transactionAlreadyActive
}

public extension Database {
    /// Runs `body` with a progress handler that interrupts SQLite once the
    /// instruction allowance or deadline is exhausted.
    ///
    /// An interruption is reported as the ``OperationLimitError`` that caused
    /// it rather than `SQLITE_INTERRUPT`. The handler is removed on every
    /// exit; statements evaluated outside the scope are unaffected. Scopes
    /// don't nest.
    func withOperationLimits<Result>(_ limits: OperationLimits, _ body: (OperationLimitScope) throws -> Result) throws -> Result {
        guard activeOperationLimitScope == nil else {
            throw OperationLimitError.nestedScope
        }

        let scope = OperationLimitScope(limits)
        activeOperationLimitScope = scope
        sqlite3_progress_handler(connection, limits.instructionsPerCheck, { context in
            guard let context else { return 0 }
            return Unmanaged<OperationLimitScope>.fromOpaque(context).takeUnretainedValue().shouldInterrupt() ? 1 : 0
        }, Unmanaged.passUnretained(scope).toOpaque())
        // `activeOperationLimitScope` keeps `scope` alive while it's installed
        defer {
            sqlite3_progress_handler(connection, 0, nil, nil)
            activeOperationLimitScope = nil
        }

        let result: Result
        do {
            try scope.checkDeadline()
            result = try body(scope)
        } catch {
            if let exceededLimit = scope.exceededLimit {
                throw exceededLimit
            }
            throw error
        }

        // an interruption that `body` swallowed, or a deadline passed during
        // work the handler didn't observe, still invalidates the result
        try scope.checkDeadline()
        return result
    }

    /// Runs `body` inside `BEGIN DEFERRED` … `COMMIT`, so every statement in it
    /// reads from one snapshot. Rolls back when `body` or `COMMIT` fails.
    func withReadTransaction<Result>(_ body: () throws -> Result) throws -> Result {
        guard sqlite3_get_autocommit(connection) != 0 else {
            throw DatabaseTransactionError.transactionAlreadyActive
        }

        try execute(sqlWithoutEscaping: "BEGIN DEFERRED")
        do {
            let result = try body()
            try execute(sqlWithoutEscaping: "COMMIT")
            return result
        } catch {
            rollBackIfInTransaction()
            throw error
        }
    }
}

private extension Database {
    func rollBackIfInTransaction() {
        guard sqlite3_get_autocommit(connection) == 0 else { return }
        // keep the primary error; if this fails, the connection stays in the
        // transaction and the next `withReadTransaction` reports it
        try? execute(sqlWithoutEscaping: "ROLLBACK")
    }
}

private func monotonicNanoseconds() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
}
