import SwiftUI
import LedgerMac

struct ImportResultsView: View {
    @ObservedObject var batch: ImportBatch
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if !batch.items.isEmpty || batch.notice != nil {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("本次导入").font(.system(size: 15, weight: .semibold))
                    if batch.isImporting { ProgressView().controlSize(.small) }
                    Spacer()
                    Text(summary).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
                if let notice = batch.notice {
                    Label(notice, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(Palette.amber)
                }
                ForEach(batch.items) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: symbol(item.status)).foregroundStyle(color(item.status)).frame(width: 18)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1).help(item.name)
                            Text(label(item.status)).font(.system(size: 11)).foregroundStyle(color(item.status)).textSelection(.enabled)
                            if let id = item.status.entryID, let entry = model.canonicalEntry(for: id) {
                                HStack {
                                    Text("记录状态").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                                    StateBadge(state: entry.state)
                                }
                                if let error = entry.error {
                                    Text(error).font(.system(size: 11)).foregroundStyle(Palette.amber).textSelection(.enabled)
                                }
                            }
                        }
                        Spacer()
                        if let id = item.status.entryID {
                            Button("查看记录") { model.showImportedEntry(id) }.buttonStyle(QuietButtonStyle())
                        }
                    }.padding(.vertical, 7)
                    if item.id != batch.items.last?.id { Divider() }
                }
                Text("仅显示最近一批导入结果。已导入表示图片已保存，识别完成后仍需你确认入账。")
                    .font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }.padding(18).background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.border))
        }
    }

    private var summary: String {
        var imported = 0, duplicate = 0, failed = 0
        for item in batch.items {
            switch item.status {
            case .imported: imported += 1
            case .duplicate: duplicate += 1
            case .failed: failed += 1
            default: break
            }
        }
        return "共 \(batch.items.count) 个 · 已导入 \(imported) · 重复 \(duplicate) · 失败 \(failed)"
    }

    private func label(_ status: ImportStatus) -> String {
        switch status {
        case .waiting: return "等待导入"
        case .reading: return "正在读取文件地址…"
        case .importing: return "正在校验并保存图片…"
        case .imported: return "已导入"
        case .duplicate: return "图片重复，已关联已有记录"
        case .failed(let message): return "导入失败：" + message
        }
    }
    private func symbol(_ status: ImportStatus) -> String {
        switch status {
        case .imported: return "checkmark.circle"
        case .duplicate: return "doc.on.doc"
        case .failed: return "exclamationmark.circle"
        default: return "clock"
        }
    }
    private func color(_ status: ImportStatus) -> Color {
        switch status {
        case .failed: return Palette.amber
        case .imported: return Palette.green
        default: return Palette.secondary
        }
    }
}
