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


/// Reports appearance changes, so layer colours follow light and dark mode.
final class PageItemView: NSView {
    var onAppearanceChange: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); onAppearanceChange?() }
}

final class PageItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PageItem")
    let thumbnail = NSImageView()
    let caption = NSTextField(labelWithString: "")
    /// Rounded label behind the page number; filled with the accent colour when selected.
    let captionPill = NSView()
    var source: Int?
    private var loaded = false

    override func loadView() {
        let root = PageItemView(); root.wantsLayer = true; root.layer?.cornerRadius = 8
        thumbnail.imageScaling = .scaleProportionallyUpOrDown; thumbnail.wantsLayer = true; thumbnail.layer?.cornerRadius = 2
        let shadow = NSShadow(); shadow.shadowBlurRadius = 3; shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3); thumbnail.shadow = shadow
        captionPill.wantsLayer = true; captionPill.layer?.cornerRadius = 9
        caption.alignment = .center; caption.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium); caption.lineBreakMode = .byTruncatingTail
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        thumbnail.setAccessibilityElement(false); caption.setAccessibilityElement(false)
        for view in [thumbnail, captionPill, caption] { view.translatesAutoresizingMaskIntoConstraints = false }
        root.addSubview(thumbnail); root.addSubview(captionPill); captionPill.addSubview(caption)
        NSLayoutConstraint.activate([
            thumbnail.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            thumbnail.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            thumbnail.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            thumbnail.bottomAnchor.constraint(equalTo: captionPill.topAnchor, constant: -8),
            captionPill.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            captionPill.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            captionPill.heightAnchor.constraint(equalToConstant: 18),
            captionPill.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),
            captionPill.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -8),
            caption.leadingAnchor.constraint(equalTo: captionPill.leadingAnchor, constant: 8),
            caption.trailingAnchor.constraint(equalTo: captionPill.trailingAnchor, constant: -8),
            caption.centerYAnchor.constraint(equalTo: captionPill.centerYAnchor)
        ])
        root.setAccessibilityElement(true); root.setAccessibilityRole(.image)
        root.onAppearanceChange = { [weak self] in self?.updateSelection() }
        view = root
    }

    func show(_ image: NSImage?) {
        thumbnail.image = image; loaded = image != nil
        updateSelection()
    }

    override var isSelected: Bool { didSet { updateSelection() } }
    override var highlightState: NSCollectionViewItem.HighlightState { didSet { updateSelection() } }
    override func viewDidLayout() { super.viewDidLayout(); updateSelection() }

    private func updateSelection() {
        guard isViewLoaded else { return }
        let selected = isSelected || highlightState == .forSelection
        // Layer colours are fixed values, so resolve them in this view's appearance.
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor
            view.layer?.borderColor = NSColor.controlAccentColor.cgColor
            captionPill.layer?.backgroundColor = selected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
            thumbnail.layer?.backgroundColor = loaded ? NSColor.clear.cgColor : NSColor.quaternaryLabelColor.cgColor
        }
        caption.textColor = selected ? .white : .secondaryLabelColor
        view.layer?.borderWidth = selected ? 2 : 0
        view.setAccessibilitySelected(selected)
    }
}

/// Plain Delete and Forward Delete remove the selected pages; Space previews the
/// selected page, as does a double-click. Arrow keys, Shift and Command selection
/// and Select All are handled by NSCollectionView.
final class PageCollectionView: NSCollectionView {
    var onDelete: (() -> Void)?
    var onQuickLook: (() -> Void)?
    var onOpen: ((Int) -> Void)?
    override func keyDown(with event: NSEvent) {
        let keys = [NSDeleteCharacter, NSBackspaceCharacter, NSDeleteFunctionKey]
        if let key = event.charactersIgnoringModifiers?.unicodeScalars.first, event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            if keys.contains(Int(key.value)) { onDelete?(); return }
            if key == " " { onQuickLook?(); return }
        }
        super.keyDown(with: event)
    }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) { onOpen?(path.item) }
    }
}

