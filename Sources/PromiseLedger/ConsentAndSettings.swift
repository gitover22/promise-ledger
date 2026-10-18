import AppKit
import SwiftUI
import LedgerCore
import LedgerMac

struct ConsentView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            BrandMark(size: 49)
            Text("在本机看图，\n让 AI 读懂账单。").font(.system(size: 26, weight: .semibold)).lineSpacing(5)
            Text("开始前，有几件事想让你知道。") .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            VStack(alignment: .leading, spacing: 16) {
                note("photo", "图片留在这台 Mac", "截图和导入图片只保存在本机，本版本不会上传原图。")
                note("text.viewfinder", "OCR 文字发送至 MaaS", "识别出的全部文字将发送给 \(model.modelName)，可能包含姓名、地址或其他敏感信息。请仅截取适合发送的内容。")
                note("hand.raised", "由你触发，也由你确认", "不持续录屏，不监视页面。AI 结果先存为待确认，你核对后才入账。")
            }.padding(18).background(Palette.paleGreen.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            Text("同意后，后续主动截图或导入会自动识别；可随时在「设置与隐私」中撤回。")
                .font(.system(size: 10)).foregroundStyle(Palette.secondary).lineSpacing(4)
            HStack {
                Button("暂不识别") { model.showConsent = false }.buttonStyle(QuietButtonStyle())
                Spacer()
                Button("同意并开始识别") { model.grantConsent() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }.padding(34).frame(width: 490).foregroundStyle(Palette.ink).background(Palette.background)
    }
    private func note(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol).font(.system(size: 17)).frame(width: 23).foregroundStyle(Palette.green)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(text).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(4)
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("设置与隐私").font(.system(size: 22, weight: .semibold))
                Spacer()
                Button("完成") { dismiss() }.buttonStyle(QuietButtonStyle())
            }
            GroupBox("截图与后台") {
                VStack(alignment: .leading, spacing: 13) {
                    LabeledContent("全屏截图快捷键", value: "Control + Option + L")
                    Text("关闭主窗口后继续常驻菜单栏；不持续截图，不持续使用模型。多显示器时截取鼠标所在屏幕。")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(4)
                    HStack {
                        Label(model.capturePermission ? "已获得屏幕录制权限" : "屏幕录制权限待开启", systemImage: model.capturePermission ? "checkmark.circle" : "lock")
                        Spacer()
                        Button("打开系统设置") { ScreenCaptureService.openPermissionSettings() }
                        Button("刷新") { model.reloadConfiguration() }
                    }.font(.system(size: 11))
                }.padding(10)
            }
            GroupBox("AI 接入") {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("默认模型", value: model.modelName)
                    LabeledContent("密钥存储", value: "macOS 钥匙串 · 不显示密钥")
                    Text("配置由 ~/.config/promise-ledger/model.json 读取；请求携带应用标识及 bill-extraction 场景。")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(4)
                    HStack {
                        Button("重新读取配置") { model.reloadConfiguration() }
                        Spacer()
                        if model.consentGranted {
                            Button("撤回文字发送授权") { model.revokeConsent() }
                        } else {
                            Text("尚未授权发送文字").foregroundStyle(Palette.secondary)
                        }
                    }.font(.system(size: 11))
                }.padding(10)
            }
            GroupBox("待办提示") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("打开客户端时显示待处理摘要", isOn: Binding(
                        get: { model.reminderOnOpen }, set: { model.setReminderOnOpen($0) }))
                    Text("按本机日期查看今天、本周（周一至周日）、本月；逾期单列。不会发送系统通知或邮件，也不会在每天 9:00 自动弹窗。邮箱提醒列入后续计划。")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(4)
                }.padding(10)
            }
            GroupBox("本地数据") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("SQLite 数据库、原图和 OCR 文字保存在此 Mac 的 Application Support/PromiseLedger 中，不在 Git 仓库中。当前版本未做应用层加密，请使用 FileVault 保护磁盘。")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(4)
                    if model.isPreview { Text("当前使用隔离的临时预览空间，不会写入真实账本。").font(.system(size: 11)).foregroundStyle(Palette.green) }
                    Button("在 Finder 中显示数据文件夹") { NSWorkspace.shared.open(model.dataRoot) }.font(.system(size: 11))
                }.padding(10)
            }
        }.padding(30).frame(width: 590).foregroundStyle(Palette.ink).background(Palette.background)
            .onAppear { model.reloadConfiguration() }
    }
}
