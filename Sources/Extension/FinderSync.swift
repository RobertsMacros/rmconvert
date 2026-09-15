import Cocoa
import FinderSync
import OSLog

@objc(RMFinderSync)
final class RMFinderSync: FIFinderSync {
    private var manifest: ConversionManifest?
    private var available = Set<String>()
    private let logger = Logger(subsystem: RMPaths.extensionID, category: "Finder")
    private var requests: [Int:JobRequest] = [:]
    private var nextTag = 1
    private var brandIcon: NSImage?

    override init() {
        super.init()
        if let resources = Bundle(for: RMFinderSync.self).resourceURL {
            brandIcon = Brand.menuIcon(resources: resources)
            manifest = try? ConversionManifest.load(at: resources.appendingPathComponent("manifest.json"))
            if let data = try? Data(contentsOf: resources.appendingPathComponent("availability.json")), let names = try? JSONDecoder().decode([String].self, from: data) { available = Set(names) }
            if let bundled = try? Data(contentsOf:resources.appendingPathComponent("manifest.json")), UserDefaults.standard.data(forKey:"catalogueBuild") == bundled,
               let data = UserDefaults.standard.data(forKey:"catalogueSnapshot"), let snapshot = try? JSONDecoder().decode(CatalogueSnapshot.self,from:data), (try? snapshot.manifest.validate()) != nil {
                manifest = snapshot.manifest; available = Set(snapshot.available)
            }
        }
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(refresh(_:)), name: RMPaths.capabilityNotification, object: nil)
        logger.notice("Finder extension started with \(self.available.count) capabilities")
    }

    @objc private func refresh(_ notification: Notification) {
        guard let encoded = notification.userInfo?["snapshot"] as? String, encoded.utf8.count < 1_000_000,
              let data = Data(base64Encoded: encoded), let snapshot = try? JSONDecoder().decode(CatalogueSnapshot.self, from: data),
              (try? snapshot.manifest.validate()) != nil else { return }
        DispatchQueue.main.async {
            self.manifest = snapshot.manifest; self.available = Set(snapshot.available)
            UserDefaults.standard.set(data,forKey:"catalogueSnapshot")
            if let resources = Bundle(for:RMFinderSync.self).resourceURL, let bundled = try? Data(contentsOf:resources.appendingPathComponent("manifest.json")) { UserDefaults.standard.set(bundled,forKey:"catalogueBuild") }
        }
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems,
              let urls = FIFinderSyncController.default().selectedItemURLs(), !urls.isEmpty else { return nil }
        let root = NSMenu(); root.autoenablesItems = false
        if requests.count > 2000 { requests = requests.filter { $0.key > nextTag - 1000 } }
        guard let manifest else {
            let item = NSMenuItem(title: "Converter is starting", action: nil, keyEquivalent: ""); item.isEnabled = false; root.addItem(item); return root
        }
        for model in manifest.menus(for: urls, available: available) {
            let parent = NSMenuItem(title: model.label, action: nil, keyEquivalent: "")
            parent.image = brandIcon
            let submenu = NSMenu(title: model.label); submenu.autoenablesItems = false
            var group: Int?
            for entry in model.items {
                if let previous = group, previous != entry.group { submenu.addItem(.separator()) }; group = entry.group
                let item = NSMenuItem(title: entry.label, action: #selector(submit(_:)), keyEquivalent: "")
                item.target = self; item.isEnabled = entry.enabled
                // Finder proxies menu items across a process boundary, including their integer tags.
                item.tag = nextTag; nextTag += 1
                requests[item.tag] = JobRequest(action: entry.actionId, paths: urls.map(\.path), pages: nil)
                submenu.addItem(item)
            }
            parent.submenu = submenu; root.addItem(parent)
        }
        return root
    }

    @objc private func submit(_ sender: NSMenuItem) {
        logger.notice("Action selected with tag \(sender.tag)")
        guard let request = requests[sender.tag], let data = try? JSONEncoder().encode(request) else { logger.error("Missing captured selection"); return }
        let appURL = Bundle(for: RMFinderSync.self).bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = RMPaths.requestDirectory.appendingPathComponent(UUID().uuidString + ".rmconvert-request")
        do {
            try FileManager.default.createDirectory(at: RMPaths.requestDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath: file.path)
        } catch { logger.error("Could not prepare request: \(error.localizedDescription, privacy: .public)"); return }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.addsToRecentItems = false
        config.activates = false
        NSWorkspace.shared.open([file], withApplicationAt: appURL, configuration: config) { _, error in
            if let error { self.logger.error("Job launch failed: \(error.localizedDescription, privacy: .public)"); try? FileManager.default.removeItem(at: file) }
            else { self.logger.notice("Worker launched") }
        }
    }
}
