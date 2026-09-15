import Cocoa

enum Brand {
    static func menuIcon(for menu: String) -> NSImage? {
        let symbols = ["Convert": "arrow.left.arrow.right", "PDF": "doc.on.doc"]
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor]))
        guard let name = symbols[menu],
              let symbol = NSImage(systemSymbolName: name, accessibilityDescription: menu),
              let image = symbol.withSymbolConfiguration(configuration) else { return nil }
        // Preserve the semantic grey palette when Finder displays the image.
        image.isTemplate = false
        return image
    }
}
