import Foundation
import CSQLite
import LedgerCore

enum ReminderTests {
    static let cases: [(String, () async throws -> Void)] = [
        ("reminder title/date validation", { try validation() }),
        ("Monday weeks, calendar months and overdue separation", { try calendarWindows() }),
        ("Sunday/month/year boundary and leap day", { try boundaries() }),
        ("local timezone and DST date-only semantics", { try timeZones() }),
        ("completed/cancelled/undated reminders", { try statuses() }),
        ("reminder approval, persistence, edit and completion", { try await storage() }),
        ("unconfirmed/ungrounded reminders rejected", { try await approval() }),
        ("linked evidence cannot duplicate reminder actions", { try await linkedDuplicates() }),
        ("concurrent reminder insertion is idempotent", { try await concurrent() }),
        ("v2 migration preserves records and standalone backup", { try await migration() }),
        ("newer database refuses downgrade", { try newerSchema() })
    ]
    static let zone = TimeZone(identifier: "Asia/Shanghai")!
    static func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    static func item(_ due: String?, status: ReminderStatus = .pending) -> LedgerReminder {
        LedgerReminder(entryID: "fixture", title: "虚构跟进事项", dueDate: due, status: status)
    }
    static func agenda(_ due: [String?], now: String = "2026-10-14T02:00:00Z") -> ReminderAgenda {
        ReminderAgenda(reminders: due.map { item($0) }, now: date(now), timeZone: zone)
    }
    static func validation() throws {
        try expect(try LedgerReminder(entryID: "id", title: "  核对退款  ").validated().title == "核对退款")
        try expectThrows { _ = try LedgerReminder(entryID: "id", title: " \n").validated() }
        try expectThrows { _ = try LedgerReminder(entryID: "id", title: String(repeating: "字", count: 201)).validated() }
        try expectThrows { _ = try item("2026-02-30").validated() }
        try expectThrows { _ = try item("2026-2-3").validated() }
        try expect(try item(nil).validated().dueDate == nil)
    }
    static func calendarWindows() throws {
        let a = agenda(["2026-10-12", "2026-10-14", "2026-10-18", "2026-10-19", "2026-10-31", "2026-11-01", nil])
        try expect(a.today == "2026-10-14" && a.weekEnd == "2026-10-19" && a.monthEnd == "2026-11-01")
        try expect(a.overdue.count == 1 && a.undated.count == 1)
        try expect(a.items(in: .today).count == 1 && a.items(in: .week).count == 2 && a.items(in: .month).count == 4)
        try expect(a.items(in: .all).count == 5)
        let upcoming = Set(a.items(in: .all).map(\.id))
        try expect(a.overdue.allSatisfy { !upcoming.contains($0.id) })
    }
    static func boundaries() throws {
        let sunday = agenda(["2026-10-18", "2026-10-19"], now: "2026-10-18T15:59:59Z")
        try expect(sunday.items(in: .week).count == 1)
        let monday = agenda(["2026-10-18", "2026-10-19"], now: "2026-10-18T16:00:00Z")
        try expect(monday.today == "2026-10-19" && monday.overdue.count == 1 && monday.items(in: .week).count == 1)
        let yearEnd = agenda(["2026-12-31", "2027-01-01"], now: "2026-12-31T02:00:00Z")
        try expect(yearEnd.items(in: .month).count == 1 && yearEnd.items(in: .week).count == 2)
        let leap = agenda(["2028-02-29", "2028-03-01"], now: "2028-02-29T02:00:00Z")
        try expect(leap.items(in: .month).count == 1 && leap.monthEnd == "2028-03-01")
    }
    static func timeZones() throws {
        let instant = date("2026-10-18T23:30:00Z")
        let actions = [item("2026-10-19")]
        let shanghai = ReminderAgenda(reminders: actions, now: instant, timeZone: zone)
        let la = ReminderAgenda(reminders: actions, now: instant, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        try expect(shanghai.items(in: .today).count == 1 && la.items(in: .today).isEmpty)
        let dst = ReminderAgenda(reminders: [item("2026-03-08"), item("2026-03-09")],
            now: date("2026-03-08T10:30:00Z"), timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        try expect(dst.items(in: .today).count == 1 && dst.items(in: .week).count == 1)
    }
    static func statuses() throws {
        let a = ReminderAgenda(reminders: [item("2026-10-14"), item("2026-10-14", status: .completed),
            item("2026-10-13", status: .cancelled), item(nil)], now: date("2026-10-14T02:00:00Z"), timeZone: zone)
        try expect(a.pending.count == 2 && a.items(in: .today).count == 1 && a.overdue.isEmpty)
        try expect(a.history.count == 2 && a.undated.count == 1)
    }
    static func storage() async throws {
        let root = OrderDedupTests.temporary("Reminders")
        let store = try LedgerDatabase(root: root)
        let entry = try await store.save(OrderDedupTests.order(state: .confirmed))
        let action = try await store.addReminder(entryID: entry.id, title: "核对退款'); DROP TABLE reminders; --", dueDate: "2026-11-01")
        try await store.editReminder(id: action.id, title: "联系客服", dueDate: nil)
        try await store.setReminderStatus(id: action.id, status: .completed)
        let reopened = try LedgerDatabase(root: root)
        let actions = try await reopened.reminders()
        try expect(actions.count == 1 && actions[0].title == "联系客服" && actions[0].dueDate == nil && actions[0].status == .completed)
        try await store.setReminderStatus(id: action.id, status: .pending)
        let restored = try await store.reminders()
        try expect(restored[0].status == .pending)
    }
    static func approval() async throws {
        let store = try LedgerDatabase(root: OrderDedupTests.temporary("ReminderApproval"))
        var entry = try await store.save(OrderDedupTests.order())
        var rejected = false
        do { _ = try await store.addReminder(entryID: entry.id, title: "跟进", dueDate: nil) } catch { rejected = true }
        try expect(rejected)
        entry.state = .confirmed
        _ = try await store.save(entry)
        rejected = false
        do { _ = try await store.addReminder(entryID: entry.id, title: "跟进", dueDate: nil, sourceQuote: "凭空承诺") } catch { rejected = true }
        try expect(rejected)
        let reminders = try await store.reminders()
        try expect(reminders.isEmpty, "Unapproved or ungrounded promises must never be automatically tracked")
    }
    static func linkedDuplicates() async throws {
        let store = try LedgerDatabase(root: OrderDedupTests.temporary("LinkedReminders"))
        let entry = try await store.save(OrderDedupTests.order(state: .confirmed))
        let evidence = try await store.save(OrderDedupTests.order())
        let a = try await store.addReminder(entryID: entry.id, title: " 核对退款 ", dueDate: "2026-10-20")
        let b = try await store.addReminder(entryID: evidence.id, title: "核对 退款", dueDate: "2026-10-20")
        try expect(a.id == b.id)
        try await store.setReminderStatus(id: a.id, status: .completed)
        let c = try await store.addReminder(entryID: evidence.id, title: "核对退款", dueDate: "2026-10-20")
        try expect(c.id == a.id && c.status == .completed, "Repeated add cannot resurrect completed actions")
        let different = try await store.addReminder(entryID: entry.id, title: "申请价保", dueDate: "2026-10-20")
        var rejected = false
        do { try await store.editReminder(id: different.id, title: "核对退款", dueDate: "2026-10-20") } catch { rejected = true }
        try expect(rejected)
        let rows = try await store.reminders()
        try expect(rows.count == 2)
    }
    static func concurrent() async throws {
        let root = OrderDedupTests.temporary("ConcurrentReminders")
        let a = try LedgerDatabase(root: root)
        let b = try LedgerDatabase(root: root)
        let entry = try await a.save(OrderDedupTests.order(state: .confirmed))
        async let first = a.addReminder(entryID: entry.id, title: "核验服务", dueDate: nil)
        async let second = b.addReminder(entryID: entry.id, title: "核验服务", dueDate: nil)
        let results = try await (first, second)
        try expect(results.0.id == results.1.id)
        let all = try await a.reminders()
        try expect(all.count == 1)
    }
    static func migration() async throws {
        let root = OrderDedupTests.temporary("ReminderV2Migration")
        var entry: LedgerEntry!
        do {
            let initial = try LedgerDatabase(root: root)
            entry = try await initial.save(OrderDedupTests.order(state: .confirmed))
        }
        var raw: OpaquePointer?
        try expect(sqlite3_open(root.appendingPathComponent("ledger.sqlite3").path, &raw) == SQLITE_OK)
        // This is an isolated synthetic v2 fixture, never the user's database.
        try expect(sqlite3_exec(raw, "DROP TABLE reminders; PRAGMA user_version=2;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)
        let store = try LedgerDatabase(root: root)
        let rows = try await store.list()
        let actions = try await store.reminders()
        try expect(rows.count == 1 && rows[0].id == entry.id && rows[0].extraction == entry.extraction && actions.isEmpty)
        let backups = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "sqlite3" }
        try expect(backups.count == 1 && backups[0].lastPathComponent.hasPrefix("ledger-v2-"))
        let standalone = root.appendingPathComponent("standalone-v2.sqlite3")
        try FileManager.default.copyItem(at: backups[0], to: standalone)
        try expect(sqlite3_open_v2(standalone.path, &raw, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        var query: OpaquePointer?
        try expect(sqlite3_prepare_v2(raw, "PRAGMA user_version", -1, &query, nil) == SQLITE_OK)
        try expect(sqlite3_step(query) == SQLITE_ROW && sqlite3_column_int(query, 0) == 2)
        sqlite3_finalize(query); sqlite3_close(raw)
        _ = try LedgerDatabase(root: root)
        let after = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "sqlite3" }
        try expect(after.count == 1)
    }
    static func newerSchema() throws {
        let root = OrderDedupTests.temporary("ReminderFuture")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var raw: OpaquePointer?
        try expect(sqlite3_open(root.appendingPathComponent("ledger.sqlite3").path, &raw) == SQLITE_OK)
        try expect(sqlite3_exec(raw, "PRAGMA user_version=4;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)
        try expectThrows { _ = try LedgerDatabase(root: root) }
    }
}
