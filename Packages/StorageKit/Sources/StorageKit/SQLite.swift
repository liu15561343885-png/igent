import Foundation
import SQLite3

/// `SQLITE_TRANSIENT`：让 SQLite 自己复制一份字符串/二进制，调用方缓冲区可以立刻释放。
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum StoreError: Error, Equatable, CustomStringConvertible {
    case open(message: String)
    case sqlite(message: String, sql: String)
    case corruptRow(String)
    case migration(from: Int32, message: String)

    public var description: String {
        switch self {
        case let .open(message): "打开数据库失败：\(message)"
        case let .sqlite(message, sql): "SQL 失败：\(message) — \(sql)"
        case let .corruptRow(detail): "行数据损坏：\(detail)"
        case let .migration(from, message): "迁移失败（v\(from)）：\(message)"
        }
    }
}

/// 一层薄到几乎没有抽象的 SQLite 封装。
///
/// 为什么不引 GRDB：本项目构建期依赖越少越好（"完全本地"也意味着可离线构建），
/// 而这里只需要 prepare / bind / step 三个动作。代价是要自己写迁移与查询，
/// 换来的是零依赖与完全可控的错误信息。
final class Database {
    private var handle: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, handle != nil else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw StoreError.open(message: message)
        }
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit {
        sqlite3_close(handle)
    }

    var errorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle"
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.sqlite(message: errorMessage, sql: sql)
        }
    }

    /// 执行不返回行的语句（INSERT / UPDATE / DELETE）。
    func run(_ sql: String, _ bind: (OpaquePointer) -> Void = { _ in }) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(statement)
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else {
            throw StoreError.sqlite(message: errorMessage, sql: sql)
        }
    }

    /// 执行返回行的语句。
    func query<T>(
        _ sql: String,
        _ bind: (OpaquePointer) -> Void = { _ in },
        _ row: (OpaquePointer) throws -> T
    ) throws -> [T] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(statement)

        var results: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                results.append(try row(statement))
            case SQLITE_DONE:
                return results
            default:
                throw StoreError.sqlite(message: errorMessage, sql: sql)
            }
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw StoreError.sqlite(message: errorMessage, sql: sql)
        }
        return statement
    }

    // MARK: - 迁移

    var userVersion: Int32 {
        (try? query("PRAGMA user_version") { Int32(sqlite3_column_int($0, 0)) }.first) ?? 0
    }

    func setUserVersion(_ version: Int32) throws {
        try execute("PRAGMA user_version = \(version)")
    }

    /// 包在一个事务里执行，失败整体回滚。
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}

// MARK: - 绑定与读取

func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
    if let value {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    } else {
        sqlite3_bind_null(statement, index)
    }
}

func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Int64?) {
    if let value {
        sqlite3_bind_int64(statement, index, value)
    } else {
        sqlite3_bind_null(statement, index)
    }
}

func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Double?) {
    if let value {
        sqlite3_bind_double(statement, index, value)
    } else {
        sqlite3_bind_null(statement, index)
    }
}

func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Data?) {
    if let value {
        _ = value.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
        }
    } else {
        sqlite3_bind_null(statement, index)
    }
}

func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
          let pointer = sqlite3_column_text(statement, index)
    else { return nil }
    return String(cString: pointer)
}

func columnInt64(_ statement: OpaquePointer, _ index: Int32) -> Int64? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return sqlite3_column_int64(statement, index)
}

func columnDouble(_ statement: OpaquePointer, _ index: Int32) -> Double? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return sqlite3_column_double(statement, index)
}

func columnData(_ statement: OpaquePointer, _ index: Int32) -> Data? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    let count = Int(sqlite3_column_bytes(statement, index))
    guard count > 0, let pointer = sqlite3_column_blob(statement, index) else {
        return Data()
    }
    return Data(bytes: pointer, count: count)
}
