import AppKit
import Foundation
import LedgerMac

struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

@main @MainActor struct ImportTests {
    static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message) }
    }

    static func finished(_ batch: ImportBatch) async throws {
        for _ in 0..<10_000 {
            if !batch.isImporting { return }
            await Task.yield()
        }
        throw Failure("Import did not finish")
    }

    static func main() async {
        do {
            try await changedFilesAfterPreview()
            try await mixedBatch()
            try await limitsAndBusy()
            try imageValidation()
            try await previewWorkflow()
            print("PASS: all import tests; no model calls or user files used")
        } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    }

    static func mixedBatch() async throws {
        let batch = ImportBatch()
        let files = ["first.png", "duplicate.png", "broken.png", "last.png"].map {
            ImportCandidate.file(URL(fileURLWithPath: "/synthetic/" + $0))
        }
        let unreadable = ImportCandidate(name: "拖入项目 5") { throw Failure("文件地址无法读取") }
        var visited: [String] = []
        var completions = 0
        try expect(batch.start(files + [unreadable], importFile: { url, _ in
            visited.append(url.lastPathComponent)
            switch url.lastPathComponent {
            case "duplicate.png": return .duplicate(entryID: "existing")
            case "broken.png": throw Failure("图片损坏")
            default: return .imported(entryID: url.lastPathComponent)
            }
        }, completion: { completions += 1 }), "Batch should be accepted")
        try await finished(batch)
        try expect(visited == ["first.png", "duplicate.png", "broken.png", "last.png"], "Failures must not stop later files or reorder them")
        try expect(batch.items.map(\.status) == [.imported(entryID: "first.png"), .duplicate(entryID: "existing"), .failed("图片损坏"), .imported(entryID: "last.png"), .failed("文件地址无法读取")], "Each input needs its own result, including drop failures")
        try expect(completions == 1, "Complete once after the whole batch")
        print("PASS: ordered mixed results, duplicate references, per-file errors and unreadable drop")
    }

    static func limitsAndBusy() async throws {
        let batch = ImportBatch()
        let file = ImportCandidate.file(URL(fileURLWithPath: "/synthetic/order.png"))
        var calls = 0
        let importer: (URL, String?) async throws -> ImportOutcome = { _, _ in calls += 1; return .imported(entryID: "one") }
        try expect(!batch.start(Array(repeating: file, count: 11), importFile: importer), "11 files must reject the whole batch")
        try expect(calls == 0 && batch.notice != nil && batch.items.isEmpty, "Rejected files must not start work")
        try expect(!batch.start([], importFile: importer), "Empty input must not start")
        var resume: CheckedContinuation<URL, Never>?
        let held = ImportCandidate(name: "等待文件地址") {
            await withCheckedContinuation { resume = $0 }
        }
        try expect(batch.start([held], importFile: importer), "Initial drop must start")
        let ids = batch.items.map(\.id)
        try expect(!batch.start([file], importFile: importer), "Busy drop must be rejected before resolving its files")
        try expect(batch.items.map(\.id) == ids && batch.notice != nil, "Busy rejection must retain current results and explain why")
        while resume == nil { await Task.yield() }
        resume?.resume(returning: URL(fileURLWithPath: "/synthetic/resolved.png"))
        try await finished(batch)
        try expect(batch.items.first?.name == "resolved.png", "Resolved filenames must replace drop placeholders")
        try expect(batch.start(Array(repeating: file, count: 10), importFile: importer), "10 files must be accepted")
        try await finished(batch)
        try expect(calls == 11 && batch.items.count == 10, "New batch replaces old results and handles all 10 inputs")
        print("PASS: batch limits, busy feedback during URL resolution, and next batch")
    }

    static func imageValidation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ImportTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let images = root.appendingPathComponent("Images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let png = root.appendingPathComponent("receipt.png")
        try ImagePipeline.makeDiagnosticReceipt(at: png)
        let a = try ImagePipeline.prepare(url: png, imagesDirectory: images)
        let b = try ImagePipeline.prepare(url: png, imagesDirectory: images)
        try expect(a.hash == b.hash, "Same image must retain deduplication identity")
        let bitmap = NSBitmapImageRep(data: try Data(contentsOf: png))!
        for (format, name) in [(NSBitmapImageRep.FileType.jpeg, "receipt.jpg"), (.tiff, "receipt.tiff")] {
            let url = root.appendingPathComponent(name)
            try bitmap.representation(using: format, properties: [:])!.write(to: url)
            _ = try ImagePipeline.prepare(url: url, imagesDirectory: images)
        }
        let boundary = root.appendingPathComponent("boundary.png")
        try Data(contentsOf: png).write(to: boundary)
        let handle = try FileHandle(forWritingTo: boundary)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 40 * 1_024 * 1_024)
        _ = try ImagePipeline.prepare(url: boundary, imagesDirectory: images)
        try handle.truncate(atOffset: 40 * 1_024 * 1_024 + 1)
        var tooLarge = false
        do { _ = try ImagePipeline.prepare(url: boundary, imagesDirectory: images) }
        catch { tooLarge = error.localizedDescription.contains("40 MB") }
        try expect(tooLarge, "40 MB is accepted; one byte over must give a size error")
        let gif = root.appendingPathComponent("unsupported.png")
        try bitmap.representation(using: .gif, properties: [:])!.write(to: gif)
        var rejected = false
        do { _ = try ImagePipeline.prepare(url: gif, imagesDirectory: images) } catch { rejected = true }
        try expect(rejected, "Actual unsupported GIF bytes must be rejected even with a PNG extension")
        for url in [root, root.appendingPathComponent("empty.png"), root.appendingPathComponent("broken.png")] {
            if url.lastPathComponent == "empty.png" { try Data().write(to: url) }
            if url.lastPathComponent == "broken.png" { try Data("not an image".utf8).write(to: url) }
            var failed = false
            do { _ = try ImagePipeline.prepare(url: url, imagesDirectory: images) } catch { failed = true }
            try expect(failed, "Invalid inputs must fail: \(url.lastPathComponent)")
        }
        print("PASS: PNG/JPEG/TIFF decoding, 40 MB boundary, deduplication, content type and invalid files")
    }
}
