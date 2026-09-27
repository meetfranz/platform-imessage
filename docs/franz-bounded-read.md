# IMDatabase bounded reads (Franz)

Two additive `IMDatabase` APIs read `chat.db` in bounded pages. They don't
change `messages(since:)`, `mappedMessageRows(rowIDs:)` or any other existing
API; see [franz-read-api.md](./franz-read-api.md) for those and for opening the
database (explicit Messages directory, `createIndexes: false`).

```swift
func boundedMessagePage(afterRowID: Int, throughRowID: Int? = nil, limit: Int = 50) throws -> BoundedMessagePage
func boundedMessageRefresh(rowIDs: [Int]) throws -> BoundedMessageRefresh
```

Neither makes network calls, looks up attachment files or does file IO beyond
SQLite reading `chat.db`.

## Concurrency and transactions

`IMDatabase` is not thread-safe. Serialize these calls with every other call on
the instance. Each call runs in one read transaction (`BEGIN DEFERRED` …
`COMMIT`), so classification and payloads come from the same snapshot of
`message`, `chat_message_join`, `chat` and `handle`. A call made while the
connection is already in a transaction or limit scope throws `.concurrentUse`.

## Paging: `boundedMessagePage`

Scans `afterRowID < ROWID <= throughRowID` in ascending ROWID order with
`ORDER BY ROWID ASC LIMIT limit + 1`. There is no `OFFSET`, no timestamp
cursor and no enumeration of integer ranges, so sparse ROWIDs and rows with
identical dates page correctly.

- `afterRowID >= 0`; `throughRowID >= afterRowID` if given; `limit` in `1...100`
  (default 50). Anything else throws `.invalidArgument` before reading.
- Omit `throughRowID` on the first page of a scan: the page captures
  `MAX(ROWID)` in its transaction (never below `afterRowID`) and returns it as
  `throughRowID`. Pass that value back unchanged, with `nextAfterRowID`, until
  `hasMore` is `false`. Rows committed above the bound belong to a later scan.
- `rows` holds every source row in `(afterRowID, lastScannedRowID]`. Nothing in
  that range is filtered out.
- `hasMore == true`: `nextAfterRowID == lastScannedRowID`, and rows may remain
  up to `throughRowID`.
- `hasMore == false`: the range was proven exhausted and
  `nextAfterRowID == throughRowID`. Only then does an empty page advance to the
  bound.

## Refreshing: `boundedMessageRefresh`

Takes 1...100 distinct positive ROWIDs; anything else throws
`.invalidArgument`. Returns existing rows ascending by ROWID and lists the rest
in `missingRowIDs`, ascending. A missing row is absent from this snapshot; the
API doesn't infer deletion. If the rows don't fit in 4 MiB, it throws
`.batchTooLarge` rather than returning part of them; split the request.

## Row results

Each row is `.ready(MappedMessageRow)` or `.unresolved(BoundedUnresolvedMessageRow)`.

A ready row was mapped in the same transaction that classified it, and is
joined to exactly one chat: `threadID` (chat GUID) and `chatRowID` are set,
along with `roomName`, `participantID` (`handle.id` for `handle_id`) and
`otherID` (`handle.id` for `other_handle`). Timestamps (`date`, `dateRead`,
`dateEdited`, …) are the raw integer nanoseconds from `chat.db`.

An unresolved row has a positive `rowID`, a `guid` only when it's valid text of
at most 1024 bytes, and the first matching reason:

| Reason | Meaning |
| --- | --- |
| `invalidIdentity` | `guid` is `NULL`, empty or not text |
| `noValidChatJoin` | no join row, or the joined chat is missing or has no valid GUID |
| `multipleChats` | joined to more than one distinct chat; never guessed |
| `oversizedIdentifier` | GUID, `associated_message_guid`, `reply_to_guid`, `thread_originator_guid`, chat GUID, room name or a handle ID exceeds 1024 bytes |
| `oversizedRow` | selected fields exceed 1 MiB |
| `undecodable` | a selected field has a storage type the mapped row can't decode |

Identical duplicate join rows count as one chat. Rows that are unresolved now
(for example a join that isn't visible yet) can be retried with
`boundedMessageRefresh`; retrying, and deciding when to give up, is the
caller's job.

## Bounds

- Only the `message` columns `MappedMessageRow` reads are selected, plus the
  chat and handle columns above. A column missing from an older schema decodes
  as `NULL`/its default; columns the mapper doesn't read, however large, are
  never selected.
- Sizes are UTF-8/blob byte counts, read with `octet_length` (or `length` for
  blobs on SQLite before 3.43) before any Swift `String`/`Data` is built. An
  oversized row is classified without copying its payload into Swift. On SQLite
  before 3.43 (macOS 13 and earlier), measuring text still makes SQLite read it.
- Per row: 1 MiB across the selected variable-sized fields. Per page or refresh:
  4 MiB. A row that fits on its own but not in the page's remaining budget
  starts the next page; the continuation never skips it. The first row always
  fits, so every non-exhausted page makes progress.
- Join fan-out is bounded before mapping: classification reads `MIN`/`MAX` of
  the joined chat IDs, and the payload query joins exactly that one chat.
- Each call runs under a SQLite progress handler with a finite VM instruction
  allowance and a monotonic deadline, checked around schema discovery,
  statement preparation and stepping. It's removed, and the transaction ended,
  on every exit. It doesn't create indexes or busy-wait. These bound work and
  deserialization, not process memory, and can't preempt a single stalled
  filesystem read.

## Errors

Every failure throws a fixed `BoundedMessageReadError` and leaves no usable
progress; retry the same request.

| Error | Cause |
| --- | --- |
| `invalidArgument` | input out of range |
| `unsupportedSchema` | `message.guid`, `chat.guid`, `chat_message_join.chat_id`/`message_id` or `handle.id` missing |
| `batchTooLarge` | refresh exceeds 4 MiB |
| `instructionAllowanceExhausted`, `deadlineExceeded` | work limit reached |
| `concurrentUse` | reentrant or overlapping use of the connection |
| `inconsistentSnapshot` | a classified row wasn't read back (not expected within one transaction) |
| `sqliteFailure(code:)` | SQLite primary result code |
| `unexpectedFailure` | anything else |

The connection stays usable after any of these, including interruption.

## Caller responsibilities

The API doesn't persist anything. The caller owns durable checkpoints
(`afterRowID`, `throughRowID`), the retained set of unresolved row IDs and when
to retry them, bootstrap and history policy, and periodic full reconciliation.
A ROWID scan doesn't report edits, read receipts or late joins on rows it has
already passed. Find those by rescanning or refreshing, not by comparing
timestamps.

## SQLite statement cleanup

These APIs also change `Statement` cleanup in the `SQLite` target, affecting
every caller:

- A step or row-handler error is rethrown unchanged; the reset that follows no
  longer traps on the repeated error (such as `SQLITE_INTERRUPT`).
- After a successful or early-stopped evaluation, a reset error is thrown.
- `deinit` always finalizes without trapping.
- Text decoding copies the exact SQLite byte count, preserving embedded NULs. Invalid UTF-8 throws a content-free column error instead of silently substituting characters. A mapped-row decoding failure becomes unresolved; a failure while recovering an unresolved GUID fails the whole bounded operation with a fixed error.

References: [sqlite3_reset](https://www.sqlite.org/c3ref/reset.html),
[sqlite3_progress_handler](https://www.sqlite.org/c3ref/progress_handler.html),
[sqlite3_finalize](https://www.sqlite.org/c3ref/finalize.html).
