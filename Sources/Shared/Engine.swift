import Foundation
import PDFKit
import ImageIO
import CoreImage
import UniformTypeIdentifiers
import Darwin

struct FileResult: Codable {
    var input: String
    var outputs: [String]
    var status: String
    var detail: String
}
struct JobReport: Codable {
    var id = UUID().uuidString
    var action: String
    var started = Date()
    var results: [FileResult]
    var failures: Int { results.filter { $0.status == "failed" }.count }
    var outputs: [String] { results.flatMap(\.outputs) }
    var summary: String {
        if action.hasPrefix("pdf.combine") && failures == 0 { return "Combined \(results.count) files into one PDF." }
        let done = results.filter { $0.status == "converted" }.count
        let skipped = results.filter { $0.status == "skipped" }.count
        return "Converted \(done) of \(results.count)." + (failures > 0 ? " \(failures) failed." : "") + (skipped > 0 ? " \(skipped) unchanged." : "")
    }
}

enum BackendRegistry {
    static let candidates: [String: [String]] = [
        "ffmpeg":["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"],
        "ffprobe":["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"],
        "pandoc":["/opt/homebrew/bin/pandoc", "/usr/local/bin/pandoc"],
        "magick":["/opt/homebrew/bin/magick", "/usr/local/bin/magick"],
        "qpdf":["/opt/homebrew/bin/qpdf", "/usr/local/bin/qpdf"],
        "pdftoppm":["/opt/homebrew/bin/pdftoppm", "/usr/local/bin/pdftoppm"],
        "pdftotext":["/opt/homebrew/bin/pdftotext", "/usr/local/bin/pdftotext"],
        "yq":["/opt/homebrew/bin/yq", "/usr/local/bin/yq"],
        "soffice":["/Applications/LibreOffice.app/Contents/MacOS/soffice", "/opt/homebrew/bin/soffice", "/usr/local/bin/soffice"]
    ]
    static func resolved() -> [String: String] {
        candidates.compactMapValues { $0.first { FileManager.default.isExecutableFile(atPath: $0) } }
    }
    static func available() -> Set<String> { Set(resolved().keys).union(["native", "textutil", "plutil", "iconutil"]) }
}

enum AtomicOutput {
    static func stage(beside input: URL) throws -> URL {
        let directory = input.deletingLastPathComponent().appendingPathComponent(".rmconvert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }
    static func publish(_ temporary: URL, as base: URL, directory: Bool = false) throws -> URL {
        for index in 0..<10000 {
            let target: URL
            if index == 0 { target = base }
            else if directory || base.pathExtension.isEmpty { target = base.deletingLastPathComponent().appendingPathComponent("\(base.lastPathComponent)-\(index)") }
            else { target = base.deletingLastPathComponent().appendingPathComponent("\(base.deletingPathExtension().lastPathComponent)-\(index).\(base.pathExtension)") }
            if renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
            if errno == EEXIST { continue }
            throw RMError("Could not safely save \(target.lastPathComponent): \(String(cString: strerror(errno))).")
        }
        throw RMError("Too many files with the same name in the destination.")
    }
    static func checkInput(_ url: URL) throws -> URL {
        let real = url.standardizedFileURL.resolvingSymlinksInPath()
        var logical = real.path
        let prefix = "/System/Volumes/Data"
        if logical.hasPrefix(prefix + "/") {
            let proposed = String(logical.dropFirst(prefix.count))
            var a = stat(), b = stat()
            if stat(real.path, &a) == 0, stat(proposed, &b) == 0, a.st_dev == b.st_dev, a.st_ino == b.st_ino { logical = proposed }
        }
        if logical == "/System" || logical.hasPrefix("/System/") || logical == "/Library" || logical.hasPrefix("/Library/") || URL(fileURLWithPath: logical).pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }) {
            throw RMError("Files inside system folders or app bundles are excluded.")
        }
        let values = try real.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard values.isRegularFile == true || (values.isDirectory == true && real.pathExtension.lowercased() == "rtfd") else { throw RMError("Choose files rather than folders.") }
        if values.isUbiquitousItem == true, let status = values.ubiquitousItemDownloadingStatus, status == .notDownloaded { throw RMError("Download this file locally before converting it.") }
        guard FileManager.default.isReadableFile(atPath: real.path) else { throw RMError("The source file is not readable.") }
        return real
    }
}

