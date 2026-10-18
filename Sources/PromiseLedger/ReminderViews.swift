import SwiftUI
import LedgerCore

struct ReminderDraft: Identifiable {
    let id = UUID()
    let entryID: String
    var existingID: String?
    var title: String
    var dueDate: String?
    var sourceQuote: String?
    var conditions: String?

    init(entry: LedgerEntry, promise: LedgerPromise? = nil) {
        entryID = entry.id
        title = promise?.userAction ?? promise?.text ?? ""
        dueDate = promise?.deadline
        sourceQuote = promise?.sourceQuote
        conditions = promise?.conditions
    }
    init(reminder: LedgerReminder) {
        entryID = reminder.entryID
        existingID = reminder.id
        title = reminder.title
        dueDate = reminder.dueDate
        sourceQuote = reminder.sourceQuote
    }
}

struct OpenReminderCard: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("打开账本，也把这些事放在心上。", systemImage: "sun.max")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { model.showOpenReminder = false } label: {
                    Image(systemName: "xmark").font(.system(size: 10))
                }.buttonStyle(.plain).accessibilityLabel("收起本次待办提示")
            }
            HStack(spacing: 12) {
                ForEach([ReminderPeriod.today, .week, .month]) { period in
                    Button { model.showReminders(period) } label: {
                        HStack(alignment: .firstTextBaseline) {
                            Text(period.rawValue).font(.system(size: 11))
                            Spacer()
                            Text("\(model.agenda.items(in: period).count)")
                                .font(.system(size: 24, weight: .medium, design: .rounded))
                            Text("项").font(.system(size: 10))
                        }.padding(13).background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain)
                }
            }
            HStack {
                Text(summary).font(.system(size: 10)).foregroundStyle(Palette.secondary)
                Spacer()
                Button("查看待办 →") { model.showReminders(.all) }
                    .font(.system(size: 11, weight: .medium)).buttonStyle(.plain)
            }
        }.padding(19).foregroundStyle(Palette.green)
            .background(Palette.paleGreen.opacity(0.65), in: RoundedRectangle(cornerRadius: 13))
    }
    private var summary: String {
        var parts = ["本周、本月包含今天，不累加"]
        if !model.agenda.overdue.isEmpty { parts.append("另有 \(model.agenda.overdue.count) 项逾期") }
        if !model.agenda.undated.isEmpty { parts.append("\(model.agenda.undated.count) 项日期待定") }
        return parts.joined(separator: " · ")
    }
}

