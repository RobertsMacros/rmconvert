import Cocoa
import OSLog

/// Native Services also work in Finder views that omit Finder Sync extensions.
/// This provider only chooses an action and starts an isolated background worker.
final class ConversionServices: NSObject {
    weak var delegate: AppDelegate?
    private var requests: [Int: JobRequest] = [:]
    private var chosen: JobRequest?
    private let logger = Logger(subsystem: RMPaths.bundleID, category: "Services")

    init(delegate: AppDelegate) { self.delegate = delegate }

    @objc func chooseConversion(_ pasteboard: NSPasteboard, userData: String,
                                error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard ["Convert", "PDF"].contains(userData), let delegate, !delegate.serviceSelecting else { return }
        var urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if urls.isEmpty, let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            urls = paths.map { URL(fileURLWithPath: $0) }
        }
        guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { error.pointee = "Choose files in Finder first."; return }
        logger.notice("Service received: \(userData, privacy: .public), files=\(urls.count)")
        delegate.serviceSelecting = true
        let inputs = urls
        // Reply to Services immediately; menu tracking and conversion must not block Finder.
        DispatchQueue.main.async { self.choose(menuName: userData, urls: inputs) }
    }

    private func choose(menuName: String, urls: [URL]) {
        let scopes = urls.filter { $0.startAccessingSecurityScopedResource() }
        do {
            let manifest = try ConversionManifest.load(at: RMPaths.manifestURL)
            let model = manifest.menus(for: urls, available: BackendRegistry.available()).first { $0.label == menuName }
            let menu = NSMenu(title: menuName); menu.autoenablesItems = false
            requests.removeAll(); chosen = nil
            var group: Int?
            for (index, entry) in (model?.items ?? []).enumerated() {
                if let previous = group, previous != entry.group { menu.addItem(.separator()) }
                group = entry.group
                let item = NSMenuItem(title: entry.label, action: #selector(selectAction(_:)), keyEquivalent: "")
                item.target = self; item.tag = index; item.isEnabled = entry.enabled
                requests[index] = JobRequest(action: entry.actionId, paths: urls.map(\.path), pages: nil)
                menu.addItem(item)
            }
            if menu.items.isEmpty {
                let item = NSMenuItem(title: "No actions for this selection", action: nil, keyEquivalent: "")
                item.isEnabled = false; menu.addItem(item)
            }
            let location = NSEvent.mouseLocation
            let previous = NSWorkspace.shared.frontmostApplication
            // Wait until activation completes before tracking the pop-up. Otherwise
            // the activation event itself can dismiss the newly opened menu.
            presentWhenActive {
                self.logger.notice("Service menu opened: \(menuName, privacy: .public)")
                menu.popUp(positioning: nil, at: location, in: nil)
                self.logger.notice("Service menu closed: selected=\(self.chosen != nil)")
                previous?.activate(options: [])
                do {
                    if let request = self.chosen { try self.dispatch(request, urls: urls, scopes: scopes) }
                    else { self.finish(scopes: scopes) }
                } catch {
                    self.logger.error("Service dispatch failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
                    self.finish(scopes: scopes)
                }
            }
        } catch {
            logger.error("Service dispatch failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
            finish(scopes: scopes)
        }
    }

    private func presentWhenActive(_ present: @escaping () -> Void) {
        if NSApp.isActive { DispatchQueue.main.async(execute: present); return }
        var observer: NSObjectProtocol?
        var presented = false
        let once = {
            guard !presented else { return }; presented = true
            if let observer { NotificationCenter.default.removeObserver(observer) }
            DispatchQueue.main.async(execute: present)
        }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: NSApp, queue: .main) { _ in once() }
        NSApp.activate(ignoringOtherApps: true)
        // A denied activation must not strand the invisible service process.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { once() }
    }

    @objc private func selectAction(_ sender: NSMenuItem) { chosen = requests[sender.tag] }

    private func dispatch(_ request: JobRequest, urls: [URL], scopes: [URL]) throws {
        let folder = RMPaths.requestDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent(UUID().uuidString + ".rmconvert-request")
        try JSONEncoder().encode(request).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false; configuration.addsToRecentItems = false
        NSWorkspace.shared.open([file] + urls, withApplicationAt: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error {
                self.logger.error("Service worker launch failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
                try? FileManager.default.removeItem(at: file)
            } else { self.logger.notice("Service worker launched") }
            DispatchQueue.main.async { self.finish(scopes: scopes) }
        }
    }

    private func finish(scopes: [URL]) {
        delegate?.serviceSelecting = false
        scopes.forEach { $0.stopAccessingSecurityScopedResource() }
        // Do not close an existing setup, page picker or independently running job.
        if let delegate, !delegate.worker, !delegate.serviceSelecting, delegate.window == nil, delegate.logWindow == nil {
            NSApp.terminate(nil)
        }
    }
}