final class ConversionEngine {
    let manifest: ConversionManifest
    let backends: [String: String]
    private var conversionNote = ""
    var available: Set<String> { Set(backends.keys).union(["native", "textutil", "plutil", "iconutil"]) }
    init(manifest: ConversionManifest, backends: [String: String] = BackendRegistry.resolved()) { self.manifest = manifest; self.backends = backends }

    func run(_ request: JobRequest) -> JobReport {
        var report = JobReport(action: request.action, results: [])
        defer { JobLog.append(report) }
        guard let action = manifest.actions.first(where: { $0.id == request.action }), !request.paths.isEmpty else {
            report.results = [FileResult(input: "", outputs: [], status: "failed", detail: "Unknown action or empty selection.")]; return report
        }
        let inputURLs = request.paths.map { URL(fileURLWithPath: $0) }
        guard inputURLs.count >= action.minimumCount, action.maximumCount.map({ inputURLs.count <= $0 }) ?? true else {
            report.results = inputURLs.map { FileResult(input: $0.path, outputs: [], status: "failed", detail: "This action does not support this number of files.") }; return report
        }
        let jobLock: ProcessLock
        do { jobLock = try ProcessLock(name: "jobs", slots: 4, timeout: 600) }
        catch { report.results = inputURLs.map { FileResult(input: $0.path, outputs: [], status: "failed", detail: error.localizedDescription) }; return report }
        defer { withExtendedLifetime(jobLock) {} }
        if request.action.hasPrefix("pdf.combine") {
            do {
                let sources = try inputURLs.map { try AtomicOutput.checkInput($0) }.sorted {
                    let comparison = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    return comparison == .orderedSame ? $0.lastPathComponent < $1.lastPathComponent : comparison == .orderedAscending
                }
                guard Set(sources.map { $0.deletingLastPathComponent() }).count == 1 else { throw RMError("Combine files from the same folder.") }
                guard sources.allSatisfy({ manifest.route(action.id, source: $0, available: available) != nil }) else { throw RMError("This selection cannot be combined using this action.") }
                let output = try combine(sources, images: request.action == "pdf.combine-images")
                report.results = sources.enumerated().map { FileResult(input: $0.element.path, outputs: $0.offset == 0 ? [output.path] : [], status: "converted", detail: "Included in \(output.lastPathComponent)") }
            } catch { report.results = inputURLs.map { FileResult(input: $0.path, outputs: [], status: "failed", detail: error.localizedDescription) } }
        } else if action.outputFormat != "csv", inputURLs.allSatisfy({
            let ext = ConversionManifest.extensionOf($0)
            return !["csv","tsv"].contains(ext) && ext != action.outputFormat && manifest.route(action.id,source:$0,available:available)?.handler == "office"
        }) {
            report.results = officeBatches(inputURLs, action:action)
        } else {
            for original in inputURLs {
                do {
                    let input = try AtomicOutput.checkInput(original)
                    if request.action.hasPrefix("convert."), ConversionManifest.extensionOf(input) == action.outputFormat {
                        report.results.append(FileResult(input: input.path, outputs: [], status: "skipped", detail: "Already this format.")); continue
                    }
                    guard let route = manifest.route(request.action, source: input, available: available) else { throw RMError("No available converter for this file and action. Open rmconvert and check converters.") }
                    conversionNote = route.options["note"] ?? ""
                    if ConversionManifest.extensionOf(input) == "psd" { conversionNote += " PSD layers are flattened to the composite image." }
                    if route.handler == "image" || route.handler.hasPrefix("image.") { conversionNote += " Orientation is applied; ancillary metadata is not copied." }
                    if route.handler == "pdf" { conversionNote += " New page document; document outlines and signatures are not preserved." }
                    let outputs = try convert(input, action: action, route: route, pages: request.pages)
                    report.results.append(FileResult(input: input.path, outputs: outputs.map(\.path), status: outputs.isEmpty ? "skipped" : "converted", detail: outputs.isEmpty ? "No change was needed." : conversionNote.trimmingCharacters(in:.whitespaces)))
                } catch { report.results.append(FileResult(input: original.path, outputs: [], status: "failed", detail: error.localizedDescription)) }
            }
        }
        return report
    }

