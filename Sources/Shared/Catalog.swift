import Foundation

struct ConversionAction: Codable {
    var id: String
    var label: String
    var menu: String
    var group: Int
    var order: Int
    var outputFormat: String?
    var minimumCount: Int = 1
    var maximumCount: Int?
    var sameDirectory: Bool = false
    var showCurrent: Bool = false
    var needsPages: Bool = false
}

struct ConversionRoute: Codable {
    var action: String
    var from: [String]
    var handler: String
    var backend: String
    var priority: Int = 10
    var label: String?
    var group: Int?
    var options: [String: String] = [:]
    var requires: [String]?
}

struct ConversionManifest: Codable {
    var schemaVersion: Int
    var actions: [ConversionAction]
    var routes: [ConversionRoute]

    static func load(at url: URL) throws -> ConversionManifest {
        let result = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try result.validate()
        return result
    }

    func validate() throws {
        guard schemaVersion == 3 else { throw RMError("Unsupported manifest schema version.") }
        guard Set(actions.map(\.id)).count == actions.count else { throw RMError("Action IDs must be unique.") }
        let names = Set(actions.map(\.id))
        let handlers = Set(["image","image.pdf","image.extra","pdf","pdf.raster","pdf.text","pdf.compress","office","office.raster","rtfd.pdf","pandoc.pdf","textutil","pandoc","data","plist","media"])
        let backends = Set(["native","textutil","plutil","iconutil","ffmpeg","ffprobe","pandoc","magick","soffice","qpdf","pdftoppm","pdftotext","yq"])
        let formats = Set(["jpg","png","tiff","heic","webp","avif","icns","ico","pdf","txt","md","html","rtf","rtfd","doc","docx","odt","epub","csv","tsv","json","yaml","xml","toml","xlsx","plist","mp4","mov","mkv","webm","gif","mp3","m4a","wav","aiff","flac","m4r","srt","vtt"])
        for action in actions {
            guard ["Convert", "PDF"].contains(action.menu), action.minimumCount > 0, action.maximumCount.map({ $0 >= action.minimumCount }) ?? true,
                  action.outputFormat.map(formats.contains) ?? true else {
                throw RMError("Invalid menu or selection count for \(action.id).")
            }
        }
        var pairs = Set<String>()
        for route in routes {
            guard names.contains(route.action), !route.from.isEmpty, handlers.contains(route.handler), backends.contains(route.backend), (route.requires ?? []).allSatisfy(backends.contains), actions.first(where: { $0.id == route.action })?.outputFormat != nil else { throw RMError("Invalid route for \(route.action).") }
            guard route.from.allSatisfy({ $0.range(of: "^[a-z0-9]+$", options: .regularExpression) != nil }) else { throw RMError("Source extensions must be normalised lowercase names.") }
            guard !route.from.contains("pdf") || route.action != "convert.docx" else { throw RMError("PDF to DOCX is excluded.") }
            for ext in route.from {
                let key = "\(route.action)|\(ext)|\(route.priority)"
                guard pairs.insert(key).inserted else { throw RMError("Competing routes at the same priority: \(key).") }
            }
        }
    }

    func route(_ action: String, source: URL, available: Set<String>) -> ConversionRoute? {
        let ext = Self.extensionOf(source)
        return routes.filter { $0.action == action && $0.from.contains(ext) && available.contains($0.backend) && ($0.requires ?? []).allSatisfy(available.contains) }.min { $0.priority < $1.priority }
    }

    static func extensionOf(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ["jpeg":"jpg", "tif":"tiff", "aif":"aiff", "heif":"heic", "yml":"yaml", "htm":"html", "markdown":"md" ][ext] ?? ext
    }

    func menus(for urls: [URL], available: Set<String>) -> [MenuModel] {
        guard !urls.isEmpty else { return [] }
        // Eligibility depends on source types; avoid resolving the same route for every file.
        var representatives: [String:URL] = [:]
        for url in urls { representatives[Self.extensionOf(url)] = url }
        let types = representatives.keys.sorted(), sources = types.compactMap { representatives[$0] }
        let sameDirectory = Set(urls.map { $0.deletingLastPathComponent().standardizedFileURL.path }).count == 1
        var result: [MenuModel] = []
        for menuName in ["Convert", "PDF"] {
            var items: [MenuItemModel] = []
            for action in actions where action.menu == menuName {
                guard urls.count >= action.minimumCount, action.maximumCount.map({ urls.count <= $0 }) ?? true else { continue }
                if action.sameDirectory && !sameDirectory { continue }
                let actual = sources.map { route(action.id, source: $0, available: available) }
                let ordinary = action.id.hasPrefix("convert.")
                let current = types.map { ordinary && $0 == action.outputFormat }
                let allCurrent = current.allSatisfy { $0 }
                if allCurrent && !action.showCurrent { continue }
                guard zip(actual, current).allSatisfy({ $0.0 != nil || $0.1 }), actual.contains(where: { $0 != nil }) else { continue }
                let concrete = actual.compactMap { $0 }
                let labels = Set(concrete.map { $0.label ?? action.label })
                let groups = Set(concrete.map { $0.group ?? action.group })
                items.append(MenuItemModel(actionId: action.id, label: labels.count == 1 ? labels.first! : action.label,
                                           enabled: !allCurrent, group: groups.count == 1 ? groups.first! : action.group,
                                           order: action.order, needsPages: action.needsPages))
            }
            if !items.isEmpty { result.append(MenuModel(label: menuName, items: items.sorted { ($0.group, $0.order, $0.label) < ($1.group, $1.order, $1.label) })) }
        }
        if result.isEmpty {
            let anyConfigured = actions.contains { action in sources.allSatisfy { source in routes.contains { $0.action == action.id && $0.from.contains(Self.extensionOf(source)) } } }
            result = [MenuModel(label: "Convert", items: [MenuItemModel(actionId: "", label: anyConfigured ? "Required converters are not installed" : "No shared format for this selection", enabled: false, group: 0, order: 0, needsPages: false)])]
        }
        return result
    }
}

struct MenuItemModel: Codable {
    var actionId: String
    var label: String
    var enabled: Bool
    var group: Int
    var order: Int
    var needsPages: Bool
}
struct MenuModel: Codable { var label: String; var items: [MenuItemModel] }
struct JobRequest: Codable { var action: String; var paths: [String]; var pages: String? }
struct CatalogueSnapshot: Codable { var manifest: ConversionManifest; var available: [String] }
struct RMError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum RMPaths {
    static let bundleID = "com.robertsmacros.rmconvert"
    static let extensionID = "com.robertsmacros.rmconvert.Finder"
    static let capabilityNotification = Notification.Name("com.robertsmacros.rmconvert.capabilities")
    static let closeSetupNotification = Notification.Name("com.robertsmacros.rmconvert.closeSetup")
    static var requestDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/rmconvert/Requests", isDirectory: true)
    }
    static var resourceDirectory: URL {
        if let url = Bundle.main.resourceURL, FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) { return url }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        return executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
    }
    static var manifestURL: URL {
        let custom = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/rmconvert/manifest.json")
        return FileManager.default.fileExists(atPath: custom.path) ? custom : resourceDirectory.appendingPathComponent("manifest.json")
    }
}
