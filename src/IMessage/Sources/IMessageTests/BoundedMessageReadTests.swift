import Foundation
import SQLite
import Testing
@testable import IMDatabase

// Synthetic, empty temporary chat.db files only; no live Messages data.

private let chatGUID = "any;-;+15555550100"
private let sameDate: Int64 = 700_000_000_000_000_000

@Test func sparseSameTimeRowsPageInRowIDOrderWithFixedBound() throws {
    let fixture = try BoundedReadFixture()
    defer { fixture.cleanup() }
    try fixture.insertChat(rowID: 1, guid: chatGUID)
    for rowID in [3, 7, 1000, 1_000_000] {
        try fixture.insertMessage(rowID: rowID, date: sameDate)
        try fixture.join(messageRowID: rowID, chatRowID: 1)
    }

    let first = try fixture.imDatabase.boundedMessagePage(afterRowID: 0, limit: 2)
    #expect(first.rows.map(\.rowID) == [3, 7])
    #expect(first.throughRowID == 1_000_000)
    #expect(first.lastScannedRowID == 7)
    #expect(first.nextAfterRowID == 7)
    #expect(first.hasMore)
    #expect(first.rows.allSatisfy { $0.ready?.threadID == chatGUID && $0.ready?.chatRowID == 1 })

    // a row committed after the bound was captured belongs to a later scan
    try fixture.insertMessage(rowID: 2_000_000, date: sameDate)
    try fixture.join(messageRowID: 2_000_000, chatRowID: 1)

    let second = try fixture.imDatabase.boundedMessagePage(afterRowID: first.nextAfterRowID, throughRowID: first.throughRowID, limit: 2)
    #expect(second.rows.map(\.rowID) == [1000, 1_000_000])
    #expect(second.throughRowID == 1_000_000)
    #expect(!second.hasMore)
    #expect(second.nextAfterRowID == 1_000_000)

    let next = try fixture.imDatabase.boundedMessagePage(afterRowID: second.nextAfterRowID, limit: 2)
    #expect(next.rows.map(\.rowID) == [2_000_000])
    #expect(next.rows.first?.ready?.date == Int(sameDate))
}

@Test func emptyRangesProgressOnlyToTheFixedBound() throws {
    let fixture = try BoundedReadFixture()
    defer { fixture.cleanup() }

    let empty = try fixture.imDatabase.boundedMessagePage(afterRowID: 0)
    #expect(empty.rows.isEmpty)
    #expect(empty.throughRowID == 0)
    #expect(empty.lastScannedRowID == nil)
    #expect(empty.nextAfterRowID == 0)
    #expect(!empty.hasMore)

    try fixture.insertChat(rowID: 1, guid: chatGUID)
    try fixture.insertMessage(rowID: 5)
    try fixture.join(messageRowID: 5, chatRowID: 1)

    let gap = try fixture.imDatabase.boundedMessagePage(afterRowID: 10, throughRowID: 20)
    #expect(gap.rows.isEmpty)
    #expect(gap.nextAfterRowID == 20)
    #expect(!gap.hasMore)

    // a captured bound never moves below the requested start
    let beyond = try fixture.imDatabase.boundedMessagePage(afterRowID: 50)
    #expect(beyond.throughRowID == 50)
    #expect(beyond.nextAfterRowID == 50)
    #expect(beyond.rows.isEmpty)
}

