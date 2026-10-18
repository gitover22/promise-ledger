import AppKit
import Combine
import CSQLite
import LedgerCore
import LedgerMac

private struct TestFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw TestFailure(message: message) }
}

@MainActor private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw TestFailure(message: "Timed out waiting for the local task")
}

/// Uses synthetic captures and isolated databases; AI is opt-in via --live-ai only.
@main struct LedgerAppTests {
    @MainActor static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        var configurationURL = ModelConfiguration.defaultURL
        if let index = arguments.firstIndex(of: "--config") {
            guard arguments.indices.contains(index + 1) else {
                print("Usage: test-capture.sh [--live-ai [--config /path/to/model.json]]")
                exit(2)
            }
            configurationURL = URL(fileURLWithPath: arguments[index + 1])
        }
        let liveAI = arguments.contains("--live-ai")
        if liveAI {
            do { _ = try ModelConfiguration.load(from: configurationURL) }
            catch { print("LIVE AI BLOCKED: \(error.localizedDescription)"); exit(2) }
        }
        var cases: [(String, @MainActor () async throws -> Void)] = [
            ("initialization failure can recover", initializationRecovery),
            ("capture reentry, consent, persistence and duplicate", captureLifecycle),
            ("capture failure permits retry", captureRecovery),
            ("captured receipt runs real OCR and honors revoked consent", capturedReceiptOCR),
            ("review corrections validate and persist exact money", reviewConfirmation),
            ("missing review currency defaults without rewriting extraction", reviewCurrencyDefault),
            ("default review currency still requires duplicate review", reviewCurrencyDeduplication),
            ("storage failure stops worker", storageFailure),
            ("processing record resumes after storage recovery", { try await processingStorageRecovery() }),
            ("retrying another record resumes interrupted processing", { try await processingStorageRecovery(retryAnotherEntry: true) })
        ]
        if liveAI {
            print("LIVE AI: sends only generated receipt OCR to the configured model; no real screen capture.")
            cases.append(("live screenshot task -> OCR -> AI -> review -> SQLite", {
                try await liveReceiptPipeline(configurationURL: configurationURL)
            }))
        }
        var failures = 0
        for (name, operation) in cases {
            do { try await operation(); print("PASS: \(name)") }
            catch { failures += 1; print("FAIL: \(name): \(error.localizedDescription)") }
        }
        let scope = liveAI ? "Synthetic captures only; live model explicitly enabled; user ledger untouched." : "Synthetic captures only; no AI, credentials or user ledger used."
        print("\(cases.count - failures)/\(cases.count) app tests passed. \(scope)")
        if failures > 0 { exit(1) }
    }

    @MainActor static func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LedgerCaptureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @MainActor static func syntheticImage() throws -> CGImage {
        guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw TestFailure(message: "Cannot create synthetic image")
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        guard let image = context.makeImage() else { throw TestFailure(message: "Cannot create synthetic image") }
        return image
    }

    @MainActor static func testConfiguration(in root: URL) throws -> URL {
        let url = root.appendingPathComponent("test-model.json")
        let configuration = """
        {"chat_completions_url":"https://example.invalid/chat/completions","model":"test-only",
         "authorization_header":"Authorization","authorization_value_prefix":"Bearer ",
         "application_id":"test","application_id_field":"x-maas-app-id","application_id_location":"header",
         "credential":{"store":"macos-keychain","service":"LedgerCaptureTests-unused","account":"unused"},
         "request_defaults":{"stream":false}}
        """
        try Data(configuration.utf8).write(to: url)
        return url
    }

    @MainActor static func capturedReceiptOCR() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = root.appendingPathComponent("synthetic-receipt.png")
        try ImagePipeline.makeDiagnosticReceipt(at: receipt)
        guard let image = NSBitmapImageRep(data: try Data(contentsOf: receipt))?.cgImage else {
            throw TestFailure(message: "Cannot read generated receipt")
        }
        var aiCalls = 0
        let model = AppModel(dataRoot: root, isPreview: true, configurationURL: try testConfiguration(in: root),
                             captureImage: { image }, extractBill: { _, _ in
            aiCalls += 1
            throw TestFailure(message: "Revoked consent must not enter the model boundary")
        })
        await model.initialize(registerHotKey: false)
        var revoked = false
        let observation = model.$activity.sink { activity in
            if activity == "正在读取图片文字…", !revoked {
                revoked = true
                model.revokeConsent()
            }
        }
        defer { observation.cancel() }
        model.captureScreen()
        try await waitUntil { !model.isCapturing }
        try expect(model.entries.count == 1 && model.showConsent, "Receipt capture must first await consent")
        model.grantConsent()
        try await waitUntil(timeout: .seconds(20)) { model.entries.first?.state == .queued && model.entries.first?.ocrText.isEmpty == false }
        try expect(revoked && !model.consentGranted && aiCalls == 0, "Revocation did not block the model call after OCR")
        let entry = model.entries[0]
        try expect(entry.ocrText.contains("129.00"), "Actual screenshot OCR lost the receipt amount")
        try expect(entry.ocrText.contains("TEST-20261018-001"), "Actual screenshot OCR lost the order ID")
        try expect(entry.source == .screenshot && entry.extraction == nil, "OCR-only run must not invent AI extraction")
        let store = try LedgerDatabase(root: root)
        let restored = try await store.list()
        try expect(restored.first?.ocrText == entry.ocrText && restored.first?.state == .queued,
                   "Actual OCR text was not persisted for a later user-initiated attempt")
        try expect(FileManager.default.fileExists(atPath: model.imageURL(for: entry).path), "Receipt original was not saved")
        print("CHECK: real Vision OCR recovered amount 129.00 and order TEST-20261018-001 through AppModel; AI blocked by revocation")
    }

    @MainActor static func liveReceiptPipeline(configurationURL: URL) async throws {
        // Validate configuration before any credential access or generated-image processing.
        let configuration = try ModelConfiguration.load(from: configurationURL)
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = root.appendingPathComponent("synthetic-receipt.png")
        try ImagePipeline.makeDiagnosticReceipt(at: receipt)
        guard let image = NSBitmapImageRep(data: try Data(contentsOf: receipt))?.cgImage else {
            throw TestFailure(message: "Cannot read generated receipt")
        }
        // Real AIClient and transport: only capture is injected, to avoid reading the desktop.
        let model = AppModel(dataRoot: root, isPreview: true, configurationURL: configurationURL, captureImage: { image })
        await model.initialize(registerHotKey: false)
        model.captureScreen()
        try await waitUntil { !model.isCapturing }
        try expect(model.entries.count == 1 && model.entries[0].state == .queued && model.showConsent,
                   "Live diagnostic must require consent before processing")
        model.grantConsent()
        try await waitUntil(timeout: .seconds(120)) {
            model.entries.first?.state == .needsReview || model.entries.first?.state == .failed || model.queuePaused
        }
        guard let entry = model.entries.first, entry.state == .needsReview, let extraction = entry.extraction else {
            throw TestFailure(message: model.entries.first?.error ?? model.banner ?? "Live screenshot task did not produce a reviewable bill")
        }
        try expect(extraction.decimalAmount == Decimal(string: "129.00") && extraction.currency == "CNY",
                   "Live extraction amount/currency did not match the known receipt")
        try expect(extraction.orderID == "TEST-20261018-001", "Live extraction lost the known order ID")
        try expect(entry.source == .screenshot && entry.model == configuration.model && entry.ocrText.contains("129.00"),
                   "Live result lost capture source, model or OCR evidence")
        // Check actual model output before simulating confirmation; do not correct extraction errors.
        let confirmed = await model.confirm(entry, draft: extraction)
        try expect(confirmed, "Known synthetic receipt could not be confirmed")
        let reopened = try LedgerDatabase(root: root)
        let rows = try await reopened.list()
        try expect(rows.count == 1 && rows.first?.state == .confirmed && rows.first?.extraction == extraction && rows.first?.ocrText == entry.ocrText,
                   "Live screenshot result did not survive database reopen")
        print("CHECK: \(configuration.model) extracted CNY 129.00 / TEST-20261018-001 via the real AppModel pipeline")
    }

    @MainActor static func reviewConfirmation() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LedgerDatabase(root: root)
        // A domain fixture tests review/save behavior; it is not a model response or accuracy claim.
        let candidate = BillExtraction(title: "Synthetic receipt", merchant: "Test Store", amount: "129.00", currency: "CNY",
                                       transactionDate: "2026-10-18", orderID: "TEST-20261018-001", confidence: 0.8)
        let entry = LedgerEntry(source: .screenshot, imageFilename: "fixture.jpg", imageHash: "review-fixture", state: .needsReview,
                                ocrText: "Total paid: 129.00 CNY", extraction: candidate)
        try await store.save(entry)
        let model = AppModel(dataRoot: root, isPreview: true, captureImage: {
            throw TestFailure(message: "Review test must not capture")
        })
        await model.initialize(registerHotKey: false)
        var invalid = candidate; invalid.amount = "-1"
        let rejected = await model.confirm(entry, draft: invalid)
        try expect(!rejected && model.entries.first?.state == .needsReview, "Invalid money must not enter the confirmed ledger")
        var corrected = candidate; corrected.amount = "129.10"; corrected.merchant = "Corrected Test Store"
        let confirmed = await model.confirm(entry, draft: corrected)
        try expect(confirmed && model.entries.first?.state == .confirmed, "Valid review corrections were not confirmed")
        let reopened = try LedgerDatabase(root: root)
        let rows = try await reopened.list()
        try expect(rows.first?.extraction?.amount == "129.10" && rows.first?.extraction?.decimalAmount == Decimal(string: "129.10"),
                   "Confirmed amount did not retain exact decimal value")
        try expect(rows.first?.extraction?.merchant == "Corrected Test Store" && rows.first?.state == .confirmed,
                   "Review corrections were lost after reopening the database")
        try expect(rows.first?.source == .screenshot && rows.first?.ocrText == entry.ocrText && rows.first?.imageHash == entry.imageHash,
                   "Confirmation modified source evidence")
    }

    @MainActor static func reviewCurrencyDefault() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LedgerDatabase(root: root)
        let extraction = BillExtraction(title: "Synthetic missing-currency receipt", merchant: "Currency Test Store",
                                        amount: "22.90", transactionDate: "2026-10-11")
        let entry = LedgerEntry(source: .screenshot, imageFilename: "unused.jpg", imageHash: "currency-default",
                                state: .needsReview, ocrText: "Total paid: ¥22.90", extraction: extraction)
        try await store.save(entry)
        let model = AppModel(dataRoot: root, isPreview: true)
        await model.initialize(registerHotKey: false)
        let draft = model.reviewDraft(for: entry)
        try expect(draft.currency == "CNY" && draft.amount == "22.90" && draft.transactionDate == "2026-10-11",
                   "Missing currency should prefill CNY without changing amount or date")
        let before = try await store.list()
        try expect(before.first?.extraction == extraction && before.first?.state == .needsReview && model.entries.first?.extraction == extraction,
                   "Opening review must not rewrite the saved model result or confirm it")
        for currency in ["", " \n\t"] {
            var blank = entry
            blank.extraction?.currency = currency
            try expect(model.reviewDraft(for: blank).currency == "CNY", "Blank currency was not prefilled")
        }
        for currency in ["USD", "JPY", "CNY"] {
            var explicit = entry
            explicit.extraction?.currency = currency
            try expect(model.reviewDraft(for: explicit).currency == currency, "Explicit currency was overwritten")
        }
        for state in [EntryState.confirmed, .duplicate, .duplicateReview, .queued, .failed] {
            var other = entry; other.state = state
            try expect(model.reviewDraft(for: other).currency == nil, "Currency default leaked outside editable review")
        }
        var cleared = draft; cleared.currency = nil
        let rejected = await model.confirm(entry, draft: cleared)
        try expect(!rejected && model.entries.first?.state == .needsReview,
                   "An explicitly cleared currency must not be silently restored on confirmation")
        let confirmed = await model.confirm(entry, draft: draft)
        try expect(confirmed, "Default currency could not be confirmed")
        try expect(model.banner == nil, "A successful confirmation left an obsolete validation error")
        let foreignExtraction = BillExtraction(title: "Synthetic foreign receipt", merchant: "Foreign Currency Store", amount: "18.90")
        let foreign = LedgerEntry(source: .image, imageFilename: "foreign.jpg", imageHash: "currency-corrected",
                                  state: .needsReview, ocrText: "Total 18.90", extraction: foreignExtraction)
        try await store.save(foreign)
        var corrected = model.reviewDraft(for: foreign); corrected.currency = "USD"
        let correctedConfirmation = await model.confirm(foreign, draft: corrected)
        try expect(correctedConfirmation, "User correction of the default currency could not be confirmed")
        let reopened = try LedgerDatabase(root: root)
        let restored = try await reopened.list()
        try expect(restored.first { $0.id == entry.id }?.extraction?.currency == "CNY" && restored.first { $0.id == entry.id }?.state == .confirmed,
                   "Confirmed default currency did not survive database reopen")
        try expect(restored.first { $0.id == foreign.id }?.extraction?.currency == "USD" && restored.first { $0.id == foreign.id }?.state == .confirmed,
                   "User's explicit currency correction did not survive database reopen")
    }

    @MainActor static func reviewCurrencyDeduplication() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LedgerDatabase(root: root)
        let originalExtraction = BillExtraction(title: "Synthetic receipt", merchant: "Currency Duplicate Store", amount: "22.90",
                                                currency: "CNY", transactionDate: "2026-10-11")
        let original = LedgerEntry(source: .image, imageFilename: "original.jpg", imageHash: "currency-original",
                                   state: .confirmed, ocrText: "CNY 22.90", extraction: originalExtraction)
        try await store.save(original)
        var extraction = originalExtraction; extraction.currency = nil
        let incoming = LedgerEntry(source: .screenshot, imageFilename: "incoming.jpg", imageHash: "currency-incoming",
                                   state: .needsReview, ocrText: "Total paid: ¥22.90", extraction: extraction)
        let saved = try await store.save(incoming)
        try expect(saved.state == .needsReview, "Currency fixture must begin without a similarity candidate")
        let model = AppModel(dataRoot: root, isPreview: true)
        await model.initialize(registerHotKey: false)
        let draft = model.reviewDraft(for: saved)
        try expect(draft.currency == "CNY", "Default currency was not prepared for duplicate review")
        let confirmed = await model.confirm(saved, draft: draft)
        let rows = try await store.list()
        let candidate = rows.first { $0.id == incoming.id }
        try expect(!confirmed && candidate?.state == .duplicateReview && candidate?.duplicateCandidates == [original.id],
                   "Default currency bypassed the required review of a similar order")
        try expect(rows.filter { $0.state == .confirmed }.count == 1 && rows.first { $0.id == original.id }?.extraction == originalExtraction,
                   "Default currency created a second confirmed order or changed the existing one")
    }

    @MainActor static func initializationRecovery() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = root.appendingPathComponent("ledger")
        try Data("not a directory".utf8).write(to: ledger)
        let model = AppModel(dataRoot: ledger, isPreview: true, captureImage: {
            throw TestFailure(message: "Initialization test must not capture")
        })
        await model.initialize(registerHotKey: false)
        try expect(!model.initialized, "Failed initialization was incorrectly marked ready")
        try expect(model.banner != nil, "Initialization failure must be visible")
        var opened = 0
        model.openWindow = { opened += 1 }
        model.captureScreen()
        model.importImages([])
        try expect(!model.isCapturing && model.entries.isEmpty && opened == 2,
                   "Unavailable capture and import must show the recovery UI")
        try FileManager.default.removeItem(at: ledger)
        await model.initialize(registerHotKey: false)
        try expect(model.initialized, "Initialization could not retry after repairing the path")
    }

    @MainActor static func captureLifecycle() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try syntheticImage()
        var captures = 0
        var pending: CheckedContinuation<CGImage, Error>?
        let model = AppModel(dataRoot: root, isPreview: true, captureImage: {
            captures += 1
            return try await withCheckedThrowingContinuation { pending = $0 }
        })
        await model.initialize(registerHotKey: false)
        model.captureScreen()
        model.captureScreen()
        try await waitUntil { pending != nil }
        try expect(captures == 1 && model.isCapturing, "Repeated input started concurrent captures")
        pending?.resume(returning: image); pending = nil
        try await waitUntil { !model.isCapturing }
        try expect(model.entries.count == 1, "Capture was not saved")
        let entry = model.entries[0]
        try expect(entry.source == .screenshot && entry.state == .queued, "Capture bypassed the consent gate")
        try expect(model.showConsent && !model.consentGranted, "First capture must request consent")
        try expect(FileManager.default.fileExists(atPath: model.imageURL(for: entry).path), "Original image is missing")
        let store = try LedgerDatabase(root: root)
        let persisted = try await store.list()
        try expect(persisted.first?.id == entry.id, "Capture did not survive database reopen")
        model.captureScreen()
        try await waitUntil { pending != nil }
        pending?.resume(returning: image); pending = nil
        try await waitUntil { !model.isCapturing }
        try expect(model.entries.count == 1 && model.selection == entry.id, "Duplicate capture did not reuse its record")
    }

    @MainActor static func captureRecovery() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try syntheticImage()
        var captures = 0
        var opened = 0
        let model = AppModel(dataRoot: root, isPreview: true, captureImage: {
            captures += 1
            if captures == 1 { throw LedgerError.message("Synthetic permission denial") }
            return image
        })
        model.openWindow = { opened += 1 }
        await model.initialize(registerHotKey: false)
        model.captureScreen()
        try await waitUntil { !model.isCapturing }
        try expect(model.entries.isEmpty && opened == 1, "Failed capture must show an error without saving a record")
        try expect(model.banner == "Synthetic permission denial", "Capture error was not surfaced")
        model.captureScreen()
        try await waitUntil { !model.isCapturing }
        try expect(captures == 2 && model.entries.count == 1, "Capture remained blocked after an error")
    }

    @MainActor static func storageFailure() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LedgerDatabase(root: root)
        try await store.save(LedgerEntry(source: .screenshot, imageFilename: "unused.jpg", imageHash: "storage-failure"))
        let model = AppModel(dataRoot: root, isPreview: true, captureImage: {
            throw TestFailure(message: "Storage test must not capture")
        })
        await model.initialize(registerHotKey: false)
        var handle: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("ledger.sqlite3").path, &handle) == SQLITE_OK else {
            throw TestFailure(message: "Cannot open isolated fault-injection database")
        }
        defer { sqlite3_close(handle) }
        let trigger = "CREATE TRIGGER fail_updates BEFORE UPDATE ON entries BEGIN SELECT RAISE(FAIL, 'forced write failure'); END;"
        guard sqlite3_exec(handle, trigger, nil, nil, nil) == SQLITE_OK else {
            throw TestFailure(message: "Cannot install write-failure trigger")
        }
        var opened = 0
        model.openWindow = { opened += 1 }
        // The trigger rejects the first state write, before OCR or any AI credential read.
        model.grantConsent()
        defer { model.revokeConsent() }
        try await waitUntil { opened > 0 }
        try await Task.sleep(for: .milliseconds(100))
        try expect(opened == 1, "Storage failure retried without user action (\(opened) attempts)")
        try expect(model.queuePaused, "Further automatic work must pause after storage failure")
        let rows = try await store.list()
        try expect(rows.first?.state == .queued, "Failed writes damaged the recoverable queued record")
        guard sqlite3_exec(handle, "DROP TRIGGER fail_updates", nil, nil, nil) == SQLITE_OK else {
            throw TestFailure(message: "Cannot restore isolated database writes")
        }
        // The deliberately absent image fails before AI even if a model is configured.
        model.retry(model.entries[0])
        try await waitUntil { model.entries.first?.state == .failed }
        try expect(opened == 2 && !model.queuePaused, "Explicit retry did not resume after database recovery")
    }

    @MainActor static func processingStorageRecovery(retryAnotherEntry: Bool = false) async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configurationURL = try testConfiguration(in: root)
        let store = try LedgerDatabase(root: root)
        try await store.save(LedgerEntry(source: .screenshot, imageFilename: "deliberately-missing.jpg", imageHash: "late-storage-failure"))
        let model = AppModel(dataRoot: root, isPreview: true, configurationURL: configurationURL, captureImage: {
            throw TestFailure(message: "Storage test must not capture")
        })
        await model.initialize(registerHotKey: false)
        var handle: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("ledger.sqlite3").path, &handle) == SQLITE_OK else {
            throw TestFailure(message: "Cannot open isolated fault-injection database")
        }
        defer { sqlite3_close(handle) }
        let trigger = "CREATE TRIGGER fail_failed_state BEFORE UPDATE ON entries WHEN NEW.state='failed' BEGIN SELECT RAISE(FAIL, 'forced late write failure'); END;"
        guard sqlite3_exec(handle, trigger, nil, nil, nil) == SQLITE_OK else {
            throw TestFailure(message: "Cannot install late write-failure trigger")
        }
        var opened = 0
        model.openWindow = { opened += 1 }
        // Processing is saved, OCR fails on the missing file, then saving failed is rejected.
        model.grantConsent()
        defer { model.revokeConsent() }
        try await waitUntil { opened > 0 }
        try await Task.sleep(for: .milliseconds(30))
        try expect(model.queuePaused, "Late storage failure did not pause the queue")
        let rows = try await store.list()
        try expect(rows.first?.state == .processing, "Fault must occur after processing state was persisted")
        guard sqlite3_exec(handle, "DROP TRIGGER fail_failed_state", nil, nil, nil) == SQLITE_OK else {
            throw TestFailure(message: "Cannot restore isolated database writes")
        }
        if retryAnotherEntry {
            let another = LedgerEntry(source: .image, imageFilename: "also-missing.jpg", imageHash: "another-queued-record")
            try await store.save(another)
            model.entries.append(another)
            model.retry(another)
        } else { model.retry(model.entries[0]) }
        try await waitUntil { model.entries.allSatisfy { $0.state == .failed } }
        try expect(opened == (retryAnotherEntry ? 3 : 2) && !model.queuePaused,
                   "Explicit retry left an interrupted record stuck in processing")
    }
}
