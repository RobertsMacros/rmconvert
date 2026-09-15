import Cocoa

enum Brand {
    static func menuIcon(resources: URL) -> NSImage? {
        guard let source = NSImage(contentsOf: resources.appendingPathComponent("RobertsMacros.png")) else { return nil }
        let crop = NSRect(x: 0, y: source.size.height * 0.21, width: source.size.width, height: source.size.height * 0.79)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 96, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill(); NSRect(x: 0,y: 0,width: 96,height: 64).fill()
        source.draw(in: NSRect(x: 0,y: 9,width: 96,height: 46), from: crop, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        if let bytes = bitmap.bitmapData {
            for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
                let i = y * bitmap.bytesPerRow + x * 4
                let minimum = min(bytes[i], bytes[i + 1], bytes[i + 2])
                let alpha = min(255, max(0, (255 - Int(minimum)) * 255 / 193))
                bytes[i] = 0; bytes[i + 1] = 0; bytes[i + 2] = 0; bytes[i + 3] = UInt8(alpha)
            } }
        }
        let image = NSImage(size: NSSize(width: 24, height: 16)); image.addRepresentation(bitmap); image.isTemplate = true
        image.accessibilityDescription = "Roberts Macros"
        return image
    }
}