@Test func joinsAreClassifiedWithoutGuessing() throws {
    let fixture = try BoundedReadFixture()
    defer { fixture.cleanup() }
    try fixture.insertChat(rowID: 1, guid: chatGUID)
    try fixture.insertChat(rowID: 2, guid: "any;+;chat-2")
    try fixture.insertChat(rowID: 3, guid: nil)
    for rowID in 1 ... 5 {
        try fixture.insertMessage(rowID: rowID)
    }
    try fixture.join(messageRowID: 2, chatRowID: 99)
    try fixture.join(messageRowID: 3, chatRowID: 1)
    try fixture.join(messageRowID: 3, chatRowID: 2)
    try fixture.join(messageRowID: 4, chatRowID: 1)
    try fixture.join(messageRowID: 4, chatRowID: 1)
    try fixture.join(messageRowID: 5, chatRowID: 3)

    let page = try fixture.imDatabase.boundedMessagePage(afterRowID: 0)
    #expect(page.rows.map(\.rowID) == [1, 2, 3, 4, 5])
    #expect(page.rows[0].unresolved == BoundedUnresolvedMessageRow(rowID: 1, guid: "message-1", reason: .noValidChatJoin))
    #expect(page.rows[1].unresolved == BoundedUnresolvedMessageRow(rowID: 2, guid: "message-2", reason: .noValidChatJoin))
    #expect(page.rows[2].unresolved == BoundedUnresolvedMessageRow(rowID: 3, guid: "message-3", reason: .multipleChats))
    #expect(page.rows[3].ready?.chatRowID == 1)
    #expect(page.rows[3].ready?.threadID == chatGUID)
    #expect(page.rows[4].unresolved == BoundedUnresolvedMessageRow(rowID: 5, guid: "message-5", reason: .noValidChatJoin))

    // a late join resolves on refresh
    try fixture.join(messageRowID: 1, chatRowID: 2)
    let refresh = try fixture.imDatabase.boundedMessageRefresh(rowIDs: [1])
    #expect(refresh.rows.first?.ready?.threadID == "any;+;chat-2")
    #expect(refresh.missingRowIDs.isEmpty)
}

@Test func identityAndByteLimitsApplyBeforeDecoding() throws {
    let fixture = try BoundedReadFixture()
    defer { fixture.cleanup() }
    let limits = BoundedMessageReadLimits.self
    try fixture.insertChat(rowID: 1, guid: chatGUID)
    try fixture.insertHandle(rowID: 1, id: "+15555550101")
    try fixture.insertHandle(rowID: 2, id: String(repeating: "h", count: limits.maximumIdentifierBytes + 1))

    try fixture.insertMessage(rowID: 1, guid: "")
    try fixture.insertMessage(rowID: 2, guid: "placeholder-2")
    try fixture.execute("UPDATE message SET guid = ? WHERE ROWID = 2", Data([1]))
    try fixture.insertMessage(rowID: 3, guid: String(repeating: "g", count: limits.maximumIdentifierBytes + 1))
    // oversized and stored with the wrong type: decoding would fail, so an
    // oversizedRow result shows the payload was never decoded
    try fixture.insertMessage(rowID: 4)
    try fixture.execute("UPDATE message SET text = ? WHERE ROWID = 4", Data(count: 2 * limits.maximumRowBytes))
    // 600,000 characters, 1,200,000 UTF-8 bytes
    try fixture.insertMessage(rowID: 5, text: String(repeating: "é", count: 600_000))
    try fixture.insertMessage(rowID: 6, handleID: 2)
    try fixture.insertMessage(rowID: 7, text: String(repeating: "a", count: limits.maximumRowBytes - 1024), handleID: 1)
    try fixture.insertMessage(rowID: 8)
    try fixture.execute("UPDATE message SET date = 'yesterday' WHERE ROWID = 8")
    for rowID in 1 ... 8 {
        try fixture.join(messageRowID: rowID, chatRowID: 1)
    }

    let page = try fixture.imDatabase.boundedMessagePage(afterRowID: 0)
    #expect(page.rows.map(\.rowID) == Array(1 ... 8))
    #expect(!page.hasMore)
    #expect(page.rows[0].unresolved == BoundedUnresolvedMessageRow(rowID: 1, guid: nil, reason: .invalidIdentity))
    #expect(page.rows[1].unresolved == BoundedUnresolvedMessageRow(rowID: 2, guid: nil, reason: .invalidIdentity))
    #expect(page.rows[2].unresolved == BoundedUnresolvedMessageRow(rowID: 3, guid: nil, reason: .oversizedIdentifier))
    #expect(page.rows[3].unresolved == BoundedUnresolvedMessageRow(rowID: 4, guid: "message-4", reason: .oversizedRow))
    #expect(page.rows[4].unresolved == BoundedUnresolvedMessageRow(rowID: 5, guid: "message-5", reason: .oversizedRow))
    #expect(page.rows[5].unresolved == BoundedUnresolvedMessageRow(rowID: 6, guid: "message-6", reason: .oversizedIdentifier))
    #expect(page.rows[6].ready?.text?.utf8.count == limits.maximumRowBytes - 1024)
    #expect(page.rows[6].ready?.participantID == "+15555550101")
    #expect(page.rows[7].unresolved == BoundedUnresolvedMessageRow(rowID: 8, guid: "message-8", reason: .undecodable))

    let refresh = try fixture.imDatabase.boundedMessageRefresh(rowIDs: [4, 7])
    #expect(refresh.rows.map(\.rowID) == [4, 7])
    #expect(refresh.rows[0].unresolved?.reason == .oversizedRow)
    #expect(refresh.rows[1].ready != nil)
}