    private func officeBatches(_ inputs: [URL], action: ConversionAction) -> [FileResult] {
        var results: [FileResult] = [], groups: [String:[URL]] = [:]
        for original in inputs {
            do {
                let source = try AtomicOutput.checkInput(original), ext = ConversionManifest.extensionOf(source)
                let family = ["xlsx","xls","ods"].contains(ext) ? "calc" : ["pptx","ppt","odp"].contains(ext) ? "impress" : "writer"
                let key = source.deletingLastPathComponent().path + "\0" + family
                groups[key,default:[]].append(source)
            } catch { results.append(FileResult(input:original.path,outputs:[],status:"failed",detail:error.localizedDescription)) }
        }
        for key in groups.keys.sorted() {
            var batches: [[URL]] = [], batch: [URL] = [], stems = Set<String>()
            for source in groups[key]! {
                let stem = source.deletingPathExtension().lastPathComponent.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"en_US_POSIX"))
                if batch.count == 20 || stems.contains(stem) { batches.append(batch); batch = []; stems = [] }
                batch.append(source); stems.insert(stem)
            }
            if !batch.isEmpty { batches.append(batch) }
            for batch in batches {
                do {
                    let stage = try AtomicOutput.stage(beside:batch[0]); defer { try? FileManager.default.removeItem(at:stage) }
                    let outcome = try DocumentConversion.officeBatch(batch,format:action.outputFormat!,stage:stage,backends:backends)
                    for source in batch {
                        do {
                            guard let output = outcome.outputs[source] else { throw RMError(outcome.errors[source] ?? "No output was produced.") }
                            let published = try AtomicOutput.publish(output,as:source.deletingPathExtension().appendingPathExtension(action.outputFormat!))
                            results.append(FileResult(input:source.path,outputs:[published.path],status:"converted",detail:"Rendered by LibreOffice in a batch of \(batch.count). Layout and font substitutions depend on the source document and installed fonts."))
                        } catch { results.append(FileResult(input:source.path,outputs:[],status:"failed",detail:error.localizedDescription)) }
                    }
                } catch { results += batch.map { FileResult(input:$0.path,outputs:[],status:"failed",detail:error.localizedDescription) } }
            }
        }
        return results
    }

    func convert(_ input: URL, action: ConversionAction, route: ConversionRoute, pages: String?) throws -> [URL] {
        let stage = try AtomicOutput.stage(beside: input)
        defer { try? FileManager.default.removeItem(at: stage) }
        let format = action.outputFormat ?? "pdf"
        let temporary = stage.appendingPathComponent("output.\(format)")
        var base = input.deletingPathExtension().appendingPathExtension(format)
        switch route.handler {
        case "office.raster":
            let pdf = try DocumentConversion.office(input,format:"pdf",stage:stage,backends:backends)
            var rasterRoute = route; rasterRoute.handler = "pdf.raster"; rasterRoute.backend = "pdftoppm"
            let rendered = try convert(pdf,action:action,route:rasterRoute,pages:nil)
            guard let directory = rendered.first else { throw RMError("No slide images were produced.") }
            base = input.deletingLastPathComponent().appendingPathComponent(input.deletingPathExtension().lastPathComponent + "-png")
            return [try AtomicOutput.publish(directory,as:base,directory:true)]
        case "image.extra": try ExtraImages.convert(input,to:temporary,format:format,stage:stage,backends:backends)
        case "media":
            let (result,directory,note) = try MediaConversion.convert(input, target: format, stage: stage, output: temporary, backends: backends)
            conversionNote = note
            if directory {
                base = input.deletingLastPathComponent().appendingPathComponent(input.deletingPathExtension().lastPathComponent + "-" + format)
                return [try AtomicOutput.publish(result, as: base, directory: true)]
            }
        case "image": try ImageConversion.write(input, to: temporary, format: format)
        case "image.pdf": try ImageConversion.pdf([input], to: temporary)
        case "office":
            let result = try DocumentConversion.office(input, format: format, stage: stage, backends: backends)
            if format == "csv" {
                base = input.deletingLastPathComponent().appendingPathComponent(input.deletingPathExtension().lastPathComponent + "-csv")
                return [try AtomicOutput.publish(result, as: base, directory: true)]
            }
            try FileManager.default.moveItem(at: result, to: temporary)
        case "textutil":
            if ConversionManifest.extensionOf(input) == "html" { try DocumentConversion.checkLocalResources(input) }
            var destination = temporary
            let directory = stage.appendingPathComponent("document",isDirectory:true)
            if format == "html" {
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
                destination = directory.appendingPathComponent(input.deletingPathExtension().lastPathComponent + ".html")
            }
            try ProcessRunner.run("/usr/bin/textutil", ["-convert",format,"-output",destination.path,"-timeout","10","--",input.path], in: stage)
            try DocumentConversion.validate(destination, format: format)
            if format == "html" {
                base = input.deletingLastPathComponent().appendingPathComponent(input.deletingPathExtension().lastPathComponent + "-html")
                return [try AtomicOutput.publish(directory,as:base,directory:true)]
            }
            if format == "rtfd" { return [try AtomicOutput.publish(temporary, as: base, directory: true)] }
        case "pandoc", "pandoc.pdf", "rtfd.pdf":
            let directory = stage.appendingPathComponent("document", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let assets = directory.appendingPathComponent("assets", isDirectory: true)
            if route.handler == "rtfd.pdf" {
                let docx = stage.appendingPathComponent("document.docx")
                try ProcessRunner.run("/usr/bin/textutil", ["-convert","docx","-output",docx.path,"--",input.path], in: stage)
                let result = try DocumentConversion.office(docx, format: "pdf", stage: stage, backends: backends)
                try FileManager.default.moveItem(at: result, to: temporary)
            } else if route.handler == "pandoc.pdf" {
                let odt = directory.appendingPathComponent("document.odt")
                try DocumentConversion.pandoc(input, format: "odt", output: odt, assets: assets, stage: stage, backends: backends)
                let result = try DocumentConversion.office(odt, format: "pdf", stage: stage, backends: backends)
                try FileManager.default.moveItem(at: result, to: temporary)
            } else {
                let output = directory.appendingPathComponent(input.deletingPathExtension().lastPathComponent + "." + format)
                try DocumentConversion.pandoc(input, format: format, output: output, assets: assets, stage: stage, backends: backends)
                if format == "md" || format == "html" {
                    var contents = try String(contentsOf: output, encoding: .utf8)
                    contents = contents.replacingOccurrences(of: assets.path, with: "assets").replacingOccurrences(of: assets.absoluteString, with: "assets")
                    try contents.write(to: output, atomically: true, encoding: .utf8)
                    base = input.deletingLastPathComponent().appendingPathComponent(input.deletingPathExtension().lastPathComponent + "-" + (format == "md" ? "markdown" : "html"))
                    return [try AtomicOutput.publish(directory, as: base, directory: true)]
                }
                try FileManager.default.moveItem(at: output, to: temporary)
            }
        case "data": try DataConversion.convert(input, to: temporary, format: format, stage: stage, backends: backends)
        case "plist":
            var original = PropertyListSerialization.PropertyListFormat.xml
            let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: input), options: [], format: &original)
            let encoding: PropertyListSerialization.PropertyListFormat = action.id == "plist.binary" ? .binary : .xml
            if original == encoding { return [] }
            try PropertyListSerialization.data(fromPropertyList: value, format: encoding, options: 0).write(to: temporary)
        case "pdf.raster":
            let document = try loadPDF(input)
            for index in 0..<document.pageCount {
                let bounds = document.page(at: index)!.bounds(for: .mediaBox)
                guard bounds.width * bounds.height * 300 * 300 / (72 * 72) <= 120_000_000 else { throw RMError("A PDF page exceeds the 120-megapixel rendering limit at 300 dpi.") }
            }
            let directory = stage.appendingPathComponent("pages", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let prefix = directory.appendingPathComponent("page").path
            var args = ["-r", "300", "-forcenum", format == "jpg" ? "-jpeg" : "-png"]
            if format == "jpg" { args += ["-jpegopt", "quality=95"] }
            try ProcessRunner.run(backends["pdftoppm"]!, args + [input.path, prefix], in: stage, timeout: 600)
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            guard files.count == document.pageCount else { throw RMError("The PDF renderer did not produce every page.") }
            for file in files { _ = try ImageConversion.image(file) }
            base = input.deletingLastPathComponent().appendingPathComponent(input.deletingPathExtension().lastPathComponent + "-" + format)
            return [try AtomicOutput.publish(directory, as: base, directory: true)]
        case "pdf.text":
            _ = try loadPDF(input)
            try ProcessRunner.run(backends["pdftotext"]!, ["-enc", "UTF-8", input.path, temporary.path], in: stage)
            _ = try String(contentsOf: temporary, encoding: .utf8)
        case "pdf.compress":
            let original = try loadPDF(input)
            try ProcessRunner.run(backends["qpdf"]!, ["--object-streams=generate", "--stream-data=compress", "--recompress-flate", "--compression-level=9", input.path, temporary.path], in: stage, timeout: 600)
            guard try loadPDF(temporary).pageCount == original.pageCount else { throw RMError("Compression changed the PDF page count.") }
            let before = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let after = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            if after >= before { return [] }
            base = input.deletingLastPathComponent().appendingPathComponent(input.deletingPathExtension().lastPathComponent + "-compressed.pdf")
        case "pdf":
            let document = try loadPDF(input)
            if action.id == "pdf.split" {
                let directory = stage.appendingPathComponent("pages", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                for index in 0..<document.pageCount {
                    let single = PDFDocument(); single.insert(document.page(at: index)!.copy() as! PDFPage, at: 0)
                    let pageURL = directory.appendingPathComponent(String(format: "page-%04d.pdf", index + 1))
                    try writePDF(single, to: pageURL)
                }
                base = input.deletingLastPathComponent().appendingPathComponent(input.deletingPathExtension().lastPathComponent + "-pages")
                return [try AtomicOutput.publish(directory, as: base, directory: true)]
            }
            if action.needsPages {
                guard let pages else { throw RMError("Specify pages using --pages, for example 1-3,5.") }
                let selected = try PageRanges.parse(pages, pageCount: document.pageCount)
                let indexes = action.id == "pdf.remove" ? Array(0..<document.pageCount).filter { !Set(selected).contains($0) } : selected
                guard !indexes.isEmpty else { throw RMError("Keep at least one page in the PDF.") }
                let output = PDFDocument()
                for index in indexes { output.insert(document.page(at: index)!.copy() as! PDFPage, at: output.pageCount) }
                try writePDF(output, to: temporary)
                let suffix = action.id == "pdf.remove" ? "-remaining" : "-extracted"
                base = input.deletingLastPathComponent().appendingPathComponent(input.deletingPathExtension().lastPathComponent + suffix + ".pdf")
            } else if action.id == "pdf.rotate-right" || action.id == "pdf.rotate-left" {
                let output = PDFDocument()
                for index in 0..<document.pageCount {
                    let page = document.page(at: index)!.copy() as! PDFPage
                    page.rotation = (page.rotation + (action.id == "pdf.rotate-right" ? 90 : 270)) % 360
                    output.insert(page, at: output.pageCount)
                }
                try writePDF(output, to: temporary)
            } else { throw RMError("Unsupported PDF operation.") }
        default: throw RMError("The \(route.handler) converter is not implemented yet.")
        }
        return [try AtomicOutput.publish(temporary, as: base)]
    }

    func combine(_ inputs: [URL], images: Bool) throws -> URL {
        let stage = try AtomicOutput.stage(beside: inputs[0]); defer { try? FileManager.default.removeItem(at: stage) }
        let file = stage.appendingPathComponent("combined.pdf")
        if images { try ImageConversion.pdf(inputs, to: file) }
        else {
            let combined = PDFDocument()
            for input in inputs {
                guard input.pathExtension.lowercased() == "pdf" else { throw RMError("Select PDF files to combine.") }
                let document = try loadPDF(input)
                guard combined.pageCount + document.pageCount <= 5000 else { throw RMError("The combined PDF exceeds the 5,000-page limit.") }
                for index in 0..<document.pageCount { combined.insert(document.page(at: index)!.copy() as! PDFPage, at: combined.pageCount) }
            }
            try writePDF(combined, to: file)
        }
        return try AtomicOutput.publish(file, as: inputs[0].deletingLastPathComponent().appendingPathComponent("Combined.pdf"))
    }

    func loadPDF(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw RMError("This is not a readable PDF.") }
        guard !document.isEncrypted else { throw RMError("Encrypted PDFs are not supported. Save an unencrypted copy first.") }
        guard document.pageCount > 0, document.pageCount <= 5000 else { throw RMError("Choose a PDF with between 1 and 5,000 pages.") }
        for index in 0..<document.pageCount {
            if document.page(at: index)?.annotations.contains(where: { $0.type == "Widget" }) == true { throw RMError("This PDF contains interactive form fields. Flatten a copy before using these tools.") }
        }
        return document
    }
    func writePDF(_ pdf: PDFDocument, to url: URL) throws {
        guard pdf.write(to: url), let check = PDFDocument(url: url), check.pageCount == pdf.pageCount else { throw RMError("The generated PDF could not be validated.") }
    }
}

