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
                Label("待办概览", systemImage: "calendar")
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
                Button("查看全部") { model.showReminders(.all) }
                    .font(.system(size: 11, weight: .medium)).buttonStyle(.plain)
            }
        }.padding(19).foregroundStyle(Palette.green)
            .background(Palette.paleGreen.opacity(0.65), in: RoundedRectangle(cornerRadius: 13))
    }
    private var summary: String {
        var parts = ["本周、本月均包含今天"]
        if !model.agenda.overdue.isEmpty { parts.append("逾期 \(model.agenda.overdue.count) 项") }
        if !model.agenda.undated.isEmpty { parts.append("未定日期 \(model.agenda.undated.count) 项") }
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
                    Text("待办事项").font(.system(size: 27, weight: .semibold))
                    Text("查看退款跟进、价保申请等需要处理的事项。")
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
                    .help("选择一笔已入账账单，为它添加待办。")
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
            Text("\(agenda.today) · 本周为周一至周日，本月为自然月")
                .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                .help("本周、本月包含今天；逾期和未定日期的事项单独列出。")
            if !agenda.overdue.isEmpty {
                group("已逾期", reminders: agenda.overdue, overdue: true)
            }
            VStack(alignment: .leading, spacing: 12) {
                let upcoming = agenda.items(in: model.reminderPeriod)
                if upcoming.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(emptyTitle, systemImage: "checkmark.circle")
                            .font(.system(size: 16, weight: .medium)).foregroundStyle(Palette.green)
                        Text(confirmedOrders.isEmpty ? "账单入账后，可在详情中添加待办。" : "可在账单详情中添加，或点击「新建待办」。")
                            .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(4)
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                } else { group(model.reminderPeriod == .all ? "已设日期" : model.reminderPeriod.rawValue + "待办", reminders: upcoming) }
            }
            if !agenda.undated.isEmpty { group("未定日期", reminders: agenda.undated) }
            if !agenda.history.isEmpty {
                DisclosureGroup("已完成与已取消  \(agenda.history.count)") {
                    VStack(spacing: 10) { ForEach(agenda.history) { reminder in row(reminder) } }.padding(.top, 12)
                }.font(.system(size: 12)).tint(Palette.green)
            }
            Text("完成待办不会更改账单的付款状态。")
                .font(.system(size: 10)).foregroundStyle(Palette.secondary).lineSpacing(4)
        }
        .sheet(item: $editor) { ReminderEditor(draft: $0).environmentObject(model) }
    }

    private var emptyTitle: String {
        model.reminderPeriod == .all ? "暂无已设日期的待办" : model.reminderPeriod.rawValue + "暂无待办"
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
                    Label(reminder.dueDate ?? "未定日期", systemImage: "calendar")
                        .foregroundStyle(overdue ? Palette.amber : Palette.secondary)
                    if reminder.status != .pending { Text(reminder.status.label).foregroundStyle(Palette.secondary) }
                    Button("查看凭据") { model.requestedDetailID = reminder.entryID }
                        .buttonStyle(.plain).foregroundStyle(Palette.green)
                }.font(.system(size: 10))
            }
            Spacer(minLength: 10)
            Menu {
                Button("编辑待办") { editor = ReminderDraft(reminder: reminder) }
                if reminder.status == .pending {
                    Button("标记完成") { Task { await model.setReminderStatus(reminder, .completed) } }
                    Button("取消待办（保留历史）") { Task { await model.setReminderStatus(reminder, .cancelled) } }
                } else {
                    Button("恢复待办") { Task { await model.setReminderStatus(reminder, .pending) } }
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
                Text(draft.existingID == nil ? "新建待办" : "编辑待办")
                    .font(.system(size: 21, weight: .semibold))
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(QuietButtonStyle()).disabled(saving)
            }
            Text(model.canonicalEntry(for: draft.entryID)?.title ?? "关联订单")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("事项").font(.system(size: 12, weight: .medium))
                TextField("例如：确认退款是否到账", text: $title).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("跟进日期（选填）").font(.system(size: 12, weight: .medium))
                HStack {
                    TextField("YYYY-MM-DD", text: $dueDate).textFieldStyle(.roundedBorder)
                    Button("今天") { dueDate = model.agenda.today }
                    Button("清除") { dueDate = "" }
                }
                Text("未注明具体日期的承诺不会自动换算。跟进日期仅用于提醒，不作为商家承诺的截止日期。")
                    .font(.system(size: 10)).foregroundStyle(Palette.secondary).lineSpacing(4)
            }
            if let quote = draft.sourceQuote {
                VStack(alignment: .leading, spacing: 8) {
                    Text("相关原文").font(.system(size: 11, weight: .medium))
                    Text(quote).font(.system(size: 11)).textSelection(.enabled).lineSpacing(4)
                    if let conditions = draft.conditions {
                        Text("适用条件：" + conditions).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.paleGreen.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(Palette.amber) }
            HStack {
                Text("提醒仅在应用内显示。").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                Spacer()
                Button(saving ? "正在保存…" : "保存") {
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
