import AppKit
import ScreenCaptureKit
import LedgerCore

@MainActor public enum ScreenCaptureService {
    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    public static func capture() async throws -> CGImage {
        guard hasPermission || CGRequestScreenCaptureAccess() else {
            throw LedgerError.message("请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许 AI 账本，再返回重试；部分系统需要重启应用。图片导入不需要这项权限。")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        let screenID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let display = content.displays.first(where: { $0.displayID == screenID }) ?? content.displays.first else {
            throw LedgerError.message("没有找到可截图的显示器。")
        }
        let ownApplications = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        let scale = Double(filter.pointPixelScale)
        let nativeWidth = Double(display.width) * scale
        let nativeHeight = Double(display.height) * scale
        let resize = min(1, 4_096 / max(nativeWidth, nativeHeight))
        configuration.width = max(1, Int(nativeWidth * resize))
        configuration.height = max(1, Int(nativeHeight * resize))
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    public static func openPermissionSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}
