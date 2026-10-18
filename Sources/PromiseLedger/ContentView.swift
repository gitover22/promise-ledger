import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LedgerCore
import LedgerMac

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isDropTarget = false
    @State private var detail: LedgerEntry?

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 205)
            Rectangle().fill(Palette.border).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    topBar
                    if model.section == .reminders {
                        ReminderBoard()
                    } else {
                        hero
                        if model.shouldShowOpenReminder { OpenReminderCard() }
                        statistics
                        intake
                    }
                    if let banner = model.banner { bannerView(banner) }
                    if let activity = model.activity { processingView(activity) }
                    if model.section != .reminders { records }
                    footer
                }.padding(.horizontal, 34).padding(.top, 37).padding(.bottom, 25)
            }.background(Palette.background)
        }
        .foregroundStyle(Palette.ink)
        .frame(minWidth: 1_020, minHeight: 660)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTarget, perform: receiveDrop)
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 16).stroke(Palette.green, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(12).background(Palette.paleGreen.opacity(0.3)).allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $model.showConsent) { ConsentView().environmentObject(model) }
        .sheet(isPresented: $model.showSettings) { SettingsView().environmentObject(model) }
        .sheet(item: $detail) { entry in EntryDetailView(entryID: entry.id).id(entry.id).environmentObject(model) }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in model.updateCalendar() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in model.updateCalendar() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.updateCalendar() }
        .onChange(of: model.requestedDetailID) { _, id in
            if let id, let entry = model.entries.first(where: { $0.id == id }), !model.showSettings, !model.showConsent {
                detail = entry
                model.requestedDetailID = nil
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                BrandMark()
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI 账本").font(.system(size: 17, weight: .bold))
                    Text("PROMISE LEDGER").font(.system(size: 8, weight: .medium)).tracking(1.2).foregroundStyle(Palette.secondary)
                }
            }.padding(.top, 61).padding(.bottom, 42)
            Text("账本").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.secondary).padding(.bottom, 13).padding(.leading, 12)
            ForEach(LedgerSection.allCases) { section in
                Button {
                    model.section = section
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: section.symbol).font(.system(size: 14)).frame(width: 17)
                        Text(section.rawValue).font(.system(size: 12, weight: model.section == section ? .semibold : .regular))
                        Spacer()
                        if section == .review && model.reviewCount > 0 {
                            Text("\(model.reviewCount)").font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 3).background(.white.opacity(0.8), in: Capsule())
                        }
                        if section == .reminders && !model.agenda.pending.isEmpty {
                            Text("\(model.agenda.pending.count)").font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 3).background(.white.opacity(0.8), in: Capsule())
                        }
                    }.padding(.horizontal, 12).padding(.vertical, 13)
                        .background(model.section == section ? Palette.paleGreen : .clear, in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).padding(.bottom, 4)
            }
            Spacer(minLength: 40)
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "keyboard").font(.system(size: 21, weight: .light)).foregroundStyle(Palette.green)
                Text("快捷截图").font(.system(size: 14, weight: .medium))
                Text(GlobalHotKey.display).font(.system(size: 17, weight: .medium, design: .monospaced))
                Text("在订单页面按下快捷键\n即可截取当前屏幕").font(.system(size: 10)).lineSpacing(5).foregroundStyle(Palette.secondary)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 13)).padding(.bottom, 22)
            Button { model.showSettings = true } label: {
                Label("设置与隐私", systemImage: "slider.horizontal.3").font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }.buttonStyle(.plain).padding(.leading, 10).padding(.bottom, 27)
        }.padding(.horizontal, 18).background(Palette.sidebar)
    }

    private var topBar: some View {
        HStack {
            Text(model.isPreview ? "演示模式 · 数据独立保存" : "本地账本").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary)
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(Palette.green).frame(width: 5, height: 5)
                Text("常驻菜单栏").font(.system(size: 10))
            }.foregroundStyle(Palette.green).padding(.horizontal, 10).padding(.vertical, 6)
                .background(Palette.paleGreen.opacity(0.6), in: Capsule())
            Text(Date(), format: .dateTime.month(.twoDigits).day(.twoDigits).weekday(.wide))
                .font(.system(size: 10)).foregroundStyle(Palette.secondary).padding(.leading, 8)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.section.rawValue).font(.system(size: 32, weight: .semibold)).tracking(-1)
            Text(sectionDescription)
                .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineSpacing(5)
        }.padding(.top, 5)
    }

    private var sectionDescription: String {
        switch model.section {
        case .all: return "截图或导入图片，识别后核对入账。"
        case .review: return "核对金额、币种和订单信息后入账。"
        case .confirmed: return "查看已确认的账单和补充凭据。"
        case .reminders: return "查看需要处理的事项。"
        }
    }

    private var statistics: some View {
        HStack(spacing: 13) {
            metric("本月已确认金额", value: model.monthTotal, footnote: "按交易日期 · 不折算币种", symbol: "chart.bar.xaxis")
            metric("已入账", value: "\(model.confirmedCount)", footnote: "已确认的账单", symbol: "checkmark.seal")
            metric("待确认", value: "\(model.reviewCount)", footnote: "核对信息后入账", symbol: "checkmark.bubble")
        }
    }

    private func metric(_ title: String, value: String, footnote: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                Spacer()
                Image(systemName: symbol).font(.system(size: 14, weight: .light)).foregroundStyle(Palette.green.opacity(0.7))
            }
            Text(value).font(.system(size: 27, weight: .medium, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
            Text(footnote).font(.system(size: 9)).foregroundStyle(Palette.secondary)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.83), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.border.opacity(0.65)))
    }

    private var intake: some View {
        HStack(spacing: 14) {
            Button { model.captureScreen() } label: {
                HStack(spacing: 14) {
                    Image(systemName: "viewfinder").font(.system(size: 25, weight: .light)).frame(width: 40)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(model.isCapturing ? "正在截图…" : "截图识别").font(.system(size: 15, weight: .semibold))
                        Text("截取鼠标所在屏幕的完整画面").font(.system(size: 10)).opacity(0.7)
                    }
                    Spacer(minLength: 5)
                    Text(GlobalHotKey.display).font(.system(size: 11, weight: .medium, design: .monospaced))
                        .padding(9).background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                }.padding(21).foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 80)
                    .background(Palette.green, in: RoundedRectangle(cornerRadius: 13))
            }.buttonStyle(.plain).disabled(model.isCapturing || !model.initialized)
            Button { model.chooseImages() } label: {
                HStack(spacing: 14) {
                    Image(systemName: "photo.badge.plus").font(.system(size: 25, weight: .light)).foregroundStyle(Palette.green).frame(width: 35)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(model.isImporting ? "正在导入…" : "导入图片").font(.system(size: 15, weight: .semibold))
                        Text("支持订单截图、收据，可直接拖入").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }.padding(21).frame(maxWidth: .infinity, minHeight: 80)
                    .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.border))
            }.buttonStyle(.plain).disabled(model.isImporting || !model.initialized)
        }
    }

    private var records: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text(model.section == .all ? "账单记录" : model.section.rawValue).font(.system(size: 15, weight: .semibold))
                Text("\(model.filteredEntries.count)").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(Palette.border.opacity(0.4), in: Capsule())
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary)
                    TextField("搜索商家、商品或订单", text: $model.search).textFieldStyle(.plain)
                }.font(.system(size: 10)).padding(9).frame(width: 195)
                    .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            }
            if model.filteredEntries.isEmpty { emptyState }
            else {
                VStack(spacing: 0) {
                    ForEach(model.filteredEntries) { entry in
                        Button { detail = entry } label: { entryRow(entry) }.buttonStyle(.plain)
                        if entry.id != model.filteredEntries.last?.id { Divider().padding(.leading, 69) }
                    }
                }.background(.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.border.opacity(0.65)))
            }
        }
    }

    private var emptyState: some View {
        HStack(spacing: 32) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Palette.paleGreen.opacity(0.6))
                    .frame(width: 96, height: 107).rotationEffect(.degrees(-10)).offset(x: -4, y: 4)
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Image(systemName: "sparkles").foregroundStyle(Palette.green); Spacer(); Circle().fill(Palette.paleGreen).frame(width: 9, height: 9) }
                    RoundedRectangle(cornerRadius: 2).fill(Palette.border).frame(height: 4)
                    RoundedRectangle(cornerRadius: 2).fill(Palette.border).frame(width: 45, height: 4)
                    HStack { Text("¥").font(.system(size: 21, weight: .medium)); Spacer(); Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.green) }
                }.padding(15).frame(width: 90, height: 107).background(.white, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.border.opacity(0.7))).rotationEffect(.degrees(5))
            }.frame(width: 125, height: 135)
            VStack(alignment: .leading, spacing: 10) {
                Text(emptyTitle)
                    .font(.system(size: 16, weight: .medium))
                Text(emptyDescription)
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(6)
                if model.search.isEmpty && model.section == .all {
                    Button("导入图片") { model.chooseImages() }.buttonStyle(QuietButtonStyle()).padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 35).padding(.vertical, 21).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.border, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }

    private var emptyTitle: String {
        if !model.search.isEmpty { return "未找到相关账单" }
        switch model.section {
        case .all: return "暂无账单"
        case .review: return "暂无待确认账单"
        case .confirmed: return "暂无已入账账单"
        case .reminders: return "暂无待办"
        }
    }
    private var emptyDescription: String {
        if !model.search.isEmpty { return "试试其他商家名称、商品名称或订单号。" }
        switch model.section {
        case .all: return "导入订单截图或收据，或按 ⌃⌥L 截图识别。"
        case .review: return "识别完成或需要核对重复记录的账单会显示在这里。"
        case .confirmed: return "在账单详情中核对信息并确认入账后，可在这里查看。"
        case .reminders: return "可在已入账账单的详情中添加待办。"
        }
    }

    private func entryRow(_ entry: LedgerEntry) -> some View {
        HStack(spacing: 14) {
            Image(systemName: entry.source.symbol).font(.system(size: 18, weight: .light)).foregroundStyle(Palette.green)
                .frame(width: 40, height: 43).background(Palette.paleGreen.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text([entry.extraction?.merchant ?? entry.source.label, entry.extraction?.transactionDate ?? entry.createdAt.formatted(date: .abbreviated, time: .shortened)].joined(separator: "  ·  "))
                    .font(.system(size: 10)).foregroundStyle(Palette.secondary).lineLimit(1)
                if !model.linkedEvidence(for: entry).isEmpty {
                    Text("补充凭据 \(model.linkedEvidence(for: entry).count) 张 · 不重复入账")
                        .font(.system(size: 9)).foregroundStyle(Palette.green)
                }
            }
            Spacer()
            StateBadge(state: entry.state)
            Text(entry.extraction?.formattedAmount ?? "—").font(.system(size: 14, weight: .medium, design: .rounded)).frame(minWidth: 100, alignment: .trailing)
            Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Palette.secondary.opacity(0.6))
        }.padding(.horizontal, 17).padding(.vertical, 15).contentShape(Rectangle())
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield").font(.system(size: 10))
            Text("图片保存在本机 · 识别需发送图片文字至 AI 服务")
                .font(.system(size: 9))
            Spacer()
            Text("0.3.1").font(.system(size: 8, design: .monospaced))
        }.foregroundStyle(Palette.secondary.opacity(0.85))
    }

    private func bannerView(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "info.circle").padding(.top, 1)
            Text(message).font(.system(size: 11)).lineSpacing(4).textSelection(.enabled)
            Spacer()
            Button { model.banner = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain)
        }.foregroundStyle(Palette.amber).padding(14).background(Palette.amber.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    private func processingView(_ message: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(message).font(.system(size: 11))
            Spacer()
            Text("未完成 \(model.queueCount) 张").font(.system(size: 10)).foregroundStyle(Palette.secondary)
        }.padding(14).background(Palette.paleGreen.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        guard providers.count <= 10 else { model.banner = "每次最多导入 10 张图片。"; return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                        continuation.resume(returning: data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) })
                    }
                }
                if let url { urls.append(url) }
            }
            if !urls.isEmpty { model.importImages(urls) }
        }
        return true
    }
}
