import Foundation

public enum ReminderStatus: String, Codable, CaseIterable, Sendable {
    case pending, completed, cancelled
    public var label: String {
        switch self {
        case .pending: return "待处理"
        case .completed: return "已完成"
        case .cancelled: return "已取消"
        }
    }
}

/// A user-approved action, not an inferred payment or an automatically scheduled promise.
/// entryID points to the evidence; its current canonical order is resolved when read.
public struct LedgerReminder: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var entryID: String
    public var title: String
    public var dueDate: String?
    public var sourceQuote: String?
    public var status: ReminderStatus
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, entryID: String, title: String, dueDate: String? = nil,
                sourceQuote: String? = nil, status: ReminderStatus = .pending,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.entryID = entryID; self.title = title; self.dueDate = dueDate
        self.sourceQuote = sourceQuote; self.status = status; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    public func validated() throws -> LedgerReminder {
        var result = self
        result.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.title.isEmpty, result.title.count <= 200 else {
            throw LedgerError.message("请填写 1–200 字的待办事项。")
        }
        if let date = dueDate, !BillExtraction.isValidDate(date) {
            throw LedgerError.message("处理日期请使用 YYYY-MM-DD，或留空待定。")
        }
        return result
    }
}

public enum ReminderPeriod: String, CaseIterable, Identifiable, Sendable {
    case today = "今天", week = "本周", month = "本月", all = "全部待办"
    public var id: String { rawValue }
}

/// Calendar date semantics in the Mac's local time zone. Weeks always start Monday.
/// ISO date strings are compared as dates, never parsed as UTC instants.
public struct ReminderAgenda: Sendable {
    public let reminders: [LedgerReminder]
    public let today: String
    public let weekEnd: String
    public let monthEnd: String

    public init(reminders: [LedgerReminder], now: Date = Date(), timeZone: TimeZone = .current) {
        self.reminders = reminders
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        today = formatter.string(from: now)
        weekEnd = formatter.string(from: calendar.dateInterval(of: .weekOfYear, for: now)!.end)
        monthEnd = formatter.string(from: calendar.dateInterval(of: .month, for: now)!.end)
    }

    public var pending: [LedgerReminder] { sorted(reminders.filter { $0.status == .pending }) }
    public var overdue: [LedgerReminder] { pending.filter { ($0.dueDate ?? today) < today } }
    public var undated: [LedgerReminder] { pending.filter { $0.dueDate == nil } }
    public var history: [LedgerReminder] {
        reminders.filter { $0.status != .pending }.sorted { $0.updatedAt > $1.updatedAt }
    }
    /// Overdue and undated actions are presented separately, never counted three times.
    public func items(in period: ReminderPeriod) -> [LedgerReminder] {
        pending.filter { reminder in
            guard let due = reminder.dueDate, due >= today else { return false }
            switch period {
            case .today: return due == today
            case .week: return due < weekEnd
            case .month: return due < monthEnd
            case .all: return true
            }
        }
    }
    private func sorted(_ items: [LedgerReminder]) -> [LedgerReminder] {
        items.sorted {
            if $0.dueDate != $1.dueDate { return ($0.dueDate ?? "9999") < ($1.dueDate ?? "9999") }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id < $1.id
        }
    }
}