@Test func rowsThatDoNotFitThePageStartTheNextOne() throws {
    let fixture = try BoundedReadFixture()
    defer { fixture.cleanup() }
    try fixture.insertChat(rowID: 1, guid: chatGUID)
    let text = String(repeating: "a", count: 900_000)
    for rowID in 1 ... 5 {
        try fixture.insertMessage(rowID: rowID, text: text)
        try fixture.join(messageRowID: rowID, chatRowID: 1)
    }

    let first = try fixture.imDatabase.boundedMessagePage(afterRowID: 0)
    #expect(first.rows.map(\.rowID) == [1, 2, 3, 4])
    #expect(first.rows.allSatisfy { $0.ready?.text == text })
    #expect(first.hasMore)
    #expect(first.nextAfterRowID == 4)

    let second = try fixture.imDatabase.boundedMessagePage(afterRowID: first.nextAfterRowID, throughRowID: first.throughRowID)
    #expect(second.rows.map(\.rowID) == [5])
    #expect(!second.hasMore)

    #expect(throws: BoundedMessageReadError.batchTooLarge) {
        try fixture.imDatabase.boundedMessageRefresh(rowIDs: [1, 2, 3, 4, 5])
    }
    #expect(try fixture.imDatabase.boundedMessageRefresh(rowIDs: [4, 3, 2, 1]).rows.map(\.rowID) == [1, 2, 3, 4])
}

@Test func giantUnusedColumnsAreNeverSelected() throws {
    let fixture = try BoundedReadFixture()
    defer { fixture.cleanup() }
    try fixture.insertChat(rowID: 1, guid: chatGUID)
    for rowID in 1 ... 2 {
        try fixture.insertMessage(rowID: rowID, text: "hello \(rowID)")
        try fixture.join(messageRowID: rowID, chatRowID: 1)
    }
    try fixture.execute("UPDATE message SET future_blob = zeroblob(8388608)")

    let page = try fixture.imDatabase.boundedMessagePage(afterRowID: 0)
    #expect(page.rows.map { $0.ready?.text } == ["hello 1", "hello 2"])
    #expect(!page.hasMore)
}

@Test func legacySchemaOptionalColumnsDecodeAsNull() throws {
    let fixture = try BoundedReadFixture(schema: legacySchema)
    defer { fixture.cleanup() }
    try fixture.insertChat(rowID: 1, guid: chatGUID)
    try fixture.insertHandle(rowID: 1, id: "someone@example.com")
    try fixture.insertMessage(rowID: 1, text: "old", date: 42, handleID: 1)
    try fixture.join(messageRowID: 1, chatRowID: 1)

    let row = try #require(try fixture.imDatabase.boundedMessagePage(afterRowID: 0).rows.first?.ready)
    #expect(row.text == "old")
    #expect(row.date == 42)
    #expect(row.participantID == "someone@example.com")
    #expect(row.threadID == chatGUID)
    #expect(row.roomName == nil)
    #expect(row.otherID == nil)
    #expect(row.dateEdited == nil)
    #expect(row.dateRetracted == nil)
    #expect(row.associatedMessageEmoji == nil)
    #expect(row.scheduleType == 0)
}

@Test func timestampsStayExactAndLateEditsAreFoundByRescan() throws {
    let fixture = try BoundedReadFixture()
    defer { fixture.cleanup() }
    try fixture.insertChat(rowID: 1, guid: chatGUID)
    try fixture.insertMessage(rowID: 1, text: "original", date: 1)
    try fixture.insertMessage(rowID: 2, date: Int64.max - 1)
    try fixture.execute("UPDATE message SET date_read = ?, date_edited = ? WHERE ROWID = 2", Int64.max - 2, Int64.max - 3)
    for rowID in 1 ... 2 {
        try fixture.join(messageRowID: rowID, chatRowID: 1)
    }

    let initial = try fixture.imDatabase.boundedMessagePage(afterRowID: 0)
    let exact = try #require(initial.rows[1].ready)
    #expect(exact.date == Int(Int64.max - 1))
    #expect(exact.dateRead == Int(Int64.max - 2))
    #expect(exact.dateEdited == Int(Int64.max - 3))

    // an edit to an old row doesn't move ROWID; a rescan or refresh sees it
    try fixture.execute("UPDATE message SET text = 'edited', date_edited = ? WHERE ROWID = 1", Int64(1_000))
    let rescan = try fixture.imDatabase.boundedMessagePage(afterRowID: 0, throughRowID: initial.throughRowID)
    #expect(rescan.rows[0].ready?.text == "edited")
    #expect(rescan.rows[0].ready?.dateEdited == 1_000)
    #expect(try fixture.imDatabase.boundedMessageRefresh(rowIDs: [1]).rows.first?.ready?.text == "edited")
}

