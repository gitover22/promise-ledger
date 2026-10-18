import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LedgerCore
import LedgerMac

enum LedgerSection: String, CaseIterable, Identifiable {
    case all = "全部账单", review = "待我确认", confirmed = "已入账"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .all: return "square.grid.2x2"; case .review: return "checkmark.bubble"; case .confirmed: return "checkmark.seal" }
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published var entries: [LedgerEntry] = []
    @Published var selection: String?
    @Published var section: LedgerSection = .all
    @Published var search = ""
    @Published var activity: String?
    @Published var banner: String?
    @Published var showConsent = false
    @Published var showSettings = false
    @Published var modelName = "未配置"
    @Published var capturePermission = ScreenCaptureService.hasPermission
    @Published var isCapturing = false
    @Published var isImporting = false
    @Published private(set) var initialized = false
    let dataRoot: URL
    let isPreview: Bool
    var openWindow: (() -> Void)?
    private var database: LedgerDatabase?
    private var worker: Task<Void, Never>?
    private let hotKey = GlobalHotKey()
    private let defaults: UserDefaults
    private var previewConsent = false

    init(dataRoot: URL = LedgerDatabase.defaultRoot, defaults: UserDefaults = .standard, isPreview: Bool = false) {
        self.dataRoot = dataRoot
        self.defaults = defaults
        self.isPreview = isPreview
    }

    var consentGranted: Bool { isPreview ? previewConsent : defaults.bool(forKey: "aiTextConsent.v1") }
    var selectedEntry: LedgerEntry? { entries.first { $0.id == selection } }
    var reviewCount: Int { entries.filter { $0.state == .needsReview }.count }
    var confirmedCount: Int { entries.filter { $0.state == .confirmed }.count }
    var queueCount: Int { entries.filter { $0.state == .queued || $0.state == .processing }.count }
    var filteredEntries: [LedgerEntry] {
        entries.filter { entry in
            let matchesSection = section == .all || (section == .review && entry.state == .needsReview) ||
                (section == .confirmed && entry.state == .confirmed)
            let haystack = [entry.title, entry.extraction?.merchant ?? "", entry.extraction?.orderID ?? ""].joined(separator: " ")
            return matchesSection && (search.isEmpty || haystack.localizedCaseInsensitiveContains(search))
        }
    }
    var monthTotal: String {
        let records = entries.filter { entry in
            guard entry.state == .confirmed, let dateText = entry.extraction?.transactionDate else { return false }
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
            guard let date = formatter.date(from: dateText) else { return false }
            return Calendar.current.isDate(date, equalTo: Date(), toGranularity: .month)
        }
        let currencies = Set(records.compactMap { $0.extraction?.currency })
        if currencies.count > 1 { return "多币种" }
        let valid = records.compactMap { $0.extraction }
        let total = valid.reduce(Decimal.zero) { $0 + ($1.decimalAmount ?? 0) }
        return BillExtraction(amount: NSDecimalNumber(decimal: total).stringValue, currency: currencies.first ?? "CNY").formattedAmount
    }

    func initialize() async {
        guard !initialized else { return }
        initialized = true
        do {
            database = try LedgerDatabase(root: dataRoot)
            try await reload()
        } catch { banner = error.localizedDescription }
        reloadConfiguration()
        do { try hotKey.register { [weak self] in self?.captureScreen() } }
        catch { banner = error.localizedDescription }
    }

    func reloadConfiguration() {
        do { modelName = try ModelConfiguration.load().model }
        catch { modelName = "未配置"; banner = error.localizedDescription }
        capturePermission = ScreenCaptureService.hasPermission
    }

    func chooseImages() {
        guard !isImporting else { return }
        let panel = NSOpenPanel()
        panel.title = "导入订单图片"
        panel.message = "支持手机订单截图、电子收据及账单图片，每张不超过 40 MB。"
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { importImages(panel.urls) }
    }

    func importImages(_ urls: [URL]) {
        guard !isImporting, let database else { return }
        guard urls.count <= 10 else { banner = "每次最多导入 10 张图片，模型会按顺序识别。"; return }
        isImporting = true
        Task {
            defer { isImporting = false }
            let images = await database.imagesDirectory
            for url in urls {
                do {
                    let prepared = try await Task.detached(priority: .userInitiated) {
                        try ImagePipeline.prepare(url: url, imagesDirectory: images)
                    }.value
                    try await enqueue(prepared, source: .image)
                } catch { banner = error.localizedDescription }
            }
            startOrRequestConsent()
        }
    }

    func captureScreen() {
        guard !isCapturing, let database else { return }
        isCapturing = true
        Task {
            defer { isCapturing = false; capturePermission = ScreenCaptureService.hasPermission }
            do {
                let image = try await ScreenCaptureService.capture()
                let images = await database.imagesDirectory
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try ImagePipeline.prepare(image: image, imagesDirectory: images)
                }.value
                try await enqueue(prepared, source: .screenshot)
                startOrRequestConsent()
            } catch { banner = error.localizedDescription; openWindow?() }
        }
    }

    private func enqueue(_ image: PreparedImage, source: EntrySource) async throws {
        guard let database else { return }
        if let existing = entries.first(where: { $0.imageHash == image.hash }) {
            selection = existing.id
            banner = "这张图片已经在账本里，已为你打开原记录。"
            openWindow?()
            return
        }
        let entry = LedgerEntry(source: source, imageFilename: image.filename, imageHash: image.hash)
        try await database.save(entry)
        try await reload()
        selection = entry.id
    }

    func grantConsent() {
        if isPreview { previewConsent = true }
        else { defaults.set(true, forKey: "aiTextConsent.v1") }
        showConsent = false
        beginWorker()
    }

    func revokeConsent() {
        if isPreview { previewConsent = false }
        else { defaults.set(false, forKey: "aiTextConsent.v1") }
        banner = "已暂停新的 AI 识别。正在进行的请求可能已发送，仍会完成并保存；后续识别将再次征得同意。"
        objectWillChange.send()
    }

    func startOrRequestConsent() {
        guard entries.contains(where: { $0.state == .queued }) else { return }
        if consentGranted { beginWorker() }
        else { openWindow?(); showConsent = true }
    }

    private func beginWorker() {
        guard worker == nil, consentGranted else { return }
        worker = Task {
            defer { worker = nil; activity = nil }
            while consentGranted, let pending = entries.last(where: { $0.state == .queued }) {
                await process(pending)
            }
        }
    }

    private func process(_ original: LedgerEntry) async {
        guard let database else { return }
        var entry = original
        do {
            let configuration = try ModelConfiguration.load()
            entry.state = .processing; entry.error = nil
            try await database.save(entry); try await reload()
            activity = "正在读取图片文字…"
            let path = await database.imagesDirectory.appendingPathComponent(entry.imageFilename)
            let text: String
            if entry.ocrText.isEmpty {
                text = try await Task.detached(priority: .userInitiated) { try ImagePipeline.recognize(url: path) }.value
            } else { text = entry.ocrText }
            entry.ocrText = text
            try await database.save(entry)
            guard consentGranted else {
                entry.state = .queued
                try await database.save(entry); try await reload()
                return
            }
            activity = "\(configuration.model) 正在整理账单…"
            let result = try await AIClient(configuration: configuration).extract(ocrText: text)
            entry.extraction = result; entry.state = .needsReview; entry.model = configuration.model
            try await database.save(entry); try await reload()
        } catch {
            entry.state = .failed; entry.error = error.localizedDescription
            do { try await database.save(entry); try await reload() }
            catch { banner = "识别记录保存失败，请检查磁盘空间。原图仍保留在本机。" }
            openWindow?()
        }
    }

    func retry(_ entry: LedgerEntry) {
        guard entry.state != .processing, entry.state != .confirmed, let database else { return }
        Task {
            do {
                var queued = entry; queued.state = .queued; queued.error = nil
                try await database.save(queued); try await reload()
                startOrRequestConsent()
            } catch { banner = error.localizedDescription }
        }
    }

    func confirm(_ entry: LedgerEntry, draft: BillExtraction) async -> Bool {
        guard let database, entry.state == .needsReview else { return false }
        guard draft.decimalAmount != nil, let currency = draft.currency,
              currency.range(of: #"^[A-Z]{3}$"#, options: .regularExpression) != nil else {
            banner = "入账前请填写有效金额和三位大写币种（例如 CNY）。"; return false
        }
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            banner = "入账前请填写账单名称。"; return false
        }
        if let date = draft.transactionDate, !date.isEmpty, !BillExtraction.isValidDate(date) {
            banner = "交易日期请使用 YYYY-MM-DD 格式，也可以留空。"; return false
        }
        do {
            var updated = entry; updated.extraction = draft; updated.state = .confirmed
            try await database.save(updated); try await reload()
            return true
        } catch { banner = error.localizedDescription; return false }
    }

    func imageURL(for entry: LedgerEntry) -> URL {
        dataRoot.appendingPathComponent("Images").appendingPathComponent(entry.imageFilename)
    }

    private func reload() async throws {
        guard let database else { return }
        entries = try await database.list()
    }
}
