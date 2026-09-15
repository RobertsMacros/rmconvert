import Cocoa
import FinderSync
import PDFKit
import UserNotifications

@main
enum Main {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSTextFieldDelegate, NSWindowDelegate {
    var window: NSWindow?
    var logWindow: NSWindow?
    var status = NSTextField(wrappingLabelWithString: "")
    var pageField = NSTextField(string: "")
    var pageStatus = NSTextField(wrappingLabelWithString: "")
    var pageButton = NSButton()
    var preview = PDFView()
    var pending: JobRequest?
    var pageCount = 0
    var worker = false
    var launchRequest: JobRequest?
    var didLaunch = false

    func application(_ application: NSApplication, open urls: [URL]) {
        worker = true; NSApp.setActivationPolicy(.accessory)
        do {
            guard urls.count == 1 else { throw RMError("Invalid job submission.") }
            let file = urls[0].standardizedFileURL
            let allowed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/" + RMPaths.extensionID + "/Data/Library/Application Support/rmconvert/Requests").resolvingSymlinksInPath()
            let real = file.resolvingSymlinksInPath()
            guard real.deletingLastPathComponent() == allowed, real.pathExtension == "rmconvert-request", UUID(uuidString: real.deletingPathExtension().lastPathComponent) != nil else { throw RMError("This is not a Finder job created by rmconvert.") }
            let attributes = try FileManager.default.attributesOfItem(atPath: real.path)
            guard (attributes[.size] as? Int ?? 0) <= 1_000_000, (attributes[.ownerAccountID] as? UInt32) == getuid(), attributes[.type] as? FileAttributeType == .typeRegular else { throw RMError("Invalid job file.") }
            let request = try JSONDecoder().decode(JobRequest.self, from: Data(contentsOf: real))
            try? FileManager.default.removeItem(at: real)
            if didLaunch { try handle(request) } else { launchRequest = request }
        } catch { if didLaunch { showError(error.localizedDescription) } else { DispatchQueue.main.async { self.showError(error.localizedDescription) } } }
    }

    func handle(_ request: JobRequest) throws {
        let manifest = try ConversionManifest.load(at: RMPaths.manifestURL)
        if manifest.actions.first(where: { $0.id == request.action })?.needsPages == true && request.pages == nil { try showPages(request, manifest: manifest) }
        else { run(request, manifest: manifest) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(closeSetup), name: RMPaths.closeSetupNotification, object: nil)
        UNUserNotificationCenter.current().delegate = self
        didLaunch = true
        if let request = launchRequest {
            worker = true; NSApp.setActivationPolicy(.accessory)
            do { try handle(request) } catch { showError(error.localizedDescription) }
            return
        }
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--request"), index + 1 < args.count {
            worker = true; NSApp.setActivationPolicy(.accessory)
            do {
                guard args[index + 1].utf8.count < 2_000_000, let data = Data(base64Encoded: args[index + 1]) else { throw RMError("Invalid conversion request.") }
                let request = try JSONDecoder().decode(JobRequest.self, from: data)
                let manifest = try ConversionManifest.load(at: RMPaths.manifestURL)
                if manifest.actions.first(where: { $0.id == request.action })?.needsPages == true && request.pages == nil {
                    try showPages(request, manifest: manifest)
                } else { run(request, manifest: manifest) }
            } catch { showError(error.localizedDescription) }
        } else {
            NSApp.setActivationPolicy(.regular)
            installMenu(); showSetup(); refresh()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc func closeSetup() { DispatchQueue.main.async { if !self.worker { NSApp.terminate(nil) } } }

    func installMenu() {
        let menu = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu(title: "rmconvert")
        appMenu.addItem(withTitle: "About rmconvert", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit rmconvert", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""), sub = NSMenu(title: "Edit")
        for (title, selector, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] { sub.addItem(withTitle: title, action: selector, keyEquivalent: key) }
        edit.submenu = sub; menu.addItem(edit); NSApp.mainMenu = menu
    }

    func makeWindow(_ title: String, size: NSSize) -> NSWindow {
        let result = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        result.title = title; result.isReleasedWhenClosed = false; result.center(); result.delegate = self
        result.minSize = size
        return result
    }

    func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text); field.font = .systemFont(ofSize: size, weight: weight); return field
    }

    func button(_ title: String, action: Selector) -> NSButton {
        let result = NSButton(title: title, target: self, action: action); result.bezelStyle = .rounded; return result
    }

