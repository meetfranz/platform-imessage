import Foundation
import SQLite3

public protocol ColumnValue {
    static var preferredDataType: Column.`Type` { get }

    static func readNonNullConverting(from statement: OpaquePointer, at index: Column.Index) throws(Column.Error) -> Self
}

extension String: ColumnValue {
    public static let preferredDataType: Column.`Type` = .text

    public static func readNonNullConverting(
        from statement: OpaquePointer,
        at index: Column.Index,
        ) throws(Column.Error) -> String {
        // `sqlite3_column_text` must come first: it may convert the value,
        // which changes the length `sqlite3_column_bytes` reports
        guard let ptr = sqlite3_column_text(statement, index) else { throw .outOfMemory }
        let length = sqlite3_column_bytes(statement, index)

        // read exactly `length` bytes; `String(cString:)` would stop at an
        // embedded NUL
        let buffer = UnsafeBufferPointer(start: ptr, count: Int(length))

        // reject instead of substituting U+FFFD, which could make distinct
        // byte sequences decode to the same string
        var decoder = UTF8()
        var iterator = buffer.makeIterator()
        decoding: while true {
            switch decoder.decode(&iterator) {
            case .scalarValue: continue
            case .emptyInput: break decoding
            case .error: throw .invalidUTF8(columnIndex: index)
            }
        }

        // copies, because this pointer is invalidated when we step/reset
        return String(decoding: buffer, as: UTF8.self)
    }
}

extension Int: ColumnValue {
    public static let preferredDataType: Column.`Type` = .integer

    public static func readNonNullConverting(
        from statement: OpaquePointer,
        at index: Column.Index,
        ) throws(Column.Error) -> Int {
        Int(sqlite3_column_int64(statement, index))
    }
}

extension Int64: ColumnValue {
    public static let preferredDataType: Column.`Type` = .integer

    public static func readNonNullConverting(
        from statement: OpaquePointer,
        at index: Column.Index,
        ) throws(Column.Error) -> Int64 {
        sqlite3_column_int64(statement, index)
    }
}

extension Double: ColumnValue {
    public static let preferredDataType: Column.`Type` = .float

    public static func readNonNullConverting(
        from statement: OpaquePointer,
        at index: Column.Index,
        ) throws(Column.Error) -> Double {
        sqlite3_column_double(statement, index)
    }
}

extension Data: ColumnValue {
    public static let preferredDataType: Column.`Type` = .blob

    public static func readNonNullConverting(
        from statement: OpaquePointer,
        at index: Column.Index,
        ) throws(Column.Error) -> Data {
        let length = sqlite3_column_bytes(statement, index)

        // `sqlite3_column_blob` returns `NULL` for zero-length BLOBs; take care
        // to detect this specifically as to differentiate it from a memory
        // error
        guard length > 0 else { return Data() }

        guard let beginning = sqlite3_column_blob(statement, index) else { throw .outOfMemory }

        let buffer = UnsafeBufferPointer(start: beginning.assumingMemoryBound(to: UInt8.self), count: Int(length))
        // copy BLOB content, because this pointer is invalidated when we step/reset
        return Data(buffer: buffer)
    }
}