@Test func readsKeepOneSnapshotUnderAConcurrentWriter() throws {
    let fixture = try BoundedReadFixture()
    defer { fixture.cleanup() }
    try fixture.insertChat(rowID: 1, guid: chatGUID)
    try fixture.insertChat(rowID: 2, guid: "any;+;chat-2")
    for rowID in 1 ... 2 {
        try fixture.insertMessage(rowID: rowID, text: "before \(rowID)")
        try fixture.join(messageRowID: rowID, chatRowID: 1)
    }

    let page = try fixture.imDatabase.boundedMessagePage(
        afterRowID: 0,
        throughRowID: nil,
        limit: 50,
        operationLimits: defaultBoundedReadOperationLimits,
        afterClassification: {
            try fixture.execute("UPDATE message SET text = 'after' WHERE ROWID = 1")
            try fixture.join(messageRowID: 2, chatRowID: 2)
            try fixture.insertMessage(rowID: 3)
            try fixture.join(messageRowID: 3, chatRowID: 1)
        }
    )
    #expect(page.throughRowID == 2)
    #expect(page.rows.map { $0.ready?.text } == ["before 1", "before 2"])

    let refresh = try fixture.imDatabase.boundedMessageRefresh(
        rowIDs: [1, 3],
        operationLimits: defaultBoundedReadOperationLimits,
        afterClassification: {
            try fixture.execute("DELETE FROM message WHERE ROWID IN (1, 3)")
        }
    )
    #expect(refresh.rows.map(\.rowID) == [1, 3])
    #expect(refresh.rows.allSatisfy { $0.ready != nil })
    #expect(refresh.rows.first?.ready?.text == "after")
    #expect(refresh.missingRowIDs.isEmpty)

    let after = try fixture.imDatabase.boundedMessagePage(afterRowID: 0)
    #expect(after.rows.map(\.rowID) == [2])
    #expect(after.rows.first?.unresolved?.reason == .multipleChats)
    #expect(try fixture.imDatabase.boundedMessageRefresh(rowIDs: [1, 3]).missingRowIDs == [1, 3])
}

@Test func limitsAndSQLErrorsThrowFixedErrorsAndAreRecoverable() throws {
    let fixture = try BoundedReadFixture()
    defer { fixture.cleanup() }
    try fixture.insertChat(rowID: 1, guid: chatGUID)
    try fixture.insertMessage(rowID: 1, text: "hi")
    try fixture.join(messageRowID: 1, chatRowID: 1)

    #expect(throws: BoundedMessageReadError.instructionAllowanceExhausted) {
        try fixture.imDatabase.boundedMessagePage(
            afterRowID: 0, throughRowID: nil, limit: 50,
            operationLimits: OperationLimits(instructionAllowance: 1, timeoutNanoseconds: 60_000_000_000, instructionsPerCheck: 1),
            afterClassification: nil
        )
    }
    #expect(throws: BoundedMessageReadError.deadlineExceeded) {
        try fixture.imDatabase.boundedMessageRefresh(
            rowIDs: [1],
            operationLimits: OperationLimits(instructionAllowance: 1_000_000, timeoutNanoseconds: 0),
            afterClassification: nil
        )
    }

    // no transaction or progress handler is left behind
    #expect(try fixture.imDatabase.boundedMessagePage(afterRowID: 0).rows.first?.ready?.text == "hi")
    #expect(try fixture.imDatabase.lastMessageRowID() == 1)
    #expect(try fixture.imDatabase.mappedMessageRows(rowIDs: [1]).map(\.text) == ["hi"])

    // evaluating the chat view fails with an integer overflow
    try fixture.execute("ALTER TABLE chat RENAME TO chat_table")
    try fixture.execute("CREATE VIEW chat AS SELECT ROWID AS ROWID, abs(-9223372036854775807 - 1) AS guid, room_name FROM chat_table")
    #expect(throws: BoundedMessageReadError.sqliteFailure(code: 1)) {
        try fixture.imDatabase.boundedMessagePage(afterRowID: 0)
    }
    #expect(throws: BoundedMessageReadError.sqliteFailure(code: 1)) {
        try fixture.imDatabase.boundedMessageRefresh(rowIDs: [1])
    }

    try fixture.execute("DROP VIEW chat")
    try fixture.execute("ALTER TABLE chat_table RENAME TO chat")
    #expect(try fixture.imDatabase.boundedMessageRefresh(rowIDs: [1]).rows.first?.ready?.threadID == chatGUID)
}

