import SQLite
import Testing

private func readText(_ sql: String) throws -> String? {
    let database = try Database(connecting: ":memory:", flags: .readWrite)
    let statement = try Statement.prepare(escapedSQL: sql, for: database)
    return try statement.mapRowsUntilDone { try $0[0].expect(String.self) }.first
}

@Test func emptyTextDecodesAsEmptyString() throws {
    #expect(try readText("SELECT ''") == "")
    #expect(try readText("SELECT CAST(X'' AS TEXT)") == "")
}

@Test func multibyteTextRoundTripsExactly() throws {
    // "é👋" plus a three-byte "€"
    let text = try readText("SELECT CAST(X'C3A9F09F918BE282AC' AS TEXT)")
    #expect(text == "é👋€")
    #expect(text.map { Array($0.utf8) } == [0xc3, 0xa9, 0xf0, 0x9f, 0x91, 0x8b, 0xe2, 0x82, 0xac])
}

@Test func textPreservesEmbeddedNul() throws {
    let text = try readText("SELECT CAST(X'610062F09F918B' AS TEXT)")
    #expect(text.map { Array($0.utf8) } == [0x61, 0, 0x62, 0xf0, 0x9f, 0x91, 0x8b])
    #expect(text == "a\0b👋")

    // a leading or trailing NUL is kept too
    #expect(try readText("SELECT CAST(X'0061' AS TEXT)") == "\0a")
    #expect(try readText("SELECT CAST(X'6100' AS TEXT)") == "a\0")
}

@Test(arguments: [
    "61FF62", // invalid byte
    "F09F91", // truncated sequence
    "80", // lone continuation byte
    "C0AF", // overlong encoding
    "EDA080", // UTF-16 surrogate
    "F4908080", // above U+10FFFF
    "6100FF", // invalid after an embedded NUL
])
func invalidUTF8TextIsRejected(hex: String) throws {
    let database = try Database(connecting: ":memory:", flags: .readWrite)
    let statement = try Statement.prepare(escapedSQL: "SELECT CAST(X'\(hex)' AS TEXT)", for: database)
    try statement.stepUntilDone { row in
        #expect(throws: Column.Error.invalidUTF8(columnIndex: 0)) {
            try row[0].expect(String.self)
        }
        #expect(throws: Column.Error.invalidUTF8(columnIndex: 0)) {
            try row[0].optional(String.self)
        }
    }
}

@Test func invalidUTF8ErrorOmitsContent() {
    #expect(Column.Error.invalidUTF8(columnIndex: 2).description == "invalid UTF-8 text in column 2")
}

@Test func rowsAfterInvalidUTF8StillDecode() throws {
    let database = try Database(connecting: ":memory:", flags: .readWrite)
    let statement = try Statement.prepare(
        escapedSQL: "SELECT CAST(X'FF' AS TEXT) UNION ALL SELECT CAST(X'6200' AS TEXT)",
        for: database
    )
    let results: [String?] = try statement.mapRowsUntilDone { try? $0[0].expect(String.self) }
    #expect(results == [nil, "b\0"])
}
