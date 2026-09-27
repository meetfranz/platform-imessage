import Foundation
import SQLite
import SQLite3
import Testing

private let generousLimits = OperationLimits(instructionAllowance: 1_000_000_000, timeoutNanoseconds: 60_000_000_000)
private let longQuery = """
WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 1000000)
SELECT count(*) FROM n
"""

@Test func failedStepRethrowsPrimaryErrorAndStatementStaysUsable() throws {
    let database = try Database(connecting: ":memory:", flags: .readWrite)
    let statement = try Statement.prepare(escapedSQL: "SELECT abs(?)", for: database)

    // abs(INT64_MIN) fails while stepping; resetting used to trap on the
    // repeated error
    try statement.bind(Int64.min)
    do {
        try statement.stepUntilDone { _ in }
        Issue.record("expected an integer overflow error")
    } catch let error as SQLiteError {
        #expect(error.code == Int(SQLITE_ERROR))
    }

    try statement.bind(Int64(-2))
    #expect(try statement.mapRowsUntilDone { try $0[0].expect(Int64.self) } == [2])
}

@Test func earlyStopResetsStatement() throws {
    let database = try Database(connecting: ":memory:", flags: .readWrite)
    let statement = try Statement.prepare(escapedSQL: "SELECT 1 UNION ALL SELECT 2", for: database)

    var seen = [Int]()
    try statement.stepUntilStopped { row in
        seen.append(try row[0].expect(Int.self))
        return false
    }
    #expect(seen == [1])
    #expect(try statement.mapRowsUntilDone { try $0[0].expect(Int.self) } == [1, 2])
}

@Test func exhaustedInstructionAllowanceInterruptsWithoutTrapping() throws {
    let database = try Database(connecting: ":memory:", flags: .readWrite)
    let statement = try Statement.prepare(escapedSQL: longQuery, for: database)
    let tinyLimits = OperationLimits(instructionAllowance: 10_000, timeoutNanoseconds: 60_000_000_000, instructionsPerCheck: 100)

    #expect(throws: OperationLimitError.instructionAllowanceExhausted) {
        try database.withOperationLimits(tinyLimits) { _ in
            try statement.stepUntilDone { _ in }
        }
    }
    // a statement interrupted inside the scope is finalized without trapping
    #expect(throws: OperationLimitError.instructionAllowanceExhausted) {
        try database.withOperationLimits(tinyLimits) { _ in
            let local = try Statement.prepare(escapedSQL: longQuery, for: database)
            try local.stepUntilDone { _ in }
        }
    }

    // the handler is removed and the statement was reset: it now completes
    #expect(try statement.mapRowsUntilDone { try $0[0].expect(Int.self) } == [1_000_000])
}

@Test func swallowedInterruptionStillFailsTheScope() throws {
    let database = try Database(connecting: ":memory:", flags: .readWrite)
    let tinyLimits = OperationLimits(instructionAllowance: 10_000, timeoutNanoseconds: 60_000_000_000, instructionsPerCheck: 100)

    #expect(throws: OperationLimitError.instructionAllowanceExhausted) {
        try database.withOperationLimits(tinyLimits) { _ in
            try? database.execute(sqlWithoutEscaping: longQuery)
        }
    }
}

@Test func expiredDeadlineFailsBeforeRunningBody() throws {
    let database = try Database(connecting: ":memory:", flags: .readWrite)
    var ranBody = false

    #expect(throws: OperationLimitError.deadlineExceeded) {
        try database.withOperationLimits(OperationLimits(instructionAllowance: 1_000, timeoutNanoseconds: 0)) { _ in
            ranBody = true
        }
    }
    #expect(!ranBody)
}

@Test func deadlineExceededDuringNonSQLBodyCannotReturnSuccess() throws {
    let database = try Database(connecting: ":memory:", flags: .readWrite)
    let limits = OperationLimits(instructionAllowance: 10_000, timeoutNanoseconds: 1_000_000)

    #expect(throws: OperationLimitError.deadlineExceeded) {
        try database.withOperationLimits(limits) { _ in
            Thread.sleep(forTimeInterval: 0.03)
            return 1
        }
    }
}

@Test func nestedScopesAreRejectedAndOuterScopeIsRestored() throws {
    let database = try Database(connecting: ":memory:", flags: .readWrite)

    try database.withOperationLimits(generousLimits) { _ in
        #expect(throws: OperationLimitError.nestedScope) {
            try database.withOperationLimits(generousLimits) { _ in }
        }
        try database.execute(sqlWithoutEscaping: "SELECT 1")
    }

    // the outer scope ended, so a new one can begin
    try database.withOperationLimits(generousLimits) { _ in
        try database.execute(sqlWithoutEscaping: longQuery)
    }
}

@Test func readTransactionRollsBackOnErrorAndRejectsNesting() throws {
    struct Failure: Error {}
    let database = try Database(connecting: ":memory:", flags: .readWrite)
    try database.execute(sqlWithoutEscaping: "CREATE TABLE t (x)")

    #expect(throws: Failure.self) {
        try database.withReadTransaction {
            try database.execute(sqlWithoutEscaping: "INSERT INTO t VALUES (1)")
            throw Failure()
        }
    }
    #expect(throws: DatabaseTransactionError.transactionAlreadyActive) {
        try database.withReadTransaction {
            try database.withReadTransaction {}
        }
    }

    let count = try database.withReadTransaction {
        try Statement.prepare(escapedSQL: "SELECT count(*) FROM t", for: database)
            .mapRowsUntilDone { try $0[0].expect(Int.self) }
    }
    #expect(count == [0])
}
