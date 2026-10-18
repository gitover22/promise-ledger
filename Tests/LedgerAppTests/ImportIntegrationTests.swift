import AppKit
import ImageIO
import LedgerCore
import LedgerMac

extension LedgerAppTests {
    @MainActor static func manualImportWorkflow() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = root.appendingPathComponent("receipt.png")
        let broken = root.appendingPathComponent("broken.png")
        try ImagePipeline.makeDiagnosticReceipt(at: receipt)
        try Data("invalid image fixture".utf8).write(to: broken)
        let ledgerRoot = root.appendingPathComponent("ledger")
        var aiCalls = 0
        let model = AppModel(dataRoot: ledgerRoot, isPreview: true, configurationURL: try testConfiguration(in: root),
            extractBill: { _, _ in
                aiCalls += 1
                throw TestFailure(message: "Manual import must await explicit AI consent")
            })
        await model.initialize(registerHotKey: false)
        try expect(model.importCandidates([.file(receipt), .file(broken)]), "Manual selection was rejected")
        try await waitUntil(timeout: .seconds(20)) { !model.importSelection.isChecking }
        let store = try LedgerDatabase(root: ledgerRoot)
        let before = try await store.list()
        let images = await store.imagesDirectory
        let previewFiles = try FileManager.default.contentsOfDirectory(atPath: images.path)
        try expect(model.importSelection.readyCount == 1 && model.importSelection.rows[1].error != nil,
                   "Preview must distinguish valid and invalid files")
        try expect(before.isEmpty && previewFiles.isEmpty,
                   "Preview wrote ledger data before confirmation")
        model.importSelection.cancel()
        try expect(model.entries.isEmpty && !model.showConsent && aiCalls == 0, "Cancellation saved or transmitted a file")
        model.importImages([receipt])
        try await waitUntil(timeout: .seconds(20)) { !model.importSelection.isChecking }
        model.confirmImportSelection()
        model.confirmImportSelection()
        try await waitUntil { !model.isImporting }
        let rows = try await store.list()
        try expect(rows.count == 1 && rows[0].state == .queued && rows[0].source == .image,
                   "Manual confirmation must save exactly one queued image")
        try expect(model.importBatch.items.count == 1 && model.importBatch.items[0].status == .imported(entryID: rows[0].id),
                   "The result did not identify the persisted entry")
        try expect(model.showConsent && !model.consentGranted && aiCalls == 0, "Import bypassed the AI consent gate")
    }

    @MainActor static func concurrentManualImportAndCapture() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = root.appendingPathComponent("receipt.png")
        try ImagePipeline.makeDiagnosticReceipt(at: receipt)
        // Use the same decoded pixels as file intake, not a real desktop capture.
        guard let source = CGImageSourceCreateWithURL(receipt as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4_096
              ] as CFDictionary) else { throw TestFailure(message: "Cannot decode synthetic capture") }
        var aiCalls = 0
        let ledgerRoot = root.appendingPathComponent("ledger")
        let model = AppModel(dataRoot: ledgerRoot, isPreview: true, configurationURL: try testConfiguration(in: root),
            captureImage: { image }, extractBill: { _, _ in
                aiCalls += 1
                throw TestFailure(message: "Concurrent intake must await consent")
            })
        await model.initialize(registerHotKey: false)
        model.importImages([receipt])
        try await waitUntil(timeout: .seconds(20)) { !model.importSelection.isChecking }
        model.confirmImportSelection()
        model.captureScreen()
        try await waitUntil(timeout: .seconds(20)) { !model.isCapturing && !model.isImporting }
        let store = try LedgerDatabase(root: ledgerRoot)
        let rows = try await store.list()
        try expect(rows.count == 1 && rows[0].state == .queued, "Concurrent intake created duplicate image entries")
        guard let result = model.importBatch.items.first?.status else { throw TestFailure(message: "Missing batch result") }
        switch result {
        case .imported(let id):
            try expect(id == rows[0].id && rows[0].source == .image, "Import winner lost its identity")
        case .duplicate(let id):
            try expect(id == rows[0].id && rows[0].source == .screenshot, "Duplicate import did not reuse the capture")
        default: throw TestFailure(message: "Concurrent intake reported an error instead of reusing the entry")
        }
        try expect(model.selection == rows[0].id && aiCalls == 0 && !model.consentGranted,
                   "Concurrent intake lost selection or triggered AI")
    }

    @MainActor static func duplicateImportPreservesConfirmedOrder() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.png")
        let alternate = root.appendingPathComponent("alternate.png")
        try ImagePipeline.makeDiagnosticReceipt(at: original)
        try ImagePipeline.makeDiagnosticReceipt(at: alternate, alternate: true)
        let ledgerRoot = root.appendingPathComponent("ledger")
        let store = try LedgerDatabase(root: ledgerRoot)
        let images = await store.imagesDirectory
        let first = try ImagePipeline.prepare(url: original, imagesDirectory: images)
        let second = try ImagePipeline.prepare(url: alternate, imagesDirectory: images)
        let originalOCR = try ImagePipeline.recognize(url: images.appendingPathComponent(first.filename))
        let alternateOCR = try ImagePipeline.recognize(url: images.appendingPathComponent(second.filename))
        // Domain fixtures test preservation and routing, not AI accuracy.
        let bill = BillExtraction(title: "Synthetic receipt", merchant: "Ledger Test Store", amount: "129.00",
            currency: "CNY", transactionDate: "2026-10-18", orderID: "TEST-20261018-001",
            platform: "Taobao", orderIDSourceQuote: "Order: TEST-20261018-001")
        let canonical = try await store.save(LedgerEntry(source: .image, imageFilename: first.filename,
            imageHash: first.hash, state: .confirmed, ocrText: originalOCR, extraction: bill, promptVersion: "domain-fixture"))
        let linked = try await store.save(LedgerEntry(source: .screenshot, imageFilename: second.filename,
            imageHash: second.hash, state: .needsReview, ocrText: alternateOCR, extraction: bill))
        try expect(linked.duplicateOf == canonical.id, "Fixture must already be linked to the confirmed order")
        let model = AppModel(dataRoot: ledgerRoot, isPreview: true, configurationURL: try testConfiguration(in: root))
        await model.initialize(registerHotKey: false)
        model.importImages([alternate])
        try await waitUntil(timeout: .seconds(20)) { !model.importSelection.isChecking }
        model.confirmImportSelection()
        try await waitUntil { !model.isImporting }
        try expect(model.importBatch.items.first?.status == .duplicate(entryID: canonical.id),
                   "Duplicate feedback must link to the canonical order, not its evidence row")
        let rows = try await store.list()
        try expect(rows.count == 2 && rows.filter { $0.state == .confirmed }.count == 1,
                   "Repeated import inserted or confirmed a second bill")
        let restored = rows.first { $0.id == canonical.id }
        try expect(restored?.extraction == bill && restored?.ocrText == originalOCR && restored?.promptVersion == canonical.promptVersion,
                   "Repeated import overwrote confirmed facts or provenance")
        try expect(rows.first { $0.id == linked.id }?.source == .screenshot && !model.showConsent,
                   "Repeated import changed evidence source or started new recognition")
    }

    @MainActor static func changedManualImportFiles() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.png")
        let changed = root.appendingPathComponent("changed.png")
        let deleted = root.appendingPathComponent("deleted.png")
        try ImagePipeline.makeDiagnosticReceipt(at: original)
        try FileManager.default.copyItem(at: original, to: changed)
        try FileManager.default.copyItem(at: original, to: deleted)
        let ledgerRoot = root.appendingPathComponent("ledger")
        let model = AppModel(dataRoot: ledgerRoot, isPreview: true, configurationURL: try testConfiguration(in: root))
        await model.initialize(registerHotKey: false)
        model.importImages([changed, deleted, original])
        try await waitUntil(timeout: .seconds(20)) { !model.importSelection.isChecking }
        try expect(model.importSelection.readyCount == 3, "All initial previews must be valid")
        try ImagePipeline.makeDiagnosticReceipt(at: changed, alternate: true)
        try FileManager.default.removeItem(at: deleted)
        model.confirmImportSelection()
        try await waitUntil(timeout: .seconds(20)) { !model.isImporting }
        let items = model.importBatch.items
        guard items.count == 3, case .failed = items[0].status, case .failed = items[1].status,
              case .imported = items[2].status else {
            throw TestFailure(message: "Changed/deleted inputs must fail individually while valid input continues")
        }
        let store = try LedgerDatabase(root: ledgerRoot)
        let rows = try await store.list()
        let images = await store.imagesDirectory
        let savedFiles = try FileManager.default.contentsOfDirectory(atPath: images.path)
        try expect(rows.count == 1 && savedFiles.count == 1,
                   "Rejected preview files left ledger entries or image artifacts")
        try expect(rows[0].state == .queued && model.showConsent && !model.consentGranted,
                   "Valid remainder must still await AI consent")
    }
}
