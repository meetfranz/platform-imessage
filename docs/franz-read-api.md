# IMDatabase read API (Franz)

The `IMDatabase` library product gives local read access to `chat.db` and lets
you poll it for message changes. None of the APIs below make network calls.

```swift
.product(name: "IMDatabase", package: "platform-imessage")
```

Public APIs used by this consumer:

- `IMDatabase.messages(since: MessageUpdatesCursor) throws -> UpdatedMessagesQueryResult`
  - `UpdatedMessagesQueryResult`: `updatedMessages`, `unresolvedNewMessageRowIDs`, `nextCursor`
  - `UpdatedMessageChange`: `rowID`, `chatGUID`, `isNew`, `wasRead`, `wasEdited`, `isHydrationUpdate`
- `IMDatabase.messageUpdateCursorSnapshot() throws -> MessageUpdatesCursor`
- `IMDatabase.threadIDForMessage(rowID: Int) throws -> String?`
- `IMDatabase.mappedMessageRows(rowIDs: [Int]) throws -> [MappedMessageRow]`
- `IMDatabase.mappedMessageRows(guids: [String]) throws -> [MappedMessageRow]`

The initializers and `merging(_:)` on the update result types are still
`package`-scoped. You read these results; you don't construct them.

## Opening the database

Pass the Messages directory explicitly, and always pass `createIndexes: false`
explicitly:

```swift
let db = try IMDatabase(
    messagesDataBaseURL: URL(fileURLWithPath: "/Users/<user>/Library/Messages", isDirectory: true),
    createIndexes: false
)
```

- `createIndexes: false` is required. With `true`, the initializer first opens
  `chat.db` **read-write** and runs `CREATE INDEX` on `message.date_read` and
  `message.date_edited`. So not every way of constructing an `IMDatabase` is
  read-only. With `createIndexes: false`, the initializer opens only a
  `.readOnly` SQLite connection. Pass it explicitly anyway, so the code doesn't
  depend on the default staying `false`. Without those indexes, the
  `date_read` / `date_edited` filters can be slow on large databases.
- If you pass a URL, the initializer skips restoring the library's saved
  security-scoped bookmark. Your process must already be able to read that
  directory, for example through Full Disk Access.
- Only the calls listed above are covered here. Other `IMDatabase` APIs, such
  as change listening and file watching, aren't part of this contract.

## Concurrency

`IMDatabase` is not thread-safe. All calls share one SQLite connection and a
prepared-statement cache, and `messages(since:)` resets and rebinds a cached
statement. Serialize every call on an instance (queue, actor, or lock),
including the lookup APIs.

## Cursor semantics

`MessageUpdatesCursor` holds three independent high-water marks:

- `lastRowID`: `message.ROWID`
- `lastDateReadNanoseconds`: raw `message.date_read`
- `lastDateEditedNanoseconds`: raw `message.date_edited`

The date fields hold the exact integer nanoseconds stored in `chat.db`, counted
from the Apple reference date (2001-01-01 UTC). Store them as `Int64` exactly
as given. Round-tripping through `Date`/`Double`, or converting to seconds or
milliseconds, can lose precision and cause missed or repeated rows. A stored
value of `0` is treated like `NULL`.

A row matches when `ROWID > lastRowID OR date_read > lastDateRead OR
date_edited > lastDateEdited`. Each flag is computed against the cursor you
passed in. Results come back in `ROWID` order.

Limitations:

- **Unbounded results.** The query has no `LIMIT` and no paging. It loads every
  matching row into memory. `MessageUpdatesCursor.empty` returns every message
  in the database, so don't use it as a starting cursor.
- **Global maxima.** The read and edit marks are single maxima across all rows.
  If a row later gets a `date_read` / `date_edited` at or below the current
  mark (from clock skew or a synced device, for example), it won't be reported.
- **Duplicates.** A message joined to more than one chat can appear once per
  join row. Results aren't de-duplicated by `rowID`.

## Starting point: snapshot vs. history

`messageUpdateCursorSnapshot()` returns the current high-water marks:
`sqlite_sequence.seq` for `message` (the highest ROWID ever allocated, not
necessarily the current maximum), plus `MAX(date_read)` and `MAX(date_edited)`.
Polling from a snapshot reports only changes made **after** it was taken.

A snapshot alone therefore **skips every historical message**. If you need
existing history, you need a separate bootstrap step, qualified on its own
terms (what range, how it's paged, how it handles changes that happen during
the bootstrap). Take the snapshot before the bootstrap starts, and begin
polling from it afterwards, so that changes made during the bootstrap are
reported by polling. Expect overlap between the two and de-duplicate. This
document doesn't define or guarantee a history bootstrap.

## Unresolved new rows

A new row can become visible before its `chat_message_join` row. Those row IDs
go into `unresolvedNewMessageRowIDs`, not `updatedMessages`.

**`nextCursor.lastRowID` still advances past them.** Polling again with
`nextCursor` won't return them, and `messages(since:)` doesn't retry anything
itself. So you must:

1. **Retain the IDs durably.** Commit `unresolvedNewMessageRowIDs` in the same
   durable write as the batch's effects and the new `nextCursor`. Never persist
   a cursor that has moved past a row ID without also persisting that ID, or
   the row is lost.
2. **Re-resolve by ID** on later ticks, serialized with the other calls:
   - `mappedMessageRows(rowIDs:)` returns full rows. Batching (500 per query)
     is handled internally. The result is ordered by `date` descending, not by
     input order. A message joined to several chats can return one row per
     join. `threadID` / `chatRowID` stay `nil` while the join is still
     missing.
   - `threadIDForMessage(rowID:)` is a lighter check that returns only the
     chat GUID. It returns `nil` both when the join is still missing and when
     the row doesn't exist.
3. **Remove an ID** from the retained set only in the same durable write as its
   resolved effect. If the row is gone from `message` entirely, record that as
   an explicit outcome under your own policy; don't silently drop the ID.

`mappedMessageRows(guids:)` is the GUID-keyed equivalent, also batched
internally. It returns rows in no guaranteed order.

## Omitted orphan updates

If an existing row (`isNew == false`) matches on read or edit but has no chat
join, `messages(since:)` drops it silently (logging at most 10 per call). The
cursor still advances past its dates, and the row ID isn't returned anywhere,
so this API doesn't report that change.

## Hydration and delivery limitations

- `messages(since:)` never sets `isHydrationUpdate`. Link previews and
  attachment transfers that finish after the first emit don't change
  `date_read` / `date_edited`, so this query doesn't report them. Only the
  `IMessage` target's `EventWatcher` detects them.
- Results are change notifications (`rowID` + `chatGUID` + flags). Fetch
  content with `mappedMessageRows(rowIDs:)`, and expect that content (text,
  attachments, previews) may still be incomplete when you fetch it.
- Nothing guarantees delivery. Persist `nextCursor`, together with the retained
  unresolved IDs, only after the batch's effects are durably handled.

This is best-effort change detection, not a lossless sync mechanism. Reconcile
periodically if you need completeness.
