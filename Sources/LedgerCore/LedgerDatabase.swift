import Foundation
import CSQLite

public actor LedgerDatabase {
    private var handle: OpaquePointer?
    public let root: URL
    public var imagesDirectory: URL { root.appendingPathComponent("Images", isDirectory: true) }
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PromiseLedger", isDirectory: true)
    }

    public init(root: URL = LedgerDatabase.defaultRoot) throws {
        self.root = root
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.createDirectory(at: root.appendingPathComponent("Images"), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let path = root.appendingPathComponent("ledger.sqlite3").path
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw LedgerError.message("无法打开本地账本数据库。")
        }
        sqlite3_busy_timeout(handle, 5_000)
        let schema = """
        PRAGMA journal_mode=WAL;
        PRAGMA foreign_keys=ON;
        CREATE TABLE IF NOT EXISTS entries (
            id TEXT PRIMARY KEY, created_at REAL NOT NULL, source TEXT NOT NULL,
            image_filename TEXT NOT NULL, image_hash TEXT NOT NULL UNIQUE,
            state TEXT NOT NULL, ocr_text TEXT NOT NULL DEFAULT '', extraction_json TEXT,
            error TEXT, model TEXT
        );
        CREATE INDEX IF NOT EXISTS entries_created_at ON entries(created_at DESC);
        PRAGMA user_version=1;
        UPDATE entries SET state='queued', error=NULL WHERE state='processing';
        """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle); handle = nil
            throw LedgerError.message("初始化本地账本失败。")
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        for auxiliary in [path + "-wal", path + "-shm"] where manager.fileExists(atPath: auxiliary) {
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auxiliary)
        }
    }

    deinit { if let handle { sqlite3_close(handle) } }

    public func list() throws -> [LedgerEntry] {
        let statement = try prepare("SELECT id,created_at,source,image_filename,image_hash,state,ocr_text,extraction_json,error,model FROM entries ORDER BY created_at DESC")
        defer { sqlite3_finalize(statement) }
        var result: [LedgerEntry] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw databaseError() }
            guard let id = string(statement, 0), let source = EntrySource(rawValue: string(statement, 2) ?? ""),
                  let filename = string(statement, 3), let hash = string(statement, 4),
                  let state = EntryState(rawValue: string(statement, 5) ?? "") else {
                throw LedgerError.message("数据库中有无法读取的记录，请保留数据并联系开发者。")
            }
            let extraction = try string(statement, 7).map { try JSONDecoder().decode(BillExtraction.self, from: Data($0.utf8)) }
            result.append(LedgerEntry(id: id, createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                source: source, imageFilename: filename, imageHash: hash, state: state,
                ocrText: string(statement, 6) ?? "", extraction: extraction, error: string(statement, 8), model: string(statement, 9)))
        }
        return result
    }

    public func save(_ entry: LedgerEntry) throws {
        let statement = try prepare("""
        INSERT INTO entries(id,created_at,source,image_filename,image_hash,state,ocr_text,extraction_json,error,model)
        VALUES(?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET state=excluded.state,ocr_text=excluded.ocr_text,
          extraction_json=excluded.extraction_json,error=excluded.error,model=excluded.model
        """)
        defer { sqlite3_finalize(statement) }
        bind(entry.id, to: statement, at: 1)
        sqlite3_bind_double(statement, 2, entry.createdAt.timeIntervalSince1970)
        bind(entry.source.rawValue, to: statement, at: 3)
        bind(entry.imageFilename, to: statement, at: 4)
        bind(entry.imageHash, to: statement, at: 5)
        bind(entry.state.rawValue, to: statement, at: 6)
        bind(entry.ocrText, to: statement, at: 7)
        let json = try entry.extraction.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        bind(json, to: statement, at: 8)
        bind(entry.error, to: statement, at: 9)
        bind(entry.model, to: statement, at: 10)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        return statement
    }
    private func bind(_ text: String?, to statement: OpaquePointer, at index: Int32) {
        if let text { _ = text.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) } }
        else { sqlite3_bind_null(statement, index) }
    }
    private func string(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }
    private func databaseError() -> LedgerError { .message("本地数据库操作失败。原始图片不会被删除，请重试。") }
}