enum ImageConversion {
    static func image(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) == 1 else { throw RMError("Choose a readable, single-frame image.") }
        if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source,0,kCGImageAuxiliaryDataTypeHDRGainMap) != nil { throw RMError("This image contains an HDR gain map. Export an SDR copy before converting it.") }
        if #available(macOS 15.0, *), CGImageSourceCopyAuxiliaryDataInfoAtIndex(source,0,kCGImageAuxiliaryDataTypeISOGainMap) != nil { throw RMError("This image contains an HDR gain map. Export an SDR copy before converting it.") }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard w > 0, h > 0, Double(w) * Double(h) <= 120_000_000 else { throw RMError("This image exceeds the 120-megapixel processing limit.") }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw RMError("The image could not be decoded.") }
        guard !image.bitmapInfo.contains(.floatComponents) else { throw RMError("Floating-point raster images need an explicit SDR export before conversion.") }
        let orientation = props[kCGImagePropertyOrientation] as? Int32 ?? 1
        if orientation == 1 { return image }
        let oriented = CIImage(cgImage: image).oriented(forExifOrientation: orientation)
        guard let result = CIContext().createCGImage(oriented, from: oriented.extent, format: image.bitsPerComponent > 8 ? .RGBA16 : .RGBA8, colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!) else { throw RMError("Could not apply image orientation.") }
        return result
    }
    static func write(_ url: URL, to output: URL, format: String) throws {
        var pixels = try image(url)
        if format == "heic" && pixels.bitsPerComponent > 8 { throw RMError("HEIC output currently supports 8-bit SDR images only. Use PNG or TIFF for this image.") }
        if format == "jpg" {
            let colourSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let canvas = CGContext(data: nil, width: pixels.width, height: pixels.height, bitsPerComponent: 8, bytesPerRow: 0, space: colourSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw RMError("Could not prepare JPEG pixels.") }
            canvas.setFillColor(CGColor(gray: 1, alpha: 1)); canvas.fill(CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
            canvas.draw(pixels, in: CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height)); pixels = canvas.makeImage()!
        }
        let types: [String:String] = ["jpg":"public.jpeg", "png":"public.png", "tiff":"public.tiff", "heic":"public.heic", "avif":"public.avif", "ico":"com.microsoft.ico", "icns":"com.apple.icns"]
        guard let type = types[format], let destination = CGImageDestinationCreateWithURL(output as CFURL, type as CFString, 1, nil) else { throw RMError("This macOS version cannot write \(format.uppercased()).") }
        CGImageDestinationAddImage(destination, pixels, [kCGImageDestinationLossyCompressionQuality: format == "jpg" ? 0.95 : 0.90, kCGImagePropertyOrientation: 1] as CFDictionary)
        guard CGImageDestinationFinalize(destination), let check = CGImageSourceCreateWithURL(output as CFURL, nil), CGImageSourceGetCount(check) == 1,
              let decoded = CGImageSourceCreateImageAtIndex(check, 0, nil), decoded.width == pixels.width, decoded.height == pixels.height else { throw RMError("The converted image could not be validated.") }
    }
    static func pdf(_ urls: [URL], to output: URL) throws {
        guard let consumer = CGDataConsumer(url: output as CFURL), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw RMError("Could not create the PDF.") }
        for url in urls {
            let pixels = try image(url)
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString:Any] ?? [:]
            let dx = props[kCGImagePropertyDPIWidth] as? Double ?? 144, dy = props[kCGImagePropertyDPIHeight] as? Double ?? 144
            let validDPI = dx.isFinite && dy.isFinite && dx >= 10 && dy >= 10 && dx <= 2400 && dy <= 2400
            let rotated = (props[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
            let xDPI = validDPI ? (rotated ? dy : dx) : 144, yDPI = validDPI ? (rotated ? dx : dy) : 144
            var box = CGRect(x: 0, y: 0, width: Double(pixels.width)*72/xDPI, height: Double(pixels.height)*72/yDPI)
            let data = NSData(bytes: &box, length: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox as String: data] as CFDictionary)
            context.draw(pixels, in: box); context.endPDFPage()
        }
        context.closePDF()
        guard let check = PDFDocument(url: output), check.pageCount == urls.count else { throw RMError("The generated PDF could not be validated.") }
    }
}

enum JobLog {
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["RMCONVERT_LOG_DIRECTORY"] { return URL(fileURLWithPath: override) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/rmconvert", isDirectory: true)
    }
    static func append(_ report: JobReport) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: directory.appendingPathComponent(report.id + ".json"), options: .atomic)
            let files = try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.contentModificationDateKey,.isRegularFileKey])
            let dated = files.compactMap { url -> (URL,Date)? in
                guard url.pathExtension == "json", UUID(uuidString:url.deletingPathExtension().lastPathComponent) != nil,
                      let values = try? url.resourceValues(forKeys:[.contentModificationDateKey,.isRegularFileKey]), values.isRegularFile == true,
                      let date = values.contentModificationDate else { return nil }
                return (url,date)
            }.sorted { $0.1 > $1.1 }
            let cutoff = Date().addingTimeInterval(-30*24*60*60)
            for (index,item) in dated.enumerated() where index >= 1000 || item.1 < cutoff { try? FileManager.default.removeItem(at:item.0) }
        } catch { fputs("Could not write the conversion log: \(error.localizedDescription)\n", stderr) }
    }
}
