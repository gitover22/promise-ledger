import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import Vision
import LedgerCore

public struct PreparedImage: Sendable {
    public let filename: String
    public let hash: String
}

public enum ImagePipeline {
    public static let supportedContentTypes: [UTType] = [.png, .jpeg, .heic, .tiff]

    public static func prepare(url: URL, imagesDirectory: URL) throws -> PreparedImage {
        guard url.isFileURL else { throw LedgerError.message("请拖入本机图片文件。") }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var freshURL = url
        freshURL.removeAllCachedResourceValues()
        let values = try freshURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw LedgerError.message("不能导入文件夹，请选择其中的图片。") }
        guard let size = values.fileSize, size > 0 else { throw LedgerError.message("文件为空，请重新导出图片。") }
        guard size <= 40 * 1_024 * 1_024 else { throw LedgerError.message("图片超过 40 MB，请缩小后重新导入。") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String) else {
            throw LedgerError.message("文件不是可读取的图片，可能已损坏，请重新导出。")
        }
        guard supportedContentTypes.contains(where: { type.conforms(to: $0) }) else {
            throw LedgerError.message("不支持该图片格式，请使用 PNG、JPEG、HEIC 或 TIFF。")
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Double(width) * Double(height) <= 100_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4_096
              ] as CFDictionary) else {
            throw LedgerError.message("图片无法解码或尺寸过大，请换一张清晰的订单截图。")
        }
        return try prepare(image: image, imagesDirectory: imagesDirectory)
    }

    public static func prepare(image: CGImage, imagesDirectory: URL) throws -> PreparedImage {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw LedgerError.message("无法保存原始凭据图片。")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw LedgerError.message("图片保存失败。") }
        let bytes = data as Data
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let filename = hash + ".jpg"
        let path = imagesDirectory.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: path.path) {
            try bytes.write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
        return PreparedImage(filename: filename, hash: hash)
    }

    public static func recognize(url: URL) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(url: url, options: [:])
        try handler.perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LedgerError.message("没有识别到文字，请使用更清晰、包含订单信息的图片。")
        }
        return text
    }

    /// Synthetic receipt for diagnostics only; never reads the user's screen.
    @MainActor public static func makeDiagnosticReceipt(at url: URL, alternate: Bool = false) throws {
        let image = NSImage(size: NSSize(width: 1_000, height: 1_000))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1_000, height: 1_000).fill()
        let lines = [alternate ? "ORDER DETAILS - SUPPORT COPY" : "PROMISE LEDGER TEST RECEIPT",
                     "Platform: Taobao", "Merchant: Ledger Test Store",
                     "Product: Wireless Keyboard", "Order: TEST-20261018-001",
                     "Date: 2026-10-18", "Payment: Paid", "Currency: CNY",
                     "Total paid: 129.00", alternate ? "Refund promised within 3 business days" : "Warranty: 1 year"]
        for (index, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 55, y: 900 - index * 90), withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 31, weight: index == 0 ? .bold : .regular),
                .foregroundColor: NSColor.black
            ])
        }
        image.unlockFocus()
        guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw LedgerError.message("无法生成诊断图片。")
        }
        try png.write(to: url, options: .atomic)
    }
}
