import Foundation
import SQLite

// Generous for at most 101 ROWID-indexed rows; exhausted only by pathological
// join fan-out or a stalled read.
let defaultBoundedReadOperationLimits = OperationLimits(
    instructionAllowance: 50_000_000,
    timeoutNanoseconds: 10_000_000_000
)

// The `message` columns `MappedMessageRow` reads, besides ROWID. Columns
// missing from an older schema are left out and decode as `NULL`; columns not
// listed here are never selected.
private let mappedMessageColumns = [
    "guid", "text", "subject", "attributedBody", "service", "error", "date",
    "date_read", "date_delivered", "is_delivered", "is_from_me", "is_read",
    "is_audio_message", "item_type", "handle_id", "group_title",
    "group_action_type", "share_status", "associated_message_guid",
    "associated_message_type", "associated_message_emoji", "balloon_bundle_id",
    "payload_data", "expressive_send_style_id", "message_summary_info",
    "reply_to_guid", "thread_originator_guid", "thread_originator_part",
    "date_retracted", "date_edited", "was_detonated", "schedule_type",
]

// `message` columns that hold another message's GUID; bounded like identifiers.
private let mappedMessageReferenceColumns: Set<String> = [
    "associated_message_guid", "reply_to_guid", "thread_originator_guid",
]

public extension IMDatabase {
    /// Reads source rows with `afterRowID < ROWID <= throughRowID` in ascending
    /// ROWID order, in one read transaction.
    ///
    /// Omit `throughRowID` to use `MAX(ROWID)` captured in that transaction;
    /// pass the returned ``BoundedMessagePage/throughRowID`` back unchanged to
    /// continue the same scan. `afterRowID >= 0`, `throughRowID >= afterRowID`,
    /// `limit` in ``BoundedMessageReadLimits/pageLimits``.
    ///
    /// Not thread-safe; serialize calls with all other access to this
    /// instance. Throws ``BoundedMessageReadError``. See
    /// docs/franz-bounded-read.md.
    func boundedMessagePage(
        afterRowID: Int,
        throughRowID: Int? = nil,
        limit: Int = BoundedMessageReadLimits.defaultPageLimit
    ) throws -> BoundedMessagePage {
        try boundedMessagePage(
            afterRowID: afterRowID,
            throughRowID: throughRowID,
            limit: limit,
            operationLimits: defaultBoundedReadOperationLimits,
            afterClassification: nil
        )
    }

    /// Re-reads 1...100 distinct positive ROWIDs in one read transaction.
    /// Absent rows are reported in ``BoundedMessageRefresh/missingRowIDs``.
    /// Throws ``BoundedMessageReadError/batchTooLarge`` instead of returning
    /// part of the rows.
    ///
    /// Not thread-safe; serialize calls with all other access to this
    /// instance. Throws ``BoundedMessageReadError``. See
    /// docs/franz-bounded-read.md.
    func boundedMessageRefresh(rowIDs: [Int]) throws -> BoundedMessageRefresh {
        try boundedMessageRefresh(
            rowIDs: rowIDs,
            operationLimits: defaultBoundedReadOperationLimits,
            afterClassification: nil
        )
    }
}

