import Foundation
import MiniDiTCore
import SQLite3

/// Small per-file transactions keep checkpoints durable without rewriting the
/// project's entire history for every imported file. Owned by the main-actor store.
final class JournalDatabase {
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let failure = error()
            sqlite3_close(handle); handle = nil
            throw failure
        }
        do {
            sqlite3_busy_timeout(handle, 1500)
            let version = try integer("PRAGMA user_version")
            guard version == 0 || version == 1 else { throw Failure(message: String(localized: "导入记录版本较新，请使用更新的 MiniDiT。")) }
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
            try execute("CREATE TABLE IF NOT EXISTS batches (id TEXT PRIMARY KEY NOT NULL, payload TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS files (batch_id TEXT NOT NULL, id TEXT NOT NULL, ordinal INTEGER NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(batch_id, id))")
            try execute("PRAGMA user_version = 1")
        } catch {
            sqlite3_close(handle); handle = nil
            throw error
        }
    }

    deinit { sqlite3_close(handle) }

    func load() throws -> [ImportBatchRecord] {
        let batchQuery = try prepare("SELECT payload FROM batches ORDER BY rowid")
        defer { sqlite3_finalize(batchQuery) }
        var result: [ImportBatchRecord] = []
        while true {
            let step = sqlite3_step(batchQuery)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw error() }
            var batch = try JSONDecoder().decode(ImportBatchRecord.self, from: data(batchQuery, column: 0))
            let files = try prepare("SELECT payload FROM files WHERE batch_id = ? ORDER BY ordinal")
            defer { sqlite3_finalize(files) }
            try bind(batch.id.uuidString, at: 1, to: files)
            while true {
                let step = sqlite3_step(files)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else { throw error() }
                batch.files.append(try JSONDecoder().decode(ImportedFileRecord.self, from: data(files, column: 0)))
            }
            result.append(batch)
        }
        return result
    }

    func save(previous: [ImportBatchRecord], next: [ImportBatchRecord]) throws {
        let old = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        try execute("BEGIN IMMEDIATE")
        var committed = false
        defer { if !committed { try? execute("ROLLBACK") } }
        let header = try prepare("INSERT INTO batches(id, payload) VALUES(?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload")
        defer { sqlite3_finalize(header) }
        let file = try prepare("INSERT INTO files(batch_id, id, ordinal, payload) VALUES(?, ?, ?, ?) ON CONFLICT(batch_id, id) DO UPDATE SET ordinal = excluded.ordinal, payload = excluded.payload")
        defer { sqlite3_finalize(file) }
        for batch in next where old[batch.id] != batch {
            var metadata = batch; metadata.files = []
            var oldMetadata = old[batch.id]; oldMetadata?.files = []
            if oldMetadata != metadata {
                try bind(batch.id.uuidString, at: 1, to: header)
                try bind(String(decoding: JSONEncoder().encode(metadata), as: UTF8.self), at: 2, to: header)
                try run(header)
            }
            let oldFiles = Dictionary((old[batch.id]?.files ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for (index, record) in batch.files.enumerated() where oldFiles[record.id] != record {
                try bind(batch.id.uuidString, at: 1, to: file)
                try bind(record.id, at: 2, to: file)
                guard sqlite3_bind_int64(file, 3, Int64(index)) == SQLITE_OK else { throw error() }
                try bind(String(decoding: JSONEncoder().encode(record), as: UTF8.self), at: 4, to: file)
                try run(file)
            }
        }
        try execute("COMMIT")
        committed = true
    }

    private func data(_ statement: OpaquePointer, column: Int32) throws -> Data {
        guard let bytes = sqlite3_column_text(statement, column) else { throw Failure(message: String(localized: "导入记录缺少内容。")) }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        return statement
    }
    private func bind(_ text: String, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, index, text, -1, transient) == SQLITE_OK else { throw error() }
    }
    private func run(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }
    private func integer(_ sql: String) throws -> Int32 {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw error() }
        return sqlite3_column_int(statement, 0)
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    private func error() -> Failure {
        Failure(message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? String(localized: "无法打开导入记录。"))
    }
}
