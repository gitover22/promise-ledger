import AppKit
import SwiftUI
import LedgerCore
import LedgerMac

struct ConsentView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            BrandMark(size: 49)
            Text("启用账单识别").font(.system(size: 26, weight: .semibold))
            Text("识别前，请确认以下数据处理方式。").font(.system(size: 12)).foregroundStyle(Palette.secondary)
            VStack(alignment: .leading, spacing: 16) {
                note("photo", "图片保存在本机", "截图和导入的图片保存在这台 Mac，不上传原图。")
                note("text.viewfinder", "图片文字发送至 AI 服务", "识别出的全部文字会发送至 \(model.modelName)，用于提取账单信息。文字可能包含姓名、地址等敏感信息，请确认图片内容后继续。")
                note("hand.raised", "核对后入账", "应用仅在主动截图或导入后识别，不持续录屏或监控页面。识别结果需要你确认后才入账。")
            }.padding(18).background(Palette.paleGreen.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            Text("授权后，后续截图和导入将自动识别。可在「设置与隐私」中撤回授权。")
                .font(.system(size: 10)).foregroundStyle(Palette.secondary).lineSpacing(4)
            HStack {
                Button("暂不识别") { model.showConsent = false }.buttonStyle(QuietButtonStyle())
                Spacer()
                Button("同意并识别") { model.grantConsent() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
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
            GroupBox("截图") {
                VStack(alignment: .leading, spacing: 13) {
                    LabeledContent("全屏截图快捷键", value: "Control + Option + L")
                    Text("截取鼠标所在屏幕的完整画面。关闭窗口后仍可通过快捷键或菜单栏截图；不会持续录屏。")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(4)
                    HStack {
                        Label(model.capturePermission ? "屏幕录制：已授权" : "屏幕录制：未授权", systemImage: model.capturePermission ? "checkmark.circle" : "lock")
                        Spacer()
                        Button("打开系统设置") { ScreenCaptureService.openPermissionSettings() }
                        Button("刷新") { model.reloadConfiguration() }
                    }.font(.system(size: 11))
                }.padding(10)
            }
            GroupBox("识别服务") {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("默认模型", value: model.modelName)
                    LabeledContent("密钥存储", value: "macOS 钥匙串")
                    DisclosureGroup("接入信息") {
                        Text("配置文件：~/.config/promise-ledger/model.json\n服务：Rednote MaaS\n请求场景：bill-extraction")
                            .font(.system(size: 10)).foregroundStyle(Palette.secondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 5)
                    }.font(.system(size: 11))
                    HStack {
                        Button("重新读取配置") { model.reloadConfiguration() }
                        Spacer()
                        if model.consentGranted {
                            Button("撤回识别授权") { model.revokeConsent() }
                        } else {
                            Text("识别未授权").foregroundStyle(Palette.secondary)
                        }
                    }.font(.system(size: 11))
                }.padding(10)
            }
            GroupBox("待办提示") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("打开窗口时显示待办概览", isOn: Binding(
                        get: { model.reminderOnOpen }, set: { model.setReminderOnOpen($0) }))
                    Text("有未完成待办时，在首页显示今天、本周和本月的数量。提醒仅在应用内显示，不发送系统通知或邮件。")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(4)
                }.padding(10)
            }
            GroupBox("本地数据") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("账单、图片和识别文字均保存在这台 Mac，不做云端同步。识别时，图片文字仍会发送至 AI 服务。数据未单独加密，建议开启 FileVault。")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(4)
                    if model.isPreview { Text("演示数据独立保存，不影响正式账本。").font(.system(size: 11)).foregroundStyle(Palette.green) }
                    Button("打开数据文件夹") { NSWorkspace.shared.open(model.dataRoot) }.font(.system(size: 11))
                }.padding(10)
            }
        }.padding(30).frame(width: 590).foregroundStyle(Palette.ink).background(Palette.background)
            .onAppear { model.reloadConfiguration() }
    }
}