extension IMDatabase {
    /// `afterClassification` runs inside the transaction between classifying
    /// and reading payloads; tests use it to write from another connection.
    func boundedMessagePage(
        afterRowID: Int,
        throughRowID: Int?,
        limit: Int,
        operationLimits: OperationLimits,
        afterClassification: (() throws -> Void)?
    ) throws -> BoundedMessagePage {
        guard afterRowID >= 0,
              throughRowID.map({ $0 >= afterRowID }) ?? true,
              BoundedMessageReadLimits.pageLimits.contains(limit) else {
            throw BoundedMessageReadError.invalidArgument
        }

        return try performBoundedRead(operationLimits) { scope in
            let schema = try BoundedReadSchema(discoveringIn: database, scope: scope)
            let through: Int
            if let throughRowID {
                through = throughRowID
            } else {
                let maximumRowID = try maximumMessageRowID(scope: scope) ?? 0
                through = max(afterRowID, maximumRowID)
            }

            // one extra row proves whether the range continues past this page
            let classified = try classifyMessageRows(
                schema: schema,
                filter: "m.ROWID > ? AND m.ROWID <= ?",
                bindings: [afterRowID, through],
                limit: limit + 1,
                scope: scope
            )

            var hasMore = classified.count > limit
            var admitted = [ClassifiedMessageRow]()
            var resultBytes = 0
            for row in classified.prefix(limit) {
                // a row that doesn't fit starts the next page
                guard resultBytes + row.resultBytes <= BoundedMessageReadLimits.maximumResultBytes else {
                    hasMore = true
                    break
                }
                resultBytes += row.resultBytes
                admitted.append(row)
            }

            try afterClassification?()
            let rows = try materializeMessageRows(admitted, schema: schema, scope: scope)

            let lastScannedRowID = admitted.last?.rowID
            let nextAfterRowID: Int
            if hasMore {
                // the first row always fits, so a continuing page is never empty
                guard let lastScannedRowID else { throw BoundedMessageReadError.unexpectedFailure }
                nextAfterRowID = lastScannedRowID
            } else {
                nextAfterRowID = through
            }

            return BoundedMessagePage(
                afterRowID: afterRowID,
                throughRowID: through,
                rows: rows,
                lastScannedRowID: lastScannedRowID,
                nextAfterRowID: nextAfterRowID,
                hasMore: hasMore
            )
        }
    }

    func boundedMessageRefresh(
        rowIDs: [Int],
        operationLimits: OperationLimits,
        afterClassification: (() throws -> Void)?
    ) throws -> BoundedMessageRefresh {
        guard BoundedMessageReadLimits.refreshRowIDCounts.contains(rowIDs.count),
              rowIDs.allSatisfy({ $0 > 0 }),
              Set(rowIDs).count == rowIDs.count else {
            throw BoundedMessageReadError.invalidArgument
        }

        return try performBoundedRead(operationLimits) { scope in
            let schema = try BoundedReadSchema(discoveringIn: database, scope: scope)
            let classified = try classifyMessageRows(
                schema: schema,
                filter: "m.ROWID IN (\(boundedPlaceholders(count: rowIDs.count)))",
                bindings: rowIDs,
                limit: rowIDs.count,
                scope: scope
            )

            let resultBytes = classified.reduce(0) { $0 + $1.resultBytes }
            guard resultBytes <= BoundedMessageReadLimits.maximumResultBytes else {
                throw BoundedMessageReadError.batchTooLarge
            }

            try afterClassification?()
            let rows = try materializeMessageRows(classified, schema: schema, scope: scope)

            let foundRowIDs = Set(classified.map(\.rowID))
            return BoundedMessageRefresh(
                rows: rows,
                missingRowIDs: rowIDs.filter { !foundRowIDs.contains($0) }.sorted()
            )
        }
    }
}

// MARK: - Transaction and Limits

private extension IMDatabase {
    func performBoundedRead<Result>(
        _ limits: OperationLimits,
        _ body: (OperationLimitScope) throws -> Result
    ) throws -> Result {
        do {
            // the limit scope ends before COMMIT/ROLLBACK, so an exhausted
            // allowance can't interrupt the transaction's cleanup
            return try database.withReadTransaction {
                try database.withOperationLimits(limits, body)
            }
        } catch let error as BoundedMessageReadError {
            throw error
        } catch let error as OperationLimitError {
            switch error {
            case .instructionAllowanceExhausted: throw BoundedMessageReadError.instructionAllowanceExhausted
            case .deadlineExceeded: throw BoundedMessageReadError.deadlineExceeded
            case .nestedScope: throw BoundedMessageReadError.concurrentUse
            }
        } catch DatabaseTransactionError.transactionAlreadyActive {
            throw BoundedMessageReadError.concurrentUse
        } catch let error as SQLiteError {
            throw BoundedMessageReadError.sqliteFailure(code: error.code)
        } catch {
            throw BoundedMessageReadError.unexpectedFailure
        }
    }

    func prepareBoundedStatement(_ sql: String, scope: OperationLimitScope) throws -> Statement {
        // modern SQLite may run the progress handler during prepare; older
        // versions and the work around it are only covered by explicit checks
        try scope.checkDeadline()
        let statement = try Statement.prepare(escapedSQL: sql, for: database)
        try scope.checkDeadline()
        return statement
    }

