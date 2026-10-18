import SwiftUI
import LedgerMac

struct ImportPreviewView: View {
    @ObservedObject var selection: ImportSelection
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if selection.isPresented || selection.notice != nil {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("待导入文件 · 尚未保存").font(.system(size: 15, weight: .semibold))
                    if selection.isChecking { ProgressView().controlSize(.small) }
                    Spacer()
                    Text("已选 \(selection.rows.count) 张 · 可导入 \(selection.readyCount) 张")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
                if let notice = selection.notice {
                    Label(notice, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12)).foregroundStyle(Palette.amber)
                }
                if selection.isPresented {
                    Text("核对图片后点击确认。预览和取消只在本机进行，不保存账单，也不发送识别请求。")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    ForEach(selection.rows) { row in
                        HStack(spacing: 14) {
                            Group {
                                if let preview = row.preview {
                                    Image(decorative: preview.image, scale: 1).resizable().scaledToFit()
                                } else {
                                    Image(systemName: row.error == nil ? "photo" : "exclamationmark.triangle")
                                        .foregroundStyle(row.error == nil ? Palette.secondary : Palette.amber)
                                }
                            }.frame(width: 64, height: 64)
                                .background(Palette.background, in: RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(row.name).font(.system(size: 12, weight: .medium)).lineLimit(1).help(row.name)
                                if let preview = row.preview {
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(preview.byteCount), countStyle: .file) + " · 可导入")
                                        .font(.system(size: 11)).foregroundStyle(Palette.green)
                                } else if let error = row.error {
                                    Text("不可导入：" + error).font(.system(size: 11)).foregroundStyle(Palette.amber)
                                } else {
                                    Text("正在读取并校验…").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                                }
                            }
                            Spacer()
                            Button("移除") { selection.remove(row.id) }.buttonStyle(QuietButtonStyle())
                                .accessibilityLabel("移除 " + row.name)
                        }.padding(.vertical, 4)
                    }
                    if selection.rows.isEmpty {
                        Text("已移除全部文件，可取消本次选择后重新添加。")
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    }
                    HStack {
                        if !selection.isChecking && selection.rows.count > selection.readyCount {
                            Text("\(selection.rows.count - selection.readyCount) 个不可导入文件将跳过")
                                .font(.system(size: 11)).foregroundStyle(Palette.amber)
                        }
                        Spacer()
                        Button("取消本次导入") { selection.cancel() }.buttonStyle(QuietButtonStyle())
                        Button("确认导入 \(selection.readyCount) 张") { model.confirmImportSelection() }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(selection.isChecking || selection.readyCount == 0 || model.isImporting)
                    }
                }
            }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.green.opacity(0.4)))
        }
    }
}