@Test func unsupportedSchemaIsAFixedError() throws {
    let fixture = try BoundedReadFixture()
    defer { fixture.cleanup() }
    try fixture.execute("DROP TABLE chat_message_join")

    #expect(throws: BoundedMessageReadError.unsupportedSchema) {
        try fixture.imDatabase.boundedMessagePage(afterRowID: 0)
    }
}

@Test func reentrantCallsAreRejected() throws {
    let fixture = try BoundedReadFixture()
    defer { fixture.cleanup() }
    try fixture.insertChat(rowID: 1, guid: chatGUID)
    try fixture.insertMessage(rowID: 1)
    try fixture.join(messageRowID: 1, chatRowID: 1)

    var nestedError: (any Error)?
    let page = try fixture.imDatabase.boundedMessagePage(
        afterRowID: 0,
        throughRowID: nil,
        limit: 50,
        operationLimits: defaultBoundedReadOperationLimits,
        afterClassification: {
            do {
                _ = try fixture.imDatabase.boundedMessageRefresh(rowIDs: [1])
            } catch {
                nestedError = error
            }
        }
    )
    #expect(page.rows.first?.ready != nil)
    #expect(nestedError as? BoundedMessageReadError == .concurrentUse)
    #expect(try fixture.imDatabase.boundedMessageRefresh(rowIDs: [1]).rows.count == 1)
}

@Test func invalidInputsAreRejectedBeforeReading() throws {
    let fixture = try BoundedReadFixture()
    defer { fixture.cleanup() }
    let database = fixture.imDatabase

    #expect(throws: BoundedMessageReadError.invalidArgument) { try database.boundedMessagePage(afterRowID: -1) }
    #expect(throws: BoundedMessageReadError.invalidArgument) { try database.boundedMessagePage(afterRowID: 5, throughRowID: 4) }
    #expect(throws: BoundedMessageReadError.invalidArgument) { try database.boundedMessagePage(afterRowID: 0, limit: 0) }
    #expect(throws: BoundedMessageReadError.invalidArgument) { try database.boundedMessagePage(afterRowID: 0, limit: 101) }
    #expect(throws: BoundedMessageReadError.invalidArgument) { try database.boundedMessageRefresh(rowIDs: []) }
    #expect(throws: BoundedMessageReadError.invalidArgument) { try database.boundedMessageRefresh(rowIDs: Array(1 ... 101)) }
    #expect(throws: BoundedMessageReadError.invalidArgument) { try database.boundedMessageRefresh(rowIDs: [0]) }
    #expect(throws: BoundedMessageReadError.invalidArgument) { try database.boundedMessageRefresh(rowIDs: [-1]) }
    #expect(throws: BoundedMessageReadError.invalidArgument) { try database.boundedMessageRefresh(rowIDs: [1, 1]) }

    #expect(try database.boundedMessagePage(afterRowID: 0, limit: 100).rows.isEmpty)
    #expect(try database.boundedMessageRefresh(rowIDs: Array(1 ... 100)).missingRowIDs == Array(1 ... 100))
}

@Test func refreshReportsMissingRowsExplicitly() throws {
    let fixture = try BoundedReadFixture()
    defer { fixture.cleanup() }
    try fixture.insertChat(rowID: 1, guid: chatGUID)
    for rowID in [1, 3] {
        try fixture.insertMessage(rowID: rowID)
        try fixture.join(messageRowID: rowID, chatRowID: 1)
    }

    let refresh = try fixture.imDatabase.boundedMessageRefresh(rowIDs: [3, 2, 1, 999])
    #expect(refresh.rows.map(\.rowID) == [1, 3])
    #expect(refresh.rows.allSatisfy { $0.ready != nil })
    #expect(refresh.missingRowIDs == [2, 999])
}

