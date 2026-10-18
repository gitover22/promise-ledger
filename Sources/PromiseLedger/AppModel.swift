import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import LedgerCore
import LedgerMac

enum LedgerSection: String, CaseIterable, Identifiable {
    case all = "全部账单", review = "待确认", confirmed = "已入账", reminders = "待办事项"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .review: return "checkmark.bubble"
        case .confirmed: return "checkmark.seal"
        case .reminders: return "calendar.badge.clock"
        }
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published var entries: [LedgerEntry] = []
    @Published var reminders: [LedgerReminder] = []
    @Published var reminderPeriod: ReminderPeriod = .today
    @Published var showOpenReminder = true
    @Published var reminderOnOpen: Bool
    @Published private(set) var calendarNow = Date()
    @Published var selection: String?
    @Published var section: LedgerSection = .all
    @Published var search = ""
    @Published var activity: String?
    @Published var banner: String?
    @Published var requestedDetailID: String?
    @Published var showConsent = false
    @Published var showSettings = false
    @Published var modelName = "未配置"
    @Published var capturePermission = ScreenCaptureService.hasPermission
    @Published var isCapturing = false
    let importBatch = ImportBatch()
    let importSelection = ImportSelection()
    var isImporting: Bool { importBatch.isImporting }
    private var importSubscriptions = Set<AnyCancellable>()
    @Published private(set) var isInitializing = false
    @Published private(set) var initialized = false
    @Published private(set) var queuePaused = false
    let dataRoot: URL
    let isPreview: Bool
    var openWindow: (() -> Void)?
    private var database: LedgerDatabase?
    private var worker: Task<Void, Never>?
    private let hotKey = GlobalHotKey()
    private let defaults: UserDefaults
    private let configurationURL: URL
    private let captureImage: @MainActor () async throws -> CGImage
    private let extractBill: @MainActor (ModelConfiguration, String) async throws -> BillExtraction
    private var previewConsent = false

    init(dataRoot: URL = LedgerDatabase.defaultRoot, defaults: UserDefaults = .standard, isPreview: Bool = false,
         configurationURL: URL = ModelConfiguration.defaultURL,
         captureImage: @escaping @MainActor () async throws -> CGImage = { try await ScreenCaptureService.capture() },
         extractBill: @escaping @MainActor (ModelConfiguration, String) async throws -> BillExtraction = { configuration, text in
             try await AIClient(configuration: configuration).extract(ocrText: text)
         }) {
        self.dataRoot = dataRoot
        self.defaults = defaults
        self.isPreview = isPreview
        self.configurationURL = configurationURL
        self.captureImage = captureImage
        self.extractBill = extractBill
        self.reminderOnOpen = isPreview || defaults.object(forKey: "reminders.showOnOpen.v1") == nil
            ? true : defaults.bool(forKey: "reminders.showOnOpen.v1")
        importBatch.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &importSubscriptions)
        importSelection.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &importSubscriptions)
    }

    var consentGranted: Bool { isPreview ? previewConsent : defaults.bool(forKey: "aiTextConsent.v1") }
    var selectedEntry: LedgerEntry? { entries.first { $0.id == selection } }
    var reviewCount: Int { entries.filter { [.needsReview, .duplicateReview].contains($0.state) }.count }
    var confirmedCount: Int { entries.filter { $0.state == .confirmed }.count }
    var queueCount: Int { entries.filter { $0.state == .queued || $0.state == .processing }.count }
    var agenda: ReminderAgenda { ReminderAgenda(reminders: reminders, now: calendarNow) }
    var shouldShowOpenReminder: Bool { reminderOnOpen && showOpenReminder && !agenda.pending.isEmpty }

    func updateCalendar() { calendarNow = Date() }
    func windowOpened() async {
        guard initialized else { return }
        updateCalendar()
        do { try await reload(); showOpenReminder = true }
        catch { banner = error.localizedDescription }
    }
    func setReminderOnOpen(_ enabled: Bool) {
        reminderOnOpen = enabled
        if !isPreview { defaults.set(enabled, forKey: "reminders.showOnOpen.v1") }
    }
    func showReminders(_ period: ReminderPeriod = .today) {
        reminderPeriod = period
        section = .reminders
    }
    func canonicalEntry(for id: String) -> LedgerEntry? {
        var current = id
        var visited = Set<String>()
        while visited.insert(current).inserted, let entry = entries.first(where: { $0.id == current }) {
            if let target = entry.duplicateOf { current = target } else { return entry }
        }
        return nil
    }
    func saveReminder(_ draft: ReminderDraft, title: String, dueDate: String?) async -> Bool {
        guard let database else { return false }
        do {
            if let id = draft.existingID {
                try await database.editReminder(id: id, title: title, dueDate: dueDate)
                banner = "待办已更新。"
            } else {
                let stored = try await database.addReminder(entryID: draft.entryID, title: title, dueDate: dueDate, sourceQuote: draft.sourceQuote)
                banner = stored.status == .pending ? "待办已保存。" : "已有\(stored.status.label)的相同待办，未重复添加。可在历史记录中恢复。"
            }
            try await reload()
            return true
        } catch { banner = error.localizedDescription; return false }
    }
    func setReminderStatus(_ reminder: LedgerReminder, _ status: ReminderStatus) async {
        guard let database else { return }
        do { try await database.setReminderStatus(id: reminder.id, status: status); try await reload() }
        catch { banner = error.localizedDescription }
    }
    var filteredEntries: [LedgerEntry] {
        entries.filter { entry in
            guard entry.state != .duplicate else { return false }
            let matchesSection = section == .all || (section == .review && [.needsReview, .duplicateReview].contains(entry.state)) ||
                (section == .confirmed && entry.state == .confirmed)
            let haystack = [entry.title, entry.extraction?.merchant ?? "", entry.extraction?.platform ?? "", entry.extraction?.orderID ?? ""].joined(separator: " ")
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

    func initialize(registerHotKey: Bool = true) async {
        guard !initialized, !isInitializing else { return }
        isInitializing = true
        defer { isInitializing = false }
        do {
            database = try LedgerDatabase(root: dataRoot)
            if isPreview && CommandLine.arguments.contains("--preview-reminders") { try await seedReminderPreview() }
            try await reload()
            initialized = true
            banner = nil
        } catch { database = nil; banner = error.localizedDescription; return }
        reloadConfiguration()
        if registerHotKey {
            do { try hotKey.register { [weak self] in self?.captureScreen() } }
            catch { banner = error.localizedDescription }
        }
    }

    func reloadConfiguration() {
        do { modelName = try ModelConfiguration.load(from: configurationURL).model }
        catch { modelName = "未配置"; banner = error.localizedDescription }
        capturePermission = ScreenCaptureService.hasPermission
    }

    func chooseImages() {
        guard !isImporting else { banner = "上一批文件仍在导入，请等待完成后再选择图片。"; return }
        guard !importSelection.isPresented else { banner = "请先确认或取消当前待导入文件。"; return }
        guard readyDatabase() != nil else { return }
        let panel = NSOpenPanel()
        panel.title = "导入图片"
        panel.message = "选择订单截图或收据，每次最多 10 张，每张不超过 40 MB。"
        panel.allowedContentTypes = ImagePipeline.supportedContentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { importImages(panel.urls) }
    }

    func importImages(_ urls: [URL]) {
        importCandidates(urls.map { ImportCandidate.file($0) })
    }

    @discardableResult func importCandidates(_ candidates: [ImportCandidate]) -> Bool {
        guard readyDatabase() != nil else { return false }
        guard !isImporting else { banner = "上一批文件仍在导入，此次未导入。请等待完成后再选择或拖入。"; return false }
        return importSelection.stage(candidates)
    }

    func confirmImportSelection() {
        guard !isImporting else { banner = "上一批文件仍在导入，请等待完成后再确认。"; return }
        guard let database = readyDatabase() else { return }
        let candidates = importSelection.confirm()
        guard !candidates.isEmpty else { return }
        importBatch.start(candidates, importFile: { [self] url, expectedContentHash in
            let images = await database.imagesDirectory
            let prepared = try await Task.detached(priority: .userInitiated) {
                try ImagePipeline.prepare(url: url, imagesDirectory: images, expectedContentHash: expectedContentHash)
            }.value
            return try await enqueue(prepared, source: .image)
        }, completion: { [weak self] in self?.startOrRequestConsent() })
    }

    func showImportedEntry(_ id: String) {
        selection = canonicalEntry(for: id)?.id ?? id
        requestedDetailID = selection
    }

    func captureScreen() {
        guard !isCapturing, let database = readyDatabase() else { return }
        isCapturing = true
        Task {
            defer { isCapturing = false; capturePermission = ScreenCaptureService.hasPermission }
            do {
                let image = try await captureImage()
                let images = await database.imagesDirectory
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try ImagePipeline.prepare(image: image, imagesDirectory: images)
                }.value
                _ = try await enqueue(prepared, source: .screenshot)
                startOrRequestConsent()
            } catch { banner = error.localizedDescription; openWindow?() }
        }
    }

    private func enqueue(_ image: PreparedImage, source: EntrySource) async throws -> ImportOutcome {
        guard let database else { throw LedgerError.message("账本尚未就绪，请稍后重试。") }
        let entry = LedgerEntry(source: source, imageFilename: image.filename, imageHash: image.hash)
        let identifier = try await database.enqueue(entry)
        try await reload()
        let existing = entries.first { $0.id == identifier }
        let canonicalID = canonicalEntry(for: identifier)?.id ?? identifier
        selection = canonicalID
        if identifier != entry.id {
            if source == .screenshot {
                if let existing, ![.queued, .processing].contains(existing.state) { requestedDetailID = canonicalID }
                banner = "图片已导入，未重复添加。"
                openWindow?()
            }
            return .duplicate(entryID: canonicalID)
        }
        return .imported(entryID: identifier)
    }

    private func readyDatabase() -> LedgerDatabase? {
        guard initialized, let database else {
            if banner == nil { banner = isInitializing ? "账本正在初始化，请稍后重试。" : "账本尚未就绪，请点击「重试初始化」。" }
            openWindow?()
            return nil
        }
        return database
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
        banner = "已撤回识别授权。已发送的请求仍会完成并保存；后续识别需重新授权。"
        objectWillChange.send()
    }

    func startOrRequestConsent() {
        guard entries.contains(where: { $0.state == .queued }) else { return }
        guard !queuePaused else { openWindow?(); return }
        if consentGranted { beginWorker() }
        else { openWindow?(); showConsent = true }
    }

    private func beginWorker() {
        guard worker == nil, consentGranted, !queuePaused else { return }
        worker = Task {
            defer { worker = nil; activity = nil }
            while consentGranted, let pending = entries.last(where: { $0.state == .queued }) {
                guard await process(pending) else { break }
            }
        }
    }

    private func process(_ original: LedgerEntry) async -> Bool {
        guard let database else { return false }
        var entry = original
        do {
            let configuration = try ModelConfiguration.load(from: configurationURL)
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
                return false
            }
            activity = "正在识别账单…"
            let result = try await extractBill(configuration, text)
            entry.extraction = result; entry.state = .needsReview; entry.model = configuration.model
            entry.promptVersion = LedgerSystemPrompt.version
            let stored = try await database.save(entry); try await reload()
            reportDeduplication(stored)
        } catch {
            entry.state = .failed; entry.error = error.localizedDescription
            do { try await database.save(entry); try await reload() }
            catch {
                queuePaused = true
                banner = "识别队列已暂停。请检查磁盘空间后重试，原图已保留。"
                openWindow?()
                return false
            }
            openWindow?()
        }
        return true
    }

    func retry(_ entry: LedgerEntry) {
        guard [.failed, .queued, .needsReview].contains(entry.state) || (queuePaused && entry.state == .processing),
              let database else { return }
        Task {
            do {
                var retries = [entry]
                if queuePaused { retries += entries.filter { $0.state == .processing && $0.id != entry.id } }
                for var queued in retries {
                    queued.state = .queued; queued.error = nil; queued.distinctFingerprint = nil
                    try await database.save(queued)
                }
                try await reload()
                queuePaused = false
                startOrRequestConsent()
            } catch { banner = error.localizedDescription }
        }
    }

    static let defaultReviewCurrency = "CNY"

    func needsCurrencyDefault(for entry: LedgerEntry) -> Bool {
        guard entry.state == .needsReview, let extraction = entry.extraction else { return false }
        return extraction.currency?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }

    func reviewDraft(for entry: LedgerEntry) -> BillExtraction {
        var draft = entry.extraction ?? BillExtraction()
        if needsCurrencyDefault(for: entry) { draft.currency = Self.defaultReviewCurrency }
        return draft
    }

    func confirm(_ entry: LedgerEntry, draft: BillExtraction) async -> Bool {
        guard let database, entry.state == .needsReview else { return false }
        guard draft.decimalAmount != nil else {
            banner = "请填写有效金额。"; return false
        }
        guard let currency = draft.currency,
              currency.range(of: #"^[A-Z]{3}$"#, options: .regularExpression) != nil else {
            banner = "请填写三位币种代码（如 CNY、USD）。"; return false
        }
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            banner = "请填写账单名称。"; return false
        }
        if let date = draft.transactionDate, !date.isEmpty, !BillExtraction.isValidDate(date) {
            banner = "交易日期请使用 YYYY-MM-DD 格式，也可以留空。"; return false
        }
        do {
            var updated = entry; updated.extraction = draft; updated.state = .confirmed
            let stored = try await database.save(updated); try await reload()
            if stored.state != .confirmed { reportDeduplication(stored); return false }
            banner = nil
            return true
        } catch { banner = error.localizedDescription; return false }
    }

    func linkedEvidence(for entry: LedgerEntry) -> [LedgerEntry] {
        entries.filter { $0.duplicateOf == entry.id }.sorted { $0.createdAt < $1.createdAt }
    }

    func linkDuplicate(_ entry: LedgerEntry, to target: String) async {
        guard let database else { return }
        do {
            let stored = try await database.linkDuplicate(entry.id, to: target)
            try await reload()
            reportDeduplication(stored)
        } catch { banner = error.localizedDescription }
    }

    func keepSeparate(_ entry: LedgerEntry) async {
        guard let database else { return }
        do {
            try await database.keepAsSeparateOrder(entry.id)
            try await reload()
            banner = "已保留为新订单，请核对信息后入账。"
        } catch { banner = error.localizedDescription }
    }

    private func reportDeduplication(_ entry: LedgerEntry) {
        if let original = entry.duplicateOf {
            selection = original
            requestedDetailID = original
            banner = "已关联到原订单，不重复入账。新图片和承诺已保存，原订单信息未更改。"
            openWindow?()
        } else if entry.state == .duplicateReview {
            banner = "可能与已有账单重复，请核对后选择关联或保留为新订单。"
        }
    }

    func imageURL(for entry: LedgerEntry) -> URL {
        dataRoot.appendingPathComponent("Images").appendingPathComponent(entry.imageFilename)
    }

    private func reload() async throws {
        guard let database else { return }
        entries = try await database.list()
        reminders = try await database.reminders()
        updateCalendar()
    }

    /// Explicit offline UI fixtures in a new temporary preview space, never real AI output.
    private func seedReminderPreview() async throws {
        guard isPreview, let database else { return }
        let fixture = dataRoot.appendingPathComponent("synthetic-receipt.png")
        try ImagePipeline.makeDiagnosticReceipt(at: fixture)
        let images = await database.imagesDirectory
        let prepared = try ImagePipeline.prepare(url: fixture, imagesDirectory: images)
        let text = try ImagePipeline.recognize(url: images.appendingPathComponent(prepared.filename))
        let order = try await database.save(LedgerEntry(source: .image, imageFilename: prepared.filename,
            imageHash: prepared.hash, state: .confirmed, ocrText: text,
            extraction: BillExtraction(title: "演示订单 · 合成样例（非 AI 识别）", amount: "129.00", currency: "CNY",
                promises: [LedgerPromise(text: "一年保修", sourceQuote: "Warranty: 1 year")])))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        for (offset, title) in [(-1, "演示：逾期退款跟进"), (0, "演示：核对今日退款"), (2, "演示：申请价保"), (45, "演示：稍后核验保修")] {
            let due = formatter.string(from: calendar.date(byAdding: .day, value: offset, to: Date())!)
            try await database.addReminder(entryID: order.id, title: title, dueDate: due)
        }
        try await database.addReminder(entryID: order.id, title: "演示：待确定跟进日期", dueDate: nil)
        let completed = try await database.addReminder(entryID: order.id, title: "演示：已完成收货核验", dueDate: formatter.string(from: Date()))
        try await database.setReminderStatus(id: completed.id, status: .completed)
    }
}
