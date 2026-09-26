import Cocoa
import PDFKit

extension NSPasteboard.PasteboardType {
    static let organisedPage = NSPasteboard.PasteboardType("com.robertsmacros.rmconvert.page")
}

/// Renders thumbnails on one background queue from a private copy of the PDF.
/// Pages are rendered only while shown, and the cache has a fixed memory budget.
final class ThumbnailRenderer {
    static let pixelSize = NSSize(width: 520, height: 520)
    private let queue = DispatchQueue(label: "com.robertsmacros.rmconvert.thumbnails", qos: .userInitiated)
    private var document: PDFDocument?
    private let cache = NSCache<NSNumber, NSImage>()
    private let lock = NSLock()
    private var wanted = Set<Int>(), queued = Set<Int>()
    var delivered: ((Int, NSImage) -> Void)?

    init(url: URL) {
        cache.totalCostLimit = 256 * 1024 * 1024
        queue.async { self.document = PDFDocument(url: url) }
    }

    func image(for source: Int) -> NSImage? { cache.object(forKey: NSNumber(value: source)) }

    func request(_ source: Int) {
        lock.lock(); wanted.insert(source); let added = queued.insert(source).inserted; lock.unlock()
        if added { queue.async { [weak self] in self?.render(source) } }
    }

    func cancel(_ source: Int) { lock.lock(); wanted.remove(source); lock.unlock() }

    /// Waits for queued work; used by tests and before closing.
    func drain() { queue.sync {} }

    private func render(_ source: Int) {
        lock.lock(); let needed = wanted.contains(source); queued.remove(source); lock.unlock()
        guard needed, image(for: source) == nil, let page = document?.page(at: source) else { return }
        let thumbnail = page.thumbnail(of: Self.pixelSize, for: .cropBox)
        // Rasterise here so scrolling never draws PDF content on the main thread.
        guard let pixels = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let image = NSImage(cgImage: pixels, size: thumbnail.size)
        cache.setObject(image, forKey: NSNumber(value: source), cost: pixels.bytesPerRow * pixels.height)
        DispatchQueue.main.async { self.delivered?(source, image) }
    }

    /// Shows an added quarter-turn rotation without rendering the page again.
    static func rotated(_ image: NSImage, by degrees: Int) -> NSImage {
        let turns = PageOrganiser.normalised(degrees) / 90
        guard turns != 0 else { return image }
        let size = turns % 2 == 0 ? image.size : NSSize(width: image.size.height, height: image.size.width)
        return NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.translateBy(x: rect.midX, y: rect.midY)
            context.rotate(by: -CGFloat(turns) * .pi / 2)
            image.draw(in: NSRect(x: -image.size.width / 2, y: -image.size.height / 2, width: image.size.width, height: image.size.height))
            return true
        }
    }
}

final class PageItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PageItem")
    let thumbnail = NSImageView()
    let caption = NSTextField(labelWithString: "")
    var source: Int?

    override func loadView() {
        let root = NSView(); root.wantsLayer = true; root.layer?.cornerRadius = 8
        thumbnail.imageScaling = .scaleProportionallyUpOrDown; thumbnail.wantsLayer = true; thumbnail.layer?.cornerRadius = 3
        caption.alignment = .center; caption.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); caption.lineBreakMode = .byTruncatingTail
        thumbnail.setAccessibilityElement(false); caption.setAccessibilityElement(false)
        for view in [thumbnail, caption] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            thumbnail.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            thumbnail.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            thumbnail.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            thumbnail.bottomAnchor.constraint(equalTo: caption.topAnchor, constant: -4),
            caption.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            caption.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            caption.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            caption.heightAnchor.constraint(equalToConstant: 16)
        ])
        root.setAccessibilityElement(true); root.setAccessibilityRole(.image)
        view = root
    }

    func show(_ image: NSImage?) {
        thumbnail.image = image
        thumbnail.layer?.backgroundColor = image == nil ? NSColor.quaternaryLabelColor.cgColor : NSColor.clear.cgColor
    }

    override var isSelected: Bool { didSet { updateSelection() } }
    override var highlightState: NSCollectionViewItem.HighlightState { didSet { updateSelection() } }
    override func viewDidLayout() { super.viewDidLayout(); updateSelection() }

    private func updateSelection() {
        let selected = isSelected || highlightState == .forSelection
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = selected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.28).cgColor : NSColor.clear.cgColor
            view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
        view.layer?.borderWidth = selected ? 2 : 0
        view.setAccessibilitySelected(selected)
    }
}