    func mount(_ stack: NSStackView, in view: NSView, inset: CGFloat = 28) {
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: inset), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset), stack.topAnchor.constraint(equalTo: view.topAnchor, constant: inset), stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -inset)])
    }

    func showSetup() {
        let win = makeWindow("rmconvert", size: NSSize(width: 570, height: 470)); window = win
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        if let logo = NSImage(contentsOf: RMPaths.resourceDirectory.appendingPathComponent("RobertsMacros.png")) {
            let view = NSImageView(image: logo); view.imageScaling = .scaleProportionallyUpOrDown
            view.setAccessibilityLabel("Roberts Macros: because no macro is too micro")
            view.widthAnchor.constraint(equalToConstant: 170).isActive = true; view.heightAnchor.constraint(equalToConstant: 102).isActive = true
            let heading = NSStackView(views: [view, label("rmconvert", size: 30, weight: .semibold)]); heading.spacing = 28; stack.addArrangedSubview(heading)
        }
        stack.addArrangedSubview(label("Right-click files in Finder. Choose Convert for formats, or PDF to combine, split and work with pages.", size: 15))
        status.font = .systemFont(ofSize: 13); stack.addArrangedSubview(status)
        let controls = NSStackView(views: [button("Open Finder settings", action: #selector(finderSettings)), button("Check converters", action: #selector(refresh))]); controls.spacing = 10
        stack.addArrangedSubview(controls)
        stack.addArrangedSubview(NSStackView(views: [button("Enable notifications", action: #selector(notifications)), button("View log", action: #selector(showLog))]))
        let note = label("Results are saved beside the originals. Existing files are kept. PDF page tools create a new PDF; combine uses filename order."); note.textColor = .secondaryLabelColor; stack.addArrangedSubview(note)
        mount(stack, in: win.contentView!); win.makeKeyAndOrderFront(nil)
    }

    @objc func refresh() {
        do {
            let manifest = try ConversionManifest.load(at: RMPaths.manifestURL)
            let available = BackendRegistry.available()
            let missing = Set(manifest.routes.flatMap { [$0.backend] + ($0.requires ?? []) }).subtracting(available).sorted()
            let extensionState = FIFinderSyncController.isExtensionEnabled ? "Finder extension is enabled." : "Enable rmconvert in Finder extensions."
            status.stringValue = extensionState + "\n\n" + (missing.isEmpty ? "All converters used by this build are available." : "Some formats are unavailable. Missing: " + missing.joined(separator: ", ") + ".")
            let snapshot = CatalogueSnapshot(manifest: manifest, available: available.sorted())
            let data = try JSONEncoder().encode(snapshot)
            DistributedNotificationCenter.default().postNotificationName(RMPaths.capabilityNotification, object: nil, userInfo: ["snapshot":data.base64EncodedString()], deliverImmediately: true)
        } catch { status.stringValue = error.localizedDescription }
    }

    @objc func finderSettings() { FIFinderSyncController.showExtensionManagementInterface() }
    @objc func notifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            DispatchQueue.main.async { if let error { self.showError(error.localizedDescription) } else { self.refresh() } }
        }
    }

    func showPages(_ request: JobRequest, manifest: ConversionManifest) throws {
        guard request.paths.count == 1 else { throw RMError("Choose one PDF for page selection.") }
        let input = try AtomicOutput.checkInput(URL(fileURLWithPath: request.paths[0]))
        let document = try ConversionEngine(manifest: manifest).loadPDF(input)
        pageCount = document.pageCount; pending = request
        NSApp.setActivationPolicy(.regular); installMenu()
        let removing = request.action == "pdf.remove"
        let win = makeWindow(removing ? "Remove pages" : "Extract pages", size: NSSize(width: 730, height: 740)); window = win
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.addArrangedSubview(label(input.lastPathComponent, size: 18, weight: .semibold))
        stack.addArrangedSubview(label("\(pageCount) pages · original file will be kept"))
        preview.document = document; preview.autoScales = true; preview.displayMode = .singlePageContinuous
        preview.translatesAutoresizingMaskIntoConstraints = false; preview.heightAnchor.constraint(equalToConstant: 365).isActive = true
        stack.addArrangedSubview(preview); preview.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(label(removing ? "Pages to remove" : "Pages to extract", weight: .semibold))
        pageField.placeholderString = "For example: 1-3, 5, 8"; pageField.delegate = self; pageField.font = .systemFont(ofSize: 15)
        pageField.setAccessibilityLabel(removing ? "Pages to remove" : "Pages to extract")
        stack.addArrangedSubview(pageField); pageField.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        pageStatus.textColor = .secondaryLabelColor; stack.addArrangedSubview(pageStatus)
        pageButton = button(removing ? "Save remaining pages" : "Extract pages", action: #selector(submitPages)); pageButton.keyEquivalent = "\r"; pageButton.isEnabled = false
        stack.addArrangedSubview(NSStackView(views: [button("Cancel", action: #selector(cancel)), pageButton]))
        mount(stack, in: win.contentView!, inset: 22)
        win.makeKeyAndOrderFront(nil); win.makeFirstResponder(pageField); NSApp.activate(ignoringOtherApps: true)
        updatePages()
    }

    func controlTextDidChange(_ obj: Notification) { updatePages() }
    func updatePages() {
        do {
            let selected = try PageRanges.parse(pageField.stringValue, pageCount: pageCount)
            let removing = pending?.action == "pdf.remove", count = removing ? pageCount - selected.count : selected.count
            guard count > 0 else { throw RMError("Keep at least one page in the PDF.") }
            pageStatus.stringValue = "The new PDF will contain \(count) \(count == 1 ? "page" : "pages")."; pageButton.isEnabled = true
            if let first = selected.first, let page = preview.document?.page(at: first) { preview.go(to: page) }
        } catch { pageStatus.stringValue = error.localizedDescription; pageButton.isEnabled = false }
    }
    @objc func submitPages() {
        guard var request = pending else { return }; request.pages = pageField.stringValue
        do { let manifest = try ConversionManifest.load(at: RMPaths.manifestURL); window?.orderOut(nil); run(request, manifest: manifest) }
        catch { showError(error.localizedDescription) }
    }
    @objc func cancel() { NSApp.terminate(nil) }
    func windowWillClose(_ notification: Notification) { if worker { NSApp.terminate(nil) } }

    func run(_ request: JobRequest, manifest: ConversionManifest) {
        DispatchQueue.global(qos: .userInitiated).async {
            let report = ConversionEngine(manifest: manifest).run(request)
            DispatchQueue.main.async {
                let content = UNMutableNotificationContent(); content.title = "rmconvert"; content.body = report.summary
                content.userInfo = ["job": report.id]
                let notification = UNNotificationRequest(identifier: report.id, content: content, trigger: nil)
                UNUserNotificationCenter.current().getNotificationSettings { settings in
                    if settings.authorizationStatus == .authorized {
                        UNUserNotificationCenter.current().add(notification) { _ in DispatchQueue.main.async { NSApp.terminate(nil) } }
                    } else { DispatchQueue.main.async {
                        if report.failures > 0 { self.showError(report.results.filter { $0.status == "failed" }.map { URL(fileURLWithPath: $0.input).lastPathComponent + ": " + $0.detail }.joined(separator: "\n")) }
                        else { NSApp.terminate(nil) }
                    } }
                }
            }
        }
    }

    func showError(_ message: String) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = "rmconvert could not complete this action"; alert.informativeText = message
        alert.addButton(withTitle: "OK"); alert.runModal()
        if worker { NSApp.terminate(nil) }
    }

    @objc func showLog() {
        let win = makeWindow("rmconvert · Recent jobs", size: NSSize(width: 780, height: 500)); logWindow = win
        let scroll = NSScrollView(frame: win.contentView!.bounds); scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds); text.isEditable = false; text.isSelectable = true; text.autoresizingMask = [.width]; text.textContainerInset = NSSize(width: 20, height: 20)
        let listing = (try? FileManager.default.contentsOfDirectory(at: JobLog.directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let reports = listing.compactMap { url -> JobReport? in guard let data = try? Data(contentsOf: url) else { return nil }; return try? decoder.decode(JobReport.self, from: data) }.sorted { $0.started > $1.started }.prefix(100)
        let content = NSMutableAttributedString()
        for report in reports {
            content.append(NSAttributedString(string: "\(report.started.formatted())  ·  \(report.action)\n\(report.summary)\n", attributes: [.font:NSFont.systemFont(ofSize: 14, weight: .semibold)]))
            for result in report.results {
                content.append(NSAttributedString(string: "\(URL(fileURLWithPath: result.input).lastPathComponent): \(result.status) \(result.detail)\n", attributes: [.font:NSFont.systemFont(ofSize: 13)]))
                for path in result.outputs { content.append(NSAttributedString(string: path + "\n", attributes: [.link:URL(fileURLWithPath: path), .font:NSFont.systemFont(ofSize: 13)])) }
            }
            content.append(NSAttributedString(string: "\n"))
        }
        if reports.isEmpty { content.append(NSAttributedString(string: "No conversions yet.")) }
        text.textStorage?.setAttributedString(content); scroll.documentView = text; win.contentView!.addSubview(scroll); win.makeKeyAndOrderFront(nil)
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { self.worker = false; NSApp.setActivationPolicy(.regular); self.showLog(); NSApp.activate(ignoringOtherApps: true); completionHandler() }
    }
}