    func maximumMessageRowID(scope: OperationLimitScope) throws -> Int? {
        let statement = try prepareBoundedStatement("SELECT MAX(ROWID) FROM message", scope: scope)
        return try statement.compactMapRowsUntilDone { row in
            try row.integer(at: 0)
        }.first
    }
}

// MARK: - Schema

private struct BoundedReadSchema {
    /// Mapped `message` columns present in this database.
    let messageColumns: [String]
    let messageReferenceColumns: [String]
    let handleRowIDExpression: String
    let otherHandleRowIDExpression: String
    let roomNameExpression: String

    init(discoveringIn database: Database, scope: OperationLimitScope) throws {
        func columns(of table: String) throws -> Set<String> {
            try scope.checkDeadline()
            return Set(try database.tableColumns(table).map { $0.lowercased() })
        }

        let message = try columns(of: "message")
        let chat = try columns(of: "chat")
        let chatMessageJoin = try columns(of: "chat_message_join")
        let handle = try columns(of: "handle")
        guard message.contains("guid"),
              chat.contains("guid"),
              chatMessageJoin.isSuperset(of: ["chat_id", "message_id"]),
              handle.contains("id") else {
            throw BoundedMessageReadError.unsupportedSchema
        }

        messageColumns = mappedMessageColumns.filter { message.contains($0.lowercased()) }
        messageReferenceColumns = messageColumns.filter { mappedMessageReferenceColumns.contains($0) }
        handleRowIDExpression = message.contains("handle_id") ? "m.handle_id" : "NULL"
        otherHandleRowIDExpression = message.contains("other_handle") ? "m.other_handle" : "NULL"
        roomNameExpression = chat.contains("room_name") ? "c.room_name" : "NULL"
    }
}

// MARK: - Classification

private struct ClassifiedMessageRow {
    let rowID: Int
    /// `guid` is text of 1...maximumIdentifierBytes bytes.
    let hasValidGUID: Bool
    /// `nil` when the row is ready to be mapped.
    let unresolvedReason: BoundedMessageUnresolvedReason?
    /// Bytes this row contributes to a page or refresh.
    let resultBytes: Int
}

private extension IMDatabase {
    /// Reads only types and byte lengths, never payloads, so oversized rows are
    /// classified without being loaded.
    func classifyMessageRows(
        schema: BoundedReadSchema,
        filter: String,
        bindings: [Int],
        limit: Int,
        scope: OperationLimitScope
    ) throws -> [ClassifiedMessageRow] {
        let messageBytes = (["0"] + schema.messageColumns.map { byteLengthSQL("m.\($0)") })
            .joined(separator: " + ")
        // scalar MAX needs at least two arguments
        let referenceBytes = (["0", "0"] + schema.messageReferenceColumns.map { byteLengthSQL("m.\($0)") })
            .joined(separator: ", ")

        let sql = """
        SELECT
            s.row_id,
            s.guid_type,
            s.guid_bytes,
            s.reference_bytes,
            s.message_bytes,
            s.min_chat_id,
            s.max_chat_id,
            c.ROWID,
            typeof(c.guid),
            \(byteLengthSQL("c.guid")),
            \(byteLengthSQL(schema.roomNameExpression)),
            \(byteLengthSQL("h.id")),
            \(byteLengthSQL("oh.id"))
        FROM (
            SELECT
                m.ROWID AS row_id,
                typeof(m.guid) AS guid_type,
                \(byteLengthSQL("m.guid")) AS guid_bytes,
                MAX(\(referenceBytes)) AS reference_bytes,
                (\(messageBytes)) AS message_bytes,
                \(schema.handleRowIDExpression) AS handle_row_id,
                \(schema.otherHandleRowIDExpression) AS other_handle_row_id,
                (SELECT MIN(cmj.chat_id) FROM chat_message_join AS cmj WHERE cmj.message_id = m.ROWID) AS min_chat_id,
                (SELECT MAX(cmj.chat_id) FROM chat_message_join AS cmj WHERE cmj.message_id = m.ROWID) AS max_chat_id
            FROM message AS m
            WHERE \(filter)
            ORDER BY m.ROWID ASC
            LIMIT ?
        ) AS s
        LEFT JOIN chat AS c ON c.ROWID = s.min_chat_id AND s.min_chat_id = s.max_chat_id
        LEFT JOIN handle AS h ON h.ROWID = s.handle_row_id
        LEFT JOIN handle AS oh ON oh.ROWID = s.other_handle_row_id
        ORDER BY s.row_id ASC
        """

        let statement = try prepareBoundedStatement(sql, scope: scope)
        try statement.bind((bindings + [limit]).map { $0 as any SQLiteBindable })
        return try statement.mapRowsUntilDone { row in
            try ClassifiedMessageRow(
                rowID: row[0].expect(Int.self),
                guidType: row[1].optional(String.self),
                guidBytes: row.integer(at: 2) ?? 0,
                referenceBytes: row.integer(at: 3) ?? 0,
                messageBytes: row.integer(at: 4) ?? 0,
                minChatID: row.integer(at: 5),
                maxChatID: row.integer(at: 6),
                chatRowID: row.integer(at: 7),
                chatGUIDType: row[8].optional(String.self),
                chatGUIDBytes: row.integer(at: 9) ?? 0,
                roomNameBytes: row.integer(at: 10) ?? 0,
                handleBytes: row.integer(at: 11) ?? 0,
                otherHandleBytes: row.integer(at: 12) ?? 0
            )
        }
    }
}

