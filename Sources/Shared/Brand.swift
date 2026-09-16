import Cocoa

enum Brand {
    static func menuIcon(for menu: String, appearance: NSAppearance) -> NSImage? {
        let symbols = ["Convert": "arrow.left.arrow.right", "PDF": "doc.on.doc"]
        guard let name = symbols[menu],
              let symbol = NSImage(systemSymbolName: name, accessibilityDescription: menu)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)) else { return nil }
        let size = NSSize(width: ceil(symbol.size.width), height: ceil(symbol.size.height))
        let image = NSImage(size: size)
        // Resolve the enabled-label colour once, before Finder archives the image.
        // A translucent symbol palette can multiply opacity during rendering.
        appearance.performAsCurrentDrawingAppearance {
            for scale in [1, 2] {
                guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                    pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                    let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
                bitmap.size = size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
                let rect = NSRect(origin: .zero, size: size)
                NSColor.clear.setFill()
                rect.fill(using: .copy)
                symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                NSColor.labelColor.setFill()
                rect.fill(using: .sourceIn)
                NSGraphicsContext.restoreGraphicsState()
                image.addRepresentation(bitmap)
            }
        }
        image.isTemplate = false
        image.accessibilityDescription = menu
        return image.representations.isEmpty ? nil : image
    }
}