/// Shows the organised pages at full size. In the page preview panel, the arrow
/// keys step through pages and Space, Return or Escape closes it, as in Quick Look.
final class PagePreviewView: PDFView {
    var onStep: ((Int) -> Void)?
    var onDismiss: (() -> Void)?
    var onDelete: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              let key = event.charactersIgnoringModifiers?.unicodeScalars.first.map({ Int($0.value) }) else { super.keyDown(with: event); return }
        if let onStep, [NSLeftArrowFunctionKey, NSUpArrowFunctionKey, NSPageUpFunctionKey].contains(key) { onStep(-1) }
        else if let onStep, [NSRightArrowFunctionKey, NSDownArrowFunctionKey, NSPageDownFunctionKey].contains(key) { onStep(1) }
        else if let onDismiss, [0x20, 0x1B, NSCarriageReturnCharacter, NSEnterCharacter].contains(key) { onDismiss() }
        else if let onDelete, [NSDeleteCharacter, NSBackspaceCharacter, NSDeleteFunctionKey].contains(key) { onDelete() }
        else { super.keyDown(with: event) }
    }
}

extension NSToolbarItem.Identifier {
    static let organiserView = NSToolbarItem.Identifier("organiser.view")
    static let organiserQuickLook = NSToolbarItem.Identifier("organiser.quicklook")
    static let organiserRotate = NSToolbarItem.Identifier("organiser.rotate")
    static let organiserMove = NSToolbarItem.Identifier("organiser.move")
    static let organiserDelete = NSToolbarItem.Identifier("organiser.delete")
    static let organiserPages = NSToolbarItem.Identifier("organiser.pages")
    static let organiserSize = NSToolbarItem.Identifier("organiser.size")
}

/// The Organise pages window: reorder, rotate, delete and extract, then save a
/// new PDF beside the original. Every edit can be undone; the original is kept.
/// Thumbnails and the full-size page views always show the current, unsaved arrangement.
final class PageOrganiserController: NSWindowController, NSWindowDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate, NSTextFieldDelegate, NSMenuItemValidation, NSToolbarDelegate {
    enum Mode: Int { case thumbnails, pages }
    static let sizeKey = "OrganiserThumbnailSize"
    static let frameName = "OrganisePages"
    /// Small, medium and large thumbnail widths; the slider moves freely between them.
    static let sizes: [CGFloat] = [96, 176, 256]

    let input: URL
    let pageCount: Int
    private let engine: ConversionEngine
    private let source: PDFDocument
    private let renderer: ThumbnailRenderer
    private let history = UndoManager()
    private(set) var pages: [OrganisedPage]
    private(set) var busy = false
    private(set) var mode = Mode.thumbnails
    private var dragged: IndexSet?
    private var selectionObservation: NSKeyValueObservation?
    /// The current arrangement as a PDF, built when a full-size view needs it.
    private var arranged: PDFDocument?
    /// Set while the window itself moves the page preview, so that move does not change the selection.
    private var navigating = false
    let collection = PageCollectionView()
    private let scroll = NSScrollView()
    /// Every page, full width, in one scrolling column.
    let pagesView = PagePreviewView()
    /// One page at a time in a separate panel (Space, double-click or Command-Y).
    let lookView = PagePreviewView()
    private(set) var lookPanel: NSPanel?
    private(set) var lookIndex = 0
    let pageField = NSTextField(string: "")
    let status = NSTextField(labelWithString: "")
    let result = NSTextField(wrappingLabelWithString: "")
    private let layout = NSCollectionViewFlowLayout()
    let sizeSlider = NSSlider(value: 176, minValue: 96, maxValue: 256, target: nil, action: nil)
    private var viewControl = NSSegmentedControl(), rotateControl = NSSegmentedControl(), moveControl = NSSegmentedControl()
    private var deleteControl = NSSegmentedControl(), lookControl = NSSegmentedControl()
    private var saveButtons: [NSButton] = []
    private(set) var saveButton = NSButton(), extractButton = NSButton(), removeButton = NSButton()
    var onClose: (() -> Void)?
    /// Called after each save attempt, with the new file or the error message.
    var onSave: ((String, Result<URL, Error>) -> Void)?

