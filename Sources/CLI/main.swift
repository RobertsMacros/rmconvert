import Foundation
import AppKit
import Darwin

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    if args == ["--close-setup"] {
        DistributedNotificationCenter.default().postNotificationName(RMPaths.closeSetupNotification, object: nil, userInfo: nil, deliverImmediately: true)
        RunLoop.current.run(until:Date().addingTimeInterval(0.2))
        exit(0)
    }
    if args == ["--can-install"] {
        for _ in 0..<10 {
            if !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == RMPaths.bundleID && $0.executableURL?.lastPathComponent == "RMConvertApp" }) { exit(0) }
            RunLoop.current.run(until:Date().addingTimeInterval(0.1))
        }
        throw RMError("Finish active conversions and close PDF page windows before updating rmconvert.")
    }
    if args.contains("--help") || args.isEmpty {
        print("""
        rmconvert: local file conversion and PDF tools
        --doctor                         Check installed converters
        --validate                       Validate the active manifest
        --list                           List actions
        --targets-for -- FILE...          Show menus for a selection
        --action ID [--pages 1-3,5] -- FILE...
        --to FORMAT -- FILE...            Convert files
        Outputs are new files beside the originals. Existing files are never replaced.
        """); exit(0)
    }
    if args == ["--doctor"] { try printJSON(BackendRegistry.resolved()); exit(0) }
    let manifest = try ConversionManifest.load(at: RMPaths.manifestURL)
    if args == ["--validate"] { print("Manifest is valid: \(manifest.actions.count) actions, \(manifest.routes.count) routes."); exit(0) }
    if args == ["--list"] { try printJSON(manifest.actions); exit(0) }
    guard let separator = args.firstIndex(of: "--"), separator + 1 < args.count else { throw RMError("Put -- before the source filenames.") }
    let paths = Array(args[(separator + 1)...]).map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    let options = Array(args[..<separator])
    if options == ["--targets-for"] { try printJSON(manifest.menus(for: paths.map { URL(fileURLWithPath: $0) }, available: BackendRegistry.available())); exit(0) }
    var action: String?, pages: String?, index = 0
    while index < options.count {
        guard index + 1 < options.count else { throw RMError("Missing value for \(options[index]).") }
        switch options[index] {
        case "--action": action = options[index + 1]
        case "--to": action = "convert." + ConversionManifest.extensionOf(URL(fileURLWithPath: "file." + options[index + 1]))
        case "--pages": pages = options[index + 1]
        default: throw RMError("Unknown option: \(options[index]).")
        }
        index += 2
    }
    guard let action else { throw RMError("Choose --action or --to.") }
    let report = ConversionEngine(manifest: manifest).run(JobRequest(action: action, paths: paths, pages: pages))
    try printJSON(report)
    fputs(report.summary + "\n", stderr)
    exit(report.failures > 0 ? 1 : 0)
} catch { fputs("rmconvert: \(error.localizedDescription)\n", stderr); exit(2) }
