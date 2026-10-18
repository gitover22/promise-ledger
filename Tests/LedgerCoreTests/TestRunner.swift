import Foundation
import LedgerCore

struct TestFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String = "Assertion failed", line: UInt = #line) throws {
    guard try condition() else { throw TestFailure(message: "Line \(line): \(message)") }
}

func expectThrows(_ operation: () throws -> Void, line: UInt = #line) throws {
    do { try operation() } catch { return }
    throw TestFailure(message: "Line \(line): expected an error")
}

/// Dependency-free unit runner; named separately from main.swift for multi-file @main.
@main struct LedgerTests {
    static func main() async {
        let cases: [(String, () async throws -> Void)] = [
            ("decimal precision and invalid amounts", { try decimalAmounts() }),
            ("strict calendar dates", { try calendarDates() }),
            ("source-grounded promises", { try groundedPromises() }),
            ("invalid fields become review warnings", { try invalidFields() }),
            ("non-bills and invalid confidence rejected", { try nonBills() }),
            ("fenced JSON extraction", { try fencedJSON() }),
            ("malformed extraction rejected", { try malformedJSON() }),
            ("complete SSE with usage chunk", { try completedSSE() }),
            ("incomplete and errored SSE rejected", { try incompleteSSE() }),
            ("non-streaming completion", { try nonStreaming() }),
            ("SQLite round-trip, update, SQL parameters", { try await databaseRoundTrip() }),
            ("SQLite duplicate image constraint", { try await databaseDuplicate() }),
            ("concurrent screenshot and upload reuse the same SQLite entry", { try await databaseConcurrentEnqueue() }),
            ("duplicate enqueue preserves existing SQLite state and data", { try await databaseEnqueuePreservesExisting() }),
            ("interrupted work recovery", { try await recovery() })
        ]
        let allCases = cases + OrderDedupTests.cases + ReminderTests.cases
        var failures = 0
        for (name, operation) in allCases {
            do { try await operation(); print("PASS: \(name)") }
            catch { failures += 1; print("FAIL: \(name): \(error.localizedDescription)") }
        }
        print("\(allCases.count - failures)/\(allCases.count) tests passed. No network calls or credentials used.")
        if failures > 0 { exit(1) }
    }

    static func decimalAmounts() throws {
        let a = BillExtraction(amount: "0.10")
        let b = BillExtraction(amount: "0.20")
        try expect((a.decimalAmount ?? 0) + (b.decimalAmount ?? 0) == Decimal(string: "0.30"))
        for invalid in ["-1", "NaN", "1,234.00", "1e10", "10x", ""] {
            try expect(BillExtraction(amount: invalid).decimalAmount == nil, "Accepted invalid amount: \(invalid)")
        }
    }

    static func calendarDates() throws {
        try expect(BillExtraction.isValidDate("2024-02-29"))
        for invalid in ["2025-02-29", "2026-13-01", "2026-02-30", "10-18", "2026-1-2"] {
            try expect(!BillExtraction.isValidDate(invalid), "Accepted invalid date: \(invalid)")
        }
    }

    static func groundedPromises() throws {
        let bill = BillExtraction(amount: "129.00", currency: "CNY", confidence: 0.8, promises: [
            LedgerPromise(text: "一年保修", sourceQuote: "Warranty: 1 year"),
            LedgerPromise(text: "七天退货", sourceQuote: "7-day returns")
        ])
        let result = try bill.validated(ocrText: "Total: 129.00\nWarranty: 1 year")
        try expect(result.promises.count == 1)
        try expect(result.warnings.count == 1)
    }

    static func invalidFields() throws {
        let bill = BillExtraction(amount: "NaN", currency: "人民币", transactionDate: "2026-02-30", category: "臆造分类", confidence: 0.7)
        let result = try bill.validated(ocrText: "订单")
        try expect(result.amount == nil && result.currency == nil && result.transactionDate == nil)
        try expect(result.category == "未分类" && result.warnings.count == 3)
    }

    static func nonBills() throws {
        try expectThrows { _ = try BillExtraction(isBill: false).validated(ocrText: "hello") }
        try expectThrows { _ = try BillExtraction(confidence: 2).validated(ocrText: "receipt") }
    }

    static func fencedJSON() throws {
        let bill = BillExtraction(amount: "19.80", currency: "CNY", confidence: 0.8)
        let json = String(decoding: try JSONEncoder().encode(bill), as: UTF8.self)
        let decoded = try ExtractionDecoder.decode("```json\n\(json)\n```", ocrText: "19.80 CNY")
        try expect(decoded.amount == "19.80")
    }

    static func malformedJSON() throws {
        try expectThrows { _ = try ExtractionDecoder.decode("{\"amount\":", ocrText: "129") }
    }

    static func completedSSE() throws {
        let data = Data("""
        data: {"choices":[{"delta":{"content":"你"},"finish_reason":null}]}

        data: {"choices":[{"delta":{"content":"好"},"finish_reason":"stop"}]}

        data: {"choices":[],"usage":{"total_tokens":26}}

        data: [DONE]

        """.utf8)
        try expect(try CompletionParser.text(from: data, isStream: true) == "你好")
    }

    static func incompleteSSE() throws {
        let unfinished = Data("data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n".utf8)
        try expectThrows { _ = try CompletionParser.text(from: unfinished, isStream: true) }
        let truncated = Data("data: {\"choices\":[{\"delta\":{\"content\":\"partial\"},\"finish_reason\":\"length\"}]}\ndata: [DONE]\n".utf8)
        try expectThrows { _ = try CompletionParser.text(from: truncated, isStream: true) }
        let error = Data("data: {\"error\":{\"message\":\"failed\"}}\ndata: [DONE]\n".utf8)
        try expectThrows { _ = try CompletionParser.text(from: error, isStream: true) }
    }