    init(input: URL, document: PDFDocument, engine: ConversionEngine, logo: NSImage?) {
        self.input = input; self.engine = engine; source = document; pageCount = document.pageCount
        pages = PageOrganiser.pages(count: document.pageCount)
        renderer = ThumbnailRenderer(url: input)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Organise pages"; window.subtitle = input.lastPathComponent
        window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 760, height: 520)
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self
        build(in: window, notes: PageOrganiser.unpreservedFeatures(of: document), logo: logo)
        // Reopen at the size and place last used.
        if !window.setFrameUsingName(Self.frameName) { window.center() }
        _ = window.setFrameAutosaveName(Self.frameName)
        renderer.delivered = { [weak self] source, image in self?.deliver(image, for: source) }
        updateState()
    }
    required init?(coder: NSCoder) { nil }

    // MARK: Layout

    private func build(in window: NSWindow, notes: [String], logo: NSImage?) {
        let content = window.contentView!

        // Toolbar controls, grouped: view, edits, then selection and size.
        func segments(_ entries: [(symbol: String, name: String, tip: String)], _ action: Selector, tracking: NSSegmentedControl.SwitchTracking = .momentary) -> NSSegmentedControl {
            let images = entries.map { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.name) ?? NSImage() }
            let control = NSSegmentedControl(images: images, trackingMode: tracking, target: self, action: action)
            for (index, entry) in entries.enumerated() { control.setToolTip(entry.tip, forSegment: index) }
            control.setAccessibilityLabel(entries.map(\.name).joined(separator: ", "))
            return control
        }
        viewControl = segments([("square.grid.2x2", "Thumbnails", "Show pages as thumbnails (Command-1)"),
                                ("rectangle.grid.1x2", "Pages", "Preview every page at full width (Command-2)")], #selector(changeMode(_:)), tracking: .selectOne)
        viewControl.selectedSegment = Mode.thumbnails.rawValue
        lookControl = segments([("eye", "Quick Look", "Preview the selected page large (Space or Command-Y); arrow keys move between pages")], #selector(quickLook(_:)))
        rotateControl = segments([("rotate.left", "Rotate left", "Rotate the selected pages 90 degrees anticlockwise (Command-L)"),
                                  ("rotate.right", "Rotate right", "Rotate the selected pages 90 degrees clockwise (Command-R)")], #selector(rotateSegment(_:)))
        moveControl = segments([("arrow.left", "Move earlier", "Move the selected pages one place earlier (Option-Command-Left Arrow)"),
                                ("arrow.right", "Move later", "Move the selected pages one place later (Option-Command-Right Arrow)")], #selector(moveSegment(_:)))
        deleteControl = segments([("trash", "Delete", "Delete the selected pages (Delete)")], #selector(deletePages(_:)))

        pageField.placeholderString = "Select pages: 1-3, 5"; pageField.delegate = self
        pageField.target = self; pageField.action = #selector(choosePages(_:))
        pageField.setAccessibilityLabel("Pages to select, by position, for example 1-3, 5, 8")
        pageField.toolTip = "Type page positions to select them, for example 1-3, 5, 8"
        pageField.widthAnchor.constraint(equalToConstant: 168).isActive = true
        sizeSlider.target = self; sizeSlider.action = #selector(resize(_:)); sizeSlider.isContinuous = true
        sizeSlider.numberOfTickMarks = Self.sizes.count; sizeSlider.allowsTickMarkValuesOnly = false
        sizeSlider.controlSize = .small; sizeSlider.setAccessibilityLabel("Thumbnail size"); sizeSlider.toolTip = "Thumbnail size"
        sizeSlider.widthAnchor.constraint(equalToConstant: 96).isActive = true
        let stored = UserDefaults.standard.double(forKey: Self.sizeKey)
        if stored >= sizeSlider.minValue && stored <= sizeSlider.maxValue { sizeSlider.doubleValue = stored }

        let toolbar = NSToolbar(identifier: "OrganisePagesToolbar")
        toolbar.delegate = self; toolbar.displayMode = .iconOnly; toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        // Thumbnail grid.
        layout.minimumInteritemSpacing = 16; layout.minimumLineSpacing = 16
        layout.sectionInset = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        collection.collectionViewLayout = layout
        collection.isSelectable = true; collection.allowsMultipleSelection = true; collection.allowsEmptySelection = true
        collection.backgroundColors = [.underPageBackgroundColor]
        collection.dataSource = self; collection.delegate = self
        collection.register(PageItem.self, forItemWithIdentifier: PageItem.identifier)
        collection.registerForDraggedTypes([.organisedPage])
        collection.setDraggingSourceOperationMask(.move, forLocal: true)
        collection.setAccessibilityLabel("Pages")
        collection.onDelete = { [weak self] in self?.deletePages(nil) }
        collection.onQuickLook = { [weak self] in self?.quickLook(nil) }
        collection.onOpen = { [weak self] index in self?.select(IndexSet(integer: index), scroll: false); self?.showLook(at: index) }
        scroll.documentView = collection; scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        scroll.drawsBackground = true; scroll.backgroundColor = .underPageBackgroundColor
        resizeItems()

        // Every page, large, in one scrolling column.
        pagesView.displayMode = .singlePageContinuous; pagesView.displayDirection = .vertical
        pagesView.displaysPageBreaks = true; pagesView.autoScales = true
        pagesView.backgroundColor = .underPageBackgroundColor
        pagesView.setAccessibilityLabel("Page preview")
        pagesView.onDelete = { [weak self] in self?.deletePages(nil) }
        pagesView.isHidden = true
        NotificationCenter.default.addObserver(self, selector: #selector(previewPageChanged(_:)), name: .PDFViewPageChanged, object: pagesView)

        let stage = NSView()
        for view in [scroll, pagesView] {
            view.translatesAutoresizingMaskIntoConstraints = false; stage.addSubview(view)
            NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: stage.leadingAnchor), view.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
                                         view.topAnchor.constraint(equalTo: stage.topAnchor), view.bottomAnchor.constraint(equalTo: stage.bottomAnchor)])
        }

        // Footer: brand mark, page count and messages, then the save actions.
        status.font = .systemFont(ofSize: 13); status.textColor = .labelColor; status.lineBreakMode = .byTruncatingTail
        result.font = .systemFont(ofSize: 11); result.textColor = .secondaryLabelColor; result.maximumNumberOfLines = 2
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        result.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let info = NSStackView(views: [status, result]); info.orientation = .vertical; info.alignment = .leading; info.spacing = 2
        if !notes.isEmpty {
            let note = NSTextField(wrappingLabelWithString: "New PDFs will not keep this document’s \(notes.joined(separator: " or ")).")
            note.textColor = .secondaryLabelColor; note.font = .systemFont(ofSize: 11)
            note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            info.addArrangedSubview(note)
        }
        info.setContentHuggingPriority(.defaultLow, for: .horizontal)
        extractButton = NSButton(title: "Extract Selected", target: self, action: #selector(extractSelected(_:)))
        extractButton.toolTip = "Save only the selected pages, in their current order and rotation, as a new PDF (Command-E)"
        removeButton = NSButton(title: "Remove Selected and Save", target: self, action: #selector(removeSelectedAndSave(_:)))
        removeButton.toolTip = "Delete the selected pages, then save the result as a new PDF"
        saveButton = NSButton(title: "Save as New PDF", target: self, action: #selector(saveOrganised(_:)))
        saveButton.toolTip = "Save the organised document beside the original (Command-S)"
        // The primary action. Return is left to the Pages field, so this is not the default button.
        saveButton.bezelColor = .controlAccentColor
        saveButtons = [extractButton, removeButton, saveButton]
        for button in saveButtons { button.bezelStyle = .rounded; button.setContentCompressionResistancePriority(.required, for: .horizontal) }
        let footer = NSStackView(); footer.orientation = .horizontal; footer.alignment = .centerY; footer.spacing = 8
        footer.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        if let logo {
            let mark = NSImageView(image: logo); mark.imageScaling = .scaleProportionallyUpOrDown
            mark.setAccessibilityLabel("Roberts Macros: because no macro is too micro")
            mark.widthAnchor.constraint(equalToConstant: 40).isActive = true; mark.heightAnchor.constraint(equalToConstant: 24).isActive = true
            footer.addView(mark, in: .leading)
        }
        footer.addView(info, in: .leading)
        for button in saveButtons { footer.addView(button, in: .trailing) }
        footer.setHuggingPriority(.defaultHigh, for: .vertical)
        let separator = NSBox(); separator.boxType = .separator
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let column = NSStackView(views: [stage, separator, footer])
        column.orientation = .vertical; column.alignment = .leading; column.spacing = 0; column.distribution = .fill
        column.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(column)
        for view in [stage, separator, footer] { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        stage.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        stage.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: content.leadingAnchor), column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                                     column.topAnchor.constraint(equalTo: content.topAnchor), column.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        window.initialFirstResponder = collection
        selectionObservation = collection.observe(\.selectionIndexPaths) { [weak self] _, _ in
            DispatchQueue.main.async { self?.selectionChanged() }
        }
    }

    // MARK: Toolbar

    private var toolbarItems: [NSToolbarItem.Identifier] {
        [.organiserView, .organiserQuickLook, .flexibleSpace, .organiserRotate, .organiserMove, .organiserDelete, .flexibleSpace, .organiserPages, .organiserSize]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarItems }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarItems }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func item(_ label: String, _ view: NSView, menu: [(String, Selector)]) -> NSToolbarItem {
            let result = NSToolbarItem(itemIdentifier: itemIdentifier); result.label = label; result.paletteLabel = label; result.view = view
            // Used when the window is too narrow and the item moves to the overflow menu.
            let form = NSMenuItem(title: label, action: menu.count == 1 ? menu[0].1 : nil, keyEquivalent: "")
            if menu.count > 1 {
                let submenu = NSMenu(title: label)
                for (title, action) in menu { submenu.addItem(withTitle: title, action: action, keyEquivalent: "") }
                form.submenu = submenu
            }
            result.menuFormRepresentation = form
            return result
        }
        switch itemIdentifier {
        case .organiserView: return item("View", viewControl, menu: [("Thumbnails", #selector(showThumbnails(_:))), ("Pages", #selector(showPages(_:)))])
        case .organiserQuickLook: return item("Quick Look", lookControl, menu: [("Quick Look", #selector(quickLook(_:)))])
        case .organiserRotate: return item("Rotate", rotateControl, menu: [("Rotate Left", #selector(rotateLeft(_:))), ("Rotate Right", #selector(rotateRight(_:)))])
        case .organiserMove: return item("Move", moveControl, menu: [("Move Earlier", #selector(moveEarlier(_:))), ("Move Later", #selector(moveLater(_:)))])
        case .organiserDelete: return item("Delete", deleteControl, menu: [("Delete", #selector(deletePages(_:)))])
        case .organiserPages: return item("Select Pages", pageField, menu: [("Select All Pages", #selector(selectAllPages(_:)))])
        case .organiserSize:
            func symbol(_ scale: NSImage.SymbolScale) -> NSImageView {
                let image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(scale: scale))
                let view = NSImageView(image: image ?? NSImage()); view.contentTintColor = .secondaryLabelColor; view.setAccessibilityElement(false)
                return view
            }
            let group = NSStackView(views: [symbol(.small), sizeSlider, symbol(.large)]); group.spacing = 4
            return item("Thumbnail Size", group, menu: [("Zoom In", #selector(zoomIn(_:))), ("Zoom Out", #selector(zoomOut(_:)))])
        default: return nil
        }
    }

    /// Adds the File, View and Pages menus used by this window to an application menu.
    static func addMenus(to menu: NSMenu) {
        func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let result = NSMenuItem(title: title, action: action, keyEquivalent: key); result.keyEquivalentModifierMask = modifiers; return result
        }
        let file = NSMenu(title: "File")
        for entry in [item("Save as New PDF", #selector(saveOrganised(_:)), "s"), item("Extract Selected", #selector(extractSelected(_:)), "e"),
                      item("Remove Selected and Save", #selector(removeSelectedAndSave(_:)), ""), .separator(), item("Close", #selector(NSWindow.performClose(_:)), "w")] { file.addItem(entry) }
        let view = NSMenu(title: "View")
        for entry in [item("as Thumbnails", #selector(showThumbnails(_:)), "1"), item("as Pages", #selector(showPages(_:)), "2"), .separator(),
                      item("Quick Look", #selector(quickLook(_:)), "y"), .separator(),
                      item("Zoom In", #selector(zoomIn(_:)), "="), item("Zoom Out", #selector(zoomOut(_:)), "-")] { view.addItem(entry) }
        let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!), right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        let pages = NSMenu(title: "Pages")
        for entry in [item("Rotate Left", #selector(rotateLeft(_:)), "l"), item("Rotate Right", #selector(rotateRight(_:)), "r"), .separator(),
                      item("Move Earlier", #selector(moveEarlier(_:)), left, [.command, .option]), item("Move Later", #selector(moveLater(_:)), right, [.command, .option]), .separator(),
                      item("Delete Pages", #selector(deletePages(_:)), String(UnicodeScalar(NSBackspaceCharacter)!)), item("Select All Pages", #selector(selectAllPages(_:)), "")] { pages.addItem(entry) }
        // After the application menu: File, then (after Edit) View and Pages.
        for (title, submenu, position) in [("File", file, 1), ("View", view, 3), ("Pages", pages, 4)] {
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: ""); holder.submenu = submenu
            menu.insertItem(holder, at: min(position, menu.numberOfItems))
        }
    }

    // MARK: Selection and state

    var selectedIndexes: IndexSet { IndexSet(collection.selectionIndexPaths.map(\.item)) }

    func select(_ indexes: IndexSet, scroll: Bool = true) {
        let paths = Set(indexes.filter { $0 < pages.count }.map { IndexPath(item: $0, section: 0) })
        collection.selectionIndexPaths = paths
        if scroll, let first = indexes.first, first < pages.count {
            collection.scrollToItems(at: [IndexPath(item: first, section: 0)], scrollPosition: .nearestHorizontalEdge)
            if mode == .pages { showInPagesView(first) }
        }
        updateState()
    }

    private func selectionChanged() {
        updateState()
        // Like Quick Look in Finder, an open page preview follows the selection.
        if lookPanel?.isVisible == true, let first = selectedIndexes.first, first != lookIndex { showLook(at: first, focus: false) }
    }

    private func updateState() {
        let count = selectedIndexes.count
        var parts = ["\(pages.count) \(pages.count == 1 ? "page" : "pages")", count == 0 ? "none selected" : "\(count) selected"]
        if pages.count != pageCount { parts.append("\(pageCount - pages.count) removed") }
        status.stringValue = parts.joined(separator: " · ")
        let editable = count > 0 && !busy
        for control in [rotateControl, moveControl, deleteControl] { control.isEnabled = editable }
        lookControl.isEnabled = !pages.isEmpty
        viewControl.selectedSegment = mode.rawValue
        sizeSlider.isEnabled = mode == .thumbnails
        extractButton.isEnabled = editable
        removeButton.isEnabled = editable && count < pages.count
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
            if focusGrid { window?.makeFirstResponder(mode == .pages ? pagesView : collection) }
        } catch { report(error.localizedDescription, failed: true) }
    }

    @objc func selectAllPages(_ sender: Any?) { select(IndexSet(0..<pages.count), scroll: false); if mode == .thumbnails { window?.makeFirstResponder(collection) } }

    @objc func resize(_ sender: Any?) {
        resizeItems()
        UserDefaults.standard.set(sizeSlider.doubleValue, forKey: Self.sizeKey)
    }
    private func resizeItems() {
        let width = CGFloat(sizeSlider.doubleValue.rounded())
        layout.itemSize = NSSize(width: width, height: (width * 1.32 + 40).rounded())
        layout.invalidateLayout()
    }

    // MARK: Views: thumbnails, every page, and one page large

    @objc func changeMode(_ sender: Any?) { setMode(Mode(rawValue: viewControl.selectedSegment) ?? .thumbnails) }
    @objc func showThumbnails(_ sender: Any?) { setMode(.thumbnails) }
    @objc func showPages(_ sender: Any?) { setMode(.pages) }

    func setMode(_ newMode: Mode) {
        defer { updateState() }
        guard newMode != mode else { return }
        if newMode == .pages {
            // Start at the first selected page, or the first page in view.
            let visible = collection.indexPathsForVisibleItems().map(\.item).min()
            let start = selectedIndexes.first ?? visible ?? 0
            mode = .pages
            setPagesDocument()
            scroll.isHidden = true; pagesView.isHidden = false
            showInPagesView(start)
            window?.makeFirstResponder(pagesView)
        } else {
            mode = .thumbnails
            pagesView.isHidden = true; scroll.isHidden = false
            if let first = selectedIndexes.first { collection.scrollToItems(at: [IndexPath(item: first, section: 0)], scrollPosition: .centeredVertically) }
            window?.makeFirstResponder(collection)
        }
    }

    /// The organised pages as a PDF, rebuilt after each edit. Pages are copied, not rendered.
    private func arrangedDocument() -> PDFDocument? {
        if arranged == nil { arranged = try? PageOrganiser.document(from: source, pages: pages) }
        return arranged
    }

    private func setPagesDocument() {
        navigating = true; defer { navigating = false }
        pagesView.document = arrangedDocument()
    }

    private func showInPagesView(_ index: Int) {
        guard let document = pagesView.document, let page = document.page(at: index) else { return }
        if let current = pagesView.currentPage, document.index(for: current) == index { return }
        navigating = true; defer { navigating = false }
        pagesView.layoutDocumentView()
        pagesView.go(to: page)
    }

    /// Scrolling the page preview selects the page in view, so edits and
    /// Extract act on the page being looked at.
    @objc private func previewPageChanged(_ notification: Notification) {
        guard mode == .pages, !navigating, let document = pagesView.document, let page = pagesView.currentPage else { return }
        let index = document.index(for: page)
        if index >= 0, index < pages.count, !selectedIndexes.contains(index) { select(IndexSet(integer: index), scroll: false) }
    }

    /// Rebuilds the full-size views after an edit, so they never show a stale arrangement.
    private func refreshPreviews(showing index: Int?) {
        arranged = nil
        if mode == .pages {
            setPagesDocument()
            if let index { showInPagesView(index) }
        }
        if lookPanel?.isVisible == true { showLook(at: min(index ?? lookIndex, pages.count - 1), focus: false) }
    }

    @objc func quickLook(_ sender: Any?) {
        if let panel = lookPanel, panel.isVisible { closeLook(); return }
        guard !pages.isEmpty else { return }
        let index = selectedIndexes.first ?? 0
        if selectedIndexes.isEmpty { select(IndexSet(integer: index)) }
        showLook(at: index)
    }

    func showLook(at index: Int, focus: Bool = true) {
        guard let document = arrangedDocument(), let page = document.page(at: index) else { return }
        let panel = lookPanel ?? makeLookPanel()
        lookIndex = index
        if lookView.document !== document { lookView.document = document }
        lookView.layoutDocumentView()
        lookView.go(to: page)
        let entry = pages[index]
        panel.title = "Page \(index + 1) of \(pages.count)"
        var details: [String] = []
        if entry.source != index { details.append("originally page \(entry.source + 1)") }
        if let turn = [90: "rotated right", 180: "rotated 180°", 270: "rotated left"][entry.rotation] { details.append(turn) }
        panel.subtitle = details.joined(separator: " · ")
        if focus { panel.makeKeyAndOrderFront(nil) } else { panel.orderFront(nil) }
    }

    private func stepLook(_ delta: Int) {
        let next = lookIndex + delta
        guard next >= 0, next < pages.count else { NSSound.beep(); return }
        select(IndexSet(integer: next))
        showLook(at: next)
    }

    func closeLook() {
        lookPanel?.orderOut(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func makeLookPanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 820), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = true; panel.isFloatingPanel = true
        panel.minSize = NSSize(width: 320, height: 400)
        // Shares this window's undo history; closing it does not close the organiser.
        panel.delegate = self
        lookView.displayMode = .singlePage; lookView.autoScales = true; lookView.displaysPageBreaks = true
        lookView.backgroundColor = .underPageBackgroundColor
        lookView.setAccessibilityLabel("Page preview")
        lookView.onStep = { [weak self] delta in self?.stepLook(delta) }
        lookView.onDismiss = { [weak self] in self?.closeLook() }
        lookView.onDelete = { [weak self] in self?.deletePages(nil) }
        panel.contentView = lookView
        if !panel.setFrameUsingName("OrganisePagesPreview"), let frame = window?.frame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: max(frame.midY - panel.frame.height / 2, 0)))
        }
        _ = panel.setFrameAutosaveName("OrganisePagesPreview")
        panel.initialFirstResponder = lookView
        lookPanel = panel
        return panel
    }

    @objc func zoomIn(_ sender: Any?) { zoom(by: 1) }
    @objc func zoomOut(_ sender: Any?) { zoom(by: -1) }
    private func zoom(by step: Int) {
        if lookPanel?.isKeyWindow == true { step > 0 ? lookView.zoomIn(nil) : lookView.zoomOut(nil); return }
        if mode == .pages { step > 0 ? pagesView.zoomIn(nil) : pagesView.zoomOut(nil); return }
        let current = CGFloat(sizeSlider.doubleValue)
        let next = step > 0 ? Self.sizes.first { $0 > current + 1 } : Self.sizes.last { $0 < current - 1 }
        guard let next else { NSSound.beep(); return }
        sizeSlider.doubleValue = Double(next); resize(nil)
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
        refreshPreviews(showing: selection.first)
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

    @objc func rotateSegment(_ sender: NSSegmentedControl) { if sender.selectedSegment == 0 { rotateLeft(sender) } else { rotateRight(sender) } }
    @objc func moveSegment(_ sender: NSSegmentedControl) { if sender.selectedSegment == 0 { moveEarlier(sender) } else { moveLater(sender) } }
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
        case #selector(showThumbnails(_:)): menuItem.state = mode == .thumbnails ? .on : .off; return true
        case #selector(showPages(_:)): menuItem.state = mode == .pages ? .on : .off; return true
        case #selector(quickLook(_:)): menuItem.title = lookPanel?.isVisible == true ? "Close Quick Look" : "Quick Look"; return !pages.isEmpty
        default: return true
        }
    }

    // MARK: Window

    @objc func closeWindow(_ sender: Any?) { window?.performClose(sender) }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { history }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window else { return true }
        if busy { report("Wait for the new PDF to finish saving."); return false }
        return true
    }
    func windowWillClose(_ notification: Notification) {
        // The page preview panel shares this delegate; only the main window ends the session.
        guard (notification.object as? NSWindow) === window else { return }
        lookPanel?.orderOut(nil)
        NotificationCenter.default.removeObserver(self, name: .PDFViewPageChanged, object: pagesView)
        selectionObservation = nil
        renderer.delivered = nil
        onClose?()
    }

    // Test access: undo history and thumbnail work.
    var undoHistory: UndoManager { history }
    func waitForThumbnails() { renderer.drain() }
}
