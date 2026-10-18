import Foundation
import LedgerMac

extension ImportTests {
    static func changedFilesAfterPreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChangedFileTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.png")
        let alternate = root.appendingPathComponent("alternate.png")
        try ImagePipeline.makeDiagnosticReceipt(at: original)
        try ImagePipeline.makeDiagnosticReceipt(at: alternate, alternate: true)
        var first = try Data(contentsOf: original), second = try Data(contentsOf: alternate)
        let length = max(first.count, second.count)
        first.append(Data(count: length - first.count)); second.append(Data(count: length - second.count))
        var failures: [String] = []
        for mode in ["replaced", "deleted"] {
            let file = root.appendingPathComponent(mode + ".png")
            try first.write(to: file)
            let date = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as! Date
            let selection = ImportSelection()
            selection.stage([.file(file), .file(alternate)])
            try await checked(selection)
            try expect(selection.readyCount == 2, "Both files must initially preview successfully")
            if mode == "replaced" {
                try second.write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
            } else { try FileManager.default.removeItem(at: file) }
            let images = root.appendingPathComponent(mode + "-images")
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            let batch = ImportBatch()
            batch.start(selection.confirm(), importFile: { url, expectedContentHash in
                let saved = try ImagePipeline.prepare(url: url, imagesDirectory: images, expectedContentHash: expectedContentHash)
                return .imported(entryID: saved.hash)
            })
            try await finished(batch)
            let expected = mode == "replaced"
                ? "图片内容已变化，请重新选择并确认后导入。"
                : "图片文件已不存在，可能已被删除或移动，请重新选择并确认后导入。"
            if batch.items[0].status != .failed(expected) {
                failures.append("\(mode): expected Chinese per-file rejection, got \(batch.items[0].status)")
            }
            try expect(batch.items[1].status.entryID != nil, "An invalidated file must not block later valid files")
            try expect(try FileManager.default.contentsOfDirectory(atPath: images.path).count == 1,
                       "Rejected files must leave no saved image")
            // A new selection is a new confirmation of the file's current contents.
            if mode == "deleted" { try second.write(to: file) }
            selection.stage([.file(file)])
            try await checked(selection)
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            batch.start(selection.confirm(), importFile: { url, expectedContentHash in
                let saved = try ImagePipeline.prepare(url: url, imagesDirectory: images, expectedContentHash: expectedContentHash)
                return .imported(entryID: saved.hash)
            })
            try await finished(batch)
            try expect(batch.items[0].status.entryID != nil,
                       "Reselecting the current content must succeed; metadata-only changes must not invalidate it")
        }
        try expect(failures.isEmpty, failures.joined(separator: "\n"))
        print("PASS: valid replacement with unchanged size/date and deleted file rejected with Chinese guidance")
    }
}
