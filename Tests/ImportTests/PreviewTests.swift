import AppKit
import Foundation
import LedgerMac

extension ImportTests {
    static func checked(_ selection: ImportSelection) async throws {
        let deadline = Date().addingTimeInterval(10)
        while selection.isChecking && Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try expect(!selection.isChecking, "Preview should finish")
    }

    static func previewWorkflow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PreviewTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let png = root.appendingPathComponent("receipt.png")
        let broken = root.appendingPathComponent("broken.png")
        try ImagePipeline.makeDiagnosticReceipt(at: png)
        try Data("invalid image".utf8).write(to: broken)
        let originalFiles = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        let selection = ImportSelection()
        try expect(selection.stage([.file(png), .file(broken), .file(png)]), "Selection accepted")
        try expect(selection.confirm().isEmpty, "Cannot confirm while checking")
        try await checked(selection)
        try expect(selection.readyCount == 2 && selection.rows[1].error != nil, "Valid and corrupt files must be distinguished before import")
        try expect(selection.rows[0].preview?.image.width ?? 0 > 0, "Preview must contain a real thumbnail")
        try expect(selection.rows[0].preview?.byteCount == Data(contentsOf: png).count, "Preview must show the file size")
        try expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == originalFiles, "Preview must not write images or a ledger")
        selection.remove(selection.rows[0].id)
        try expect(selection.readyCount == 1, "Removing a file excludes it from confirmation")
        let accepted = selection.confirm()
        try expect(accepted.count == 1 && !selection.isPresented, "Confirm returns only retained valid files and closes preview")
        try expect(selection.confirm().isEmpty, "Repeated confirmation cannot import twice")
        try expect(selection.stage([.file(png)]), "Next selection accepted")
        try await checked(selection)
        selection.cancel()
        try expect(selection.rows.isEmpty && selection.confirm().isEmpty, "Cancellation discards the whole selection")
        try expect(!selection.stage(Array(repeating: .file(png), count: 11)), "Over-limit preview must be rejected")
        print("PASS: read-only thumbnails, invalid files, remove, confirm once, cancel and batch limit")

        var resume: CheckedContinuation<URL, Never>?
        let delayed = ImportCandidate(name: "delayed.png") {
            await withCheckedContinuation { resume = $0 }
        }
        try expect(selection.stage([delayed]), "Delayed drop accepted")
        while resume == nil { await Task.yield() }
        selection.cancel()
        try expect(selection.stage([.file(broken)]), "New selection after cancellation")
        resume?.resume(returning: png)
        try await checked(selection)
        try expect(selection.rows.count == 1 && selection.rows[0].name == "broken.png" && selection.readyCount == 0, "Late drop completion must not revive cancelled files or overwrite a new selection")
        try expect(selection.confirm().isEmpty && selection.isPresented, "All-invalid selection must stay open and cannot import")
        selection.cancel()
        print("PASS: cancelling pending drop does not overwrite the next preview")

        try expect(selection.stage([.file(png)]), "Valid file can be previewed again")
        try await checked(selection)
        try Data("file replaced after preview".utf8).write(to: png)
        let batch = ImportBatch()
        let images = root.appendingPathComponent("Images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        batch.start(selection.confirm(), importFile: { url, expectedContentHash in
            _ = try ImagePipeline.prepare(url: url, imagesDirectory: images, expectedContentHash: expectedContentHash)
            return .imported(entryID: "unexpected")
        })
        try await finished(batch)
        guard case .failed = batch.items.first?.status else { throw Failure("Changed file must be revalidated at import") }
        try expect(try FileManager.default.contentsOfDirectory(atPath: images.path).isEmpty, "Invalid file must not be saved after confirmation")
        print("PASS: files changed after preview fail safely at confirmation")
    }
}
