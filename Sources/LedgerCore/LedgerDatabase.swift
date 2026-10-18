import Foundation
import CSQLite

public actor LedgerDatabase {
    private let connection: SQLiteLedger
    public let root: URL
    public var imagesDirectory: URL { root.appendingPathComponent("Images", isDirectory: true) }
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PromiseLedger", isDirectory: true)
    }
    public init(root: URL = LedgerDatabase.defaultRoot) throws {
        self.root = root
        connection = try SQLiteLedger(root: root)
    }
    public func list() throws -> [LedgerEntry] { try connection.list() }
    public func enqueue(_ entry: LedgerEntry) throws -> String { try connection.enqueue(entry) }
    public func reminders() throws -> [LedgerReminder] { try connection.reminders() }
    @discardableResult public func addReminder(entryID: String, title: String, dueDate: String?, sourceQuote: String? = nil) throws -> LedgerReminder {
        try connection.addReminder(entryID: entryID, title: title, dueDate: dueDate, sourceQuote: sourceQuote)
    }
    public func editReminder(id: String, title: String, dueDate: String?) throws {
        try connection.editReminder(id: id, title: title, dueDate: dueDate)
    }
    public func setReminderStatus(id: String, status: ReminderStatus) throws {
        try connection.setReminderStatus(id: id, status: status)
    }
    @discardableResult public func save(_ entry: LedgerEntry) throws -> LedgerEntry { try connection.save(entry) }
    @discardableResult public func linkDuplicate(_ id: String, to target: String) throws -> LedgerEntry {
        try connection.linkDuplicate(id, to: target)
    }
    @discardableResult public func keepAsSeparateOrder(_ id: String) throws -> LedgerEntry {
        try connection.keepAsSeparateOrder(id)
    }
}

/// Actor-isolated connection; IMMEDIATE transactions also serialize other connections.
private final class SQLiteLedger {
    private var handle: OpaquePointer?
    private let root: URL
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let columns = "id,created_at,source,image_filename,image_hash,state,ocr_text,extraction_json,error,model,order_key,duplicate_of,duplicate_candidates_json,distinct_fingerprint,prompt_version"

    init(root: URL) throws {
        self.root = root
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.createDirectory(at: root.appendingPathComponent("Images"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = root.appendingPathComponent("ledger.sqlite3").path
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }; handle = nil
            throw LedgerError.message("无法打开本地账本数据库。")
        }
        do {
            sqlite3_busy_timeout(handle, 5_000)
            try execute("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")
            let statement = try prepare("PRAGMA user_version")
            guard sqlite3_step(statement) == SQLITE_ROW else { sqlite3_finalize(statement); throw databaseError() }
            let version = sqlite3_column_int(statement, 0)
            sqlite3_finalize(statement)
            guard version <= 3 else { throw LedgerError.message("数据库由更新版本创建，请升级应用；不会降级或覆盖数据。") }
            if version > 0 && version < 3 { try backup(version: version) }
            if version < 2 {
                try transaction {
                    try execute("""
                    CREATE TABLE IF NOT EXISTS entries (
                        id TEXT PRIMARY KEY, created_at REAL NOT NULL, source TEXT NOT NULL,
                        image_filename TEXT NOT NULL, image_hash TEXT NOT NULL UNIQUE,
                        state TEXT NOT NULL, ocr_text TEXT NOT NULL DEFAULT '', extraction_json TEXT,
                        error TEXT, model TEXT
                    );
                    CREATE INDEX IF NOT EXISTS entries_created_at ON entries(created_at DESC);
                    ALTER TABLE entries ADD COLUMN order_key TEXT;
                    ALTER TABLE entries ADD COLUMN duplicate_of TEXT REFERENCES entries(id);
                    ALTER TABLE entries ADD COLUMN duplicate_candidates_json TEXT NOT NULL DEFAULT '[]';
                    ALTER TABLE entries ADD COLUMN distinct_fingerprint TEXT;
                    ALTER TABLE entries ADD COLUMN prompt_version TEXT;
                    """)
                    var canonical: [LedgerEntry] = []
                    let legacy = try list().sorted {
                        if ($0.state == .confirmed) != ($1.state == .confirmed) { return $0.state == .confirmed }
                        return $0.createdAt < $1.createdAt
                    }
                    for original in legacy {
                        let resolved = resolve(original, against: canonical)
                        try write(resolved)
                        canonical.append(resolved)
                    }
                    try execute("""
                    CREATE UNIQUE INDEX entries_unique_order ON entries(order_key)
                      WHERE order_key IS NOT NULL AND duplicate_of IS NULL;
                    CREATE INDEX entries_duplicate_of ON entries(duplicate_of);
                    PRAGMA user_version=2;
                    """)
                }
            }
            if version < 3 {
                try transaction {
                    try execute("""
                    CREATE TABLE reminders (
                        id TEXT PRIMARY KEY, entry_id TEXT NOT NULL REFERENCES entries(id),
                        title TEXT NOT NULL, due_date TEXT, source_quote TEXT,
                        status TEXT NOT NULL CHECK(status IN ('pending','completed','cancelled')),
                        created_at REAL NOT NULL, updated_at REAL NOT NULL
                    );
                    CREATE INDEX reminders_due_date ON reminders(status,due_date);
                    CREATE INDEX reminders_entry ON reminders(entry_id);
                    PRAGMA user_version=3;
                    """)
                }
            }
            try execute("UPDATE entries SET state='queued', error=NULL WHERE state='processing';")
            for file in [path, path + "-wal", path + "-shm"] where manager.fileExists(atPath: file) {
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
            }
        } catch {
            sqlite3_close(handle); handle = nil
            throw error
        }
    }
    deinit { if let handle { sqlite3_close(handle) } }