private extension ClassifiedMessageRow {
    init(
        rowID: Int,
        guidType: String?,
        guidBytes: Int,
        referenceBytes: Int,
        messageBytes: Int,
        minChatID: Int?,
        maxChatID: Int?,
        chatRowID: Int?,
        chatGUIDType: String?,
        chatGUIDBytes: Int,
        roomNameBytes: Int,
        handleBytes: Int,
        otherHandleBytes: Int
    ) {
        let identifierLimit = BoundedMessageReadLimits.maximumIdentifierBytes
        let identifierBytes = max(referenceBytes, chatGUIDBytes, roomNameBytes, handleBytes, otherHandleBytes)
        let rowBytes = messageBytes + chatGUIDBytes + roomNameBytes + handleBytes + otherHandleBytes

        let reason: BoundedMessageUnresolvedReason? = if guidType != "text" || guidBytes == 0 {
            .invalidIdentity
        } else if guidBytes > identifierLimit {
            .oversizedIdentifier
        } else if minChatID == nil {
            .noValidChatJoin
        } else if minChatID != maxChatID {
            .multipleChats
        } else if chatRowID == nil || chatGUIDType != "text" || chatGUIDBytes == 0 {
            .noValidChatJoin
        } else if identifierBytes > identifierLimit {
            .oversizedIdentifier
        } else if rowBytes > BoundedMessageReadLimits.maximumRowBytes {
            .oversizedRow
        } else {
            nil
        }

        let hasValidGUID = guidType == "text" && (1 ... identifierLimit).contains(guidBytes)
        self.init(
            rowID: rowID,
            hasValidGUID: hasValidGUID,
            unresolvedReason: reason,
            resultBytes: reason == nil ? rowBytes : (hasValidGUID ? guidBytes : 0)
        )
    }
}

// MARK: - Materialization

private extension IMDatabase {
    func materializeMessageRows(
        _ classified: [ClassifiedMessageRow],
        schema: BoundedReadSchema,
        scope: OperationLimitScope
    ) throws -> [BoundedMessageRowResult] {
        let readyRows = try mappedBoundedMessageRows(
            rowIDs: classified.filter { $0.unresolvedReason == nil }.map(\.rowID),
            schema: schema,
            scope: scope
        )
        let unresolvedGUIDs = try boundedMessageGUIDs(
            rowIDs: classified.filter { $0.unresolvedReason != nil && $0.hasValidGUID }.map(\.rowID),
            scope: scope
        )

        return try classified.map { row -> BoundedMessageRowResult in
            guard let reason = row.unresolvedReason else {
                guard let ready = readyRows[row.rowID] else { throw BoundedMessageReadError.inconsistentSnapshot }
                return ready
            }

            var guid: String?
            if row.hasValidGUID {
                guard let validGUID = unresolvedGUIDs[row.rowID] else { throw BoundedMessageReadError.inconsistentSnapshot }
                guid = validGUID
            }
            return .unresolved(BoundedUnresolvedMessageRow(rowID: row.rowID, guid: guid, reason: reason))
        }
    }

