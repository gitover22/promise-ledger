import AppKit
import SwiftUI
import Combine
import LedgerCore
import LedgerMac

@main @MainActor struct PromiseLedgerApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model: AppModel = {
        guard CommandLine.arguments.contains("--preview") || CommandLine.arguments.contains("--preview-reminders") else { return AppModel() }
        let identifier = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PromiseLedger-UIPreview-" + identifier)
        return AppModel(dataRoot: root, isPreview: true)
    }()
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var activityItem: NSMenuItem?
    private var subscriptions: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        buildStatusMenu()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 790),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = model.isPreview ? "AI 账本 · 隔离预览" : "你的智能 AI 账本"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(calibratedWhite: 0.97, alpha: 1)
        window.minSize = NSSize(width: 1_040, height: 700)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: ContentView().environmentObject(model))
        window.center()
        self.window = window
        model.openWindow = { [weak self] in self?.showWindow() }
        model.$activity.sink { [weak self] activity in
            self?.activityItem?.title = activity ?? "就绪"
            self?.statusItem?.button?.toolTip = activity ?? "AI 账本 · ⌃⌥L 全屏截图"
        }.store(in: &subscriptions)
        showWindow()
        Task { await model.initialize() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    @objc func showWindow() {
        let wasHidden = window?.isVisible == false
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if wasHidden { Task { await model.windowOpened() } }
    }
    @objc private func capture() { model.captureScreen() }
    @objc private func importImages() { showWindow(); model.chooseImages() }
    @objc private func settings() { showWindow(); model.showSettings = true }
    @objc private func reminders() { showWindow(); model.showReminders() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func buildStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "text.book.closed", accessibilityDescription: "AI 账本")
        let menu = NSMenu()
        let title = NSMenuItem(title: "你的智能 AI 账本", action: nil, keyEquivalent: "")
        menu.addItem(title)
        let activity = NSMenuItem(title: "就绪", action: nil, keyEquivalent: "")
        menu.addItem(activity); activityItem = activity
        menu.addItem(.separator())
        menu.addItem(item("打开账本", #selector(showWindow)))
        menu.addItem(item("查看待办", #selector(reminders)))
        menu.addItem(item("截图识别         ⌃⌥L", #selector(capture)))
        menu.addItem(item("导入图片…", #selector(importImages)))
        menu.addItem(.separator())
        menu.addItem(item("设置与隐私…", #selector(settings)))
        menu.addItem(item("退出 AI 账本", #selector(quit)))
        statusItem?.menu = menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func buildMainMenu() {
        let root = NSMenu()
        let app = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(item("关于 AI 账本", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        appMenu.items.last?.target = NSApp
        appMenu.addItem(item("设置…", #selector(settings), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(item("退出 AI 账本", #selector(quit), key: "q"))
        app.submenu = appMenu; root.addItem(app)
        let file = NSMenuItem(title: "文件", action: nil, keyEquivalent: ""); let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(item("导入图片…", #selector(importImages), key: "o"))
        fileMenu.addItem(item("显示账本", #selector(showWindow), key: "1"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        file.submenu = fileMenu; root.addItem(file)
        let edit = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""); let editMenu = NSMenu(title: "编辑")
        for (title, selector, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"),
                                       ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: Selector(selector), keyEquivalent: key))
        }
        edit.submenu = editMenu; root.addItem(edit)
        NSApp.mainMenu = root
    }
}