struct ReminderBoard: View {
    @EnvironmentObject private var model: AppModel
    @State private var editor: ReminderDraft?
    private var agenda: ReminderAgenda { model.agenda }
    private var confirmedOrders: [LedgerEntry] { model.entries.filter { $0.state == .confirmed && $0.duplicateOf == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("把承诺，变成不遗漏的小事。").font(.system(size: 27, weight: .semibold))
                    Text("今天、本周、本月，知道什么需要处理。完成一件，就放下一件。")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
                Spacer()
                Menu {
                    ForEach(confirmedOrders) { entry in
                        Button(entry.title) { editor = ReminderDraft(entry: entry) }
                    }
                } label: { Label("新建待办", systemImage: "plus") }
                    .menuStyle(.borderlessButton).fixedSize().padding(10)
                    .background(.white, in: RoundedRectangle(cornerRadius: 9))
                    .disabled(confirmedOrders.isEmpty)
            }
            HStack(spacing: 9) {
                ForEach(ReminderPeriod.allCases) { period in
                    Button { model.reminderPeriod = period } label: {
                        Text(period.rawValue + "  \(period == .all ? agenda.pending.count : agenda.items(in: period).count)")
                            .font(.system(size: 12, weight: .medium)).padding(.horizontal, 15).padding(.vertical, 11)
                            .foregroundStyle(model.reminderPeriod == period ? .white : Palette.ink)
                            .background(model.reminderPeriod == period ? Palette.green : .white, in: Capsule())
                    }.buttonStyle(.plain)
                }
            }
            Text("按本机日期 \(agenda.today) · 周一至周日 / 自然月 · 逾期与日期待定单列，不重复展示")
                .font(.system(size: 10)).foregroundStyle(Palette.secondary)
            if !agenda.overdue.isEmpty {
                group("已逾期 · 仍需处理", reminders: agenda.overdue, overdue: true)
            }
            VStack(alignment: .leading, spacing: 12) {
                let upcoming = agenda.items(in: model.reminderPeriod)
                if upcoming.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(model.reminderPeriod.rawValue + "暂无已排期待办", systemImage: "checkmark.circle")
                            .font(.system(size: 16, weight: .medium)).foregroundStyle(Palette.green)
                        Text(confirmedOrders.isEmpty ? "先导入并确认一笔账单，再从承诺或权益添加待办。" : "在账单详情中，把需要处理的承诺加入待办；日期不明确时可以先留空。")
                            .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(4)
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                } else { group(model.reminderPeriod == .all ? "已排期待办" : model.reminderPeriod.rawValue + "待处理", reminders: upcoming) }
            }
            if !agenda.undated.isEmpty { group("日期待定 · 不自动推算截止日", reminders: agenda.undated) }
            if !agenda.history.isEmpty {
                DisclosureGroup("已完成与已取消  \(agenda.history.count)") {
                    VStack(spacing: 10) { ForEach(agenda.history) { reminder in row(reminder) } }.padding(.top, 12)
                }.font(.system(size: 12)).tint(Palette.green)
            }
            Text("仅在客户端内展示你确认过的待办，不代表付款状态改变；未接入系统通知与邮件发送。")
                .font(.system(size: 10)).foregroundStyle(Palette.secondary).lineSpacing(4)
        }
        .sheet(item: $editor) { ReminderEditor(draft: $0).environmentObject(model) }
    }

    private func group(_ title: String, reminders: [LedgerReminder], overdue: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text("\(reminders.count)").font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }.foregroundStyle(overdue ? Palette.amber : Palette.ink)
            ForEach(reminders) { reminder in row(reminder, overdue: overdue) }
        }
    }
    private func row(_ reminder: LedgerReminder, overdue: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 13) {
            if reminder.status == .pending {
                Button { Task { await model.setReminderStatus(reminder, .completed) } } label: {
                    Image(systemName: "circle").font(.system(size: 22, weight: .light))
                }.buttonStyle(.plain).foregroundStyle(Palette.green).padding(.top, 2)
                    .accessibilityLabel("完成待办：" + reminder.title)
            } else {
                Image(systemName: reminder.status == .completed ? "checkmark.circle.fill" : "minus.circle")
                    .foregroundStyle(Palette.secondary).font(.system(size: 20))
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(reminder.title).font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                Text(model.canonicalEntry(for: reminder.entryID)?.title ?? "关联订单")
                    .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                HStack(spacing: 12) {
                    Label(reminder.dueDate ?? "日期待定", systemImage: "calendar")
                        .foregroundStyle(overdue ? Palette.amber : Palette.secondary)
                    if reminder.status != .pending { Text(reminder.status.label).foregroundStyle(Palette.secondary) }
                    Button("查看凭据") { model.requestedDetailID = reminder.entryID }
                        .buttonStyle(.plain).foregroundStyle(Palette.green)
                }.font(.system(size: 10))
            }
            Spacer(minLength: 10)
            Menu {
                Button("编辑事项与日期") { editor = ReminderDraft(reminder: reminder) }
                if reminder.status == .pending {
                    Button("标记完成") { Task { await model.setReminderStatus(reminder, .completed) } }
                    Button("取消待办（保留历史）") { Task { await model.setReminderStatus(reminder, .cancelled) } }
                } else {
                    Button("恢复为待处理") { Task { await model.setReminderStatus(reminder, .pending) } }
                }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("待办操作：" + reminder.title)
        }.padding(16).background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Palette.border.opacity(0.7)))
    }
}

struct ReminderEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let draft: ReminderDraft
    @State private var title: String
    @State private var dueDate: String
    @State private var saving = false
    @State private var error: String?

    init(draft: ReminderDraft) {
        self.draft = draft
        _title = State(initialValue: draft.title)
        _dueDate = State(initialValue: draft.dueDate ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(draft.existingID == nil ? "把这件事记在待办里" : "编辑待办")
                    .font(.system(size: 21, weight: .semibold))
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(QuietButtonStyle()).disabled(saving)
            }
            Text(model.canonicalEntry(for: draft.entryID)?.title ?? "关联订单")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("需要你做什么").font(.system(size: 12, weight: .medium))
                TextField("例如：确认退款是否到账", text: $title).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("处理日期 · 由你确认").font(.system(size: 12, weight: .medium))
                HStack {
                    TextField("YYYY-MM-DD，可留空待定", text: $dueDate).textFieldStyle(.roundedBorder)
                    Button("今天") { dueDate = model.agenda.today }
                    Button("待定") { dueDate = "" }
                }
                Text("“三个工作日内”等相对承诺不自动计算日期。你可以设置一个跟进日期，但它不等于商家承诺的截止日。")
                    .font(.system(size: 10)).foregroundStyle(Palette.secondary).lineSpacing(4)
            }
            if let quote = draft.sourceQuote {
                VStack(alignment: .leading, spacing: 8) {
                    Text("承诺依据 · 请核对适用条件").font(.system(size: 11, weight: .medium))
                    Text(quote).font(.system(size: 11)).textSelection(.enabled).lineSpacing(4)
                    if let conditions = draft.conditions {
                        Text("条件：" + conditions).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.paleGreen.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(Palette.amber) }
            HStack {
                Text("保存后在客户端内提示，不发送邮件。").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                Spacer()
                Button(saving ? "保存中…" : "确认并保存") {
                    saving = true
                    Task {
                        let date = dueDate.trimmingCharacters(in: .whitespacesAndNewlines)
                        let succeeded = await model.saveReminder(draft, title: title, dueDate: date.isEmpty ? nil : date)
                        saving = false
                        if succeeded { dismiss() } else { error = model.banner ?? "保存失败，请重试。" }
                    }
                }.buttonStyle(PrimaryButtonStyle()).disabled(saving)
            }
        }.padding(30).frame(width: 570).foregroundStyle(Palette.ink).background(Palette.background)
            .interactiveDismissDisabled(saving)
    }
}
