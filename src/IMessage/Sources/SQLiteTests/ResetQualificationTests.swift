import Foundation
import SQLite
import Testing

@Test func independentEarlyReturningResetReportsCommitBusy() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("franz-reset-qualification-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("data.db").path
    let writer = try Database(connecting: path, flags: [.readWrite, .createIfNecessary])
    try writer.execute(sqlWithoutEscaping: "CREATE TABLE test (value INTEGER)")
    try writer.execute(sqlWithoutEscaping: "INSERT INTO test VALUES(1)")
    let reader = try Database(connecting: path, flags: .readWrite)
    try reader.execute(sqlWithoutEscaping: "BEGIN")
    try reader.execute(sqlWithoutEscaping: "SELECT * FROM test")
    let statement = try Statement.prepare(escapedSQL: "INSERT INTO test VALUES(2) RETURNING value", for: writer)
    do {
        try statement.stepUntilStopped { _ in false }
        Issue.record("reset must report commit failure")
    } catch let error as SQLiteError {
        #expect(error.code == 5)
    }
    try reader.execute(sqlWithoutEscaping: "ROLLBACK")
    #expect(try statement.mapRowsUntilDone { try $0[0].expect(Int.self) } == [2])
}
