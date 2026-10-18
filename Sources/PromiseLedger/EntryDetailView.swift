import AppKit
import SwiftUI
import LedgerCore

struct EntryDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let entryID: String
    @State private var draft = BillExtraction()
    @State private var image: NSImage?
    @State private var saving = false
    @State private var showText = false
    @State private var displayedID: String?
    @State private var reminderDraft: ReminderDraft?
    private var entry: LedgerEntry? { model.entries.first { $0.id == (displayedID ?? entryID) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("账单详情").font(.system(size: 19, weight: .semibold))
                if let entry { StateBadge(state: entry.state) }
                Spacer()
                if displayedID != nil {
                    Button("返回") { displayedID = nil }.buttonStyle(QuietButtonStyle())
                }
                Button("关闭") { dismiss() }.buttonStyle(QuietButtonStyle())
            }.padding(24)
            Divider()
            if let entry {
                HStack(alignment: .top, spacing: 0) {
                    sourcePanel(entry).frame(width: 345)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if [.needsReview, .confirmed, .duplicate, .duplicateReview].contains(entry.state) { editor(entry) }
                            else { processingState(entry) }
                        }.padding(25)
                    }
                }
            }
        }.frame(width: 890, height: 680).foregroundStyle(Palette.ink).background(Palette.background)
            .onAppear { refreshDraft() }
            .onChange(of: entry?.state) { _, _ in refreshDraft() }
            .onChange(of: displayedID) { _, _ in refreshDraft() }
            .sheet(item: $reminderDraft) { ReminderEditor(draft: $0).environmentObject(model) }
    }

    private func refreshDraft() {
        guard let entry else { return }
        draft = model.reviewDraft(for: entry)
        image = NSImage(contentsOf: model.imageURL(for: entry))
    }

    private func sourcePanel(_ entry: LedgerEntry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Label("原图", systemImage: "photo"); Spacer(); Text(entry.source.label).foregroundStyle(Palette.secondary) }
                .font(.system(size: 11, weight: .medium))
            if let image {
                ScrollView {
                    Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 8))
                }.frame(maxHeight: .infinity)
            } else {
                ContentUnavailableView("未找到原图", systemImage: "photo.badge.exclamationmark")
            }
            DisclosureGroup("图片文字", isExpanded: $showText) {
                ScrollView { Text(entry.ocrText.isEmpty ? "尚未识别文字" : entry.ocrText).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 140).padding(.top, 6)
            }.font(.system(size: 11))
            Button("在 Finder 中显示原图") { NSWorkspace.shared.activateFileViewerSelecting([model.imageURL(for: entry)]) }
                .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(Palette.green)
        }.padding(22).frame(maxHeight: .infinity).background(.white.opacity(0.45))
    }

    private func editor(_ entry: LedgerEntry) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            if entry.state == .duplicate || entry.state == .duplicateReview { duplicatePanel(entry) }
            HStack {
                Label("账单信息", systemImage: "doc.text").font(.system(size: 15, weight: .semibold))
            }
            if !draft.summary.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("识别摘要 · 修改后以账单信息为准").font(.system(size: 9)).foregroundStyle(Palette.secondary)
                    Text(draft.summary).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(4)
                }
            }
            VStack(alignment: .leading, spacing: 13) {
                field("账单名称", text: $draft.title)
                field("商家", text: optional(\.merchant))
                field("交易平台", text: optional(\.platform))
                HStack(spacing: 13) {
                    field("金额", text: optional(\.amount))
                    field("币种（如 CNY、USD）", text: Binding(get: { draft.currency ?? "" }, set: { draft.currency = $0.isEmpty ? nil : $0.uppercased() }))
                }
                if model.needsCurrencyDefault(for: entry), draft.currency == AppModel.defaultReviewCurrency {
                    Text("币种未识别，已按人民币（CNY）预填，可修改。")
                        .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                }
                HStack(spacing: 13) {
                    field("交易日期 YYYY-MM-DD", text: optional(\.transactionDate))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("分类").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                        Picker("分类", selection: $draft.category) { ForEach(BillExtraction.categories, id: \.self) { Text($0).tag($0) } }
                            .labelsHidden().frame(maxWidth: .infinity)
                    }
                }
                field("订单号", text: optional(\.orderID))
                LabeledContent("付款状态") {
                    Picker("付款状态", selection: $draft.paymentStatus) {
                        ForEach(["已支付", "待支付", "已退款", "已取消", "未知"], id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(width: 130)
                }.font(.system(size: 11))
            }.disabled(entry.state != .needsReview)
            if !draft.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Label("请核对以下信息", systemImage: "exclamationmark.circle").font(.system(size: 11, weight: .semibold))
                    ForEach(draft.warnings, id: \.self) { Text("· " + $0).font(.system(size: 10)).lineSpacing(3) }
                }.foregroundStyle(Palette.amber).padding(13).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.amber.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            }
            if !draft.promises.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Label("承诺与权益", systemImage: "checkmark.shield").font(.system(size: 12, weight: .semibold))
                    ForEach(Array(draft.promises.enumerated()), id: \.offset) { _, promise in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(promise.text).font(.system(size: 11, weight: .medium))
                            Text("原文：" + promise.sourceQuote).font(.system(size: 10)).foregroundStyle(Palette.secondary).textSelection(.enabled)
                            if let promisor = promise.promisor { Text("承诺方：" + promisor).font(.system(size: 10)) }
                            if let conditions = promise.conditions { Text("适用条件：" + conditions).font(.system(size: 10)).foregroundStyle(Palette.secondary) }
                            if let action = promise.userAction { Text("处理事项：" + action).font(.system(size: 10)).foregroundStyle(Palette.green) }
                            if let deadline = promise.deadline { Text("原文截止日期：" + deadline).font(.system(size: 10)) }
                            Button("添加待办") { reminderDraft = ReminderDraft(entry: entry, promise: promise) }
                                .buttonStyle(QuietButtonStyle())
                                .disabled(model.canonicalEntry(for: entry.id)?.state != .confirmed)
                        }
                    }
                    Text("账单入账后可添加待办。事项和日期需单独确认，不会自动设置提醒。")
                        .font(.system(size: 9)).foregroundStyle(Palette.secondary)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Palette.paleGreen.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            }
            if entry.state == .needsReview {
                Button {
                    saving = true
                    Task {
                        let succeeded = await model.confirm(entry, draft: draft)
                        saving = false
                        if succeeded { dismiss() }
                    }
                } label: {
                    Label(saving ? "正在保存…" : "确认入账", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(PrimaryButtonStyle()).disabled(saving)
                Text("识别可能有误，请对照原图核对金额、币种和付款状态。")
                    .font(.system(size: 9)).foregroundStyle(Palette.secondary)
            } else if entry.state == .confirmed {
                Label("已确认入账", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(Palette.green)
            }
            if model.canonicalEntry(for: entry.id)?.state == .confirmed {
                HStack {
                    Button("新建待办") { reminderDraft = ReminderDraft(entry: entry) }
                        .buttonStyle(QuietButtonStyle())
                    Button("查看待办") { model.showReminders(.all); dismiss() }
                        .buttonStyle(QuietButtonStyle())
                }
            }
            let evidence = model.linkedEvidence(for: entry)
            if !evidence.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Label("补充凭据", systemImage: "link").font(.system(size: 12, weight: .semibold))
                    ForEach(evidence) { source in
                        Button { displayedID = source.id } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(source.title).font(.system(size: 11, weight: .medium))
                                Text("\(source.source.label) · \(source.extraction?.promises.count ?? 0) 条承诺 · 查看原图和原文")
                                    .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                                if let other = source.extraction, let original = entry.extraction,
                                   (other.decimalAmount != nil && original.decimalAmount != nil && other.decimalAmount != original.decimalAmount) ||
                                   (other.currency != nil && original.currency != nil && other.currency != original.currency) ||
                                   (other.paymentStatus != "未知" && original.paymentStatus != "未知" && other.paymentStatus != original.paymentStatus) {
                                    Text("金额或付款状态与原订单不同，请核对原图。原订单信息未更改。")
                                        .font(.system(size: 10)).foregroundStyle(Palette.amber)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(11)
                                .background(Palette.paleGreen.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                    }
                }
            }
            DisclosureGroup("识别信息") {
                VStack(alignment: .leading, spacing: 7) {
                    if let name = entry.model { Text("模型：" + name) }
                    Text("模型自评：\(Int(draft.confidence * 100))%（仅供参考，不代表准确率）")
                    if let version = entry.promptVersion { Text("提示词版本：" + version) }
                }.font(.system(size: 10)).foregroundStyle(Palette.secondary).padding(.top, 5)
            }.font(.system(size: 10))
            if let banner = model.banner { Text(banner).font(.system(size: 10)).foregroundStyle(Palette.amber).textSelection(.enabled) }
        }
    }

    private func duplicatePanel(_ entry: LedgerEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let target = entry.duplicateOf {
                Label("已关联到原订单", systemImage: "link").font(.system(size: 13, weight: .semibold))
                Text("图片和承诺已作为补充凭据保存，不重复入账。原订单的金额和状态保持不变。").font(.system(size: 11)).lineSpacing(4)
                Button("查看原订单") { displayedID = target }.buttonStyle(QuietButtonStyle())
            } else {
                Label("核对重复账单", systemImage: "exclamationmark.bubble").font(.system(size: 13, weight: .semibold))
                Text("这条记录可能与已有账单重复。请核对订单号和原图，选择关联或保留为新订单。核对前不会入账。").font(.system(size: 11)).lineSpacing(4)
                ForEach(entry.duplicateCandidates, id: \.self) { id in
                    if let candidate = model.entries.first(where: { $0.id == id }) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(candidate.title + " · " + (candidate.extraction?.formattedAmount ?? "金额未知")).font(.system(size: 11, weight: .medium))
                            Text("订单号：" + (candidate.extraction?.orderID ?? "缺失") + " · " + (candidate.extraction?.transactionDate ?? "日期未知"))
                                .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                            HStack {
                                Button("查看已有凭据") { displayedID = id }.buttonStyle(QuietButtonStyle())
                                Button("关联到此订单") { Task { await model.linkDuplicate(entry, to: id) } }
                                    .buttonStyle(QuietButtonStyle())
                            }
                        }
                    }
                }
                Button("保留为新订单") { Task { await model.keepSeparate(entry) } }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.amber.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
    }

    private func processingState(_ entry: LedgerEntry) -> some View {
        VStack(alignment: .leading, spacing: 19) {
            Label(model.queuePaused ? "识别已暂停" : entry.state.label, systemImage: entry.state == .failed ? "exclamationmark.bubble" : "sparkles")
                .font(.system(size: 18, weight: .medium))
            if entry.state == .processing && !model.queuePaused { ProgressView(); Text(model.activity ?? "正在识别账单…").font(.system(size: 12)) }
            if model.queuePaused, let banner = model.banner { Text(banner).font(.system(size: 12)).lineSpacing(6) }
            if let error = entry.error { Text(error).font(.system(size: 12)).lineSpacing(6).textSelection(.enabled) }
            Text("原图已保存在本机，可稍后重新识别。")
                .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(5)
            if entry.state != .processing || model.queuePaused {
                Button(model.queuePaused ? "存储恢复后重试" : (entry.state == .failed ? "重新识别" : "开始识别")) { dismiss(); model.retry(entry) }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 10)).foregroundStyle(Palette.secondary)
            TextField(entry?.state == .needsReview ? "手动填写" : "未填写", text: text)
                .textFieldStyle(.roundedBorder).font(.system(size: 12))
        }
    }
    private func optional(_ keyPath: WritableKeyPath<BillExtraction, String?>) -> Binding<String> {
        Binding(get: { draft[keyPath: keyPath] ?? "" }, set: { draft[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }
}
