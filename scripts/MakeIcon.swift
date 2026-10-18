import AppKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let p = CGFloat(pixels)
        let background = NSBezierPath(roundedRect: NSRect(x: p * 0.06, y: p * 0.06, width: p * 0.88, height: p * 0.88), xRadius: p * 0.20, yRadius: p * 0.20)
        NSColor(red: 0.16, green: 0.43, blue: 0.31, alpha: 1).setFill(); background.fill()
        let paper = NSBezierPath(roundedRect: NSRect(x: p * 0.29, y: p * 0.23, width: p * 0.42, height: p * 0.55), xRadius: p * 0.045, yRadius: p * 0.045)
        NSColor(red: 0.97, green: 0.98, blue: 0.93, alpha: 1).setFill(); paper.fill()
        for (index, width) in [0.23, 0.17, 0.23].enumerated() {
            let line = NSBezierPath(roundedRect: NSRect(x: p * 0.375, y: p * (0.64 - Double(index) * 0.10), width: p * width, height: p * 0.025), xRadius: p * 0.01, yRadius: p * 0.01)
            NSColor(red: 0.60, green: 0.73, blue: 0.58, alpha: 1).setFill(); line.fill()
        }
        let badge = NSBezierPath(ovalIn: NSRect(x: p * 0.57, y: p * 0.17, width: p * 0.24, height: p * 0.24))
        NSColor(red: 0.78, green: 0.90, blue: 0.60, alpha: 1).setFill(); badge.fill()
        let check = NSBezierPath(); check.move(to: NSPoint(x: p * 0.625, y: p * 0.29))
        check.line(to: NSPoint(x: p * 0.675, y: p * 0.24)); check.line(to: NSPoint(x: p * 0.755, y: p * 0.335))
        check.lineWidth = p * 0.022; check.lineCapStyle = .round; check.lineJoinStyle = .round
        NSColor(red: 0.12, green: 0.35, blue: 0.24, alpha: 1).setStroke(); check.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