    static func nonStreaming() throws {
        let data = Data(#"{"choices":[{"message":{"content":"你好"},"finish_reason":"stop"}]}"#.utf8)
        try expect(try CompletionParser.text(from: data, isStream: false) == "你好")
    }

    static func databaseRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LedgerUnit-\(UUID().uuidString)")
        let store = try LedgerDatabase(root: root)
        let extraction = BillExtraction(title: "Keyboard", merchant: "x'); DROP TABLE entries; --", amount: "129.00", currency: "CNY", confidence: 0.9)
        var entry = LedgerEntry(source: .image, imageFilename: "fixture.jpg", imageHash: "hash-1", state: .needsReview,
                                ocrText: "虚构原文", extraction: extraction)
        try await store.save(entry)
        var rows = try await store.list()
        try expect(rows.count == 1 && rows.first?.extraction == extraction)
        entry.state = .confirmed
        try await store.save(entry)
        rows = try await store.list()
        try expect(rows.count == 1 && rows.first?.state == .confirmed)
        let reopened = try LedgerDatabase(root: root)
        let persisted = try await reopened.list()
        try expect(persisted.first?.ocrText == "虚构原文")
        for filename in ["ledger.sqlite3", "ledger.sqlite3-wal", "ledger.sqlite3-shm"] {
            let path = root.appendingPathComponent(filename).path
            if FileManager.default.fileExists(atPath: path) {
                let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
                try expect(permissions?.intValue == 0o600, "Database file permissions must be private")
            }
        }
    }

    static func databaseDuplicate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LedgerDuplicate-\(UUID().uuidString)")
        let store = try LedgerDatabase(root: root)
        try await store.save(LedgerEntry(source: .image, imageFilename: "same.jpg", imageHash: "same"))
        var rejected = false
        do { try await store.save(LedgerEntry(source: .image, imageFilename: "same.jpg", imageHash: "same")) }
        catch { rejected = true }
        try expect(rejected, "Duplicate image was inserted")
        let rows = try await store.list()
        try expect(rows.count == 1)
    }

    static func databaseConcurrentEnqueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LedgerConcurrent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LedgerDatabase(root: root)
        let capture = LedgerEntry(source: .screenshot, imageFilename: "same.jpg", imageHash: "same")
        let upload = LedgerEntry(source: .image, imageFilename: "same.jpg", imageHash: "same")
        async let captureID = store.enqueue(capture)
        async let uploadID = store.enqueue(upload)
        let identifiers = try await (captureID, uploadID)
        try expect(identifiers.0 == identifiers.1, "Concurrent sources must reuse one entry")
        let rows = try await store.list()
        try expect(rows.count == 1 && rows.first?.id == identifiers.0)
        let original = identifiers.0 == capture.id ? capture : upload
        try expect(rows.first?.source == original.source && rows.first?.state == .queued,
                   "Duplicate enqueue must preserve the first entry")
    }

    static func databaseEnqueuePreservesExisting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LedgerEnqueuePreserve-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for state in [EntryState.queued, .processing, .needsReview, .confirmed, .failed] {
            let store = try LedgerDatabase(root: root.appendingPathComponent(state.rawValue))
            let original = try await store.save(LedgerEntry(createdAt: Date(timeIntervalSince1970: 1_700_000_000), source: .image,
                imageFilename: "original-\(state.rawValue).jpg", imageHash: state.rawValue, state: state,
                ocrText: "Original receipt: 129.00 CNY", extraction: BillExtraction(title: "已核对的账单", amount: "129.00", currency: "CNY"),
                error: state == .failed ? "保留原始失败信息" : nil, model: "original-model", promptVersion: "original-prompt"))
            let capture = LedgerEntry(source: .screenshot, imageFilename: "new-capture.jpg", imageHash: original.imageHash)
            let upload = LedgerEntry(source: .image, imageFilename: "new-upload.jpg", imageHash: original.imageHash)
            async let captureID = store.enqueue(capture)
            async let uploadID = store.enqueue(upload)
            let identifiers = try await (captureID, uploadID)
            try expect(identifiers.0 == original.id && identifiers.1 == original.id)
            let rows = try await store.list()
            let matches = rows.filter { $0.imageHash == original.imageHash }
            try expect(matches.count == 1)
            guard let stored = matches.first else { throw TestFailure(message: "Existing entry disappeared") }
            try expect(stored.state == state && stored.error == original.error && stored.model == original.model,
                       "Duplicate enqueue changed existing \(state.rawValue) state")
            try expect(stored.extraction == original.extraction && stored.ocrText == original.ocrText && stored.promptVersion == original.promptVersion,
                       "Duplicate enqueue replaced saved extraction, OCR or prompt provenance")
            try expect(stored.duplicateOf == original.duplicateOf && stored.duplicateCandidates == original.duplicateCandidates && stored.distinctFingerprint == original.distinctFingerprint,
                       "Duplicate enqueue changed order deduplication metadata")
            try expect(stored.source == original.source && stored.imageFilename == original.imageFilename && stored.createdAt == original.createdAt,
                       "Duplicate enqueue changed the original evidence")
        }
    }

    static func recovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LedgerRecovery-\(UUID().uuidString)")
        let store = try LedgerDatabase(root: root)
        try await store.save(LedgerEntry(source: .screenshot, imageFilename: "capture.jpg", imageHash: "capture", state: .processing))
        let reopened = try LedgerDatabase(root: root)
        let rows = try await reopened.list()
        try expect(rows.first?.state == .queued && rows.first?.imageFilename == "capture.jpg")
    }
}
