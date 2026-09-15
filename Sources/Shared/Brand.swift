import Cocoa

enum Brand {
    static func menuIcon(for menu: String) -> NSImage? {
        let symbols = ["Convert": "arrow.left.arrow.right", "PDF": "doc.on.doc"]
        guard let name = symbols[menu],
              let symbol = NSImage(systemSymbolName: name, accessibilityDescription: menu),
              let image = symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)) else { return nil }
        // Keep the system symbol's transparency and let Finder supply its foreground colour.
        image.isTemplate = true
        return image
    }
}
