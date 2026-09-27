import Foundation

/// Fixed bounds for ``IMDatabase/boundedMessagePage(afterRowID:throughRowID:limit:)``
/// and ``IMDatabase/boundedMessageRefresh(rowIDs:)``. See
/// docs/franz-bounded-read.md.
public enum BoundedMessageReadLimits {
    public static let defaultPageLimit = 50
    public static let pageLimits = 1 ... 100
    public static let refreshRowIDCounts = 1 ... 100
    /// UTF-8/blob bytes across a row's selected variable-sized fields.
    public static let maximumRowBytes = 1 << 20
    /// Bytes across all rows in one page or refresh.
    public static let maximumResultBytes = 4 << 20
    /// Bytes of each GUID, handle or chat identifier.
    public static let maximumIdentifierBytes = 1024
}

/// Why a source row couldn't be returned as a mapped row. Checked in this
/// order; the first match wins.
public enum BoundedMessageUnresolvedReason: String, Equatable, Hashable, Sendable {
    /// `guid` is `NULL`, empty or not text.
    case invalidIdentity
    /// No `chat_message_join` row, or the joined chat is missing or has no
    /// valid GUID.
    case noValidChatJoin
    /// Joined to more than one distinct chat.
    case multipleChats
    /// The GUID, a message GUID reference, the chat GUID/room name or a handle
    /// ID exceeds ``BoundedMessageReadLimits/maximumIdentifierBytes``.
    case oversizedIdentifier
    /// The selected fields exceed ``BoundedMessageReadLimits/maximumRowBytes``.
    case oversizedRow
    /// A selected field has a storage type the mapped row can't decode.
    case undecodable
}

public struct BoundedUnresolvedMessageRow: Equatable, Hashable, Sendable {
    /// Always positive.
    public let rowID: Int
    /// Present only when it is valid text of at most
    /// ``BoundedMessageReadLimits/maximumIdentifierBytes`` bytes.
    public let guid: String?
    public let reason: BoundedMessageUnresolvedReason
}

public enum BoundedMessageRowResult {
    /// Mapped from the same read transaction that classified the row. Joined
    /// to exactly one chat, so `threadID` and `chatRowID` are non-`nil`.
    case ready(MappedMessageRow)
    case unresolved(BoundedUnresolvedMessageRow)

    public var rowID: Int {
        switch self {
        case let .ready(row): row.rowID
        case let .unresolved(row): row.rowID
        }
    }
}

public struct BoundedMessagePage {
    /// The exclusive lower bound that was requested.
    public let afterRowID: Int
    /// The fixed inclusive upper bound: the requested one, or `MAX(ROWID)`
    /// captured in this page's read transaction. Pass it unchanged with
    /// ``nextAfterRowID`` to continue the same scan.
    public let throughRowID: Int
    /// Every source row in `(afterRowID, lastScannedRowID]`, ascending by ROWID.
    public let rows: [BoundedMessageRowResult]
    /// ROWID of the last row in ``rows``, or `nil` when it's empty.
    public let lastScannedRowID: Int?
    /// `lastScannedRowID` while ``hasMore``; `throughRowID` once the range is
    /// proven exhausted.
    public let nextAfterRowID: Int
    /// Whether rows may remain in `(nextAfterRowID, throughRowID]`.
    public let hasMore: Bool
}

public struct BoundedMessageRefresh {
    /// Requested rows that exist, ascending by ROWID.
    public let rows: [BoundedMessageRowResult]
    /// Requested ROWIDs absent from `message` in this snapshot, ascending. This
    /// is not proof of deletion.
    public let missingRowIDs: [Int]
}

/// Every failure leaves no usable progress: retry the same request.
public enum BoundedMessageReadError: Error, Equatable, Hashable, Sendable {
    case invalidArgument
    /// `message`, `chat`, `chat_message_join` or `handle` lacks a required column.
    case unsupportedSchema
    /// A refresh's rows don't fit in ``BoundedMessageReadLimits/maximumResultBytes``.
    case batchTooLarge
    case instructionAllowanceExhausted
    case deadlineExceeded
    /// The connection is already in a transaction or limit scope, e.g. from a
    /// reentrant call. Serialize calls on an `IMDatabase`.
    case concurrentUse
    /// A row classified earlier in the transaction wasn't read back.
    case inconsistentSnapshot
    case sqliteFailure(code: Int)
    case unexpectedFailure
}
