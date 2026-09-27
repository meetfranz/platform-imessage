import SQLite3

public enum SQLiteLibrary {
    public static var isThreadsafe: Bool {
        sqlite3_threadsafe() != 0
    }

    /// Whether the runtime library has `octet_length(X)` (SQLite 3.43.0),
    /// which reads a column's byte length without loading its content.
    public static var supportsOctetLength: Bool {
        sqlite3_libversion_number() >= 3_043_000
    }
}
