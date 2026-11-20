import CoreKit
import Foundation
import LLMKit

/// 会话与事件日志的持久化。
///
/// 设计要点：
/// - 事件只追加，`seq` 按会话单调递增；
/// - 消息由 `SurfaceProjection` 从事件折叠，不单独存"当前对话"；
/// - 所有写操作走事务，`seq` 分配受 `BEGIN IMMEDIATE` 保护。
public actor SessionStore {
    private let db: Database
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    static let schemaVersion: Int32 = 2

    public init(url: URL) throws {
        db = try Database(path: url.path)
        try Self.migrate(db)
    }

    /// 测试与预览用：完全在内存里。
    public static func inMemory() throws -> SessionStore {
        try SessionStore(unsafePath: ":memory:")
    }

    private init(unsafePath: String) throws {
        db = try Database(path: unsafePath)
        try Self.migrate(db)
    }

    public func close() {
        // Database 在 deinit 里关闭；这里只做显式语义。
    }

    // MARK: - 迁移

    private static func migrate(_ db: Database) throws {
        var version = db.userVersion
        guard version < schemaVersion else { return }

        if version < 1 {
            do {
                try db.transaction {
                    try db.execute("""
                    CREATE TABLE IF NOT EXISTS session (
                      id TEXT PRIMARY KEY,
                      title TEXT NOT NULL,
                      created_at REAL NOT NULL,
                      updated_at REAL NOT NULL,
                      provider TEXT,
                      model TEXT,
                      archived INTEGER NOT NULL DEFAULT 0
                    );

                    CREATE TABLE IF NOT EXISTS event (
                      session_id TEXT NOT NULL,
                      seq INTEGER NOT NULL,
                      time REAL NOT NULL,
                      kind TEXT NOT NULL,
                      payload BLOB NOT NULL,
                      surface_op TEXT,
                      PRIMARY KEY (session_id, seq)
                    );

                    CREATE INDEX IF NOT EXISTS event_kind ON event (session_id, kind);

                    CREATE TABLE IF NOT EXISTS usage_log (
                      id INTEGER PRIMARY KEY AUTOINCREMENT,
                      session_id TEXT,
                      turn INTEGER,
                      step INTEGER,
                      provider TEXT NOT NULL,
                      model TEXT NOT NULL,
                      purpose TEXT,
                      payload BLOB NOT NULL,
                      at REAL NOT NULL
                    );

                    CREATE TABLE IF NOT EXISTS provider_profile (
                      id TEXT PRIMARY KEY,
                      payload BLOB NOT NULL,
                      sort INTEGER NOT NULL DEFAULT 0,
                      updated_at REAL NOT NULL
                    );
                    """)
                    try db.setUserVersion(1)
                }
            } catch {
                throw StoreError.migration(from: version, message: String(describing: error))
            }
            version = 1
        }

        if version < 2 {
            // 老库不会重跑 v1 的建表语句，所以新增索引必须单独占一个版本，
            // 否则已安装的数据库永远拿不到它（而且没人会发现）。
            do {
                try db.transaction {
                    try db.execute(
                        "CREATE INDEX IF NOT EXISTS usage_session ON usage_log (session_id)"
                    )
                    try db.setUserVersion(2)
                }
            } catch {
                throw StoreError.migration(from: version, message: String(describing: error))
            }
            version = 2
        }
    }

    // MARK: - 会话

    @discardableResult
    public func createSession(
        title: String = "新对话",
        provider: String? = nil,
        model: String? = nil,
        at time: Date = Date()
    ) throws -> SessionSummary {
        let id = UUID()
        try db.run("""
        INSERT INTO session (id, title, created_at, updated_at, provider, model, archived)
        VALUES (?, ?, ?, ?, ?, ?, 0)
        """) {
            bind($0, 1, id.uuidString)
            bind($0, 2, title)
            bind($0, 3, time.timeIntervalSince1970)
            bind($0, 4, time.timeIntervalSince1970)
            bind($0, 5, provider)
            bind($0, 6, model)
        }
        return SessionSummary(
            id: id,
            title: title,
            createdAt: time,
            updatedAt: time,
            provider: provider,
            model: model
        )
    }

    public func sessions(includeArchived: Bool = false) throws -> [SessionSummary] {
        let sql = includeArchived
            ? "SELECT id, title, created_at, updated_at, provider, model, archived FROM session ORDER BY updated_at DESC"
            : "SELECT id, title, created_at, updated_at, provider, model, archived FROM session WHERE archived = 0 ORDER BY updated_at DESC"
        return try db.query(sql) { statement in
            guard let rawID = columnText(statement, 0), let id = UUID(uuidString: rawID) else {
                throw StoreError.corruptRow("session id")
            }
            return SessionSummary(
                id: id,
                title: columnText(statement, 1) ?? "",
                createdAt: Date(timeIntervalSince1970: columnDouble(statement, 2) ?? 0),
                updatedAt: Date(timeIntervalSince1970: columnDouble(statement, 3) ?? 0),
                provider: columnText(statement, 4),
                model: columnText(statement, 5),
                archived: (columnInt64(statement, 6) ?? 0) != 0
            )
        }
    }

    public func session(_ id: SessionID) throws -> SessionSummary? {
        try db.query("""
        SELECT id, title, created_at, updated_at, provider, model, archived FROM session WHERE id = ?
        """, { bind($0, 1, id.uuidString) }) { statement in
            SessionSummary(
                id: id,
                title: columnText(statement, 1) ?? "",
                createdAt: Date(timeIntervalSince1970: columnDouble(statement, 2) ?? 0),
                updatedAt: Date(timeIntervalSince1970: columnDouble(statement, 3) ?? 0),
                provider: columnText(statement, 4),
                model: columnText(statement, 5),
                archived: (columnInt64(statement, 6) ?? 0) != 0
            )
        }.first
    }

    public func rename(_ id: SessionID, to title: String) throws {
        try db.run("UPDATE session SET title = ?, updated_at = ? WHERE id = ?") {
            bind($0, 1, title)
            bind($0, 2, Date().timeIntervalSince1970)
            bind($0, 3, id.uuidString)
        }
    }

    public func setModel(_ id: SessionID, provider: String, model: String) throws {
        try db.run("UPDATE session SET provider = ?, model = ?, updated_at = ? WHERE id = ?") {
            bind($0, 1, provider)
            bind($0, 2, model)
            bind($0, 3, Date().timeIntervalSince1970)
            bind($0, 4, id.uuidString)
        }
    }

    public func delete(_ id: SessionID) throws {
        try db.transaction {
            try db.run("DELETE FROM event WHERE session_id = ?") { bind($0, 1, id.uuidString) }
            // usage_log 没有外键约束，不显式删就会变成永远查不到的孤儿行。
            try db.run("DELETE FROM usage_log WHERE session_id = ?") { bind($0, 1, id.uuidString) }
            try db.run("DELETE FROM session WHERE id = ?") { bind($0, 1, id.uuidString) }
        }
    }

    /// 所有事件里出现过的附件相对路径。
    ///
    /// 图片是内容寻址存储、多会话共享，所以删会话时**不能**直接删文件；
    /// 正确的做法是事后按引用集合清理（见 `AttachmentStore.prune`）。
    public func referencedAttachmentPaths() throws -> Set<String> {
        let rows = try db.query("SELECT payload FROM event") { statement -> String? in
            columnData(statement, 0).map { String(decoding: $0, as: UTF8.self) }
        }
        var paths = Set<String>()
        for payload in rows {
            guard let payload else { continue }
            paths.formUnion(Self.relativePaths(in: payload))
        }
        return paths
    }

    /// 从事件 JSON 里抠出所有 `"relativePath":"..."` 的值。
    ///
    /// 用文本扫描而不是完整解码：事件类型很多，逐个解码既慢又容易因
    /// 旧版本字段变动而整体失败；这里只关心一个字段的字符串值。
    static func relativePaths(in payload: String) -> Set<String> {
        var result = Set<String>()
        let marker = "\"relativePath\":\""
        var searchRange = payload.startIndex..<payload.endIndex
        while let found = payload.range(of: marker, range: searchRange) {
            let start = found.upperBound
            guard let end = payload[start...].firstIndex(of: "\"") else { break }
            // JSONEncoder 会把 `/` 转义成 `\/`，还原后再与磁盘路径比较。
            let raw = String(payload[start..<end])
            result.insert(raw.replacingOccurrences(of: "\\/", with: "/"))
            searchRange = payload.index(after: end)..<payload.endIndex
        }
        return result
    }

    // MARK: - 事件

    @discardableResult
    public func append(
        _ event: SessionEvent,
        to sessionID: SessionID,
        surfaceOp: SurfaceOp? = nil,
        at time: Date = Date()
    ) throws -> Int64 {
        let payload = try encoder.encode(event)
        let opData = try surfaceOp.map { try encoder.encode($0) }

        return try db.transaction {
            let next = try db.query(
                "SELECT COALESCE(MAX(seq), -1) + 1 FROM event WHERE session_id = ?",
                { bind($0, 1, sessionID.uuidString) }
            ) { columnInt64($0, 0) ?? 0 }.first ?? 0

            try db.run("""
            INSERT INTO event (session_id, seq, time, kind, payload, surface_op)
            VALUES (?, ?, ?, ?, ?, ?)
            """) {
                bind($0, 1, sessionID.uuidString)
                bind($0, 2, next)
                bind($0, 3, time.timeIntervalSince1970)
                bind($0, 4, event.kind)
                bind($0, 5, payload)
                bind($0, 6, opData)
            }
            try db.run("UPDATE session SET updated_at = ? WHERE id = ?") {
                bind($0, 1, time.timeIntervalSince1970)
                bind($0, 2, sessionID.uuidString)
            }
            return next
        }
    }

    public func records(for sessionID: SessionID, after seq: Int64 = -1) throws -> [SessionRecord] {
        let decoder = self.decoder
        return try db.query("""
        SELECT seq, time, payload, surface_op FROM event
        WHERE session_id = ? AND seq > ?
        ORDER BY seq ASC
        """, { statement in
            bind(statement, 1, sessionID.uuidString)
            bind(statement, 2, seq)
        }) { statement in
            guard let payload = columnData(statement, 2) else {
                throw StoreError.corruptRow("event payload missing")
            }
            let event = try decoder.decode(SessionEvent.self, from: payload)
            let op = try columnData(statement, 3).map {
                try decoder.decode(SurfaceOp.self, from: $0)
            }
            return SessionRecord(
                seq: columnInt64(statement, 0) ?? 0,
                sessionID: sessionID,
                time: Date(timeIntervalSince1970: columnDouble(statement, 1) ?? 0),
                event: event,
                surfaceOp: op
            )
        }
    }

    public func projection(for sessionID: SessionID) throws -> SurfaceProjection {
        SurfaceProjection.build(from: try records(for: sessionID))
    }

    // MARK: - 用量

    public func logUsage(
        sessionID: SessionID?,
        turn: Int?,
        step: Int?,
        provider: String,
        model: String,
        purpose: CallPurpose?,
        usage: TokenUsage,
        at time: Date = Date()
    ) throws {
        let payload = try encoder.encode(usage)
        try db.run("""
        INSERT INTO usage_log (session_id, turn, step, provider, model, purpose, payload, at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """) {
            bind($0, 1, sessionID?.uuidString)
            bind($0, 2, turn.map { Int64($0) })
            bind($0, 3, step.map { Int64($0) })
            bind($0, 4, provider)
            bind($0, 5, model)
            bind($0, 6, purpose?.rawValue)
            bind($0, 7, payload)
            bind($0, 8, time.timeIntervalSince1970)
        }
    }

    /// 最近一次调用的模型与用量。
    ///
    /// 连模型名一起返回：重开 App 后要按模型查价格表算成本，
    /// 只知道 token 数不知道模型的话，成本只能显示为空。
    public func latestUsage(for sessionID: SessionID) throws -> (model: String, usage: TokenUsage)? {
        let decoder = self.decoder
        let sql = "SELECT model, payload FROM usage_log WHERE session_id = ? ORDER BY id DESC LIMIT 1"
        return try db.query(sql, { bind($0, 1, sessionID.uuidString) }) { statement -> (String, TokenUsage)? in
            guard let payload = columnData(statement, 1),
                  let usage = try? decoder.decode(TokenUsage.self, from: payload)
            else { return nil }
            return (columnText(statement, 0) ?? "", usage)
        }.first ?? nil
    }

    /// 某会话累计用量。
    public func totalUsage(for sessionID: SessionID) throws -> TokenUsage? {
        let decoder = self.decoder
        let usages = try db.query(
            "SELECT payload FROM usage_log WHERE session_id = ?",
            { bind($0, 1, sessionID.uuidString) }
        ) { statement -> TokenUsage? in
            guard let payload = columnData(statement, 0) else { return nil }
            return try? decoder.decode(TokenUsage.self, from: payload)
        }
        let present = usages.compactMap { $0 }
        guard !present.isEmpty else { return nil }
        return present.reduce(TokenUsage(uncachedInputTokens: 0, outputTokens: 0)) { $0 + $1 }
    }

    // MARK: - 厂商配置

    public func saveProfile(_ profile: ProviderProfile, sort: Int = 0) throws {
        let payload = try encoder.encode(profile)
        try db.run("""
        INSERT INTO provider_profile (id, payload, sort, updated_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, sort = excluded.sort, updated_at = excluded.updated_at
        """) {
            bind($0, 1, profile.id)
            bind($0, 2, payload)
            bind($0, 3, Int64(sort))
            bind($0, 4, Date().timeIntervalSince1970)
        }
    }

    public func profiles() throws -> [ProviderProfile] {
        let decoder = self.decoder
        return try db.query("SELECT payload FROM provider_profile ORDER BY sort ASC, id ASC") { statement in
            guard let payload = columnData(statement, 0) else {
                throw StoreError.corruptRow("profile payload missing")
            }
            return try decoder.decode(ProviderProfile.self, from: payload)
        }
    }

    public func deleteProfile(id: String) throws {
        try db.run("DELETE FROM provider_profile WHERE id = ?") { bind($0, 1, id) }
    }
}