/// Plain Delete and Forward Delete remove the selected pages. Arrow keys,
/// Shift and Command selection and Select All are handled by NSCollectionView.
final class PageCollectionView: NSCollectionView {
    var onDelete: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        let keys = [NSDeleteCharacter, NSBackspaceCharacter, NSDeleteFunctionKey]
        if let key = event.charactersIgnoringModifiers?.unicodeScalars.first, keys.contains(Int(key.value)),
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty { onDelete?(); return }
        super.keyDown(with: event)
    }
}

/// The Organise pages window: reorder, rotate, delete and extract, then save a
/// new PDF beside the original. Every edit can be undone; the original is kept.
final class PageOrganiserController: NSWindowController, NSWindowDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate, NSTextFieldDelegate, NSMenuItemValidation {
    let input: URL
    let pageCount: Int
    private let engine: ConversionEngine
    private let renderer: ThumbnailRenderer
    private let history = UndoManager()
    private(set) var pages: [OrganisedPage]
    private(set) var busy = false
    private var dragged: IndexSet?
    private var selectionObservation: NSKeyValueObservation?
    let collection = PageCollectionView()
    let pageField = NSTextField(string: "")
    let status = NSTextField(labelWithString: "")
    let result = NSTextField(wrappingLabelWithString: "")
    private let layout = NSCollectionViewFlowLayout()
    private let sizeSlider = NSSlider(value: 150, minValue: 96, maxValue: 260, target: nil, action: nil)
    private var editButtons: [NSButton] = [], saveButtons: [NSButton] = []
    private var saveButton = NSButton(), extractButton = NSButton(), removeButton = NSButton()
    var onClose: (() -> Void)?
    /// Called after each save attempt, with the new file or the error message.
    var onSave: ((String, Result<URL, Error>) -> Void)?