// MARK: - Fixture

private let currentSchema = [
    """
    CREATE TABLE message (
        ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE, text TEXT, subject TEXT,
        attributedBody BLOB, service TEXT, error INTEGER DEFAULT 0, date INTEGER, date_read INTEGER,
        date_delivered INTEGER, is_delivered INTEGER DEFAULT 0, is_from_me INTEGER DEFAULT 0,
        is_read INTEGER DEFAULT 0, is_audio_message INTEGER DEFAULT 0, item_type INTEGER DEFAULT 0,
        handle_id INTEGER DEFAULT 0, other_handle INTEGER DEFAULT 0, group_title TEXT,
        group_action_type INTEGER DEFAULT 0, share_status INTEGER DEFAULT 0, associated_message_guid TEXT,
        associated_message_type INTEGER DEFAULT 0, associated_message_emoji TEXT, balloon_bundle_id TEXT,
        payload_data BLOB, expressive_send_style_id TEXT, message_summary_info BLOB, reply_to_guid TEXT,
        thread_originator_guid TEXT, thread_originator_part TEXT, date_retracted INTEGER DEFAULT 0,
        date_edited INTEGER DEFAULT 0, was_detonated INTEGER DEFAULT 0, schedule_type INTEGER DEFAULT 0,
        future_blob BLOB
    )
    """,
    "CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE, room_name TEXT)",
    "CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL)",
    // no primary key, so identical duplicate joins can be represented
    "CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER DEFAULT 0)",
    "CREATE INDEX chat_message_join_idx_message_id ON chat_message_join (message_id, chat_id)",
]

// predates date_edited, date_retracted, associated_message_emoji,
// other_handle, schedule_type and chat.room_name
private let legacySchema = [
    """
    CREATE TABLE message (
        ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL, text TEXT, service TEXT,
        error INTEGER DEFAULT 0, date INTEGER, date_read INTEGER, date_delivered INTEGER,
        is_delivered INTEGER DEFAULT 0, is_from_me INTEGER DEFAULT 0, is_read INTEGER DEFAULT 0,
        handle_id INTEGER DEFAULT 0, associated_message_guid TEXT, associated_message_type INTEGER DEFAULT 0,
        balloon_bundle_id TEXT, payload_data BLOB
    )
    """,
    "CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL)",
    "CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL)",
    "CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, PRIMARY KEY (chat_id, message_id))",
]

private final class BoundedReadFixture {
    let directory: URL
    let writer: Database
    let imDatabase: IMDatabase

    init(schema: [String] = currentSchema) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // a separate WAL writer can commit while a bounded read holds its snapshot
        writer = try Database(connecting: directory.appendingPathComponent("chat.db").path, flags: [.readWrite, .createIfNecessary])
        try writer.execute(sqlWithoutEscaping: "PRAGMA journal_mode = WAL")
        for statement in schema {
            try writer.execute(sqlWithoutEscaping: statement)
        }

        imDatabase = try IMDatabase(messagesDataBaseURL: directory, createIndexes: false)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }

    func execute<each T: SQLiteBindable>(_ sql: String, _ values: repeat each T) throws {
        try writer.execute(sqlWithoutEscaping: sql, repeat each values)
    }

    func insertChat(rowID: Int, guid: String?) throws {
        try execute("INSERT INTO chat (ROWID, guid) VALUES (?, ?)", rowID, guid)
    }

    func insertHandle(rowID: Int, id: String) throws {
        try execute("INSERT INTO handle (ROWID, id) VALUES (?, ?)", rowID, id)
    }

    func insertMessage(rowID: Int, guid: String? = nil, text: String? = nil, date: Int64 = 0, handleID: Int = 0) throws {
        try execute(
            "INSERT INTO message (ROWID, guid, text, date, handle_id) VALUES (?, ?, ?, ?, ?)",
            rowID, guid ?? "message-\(rowID)", text, date, handleID
        )
    }

    func join(messageRowID: Int, chatRowID: Int) throws {
        try execute("INSERT INTO chat_message_join (chat_id, message_id) VALUES (?, ?)", chatRowID, messageRowID)
    }
}

private extension BoundedMessageRowResult {
    var ready: MappedMessageRow? {
        if case let .ready(row) = self { row } else { nil }
    }

    var unresolved: BoundedUnresolvedMessageRow? {
        if case let .unresolved(row) = self { row } else { nil }
    }
}