    func list() throws -> [LedgerEntry] {
        let statement = try prepare("SELECT \(columns) FROM entries ORDER BY created_at DESC")
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
            let candidates = try JSONDecoder().decode([String].self, from: Data((string(statement, 12) ?? "[]").utf8))
            result.append(LedgerEntry(id: id, createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                source: source, imageFilename: filename, imageHash: hash, state: state,
                ocrText: string(statement, 6) ?? "", extraction: extraction, error: string(statement, 8), model: string(statement, 9),
                duplicateOf: string(statement, 11), duplicateCandidates: candidates, distinctFingerprint: string(statement, 13),
                promptVersion: string(statement, 14)))
        }
        return result
    }

    func enqueue(_ entry: LedgerEntry) throws -> String {
        let statement = try prepare("SELECT id FROM entries WHERE image_hash=?")
        defer { sqlite3_finalize(statement) }
        bind(entry.imageHash, to: statement, at: 1)
        let code = sqlite3_step(statement)
        if code == SQLITE_ROW {
            guard let identifier = string(statement, 0) else { throw databaseError() }
            return identifier
        }
        guard code == SQLITE_DONE else { throw databaseError() }
        return try save(entry).id
    }

    func reminders() throws -> [LedgerReminder] {
        let statement = try prepare("SELECT id,entry_id,title,due_date,source_quote,status,created_at,updated_at FROM reminders ORDER BY created_at")
        defer { sqlite3_finalize(statement) }
        var result: [LedgerReminder] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw databaseError() }
            guard let id = string(statement, 0), let entryID = string(statement, 1),
                  let title = string(statement, 2), let status = ReminderStatus(rawValue: string(statement, 5) ?? "") else {
                throw LedgerError.message("待办记录无法读取，请保留数据并联系开发者。")
            }
            result.append(LedgerReminder(id: id, entryID: entryID, title: title, dueDate: string(statement, 3),
                sourceQuote: string(statement, 4), status: status,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))))
        }
        return result
    }

    func addReminder(entryID: String, title: String, dueDate: String?, sourceQuote: String?) throws -> LedgerReminder {
        try transaction {
            let entries = try list()
            let root = try reminderRoot(entryID, entries: entries)
            guard entries.contains(where: { $0.id == root && $0.state == .confirmed }) else {
                throw LedgerError.message("请先确认账单入账，再添加待办。")
            }
            if let quote = sourceQuote {
                guard !quote.isEmpty, let evidence = entries.first(where: { $0.id == entryID }),
                      Evidence.contains(quote, in: evidence.ocrText) else {
                    throw LedgerError.message("待办的承诺原文与凭据不一致，请重新打开核对。")
                }
            }
            let reminder = try LedgerReminder(entryID: entryID, title: title, dueDate: dueDate, sourceQuote: sourceQuote).validated()
            let all = try reminders()
            // IMMEDIATE transaction also serializes repeated clicks / other connections.
            // Source IDs may differ, but linked screenshots belong to one canonical order.
            if let existing = try matchingReminder(reminder, in: all, entries: entries) { return existing }
            try writeReminder(reminder)
            return reminder
        }
    }

    func editReminder(id: String, title: String, dueDate: String?) throws {
        try transaction {
            let all = try reminders()
            guard var reminder = all.first(where: { $0.id == id }) else { throw databaseError() }
            reminder.title = title; reminder.dueDate = dueDate; reminder.updatedAt = Date()
            reminder = try reminder.validated()
            if try matchingReminder(reminder, in: all.filter { $0.id != id }, entries: list()) != nil {
                throw LedgerError.message("已有相同事项和日期的待办，请编辑已有待办。")
            }
            try writeReminder(reminder)
        }
    }

    func setReminderStatus(id: String, status: ReminderStatus) throws {
        try transaction {
            guard var reminder = try reminders().first(where: { $0.id == id }) else { throw databaseError() }
            reminder.status = status; reminder.updatedAt = Date()
            try writeReminder(reminder)
        }
    }

    private func reminderRoot(_ id: String, entries: [LedgerEntry]) throws -> String {
        try rootID(id, in: entries, excluding: "")
    }

    private func matchingReminder(_ reminder: LedgerReminder, in all: [LedgerReminder], entries: [LedgerEntry]) throws -> LedgerReminder? {
        let root = try reminderRoot(reminder.entryID, entries: entries)
        let normalize: (String) -> String = {
            $0.precomposedStringWithCompatibilityMapping.filter { !$0.isWhitespace }.lowercased()
        }
        for existing in all where existing.dueDate == reminder.dueDate && normalize(existing.title) == normalize(reminder.title) {
            if try reminderRoot(existing.entryID, entries: entries) == root { return existing }
        }
        return nil
    }

    private func writeReminder(_ reminder: LedgerReminder) throws {
        let statement = try prepare("""
        INSERT INTO reminders(id,entry_id,title,due_date,source_quote,status,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET title=excluded.title,due_date=excluded.due_date,
          status=excluded.status,updated_at=excluded.updated_at
        """)
        defer { sqlite3_finalize(statement) }
        bind(reminder.id, to: statement, at: 1); bind(reminder.entryID, to: statement, at: 2)
        bind(reminder.title, to: statement, at: 3); bind(reminder.dueDate, to: statement, at: 4)
        bind(reminder.sourceQuote, to: statement, at: 5); bind(reminder.status.rawValue, to: statement, at: 6)
        sqlite3_bind_double(statement, 7, reminder.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 8, reminder.updatedAt.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    func save(_ entry: LedgerEntry) throws -> LedgerEntry {
        try transaction {
            let entries = try list()
            var incoming = entry
            // A stale worker/UI cannot turn an already linked source into a second bill.
            if let stored = entries.first(where: { $0.id == incoming.id }), let target = stored.duplicateOf {
                incoming.duplicateOf = target
            }
            if let target = incoming.duplicateOf {
                incoming.duplicateOf = try rootID(target, in: entries, excluding: incoming.id)
            }
            let resolved = resolve(incoming, against: entries)
            try write(resolved)
            if let target = resolved.duplicateOf { try retargetChildren(of: resolved.id, to: target) }
            return resolved
        }
    }

    func linkDuplicate(_ id: String, to target: String) throws -> LedgerEntry {
        try transaction {
            let entries = try list()
            guard var entry = entries.first(where: { $0.id == id }), entry.state == .duplicateReview else {
                throw LedgerError.message("该记录已变化，请重新打开后核对。")
            }
            let canonicalID = try rootID(target, in: entries, excluding: id)
            guard entries.contains(where: { $0.id == canonicalID && $0.extraction != nil }) else { throw databaseError() }
            entry.state = .duplicate; entry.duplicateOf = canonicalID; entry.duplicateCandidates = []
            entry.distinctFingerprint = nil
            try write(entry)
            try retargetChildren(of: id, to: canonicalID)
            return entry
        }
    }

    func keepAsSeparateOrder(_ id: String) throws -> LedgerEntry {
        try transaction {
            let entries = try list()
            guard var entry = entries.first(where: { $0.id == id }), entry.state == .duplicateReview, let bill = entry.extraction else {
                throw LedgerError.message("该记录已变化，请重新打开后核对。")
            }
            switch OrderIdentity.match(entry, against: entries) {
            case .exact: throw LedgerError.message("订单标识已与已有订单一致，不能重复入账；请关联原订单。")
            case .possible(let candidates): entry.distinctFingerprint = OrderIdentity.distinctToken(bill, candidates: candidates)
            case .none: entry.distinctFingerprint = nil
            }
            entry.state = .needsReview; entry.duplicateCandidates = []
            try write(entry)
            return entry
        }
    }

    private func resolve(_ original: LedgerEntry, against entries: [LedgerEntry]) -> LedgerEntry {
        var entry = original
        if entry.duplicateOf != nil { entry.state = .duplicate; entry.duplicateCandidates = []; return entry }
        guard entry.extraction != nil, [.needsReview, .confirmed, .duplicateReview].contains(entry.state) else { return entry }
        switch OrderIdentity.match(entry, against: entries) {
        case .exact(let id):
            entry.state = .duplicate; entry.duplicateOf = id; entry.duplicateCandidates = []; entry.distinctFingerprint = nil
        case .possible(let candidates):
            let token = OrderIdentity.distinctToken(entry.extraction!, candidates: candidates)
            if entry.distinctFingerprint != token { entry.state = .duplicateReview; entry.duplicateCandidates = candidates }
            else { entry.duplicateCandidates = [] }
        case .none: entry.duplicateCandidates = []
        }
        return entry
    }

    private func write(_ entry: LedgerEntry) throws {
        let statement = try prepare("""
        INSERT INTO entries(\(columns)) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET state=excluded.state,ocr_text=excluded.ocr_text,
          extraction_json=excluded.extraction_json,error=excluded.error,model=excluded.model,
          order_key=excluded.order_key,duplicate_of=excluded.duplicate_of,
          duplicate_candidates_json=excluded.duplicate_candidates_json,distinct_fingerprint=excluded.distinct_fingerprint,
          prompt_version=excluded.prompt_version
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
        let ownsOrder = entry.duplicateOf == nil && [.needsReview, .confirmed, .duplicateReview].contains(entry.state)
        bind(ownsOrder ? OrderIdentity.strongKey(entry) : nil, to: statement, at: 11)
        bind(entry.duplicateOf, to: statement, at: 12)
        bind(String(decoding: try JSONEncoder().encode(entry.duplicateCandidates), as: UTF8.self), to: statement, at: 13)
        bind(entry.distinctFingerprint, to: statement, at: 14)
        bind(entry.promptVersion, to: statement, at: 15)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func rootID(_ id: String, in entries: [LedgerEntry], excluding source: String) throws -> String {
        var current = id
        var visited: Set<String> = [source]
        while let entry = entries.first(where: { $0.id == current }) {
            guard visited.insert(current).inserted else { throw LedgerError.message("不能循环关联订单。") }
            if let parent = entry.duplicateOf { current = parent } else { return current }
        }
        throw LedgerError.message("找不到要关联的原订单，请刷新后重试。")
    }
    private func retargetChildren(of id: String, to target: String) throws {
        let statement = try prepare("UPDATE entries SET duplicate_of=? WHERE duplicate_of=?")
        defer { sqlite3_finalize(statement) }
        bind(target, to: statement, at: 1); bind(id, to: statement, at: 2)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }
    private func backup(version: Int32) throws {
        let directory = root.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("ledger-v\(version)-\(UUID().uuidString).sqlite3").path
        var destination: OpaquePointer?
        guard sqlite3_open_v2(path, &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let destination else {
            if let destination { sqlite3_close(destination) }
            throw LedgerError.message("升级前备份创建失败，未修改旧数据。")
        }
        defer { sqlite3_close(destination) }
        guard let backup = sqlite3_backup_init(destination, "main", handle, "main") else { throw databaseError() }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else { throw LedgerError.message("升级前备份未完成，未修改旧数据。") }
        // Make the snapshot independently readable without WAL/SHM sidecars.
        guard sqlite3_exec(destination, "PRAGMA journal_mode=DELETE;", nil, nil, nil) == SQLITE_OK else {
            throw LedgerError.message("升级前备份尚未转为独立文件，未修改旧数据。")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do { let result = try body(); try execute("COMMIT;"); return result }
        catch { try? execute("ROLLBACK;"); throw error }
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw databaseError() }
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
    private func databaseError() -> LedgerError { .message("无法读写本地数据，请检查磁盘空间和文件权限后重试。") }
}
