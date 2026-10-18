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
    private var entry: LedgerEntry? { model.entries.first { $0.id == entryID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("账单详情").font(.system(size: 19, weight: .semibold))
                if let entry { StateBadge(state: entry.state) }
                Spacer()
                Button("关闭") { dismiss() }.buttonStyle(QuietButtonStyle())
            }.padding(24)
            Divider()
            if let entry {
                HStack(alignment: .top, spacing: 0) {
                    sourcePanel(entry).frame(width: 345)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if entry.state == .needsReview || entry.state == .confirmed { editor(entry) }
                            else { processingState(entry) }
                        }.padding(25)
                    }
                }
            }
        }.frame(width: 890, height: 680).foregroundStyle(Palette.ink).background(Palette.background)
            .onAppear { refreshDraft() }
            .onChange(of: entry?.state) { _, _ in refreshDraft() }
    }

    private func refreshDraft() {
        guard let entry else { return }
        if let extraction = entry.extraction { draft = extraction }
        image = NSImage(contentsOf: model.imageURL(for: entry))
    }

    private func sourcePanel(_ entry: LedgerEntry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Label("原始凭据", systemImage: "photo"); Spacer(); Text(entry.source.label).foregroundStyle(Palette.secondary) }
                .font(.system(size: 11, weight: .medium))
            if let image {
                ScrollView {
                    Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 8))
                }.frame(maxHeight: .infinity)
            } else {
                ContentUnavailableView("未找到原图", systemImage: "photo.badge.exclamationmark")
            }
            DisclosureGroup("查看 OCR 原文", isExpanded: $showText) {
                ScrollView { Text(entry.ocrText.isEmpty ? "尚未识别文字" : entry.ocrText).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 140).padding(.top, 6)
            }.font(.system(size: 11))
            Button("在 Finder 中显示原图") { NSWorkspace.shared.activateFileViewerSelecting([model.imageURL(for: entry)]) }
                .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(Palette.green)
        }.padding(22).frame(maxHeight: .infinity).background(.white.opacity(0.45))
    }

    private func editor(_ entry: LedgerEntry) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Label("AI 整理结果", systemImage: "sparkles").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("模型自评 \(Int(draft.confidence * 100))%").font(.system(size: 9)).foregroundStyle(Palette.secondary)
            }
            if !draft.summary.isEmpty { Text(draft.summary).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(4) }
            VStack(alignment: .leading, spacing: 13) {
                field("账单名称", text: $draft.title)
                field("商家", text: optional(\.merchant))
                HStack(spacing: 13) {
                    field("金额", text: optional(\.amount))
                    field("币种（如 CNY）", text: Binding(get: { draft.currency ?? "" }, set: { draft.currency = $0.isEmpty ? nil : $0.uppercased() }))
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
            }.disabled(entry.state == .confirmed)
            if !draft.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Label("需要你核对", systemImage: "exclamationmark.circle").font(.system(size: 11, weight: .semibold))
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
                            if let deadline = promise.deadline { Text("原文截止日期：" + deadline).font(.system(size: 10)) }
                        }
                    }
                    Text("本版本仅保存原文依据，尚不提供到期提醒。").font(.system(size: 9)).foregroundStyle(Palette.secondary)
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
                    Label(saving ? "正在保存…" : "确认无误，入账", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(PrimaryButtonStyle()).disabled(saving)
                Text("AI 可能出错。请对照原图核对金额、币种及付款状态。")
                    .font(.system(size: 9)).foregroundStyle(Palette.secondary)
            } else {
                Label("这笔账单已由你确认并保存在本机", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(Palette.green)
            }
            if let banner = model.banner { Text(banner).font(.system(size: 10)).foregroundStyle(Palette.amber).textSelection(.enabled) }
        }
    }

    private func processingState(_ entry: LedgerEntry) -> some View {
        VStack(alignment: .leading, spacing: 19) {
            Label(entry.state.label, systemImage: entry.state == .failed ? "exclamationmark.bubble" : "sparkles")
                .font(.system(size: 18, weight: .medium))
            if entry.state == .processing { ProgressView(); Text(model.activity ?? "正在整理账单…").font(.system(size: 12)) }
            if let error = entry.error { Text(error).font(.system(size: 12)).lineSpacing(6).textSelection(.enabled) }
            Text("原图已安全保存在这台 Mac。识别中断不会丢失原始凭据。")
                .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(5)
            if entry.state != .processing {
                Button(entry.state == .failed ? "重新识别" : "开始识别") { dismiss(); model.retry(entry) }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 10)).foregroundStyle(Palette.secondary)
            TextField("未识别，可手动填写", text: text).textFieldStyle(.roundedBorder).font(.system(size: 12))
        }
    }
    private func optional(_ keyPath: WritableKeyPath<BillExtraction, String?>) -> Binding<String> {
        Binding(get: { draft[keyPath: keyPath] ?? "" }, set: { draft[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }
}
