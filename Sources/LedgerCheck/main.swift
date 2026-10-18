import AppKit
import Foundation
import LedgerCore
import LedgerMac

@main struct LedgerCheck {
    @MainActor static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.first == "--make-fixture", arguments.count == 2 {
                let url = URL(fileURLWithPath: arguments[1])
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try ImagePipeline.makeDiagnosticReceipt(at: url)
                print("Synthetic receipt created: \(url.path)")
                return
            }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("PromiseLedger-Check-\(UUID().uuidString)")
            let database = try LedgerDatabase(root: root)
            let fixture = root.appendingPathComponent("synthetic-receipt.png")
            try ImagePipeline.makeDiagnosticReceipt(at: fixture)
            let images = await database.imagesDirectory
            let prepared = try ImagePipeline.prepare(url: fixture, imagesDirectory: images)
            let ocr = try ImagePipeline.recognize(url: images.appendingPathComponent(prepared.filename))
            guard ocr.contains("129.00"), ocr.contains("TEST-20261018-001") else {
                throw LedgerError.message("Synthetic receipt OCR did not recover the expected amount/order ID.")
            }
            print("PASS: synthetic image → local Vision OCR (no user screen captured)")
            var entry = LedgerEntry(source: .image, imageFilename: prepared.filename, imageHash: prepared.hash, ocrText: ocr)
            if arguments.contains("--live-ai") {
                let configuration = try ModelConfiguration.load()
                let extraction = try await AIClient(configuration: configuration).extract(ocrText: ocr)
                guard extraction.decimalAmount == Decimal(string: "129.00"), extraction.currency == "CNY" else {
                    throw LedgerError.message("Live AI returned an unexpected amount/currency for the synthetic receipt.")
                }
                entry.extraction = extraction; entry.state = .needsReview; entry.model = configuration.model
                print("PASS: \(configuration.model) → structured bill, CNY 129.00, review required")
            } else {
                print("SKIP: live model (run LedgerCheck --live-ai to send ONLY the synthetic receipt's OCR text)")
            }
            try await database.save(entry)
            let restored = try await database.list()
            guard restored.count == 1, restored.first?.ocrText == ocr, restored.first?.extraction == entry.extraction else {
                throw LedgerError.message("SQLite round-trip did not match the input record.")
            }
            print("PASS: SQLite persistence and reload")
            print("Diagnostic data is isolated from the user's ledger: \(root.path)")
        } catch {
            fputs("CHECK FAILED: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