    init(input: URL, document: PDFDocument, engine: ConversionEngine, logo: NSImage?) {
        self.input = input; self.engine = engine; pageCount = document.pageCount
        pages = PageOrganiser.pages(count: document.pageCount)
        renderer = ThumbnailRenderer(url: input)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Organise pages"; window.subtitle = input.lastPathComponent
        window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 700, height: 480)
        super.init(window: window)
        window.delegate = self
        build(in: window, notes: PageOrganiser.unpreservedFeatures(of: document), logo: logo)
        window.center()
        renderer.delivered = { [weak self] source, image in self?.deliver(image, for: source) }
        updateState()
    }
    required init?(coder: NSCoder) { nil }

    // MARK: Layout

    private func build(in window: NSWindow, notes: [String], logo: NSImage?) {
        let content = window.contentView!
        let title = NSTextField(labelWithString: input.lastPathComponent); title.font = .systemFont(ofSize: 17, weight: .semibold); title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let subtitle = NSTextField(labelWithString: "\(pageCount) \(pageCount == 1 ? "page" : "pages") · the original file will be kept")
        subtitle.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [title, subtitle]); heading.orientation = .vertical; heading.alignment = .leading; heading.spacing = 2
        let header = NSStackView(views: [heading]); header.alignment = .centerY
        if let logo {
            let mark = NSImageView(image: logo); mark.imageScaling = .scaleProportionallyUpOrDown
            mark.setAccessibilityLabel("Roberts Macros: because no macro is too micro")
            mark.widthAnchor.constraint(equalToConstant: 70).isActive = true; mark.heightAnchor.constraint(equalToConstant: 42).isActive = true
            header.addView(mark, in: .trailing)
        }

        func tool(_ title: String, _ symbol: String, _ action: Selector, _ tip: String) -> NSButton {
            let button = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(), target: self, action: action)
            button.imagePosition = .imageLeading; button.bezelStyle = .rounded; button.toolTip = tip
            return button
        }
        editButtons = [tool("Rotate left", "rotate.left", #selector(rotateLeft(_:)), "Rotate the selected pages 90 degrees anticlockwise (Command-L)"),
                       tool("Rotate right", "rotate.right", #selector(rotateRight(_:)), "Rotate the selected pages 90 degrees clockwise (Command-R)"),
                       tool("Move earlier", "arrow.left", #selector(moveEarlier(_:)), "Move the selected pages one place earlier (Option-Command-Left Arrow)"),
                       tool("Move later", "arrow.right", #selector(moveLater(_:)), "Move the selected pages one place later (Option-Command-Right Arrow)"),
                       tool("Delete", "trash", #selector(deletePages(_:)), "Delete the selected pages (Delete)")]
        let sizeLabel = NSTextField(labelWithString: "Size"); sizeLabel.textColor = .secondaryLabelColor
        sizeSlider.target = self; sizeSlider.action = #selector(resize(_:)); sizeSlider.setAccessibilityLabel("Thumbnail size")
        sizeSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let tools = NSStackView(views: editButtons); tools.spacing = 8
        tools.addView(sizeLabel, in: .trailing); tools.addView(sizeSlider, in: .trailing)

        let fieldLabel = NSTextField(labelWithString: "Pages")
        pageField.placeholderString = "Select pages, for example 1-3, 5, 8"; pageField.delegate = self
        pageField.target = self; pageField.action = #selector(choosePages(_:))
        pageField.setAccessibilityLabel("Pages to select, by position, for example 1-3, 5, 8")
        let selectButton = NSButton(title: "Select", target: self, action: #selector(choosePages(_:))); selectButton.bezelStyle = .rounded
        let allButton = NSButton(title: "Select all", target: self, action: #selector(selectAllPages(_:))); allButton.bezelStyle = .rounded
        allButton.toolTip = "Select every page (Command-A)"
        let chooser = NSStackView(views: [fieldLabel, pageField, selectButton, allButton]); chooser.spacing = 8

        layout.minimumInteritemSpacing = 14; layout.minimumLineSpacing = 14
        layout.sectionInset = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        collection.collectionViewLayout = layout
        collection.isSelectable = true; collection.allowsMultipleSelection = true; collection.allowsEmptySelection = true
        collection.backgroundColors = [.underPageBackgroundColor]
        collection.dataSource = self; collection.delegate = self
        collection.register(PageItem.self, forItemWithIdentifier: PageItem.identifier)
        collection.registerForDraggedTypes([.organisedPage])
        collection.setDraggingSourceOperationMask(.move, forLocal: true)
        collection.setAccessibilityLabel("Pages")
        collection.onDelete = { [weak self] in self?.deletePages(nil) }
        let scroll = NSScrollView(); scroll.documentView = collection; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        resizeItems()

        status.textColor = .secondaryLabelColor
        result.textColor = .secondaryLabelColor; result.maximumNumberOfLines = 2
        let footer = NSStackView(views: [status, result]); footer.orientation = .vertical; footer.alignment = .leading; footer.spacing = 3
        if !notes.isEmpty {
            let note = NSTextField(wrappingLabelWithString: "New PDFs will not keep this document’s \(notes.joined(separator: " or ")).")
            note.textColor = .secondaryLabelColor; note.font = .systemFont(ofSize: 12)
            footer.addArrangedSubview(note)
        }
        let close = NSButton(title: "Close", target: self, action: #selector(closeWindow(_:))); close.bezelStyle = .rounded
        extractButton = NSButton(title: "Extract selected", target: self, action: #selector(extractSelected(_:)))
        extractButton.toolTip = "Save only the selected pages, in their current order and rotation, as a new PDF (Command-E)"
        removeButton = NSButton(title: "Remove selected and save", target: self, action: #selector(removeSelectedAndSave(_:)))
        removeButton.toolTip = "Delete the selected pages, then save the result as a new PDF"
        saveButton = NSButton(title: "Save as new PDF", target: self, action: #selector(saveOrganised(_:)))
        saveButton.toolTip = "Save the organised document beside the original (Command-S)"
        saveButtons = [extractButton, removeButton, saveButton]
        for button in saveButtons { button.bezelStyle = .rounded }
        let actions = NSStackView(views: [close]); actions.spacing = 8
        for button in saveButtons { actions.addView(button, in: .trailing) }

        let stack = NSStackView(views: [header, tools, chooser, scroll, footer, actions])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        for view in [header, tools, chooser, scroll, footer, actions] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                                     stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)])
        window.initialFirstResponder = collection
        selectionObservation = collection.observe(\.selectionIndexPaths) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateState() }
        }
    }

    /// Adds the File and Pages menus used by this window to an application menu.
    static func addMenus(to menu: NSMenu) {
        func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let result = NSMenuItem(title: title, action: action, keyEquivalent: key); result.keyEquivalentModifierMask = modifiers; return result
        }
        let file = NSMenu(title: "File")
        for entry in [item("Save as New PDF", #selector(saveOrganised(_:)), "s"), item("Extract Selected", #selector(extractSelected(_:)), "e"),
                      item("Remove Selected and Save", #selector(removeSelectedAndSave(_:)), ""), .separator(), item("Close", #selector(NSWindow.performClose(_:)), "w")] { file.addItem(entry) }
        let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!), right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        let pages = NSMenu(title: "Pages")
        for entry in [item("Rotate Left", #selector(rotateLeft(_:)), "l"), item("Rotate Right", #selector(rotateRight(_:)), "r"), .separator(),
                      item("Move Earlier", #selector(moveEarlier(_:)), left, [.command, .option]), item("Move Later", #selector(moveLater(_:)), right, [.command, .option]), .separator(),
                      item("Delete Pages", #selector(deletePages(_:)), String(UnicodeScalar(NSBackspaceCharacter)!)), item("Select All Pages", #selector(selectAllPages(_:)), "")] { pages.addItem(entry) }
        for (title, submenu) in [("File", file), ("Pages", pages)] {
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: ""); holder.submenu = submenu
            menu.insertItem(holder, at: min(title == "File" ? 1 : 3, menu.numberOfItems))
        }
    }

    // MARK: Selection and state

    var selectedIndexes: IndexSet { IndexSet(collection.selectionIndexPaths.map(\.item)) }

    func select(_ indexes: IndexSet, scroll: Bool = true) {
        let paths = Set(indexes.filter { $0 < pages.count }.map { IndexPath(item: $0, section: 0) })
        collection.selectionIndexPaths = paths
        if scroll, let first = indexes.first, first < pages.count { collection.scrollToItems(at: [IndexPath(item: first, section: 0)], scrollPosition: .nearestHorizontalEdge) }
        updateState()
    }

    private func updateState() {
        let count = selectedIndexes.count
        status.stringValue = count == 0 ? "No pages selected. Click a page, or enter page numbers above." :
            "\(count) of \(pages.count) \(pages.count == 1 ? "page" : "pages") selected." + (pages.count != pageCount ? " The organised document has \(pages.count) of the original \(pageCount)." : "")
        for button in editButtons { button.isEnabled = count > 0 && !busy }
        extractButton.isEnabled = count > 0 && !busy
        removeButton.isEnabled = count > 0 && count < pages.count && !busy
        saveButton.isEnabled = !busy
    }

    private func report(_ message: String, failed: Bool = false) {
        result.stringValue = message
        result.textColor = failed ? .systemRed : .secondaryLabelColor
        result.setAccessibilityLabel(message)
        NSAccessibility.post(element: result, notification: .announcementRequested, userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func controlTextDidChange(_ obj: Notification) { applyPageField(focusGrid: false) }
    @objc func choosePages(_ sender: Any?) { applyPageField(focusGrid: true) }

    private func applyPageField(focusGrid: Bool) {
        let text = pageField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { report(""); return }
        do {
            select(try PageOrganiser.selection(text, pageCount: pages.count)); report("")
            if focusGrid { window?.makeFirstResponder(collection) }
        } catch { report(error.localizedDescription, failed: true) }
    }

    @objc func selectAllPages(_ sender: Any?) { select(IndexSet(0..<pages.count), scroll: false); window?.makeFirstResponder(collection) }

    @objc func resize(_ sender: Any?) { resizeItems() }
    private func resizeItems() {
        let width = CGFloat(sizeSlider.doubleValue.rounded())
        layout.itemSize = NSSize(width: width, height: (width * 1.32 + 30).rounded())
        layout.invalidateLayout()
    }

    // MARK: Collection data

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { pages.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: PageItem.identifier, for: indexPath) as! PageItem
        let position = indexPath.item, entry = pages[position]
        item.source = entry.source
        item.caption.stringValue = entry.source == position ? "\(position + 1)" : "\(position + 1) (was \(entry.source + 1))"
        var description = "Page \(position + 1) of \(pages.count)"
        if entry.source != position { description += ", originally page \(entry.source + 1)" }
        description += [90: ", rotated 90 degrees clockwise", 180: ", rotated 180 degrees", 270: ", rotated 90 degrees anticlockwise"][entry.rotation] ?? ""
        item.view.setAccessibilityLabel(description)
        if let image = renderer.image(for: entry.source) { item.show(ThumbnailRenderer.rotated(image, by: entry.rotation)) }
        else { item.show(nil); renderer.request(entry.source) }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        guard let source = (item as? PageItem)?.source else { return }
        // Items are recycled during reloads; only cancel pages that left the screen.
        DispatchQueue.main.async {
            if !self.collection.visibleItems().contains(where: { ($0 as? PageItem)?.source == source }) { self.renderer.cancel(source) }
        }
    }

    private func deliver(_ image: NSImage, for source: Int) {
        for case let item as PageItem in collection.visibleItems() where item.source == source {
            guard let position = collection.indexPath(for: item)?.item, position < pages.count else { continue }
            item.show(ThumbnailRenderer.rotated(image, by: pages[position].rotation))
        }
    }

    // MARK: Drag and drop

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool { !busy }
    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        let item = NSPasteboardItem(); item.setString(String(indexPath.item), forType: .organisedPage); return item
    }
    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
        dragged = IndexSet(indexPaths.map(\.item))
    }
    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) { dragged = nil }
    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo, proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        guard dragged != nil, !busy else { return [] }
        if proposedDropOperation.pointee == .on { proposedDropOperation.pointee = .before }
        return .move
    }
    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo, indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        guard let dragged else { return false }
        movePages(dragged, to: indexPath.item)
        return true
    }

    // MARK: Edits (each one can be undone)

    private func apply(_ arrangement: [OrganisedPage], selection: IndexSet, name: String) {
        let previous = pages, previousSelection = selectedIndexes
        history.registerUndo(withTarget: self) { $0.apply(previous, selection: previousSelection, name: name) }
        history.setActionName(name)
        pages = arrangement
        collection.reloadData()
        select(selection)
        report("")
    }

    func movePages(_ indexes: IndexSet, to destination: Int) {
        let moved = PageOrganiser.move(pages, indexes: indexes, to: destination)
        guard moved.pages != pages else { return }
        apply(moved.pages, selection: moved.moved, name: indexes.count == 1 ? "Move Page" : "Move Pages")
    }

    private func edit(_ name: String, _ change: ([OrganisedPage], IndexSet) throws -> (pages: [OrganisedPage], selection: IndexSet)) {
        let selection = selectedIndexes
        guard !selection.isEmpty, !busy else { NSSound.beep(); return }
        do {
            let changed = try change(pages, selection)
            if changed.pages != pages { apply(changed.pages, selection: changed.selection, name: name) }
        } catch { report(error.localizedDescription, failed: true) }
    }

    @objc func rotateLeft(_ sender: Any?) { edit("Rotate Left") { (try PageOrganiser.rotate($0, indexes: $1, by: -90), $1) } }
    @objc func rotateRight(_ sender: Any?) { edit("Rotate Right") { (try PageOrganiser.rotate($0, indexes: $1, by: 90), $1) } }
    @objc func moveEarlier(_ sender: Any?) { edit("Move Earlier") { let moved = PageOrganiser.moveEarlier($0, indexes: $1); return (moved.pages, moved.moved) } }
    @objc func moveLater(_ sender: Any?) { edit("Move Later") { let moved = PageOrganiser.moveLater($0, indexes: $1); return (moved.pages, moved.moved) } }
    @objc func deletePages(_ sender: Any?) {
        edit("Delete Pages") { pages, selection in
            let remaining = try PageOrganiser.delete(pages, indexes: selection)
            let next = min(selection.first ?? 0, remaining.count - 1)
            return (remaining, IndexSet(integer: next))
        }
    }

    // MARK: Saving

    @objc func saveOrganised(_ sender: Any?) { write(pages, label: "organised", summary: "Saved the organised document") }
    @objc func extractSelected(_ sender: Any?) {
        guard !busy else { return }
        do { write(try PageOrganiser.subset(pages, indexes: selectedIndexes), label: "extracted", summary: "Extracted the selected pages") }
        catch { report(error.localizedDescription, failed: true) }
    }
    @objc func removeSelectedAndSave(_ sender: Any?) {
        guard !busy else { return }
        let before = pages
        deletePages(sender)
        if pages != before { write(pages, label: "organised", summary: "Removed the selected pages and saved") }
    }

    private func write(_ arrangement: [OrganisedPage], label: String, summary: String) {
        guard !busy else { return }
        busy = true; updateState(); report("Saving…")
        let input = self.input, expected = pageCount, engine = self.engine
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try PageOrganiser.save(arrangement, from: input, expectedPageCount: expected, label: label, engine: engine) }
            DispatchQueue.main.async {
                self.busy = false
                switch outcome {
                case .success(let url): self.report("\(summary): “\(url.lastPathComponent)” (\(arrangement.count) \(arrangement.count == 1 ? "page" : "pages")), beside the original.")
                case .failure(let error): self.report(error.localizedDescription, failed: true)
                }
                self.updateState()
                self.onSave?(summary, outcome)
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let count = selectedIndexes.count
        switch menuItem.action {
        case #selector(saveOrganised(_:)): return !busy
        case #selector(removeSelectedAndSave(_:)): return !busy && count > 0 && count < pages.count
        case #selector(extractSelected(_:)), #selector(rotateLeft(_:)), #selector(rotateRight(_:)), #selector(moveEarlier(_:)), #selector(moveLater(_:)), #selector(deletePages(_:)): return !busy && count > 0
        default: return true
        }
    }

    // MARK: Window

    @objc func closeWindow(_ sender: Any?) { window?.performClose(sender) }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { history }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if busy { report("Wait for the new PDF to finish saving."); return false }
        return true
    }
    func windowWillClose(_ notification: Notification) {
        selectionObservation = nil
        renderer.delivered = nil
        onClose?()
    }

    // Test access: undo history and thumbnail work.
    var undoHistory: UndoManager { history }
    func waitForThumbnails() { renderer.drain() }
}