    /// Selects only the columns `MappedMessageRow` reads, joined to the single
    /// chat the classification found.
    func mappedBoundedMessageRows(
        rowIDs: [Int],
        schema: BoundedReadSchema,
        scope: OperationLimitScope
    ) throws -> [Int: BoundedMessageRowResult] {
        guard !rowIDs.isEmpty else { return [:] }

        let selections = ["m.ROWID AS ROWID"]
            + schema.messageColumns.map { "m.\($0) AS \($0)" }
            + [
                "c.guid AS threadID",
                "c.ROWID AS chatRowID",
                "\(schema.roomNameExpression) AS room_name",
                "h.id AS participantID",
                "oh.id AS otherID",
            ]
        let sql = """
        SELECT
        \(selections.joined(separator: ",\n"))
        FROM message AS m
        INNER JOIN chat AS c ON c.ROWID = (SELECT MIN(cmj.chat_id) FROM chat_message_join AS cmj WHERE cmj.message_id = m.ROWID)
        LEFT JOIN handle AS h ON h.ROWID = \(schema.handleRowIDExpression)
        LEFT JOIN handle AS oh ON oh.ROWID = \(schema.otherHandleRowIDExpression)
        WHERE m.ROWID IN (\(boundedPlaceholders(count: rowIDs.count)))
        ORDER BY m.ROWID ASC
        """

        let statement = try prepareBoundedStatement(sql, scope: scope)
        try statement.bind(rowIDs.map { $0 as any SQLiteBindable })
        let columns = MappedRowColumnIndexes(statement: statement)
        // `guid` is selected second whenever the schema passed discovery
        let guidIndex = 1

        var results = [Int: BoundedMessageRowResult]()
        try statement.stepUntilDone { row in
            let rowID = try row[0].expect(Int.self)
            do {
                results[rowID] = .ready(try MappedMessageRow(row: row, columns: columns))
            } catch where error is Column.Error || error is MappedDatabaseRowError {
                // classification guaranteed a valid text GUID
                let guid = try? row[guidIndex].optional(String.self)
                results[rowID] = .unresolved(BoundedUnresolvedMessageRow(rowID: rowID, guid: guid, reason: .undecodable))
            }
        }
        return results
    }

    func boundedMessageGUIDs(rowIDs: [Int], scope: OperationLimitScope) throws -> [Int: String] {
        guard !rowIDs.isEmpty else { return [:] }

        let statement = try prepareBoundedStatement("""
        SELECT ROWID, guid FROM message
        WHERE ROWID IN (\(boundedPlaceholders(count: rowIDs.count)))
        """, scope: scope)
        try statement.bind(rowIDs.map { $0 as any SQLiteBindable })

        var guids = [Int: String]()
        try statement.stepUntilDone { row in
            guids[try row[0].expect(Int.self)] = try row[1].optional(String.self)
        }
        return guids
    }
}

// MARK: - Helpers

private extension Row {
    /// The integer in `index`, or `nil` when it's `NULL` or another type.
    borrowing func integer(at index: Int) throws -> Int? {
        let column = self[index]
        guard column.type == .integer else { return nil }
        return try column.optionalConverting(Int.self)
    }
}

/// Byte length of `expression` without loading its content where SQLite can
/// avoid it: `octet_length` on SQLite 3.43+, `length` for blobs before that.
/// Text before 3.43 is measured by SQLite, never copied into Swift.
private func byteLengthSQL(_ expression: String) -> String {
    if SQLiteLibrary.supportsOctetLength {
        "COALESCE(octet_length(\(expression)), 0)"
    } else {
        "COALESCE(CASE typeof(\(expression)) WHEN 'blob' THEN length(\(expression)) ELSE length(CAST(\(expression) AS BLOB)) END, 0)"
    }
}

private func boundedPlaceholders(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ", ")
}
