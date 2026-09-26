import Cocoa
import PDFKit

/// Drives the real Organise pages window with generated PDFs. The window is
/// transparent while tested, so nothing appears on screen.
@main enum OrganiserWindowTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1; if !condition() { throw RMError("FAILED: " + message) }
    }
    static func pump(_ seconds: Double = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    static func wait(_ timeout: Double, until condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if condition() { return true }; pump() }
        return condition()
    }

    static func makePDF(_ url: URL, count: Int) {
        var box = CGRect(x: 0, y: 0, width: 420, height: 595)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        let colours: [NSColor] = [.systemBlue, .systemOrange, .systemGreen, .systemPurple, .systemRed, .systemTeal]
        for index in 1...count {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            colours[(index - 1) % colours.count].withAlphaComponent(0.25).setFill(); NSRect(x: 40, y: 380, width: 340, height: 170).fill()
            NSColor.darkGray.setFill(); for line in 0..<9 { NSRect(x: 40, y: 320 - line * 28, width: line % 3 == 2 ? 210 : 340, height: 10).fill() }
            ("Page \(index)" as NSString).draw(at: NSPoint(x: 60, y: 440), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 48), .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState(); context.endPDFPage()
        }
        context.closePDF()
    }

    static func loadedThumbnails(_ controller: PageOrganiserController) -> Bool {
        let items = controller.collection.visibleItems().compactMap { $0 as? PageItem }
        return !items.isEmpty && items.allSatisfy { $0.thumbnail.image != nil }
    }

    static func snapshot(_ window: NSWindow, to url: URL) throws {
        let view = window.contentView!
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw RMError("No snapshot") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }

    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let snapshotURL = CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2]) : root.appendingPathComponent("organiser.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("RMCONVERT_LOG_DIRECTORY", root.appendingPathComponent("logs").path, 1)
        NSApplication.shared.setActivationPolicy(.accessory)
        let manifest = try ConversionManifest.load(at: URL(fileURLWithPath: "Resources/manifest.json"))
        let engine = ConversionEngine(manifest: manifest)
        let logo = NSImage(contentsOf: URL(fileURLWithPath: "Resources/RobertsMacros.png"))

        // A 12-page document: selection, edits, undo and saving.
        let source = root.appendingPathComponent("Quarterly report.pdf"); makePDF(source, count: 12)
        let before = try Data(contentsOf: source)
        let controller = PageOrganiserController(input: source, document: try engine.loadPDF(source), engine: engine, logo: logo)
        let window = controller.window!
        window.alphaValue = 0; window.setFrameOrigin(NSPoint(x: 40, y: 40)); window.orderFrontRegardless()
        try expect(wait(10) { loadedThumbnails(controller) }, "thumbnails load")
        try expect(controller.collection.visibleItems().count >= 5, "grid shows several pages per row (\(controller.collection.visibleItems().count))")
        try expect(controller.status.stringValue.hasPrefix("No pages selected"), "starts with no selection")

        controller.pageField.stringValue = "2-3, 12"; controller.choosePages(nil)
        try expect(controller.selectedIndexes == [1, 2, 11], "Pages field selects ranges")
        try expect(controller.status.stringValue.hasPrefix("3 of 12"), "status reports the selection")
        controller.pageField.stringValue = "4-2"; controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        try expect(controller.result.stringValue.contains("Invalid range") && controller.selectedIndexes == [1, 2, 11], "invalid range shown inline, selection kept")

        // Each call is its own event, as with real clicks and key presses, so undo steps stay separate.
        func step(_ edit: () -> Void) { edit(); pump(0.01) }
        controller.select([1]); step { controller.rotateRight(nil) }
        try expect(controller.pages[1].rotation == 90, "rotate right")
        step { controller.rotateLeft(nil) }; step { controller.rotateLeft(nil) }
        try expect(controller.pages[1].rotation == 270, "rotate left")
        step { controller.moveLater(nil) }
        try expect(controller.pages.map(\.source).prefix(4) == [0, 2, 1, 3] && controller.selectedIndexes == [2], "move later keeps selection")
        step { controller.movePages([0, 5], to: 12) }
        try expect(controller.pages.map(\.source).suffix(2) == [0, 5] && controller.selectedIndexes == [10, 11], "drop moves several pages")
        let history = controller.undoHistory
        try expect(history.undoActionName == "Move Pages", "undo names the edit")
        step { history.undo() }
        try expect(controller.pages.map(\.source).prefix(4) == [0, 2, 1, 3], "undo drop")
        for _ in 0..<4 { step { history.undo() } }
        try expect(controller.pages == PageOrganiser.pages(count: 12), "undo every edit")
        step { history.redo() }; step { history.redo() }
        try expect(controller.pages[1].rotation == 0 && controller.pages[1].source == 1 && history.canRedo, "redo")
        step { history.redo() }; step { history.redo() }
        try expect(controller.pages[2].source == 1 && controller.pages[2].rotation == 270, "redo restores rotation and order")

        // Keyboard: Delete removes the selection; Select All; menu validation.
        controller.select([0])
        window.makeFirstResponder(controller.collection)
        let delete = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                      characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51)!
        step { controller.collection.keyDown(with: delete) }
        try expect(controller.pages.count == 11 && controller.pages[0].source == 2, "Delete key removes pages")
        step { history.undo() }
        try expect(controller.pages.count == 12, "undo delete")
        let arrow = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                     characters: String(UnicodeScalar(NSRightArrowFunctionKey)!), charactersIgnoringModifiers: String(UnicodeScalar(NSRightArrowFunctionKey)!), isARepeat: false, keyCode: 124)!
        controller.select([0], scroll: false); controller.collection.keyDown(with: arrow); pump()
        try expect(controller.selectedIndexes == [1], "arrow keys move the selection")
        controller.selectAllPages(nil)
        try expect(controller.selectedIndexes.count == 12, "select all")
        let remove = NSMenuItem(title: "", action: #selector(PageOrganiserController.removeSelectedAndSave(_:)), keyEquivalent: "")
        try expect(!controller.validateMenuItem(remove), "cannot remove every page")
        let menu = NSMenu(); menu.addItem(NSMenuItem(title: "rmconvert", action: nil, keyEquivalent: "")); menu.addItem(NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""))
        PageOrganiserController.addMenus(to: menu)
        try expect(menu.items.map(\.title) == ["rmconvert", "File", "Edit", "Pages"], "File and Pages menus")
        let shortcuts = menu.items.compactMap(\.submenu).flatMap(\.items).filter { !$0.keyEquivalent.isEmpty }.map { $0.title }
        try expect(Set(["Save as New PDF", "Extract Selected", "Rotate Left", "Rotate Right", "Move Earlier", "Move Later", "Delete Pages"]).isSubset(of: Set(shortcuts)), "keyboard shortcuts for page actions")
        for button in [controller.window!.contentView!].flatMap({ all($0) }).compactMap({ $0 as? NSButton }) {
            try expect(!(button.accessibilityLabel() ?? button.title).isEmpty, "button has an accessible name")
        }
        let item = controller.collection.visibleItems().compactMap { $0 as? PageItem }.first { controller.collection.indexPath(for: $0)?.item == 2 }
        try expect(item?.view.accessibilityLabel() == "Page 3 of 12, originally page 2, rotated 90 degrees anticlockwise", "thumbnail VoiceOver label")

        // Saving: organised, extracted, remove selected. The original is kept.
        var saved: [URL] = []
        controller.onSave = { _, outcome in if case .success(let url) = outcome { saved.append(url) } }
        controller.select([2, 3]); controller.extractSelected(nil)
        let extractedInTime = wait(20) { saved.count == 1 }
        try expect(extractedInTime, "extract selected saves: \(controller.result.stringValue)")
        controller.saveOrganised(nil)
        try expect(wait(20) { saved.count == 2 }, "save as new PDF")
        controller.select([0]); controller.removeSelectedAndSave(nil)
        try expect(wait(20) { saved.count == 3 }, "remove selected and save")
        try expect(saved.map(\.lastPathComponent) == ["Quarterly report (extracted).pdf", "Quarterly report (organised).pdf", "Quarterly report (organised)-1.pdf"], "output names")
        let extracted = PDFDocument(url: saved[0])!, organised = PDFDocument(url: saved[1])!, removed = PDFDocument(url: saved[2])!
        try expect(extracted.pageCount == 2 && extracted.page(at: 0)!.string!.contains("Page 2") && extracted.page(at: 0)!.rotation == 270, "extracted pages, order and rotation")
        try expect(organised.pageCount == 12 && organised.page(at: 1)!.string!.contains("Page 3") && organised.page(at: 2)!.rotation == 270, "organised document")
        try expect(removed.pageCount == 11 && removed.page(at: 0)!.string!.contains("Page 3"), "removed page and saved")
        try expect(controller.result.stringValue.contains("(organised)-1.pdf"), "save result shown in the window")
        let after = try Data(contentsOf: source)
        try expect(after == before, "original unchanged")
        controller.select([1, 2]); pump(0.3)
        try snapshot(window, to: snapshotURL)
        window.close()

        // 500 pages: open, select all, rotate, scroll to the end; main-thread stalls are measured.
        let large = root.appendingPathComponent("Large.pdf"); makePDF(large, count: 500)
        var longest = 0.0, last = CFAbsoluteTimeGetCurrent()
        let heartbeat = Timer(timeInterval: 0.005, repeats: true) { _ in let now = CFAbsoluteTimeGetCurrent(); longest = max(longest, now - last); last = now }
        RunLoop.main.add(heartbeat, forMode: .common)
        var start = CFAbsoluteTimeGetCurrent()
        let big = PageOrganiserController(input: large, document: try engine.loadPDF(large), engine: engine, logo: logo)
        big.window!.alphaValue = 0; big.window!.orderFrontRegardless(); big.window!.layoutIfNeeded()
        let open = CFAbsoluteTimeGetCurrent() - start
        last = CFAbsoluteTimeGetCurrent(); longest = 0
        try expect(wait(20) { loadedThumbnails(big) }, "500-page thumbnails load")
        let firstScreenStall = longest
        try expect(big.collection.visibleItems().count < 120, "only visible pages are created (\(big.collection.visibleItems().count))")
        start = CFAbsoluteTimeGetCurrent()
        big.selectAllPages(nil); big.rotateRight(nil)
        let rotateAll = CFAbsoluteTimeGetCurrent() - start
        try expect(big.pages.allSatisfy { $0.rotation == 90 }, "rotate 500 pages")
        last = CFAbsoluteTimeGetCurrent(); longest = 0
        big.select([499])
        try expect(wait(20) { loadedThumbnails(big) && big.collection.visibleItems().contains { big.collection.indexPath(for: $0)?.item == 499 } }, "scroll to page 500")
        let scrollStall = longest
        heartbeat.invalidate()
        big.waitForThumbnails()
        print(String(format: "500 pages: open %.3fs, rotate all %.3fs, longest main-thread gap while loading first screen %.3fs, while jumping to the end %.3fs", open, rotateAll, firstScreenStall, scrollStall))
        try expect(open < 1.5 && rotateAll < 0.5 && firstScreenStall < 0.25 && scrollStall < 0.25, "500-page window stays responsive")
        big.window!.close()
        print("PASS: \(checks) organiser window checks. Snapshot: \(snapshotURL.path)")
    }

    static func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
}
