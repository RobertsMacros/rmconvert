import Foundation
import Cocoa
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

@main enum CoreTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1; if !condition() { throw RMError("FAILED: " + message) }
    }
    static func rejects(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { checks += 1; return }; throw RMError("FAILED: should reject " + name)
    }
    static func hdrImages(_ root: URL, engine: ConversionEngine) throws {
        let fixture = root.appendingPathComponent("HDR photo.heic")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "tests/fixtures/hdr-gain-map.heic"), to: fixture)
        let before = try Data(contentsOf: fixture)
        let source = CGImageSourceCreateWithURL(fixture as CFURL, nil)!
        if #available(macOS 15.0, *) {
            try expect(CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil, "HDR fixture contains ISO gain map")
        }
        let baseline = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        func centre(_ image: CGImage) -> [Int] {
            let canvas = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            canvas.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let bytes = canvas.data!.assumingMemoryBound(to: UInt8.self)
            return (0..<3).map { Int(bytes[$0]) }
        }
        let expected = centre(baseline)
        for format in ["jpg", "png", "tiff", "pdf"] {
            let report = engine.run(JobRequest(action: "convert." + format, paths: [fixture.path], pages: nil))
            try expect(report.failures == 0 && report.outputs.count == 1, "HDR photo to \(format)")
            let output = URL(fileURLWithPath: report.outputs[0])
            if format == "pdf" {
                try expect(PDFDocument(url: output)?.pageCount == 1, "HDR photo PDF page")
            } else {
                let result = try ImageConversion.image(output)
                try expect(result.width == baseline.width && result.height == baseline.height, "HDR photo output dimensions")
                try expect(!result.bitmapInfo.contains(.floatComponents), "HDR photo output is integer SDR")
                let actual = centre(result)
                try expect(zip(actual, expected).allSatisfy { abs($0 - $1) <= 8 }, "HDR photo retains SDR colours")
                let check = CGImageSourceCreateWithURL(output as CFURL, nil)!
                try expect(CGImageSourceCopyAuxiliaryDataInfoAtIndex(check, 0, kCGImageAuxiliaryDataTypeHDRGainMap) == nil, "output has no Apple HDR gain map")
                if #available(macOS 15.0, *) {
                    try expect(CGImageSourceCopyAuxiliaryDataInfoAtIndex(check, 0, kCGImageAuxiliaryDataTypeISOGainMap) == nil, "output has no ISO HDR gain map")
                    try expect(result.contentHeadroom <= 1, "output has SDR headroom")
                }
            }
        }
        if #available(macOS 15.0, *) {
            let oriented = root.appendingPathComponent("HDR rotated.heic")
            let destination = CGImageDestinationCreateWithURL(oriented as CFURL, UTType.heic.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, baseline, [kCGImagePropertyOrientation: 6] as CFDictionary)
            let gain = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap)!
            CGImageDestinationAddAuxiliaryDataInfo(destination, kCGImageAuxiliaryDataTypeISOGainMap, gain)
            try expect(CGImageDestinationFinalize(destination), "oriented HDR fixture")
            let result = try ImageConversion.image(oriented)
            try expect(result.width == baseline.height && result.height == baseline.width, "HDR EXIF orientation applied")
        }
        let after = try Data(contentsOf: fixture)
        try expect(after == before, "HDR source unchanged")
    }

    static func contents(_ page: PDFPage?) -> Data? {
        guard let dictionary = page?.pageRef?.dictionary else { return nil }
        var stream: CGPDFStreamRef?, array: CGPDFArrayRef?, format = CGPDFDataFormat.raw
        if CGPDFDictionaryGetStream(dictionary, "Contents", &stream), let stream { return CGPDFStreamCopyData(stream, &format) as Data? }
        guard CGPDFDictionaryGetArray(dictionary, "Contents", &array), let array else { return nil }
        var data = Data()
        for index in 0..<CGPDFArrayGetCount(array) {
            if CGPDFArrayGetStream(array, index, &stream), let stream, let part = CGPDFStreamCopyData(stream, &format) { data.append(part as Data) }
        }
        return data
    }

    static func pagesPDF(_ url: URL, count: Int) throws {
        var box = CGRect(x: 0, y: 0, width: 420, height: 595)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for index in 1...count {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            ("Page \(index)" as NSString).draw(at: NSPoint(x: 60, y: 450), withAttributes: [.font:NSFont.systemFont(ofSize: 36), .foregroundColor:NSColor.black])
            NSGraphicsContext.restoreGraphicsState(); context.endPDFPage()
        }
        context.closePDF()
    }

    /// Organise pages: pure arrangement edits, then real PDFs written through the engine.
    static func pageOrganiser(_ root: URL, engine: ConversionEngine, manifest: ConversionManifest) throws {
        func order(_ pages: [OrganisedPage]) -> [Int] { pages.map(\.source) }
        let four = PageOrganiser.pages(count: 4)
        try expect(order(four) == [0, 1, 2, 3] && four.allSatisfy { $0.rotation == 0 }, "organiser starts in original order")
        var moved = PageOrganiser.move(four, indexes: [0], to: 3)
        try expect(order(moved.pages) == [1, 2, 0, 3] && moved.moved == [2], "move one page later")
        moved = PageOrganiser.move(four, indexes: [0], to: 4)
        try expect(order(moved.pages) == [1, 2, 3, 0] && moved.moved == [3], "move one page to the end")
        moved = PageOrganiser.move(four, indexes: [3], to: 0)
        try expect(order(moved.pages) == [3, 0, 1, 2] && moved.moved == [0], "move one page to the start")
        moved = PageOrganiser.move(four, indexes: [0, 2], to: 4)
        try expect(order(moved.pages) == [1, 3, 0, 2] && moved.moved == [2, 3], "move separated pages together")
        moved = PageOrganiser.move(four, indexes: [0, 3], to: 2)
        try expect(order(moved.pages) == [1, 0, 3, 2] && moved.moved == [1, 2], "move pages into the middle")
        try expect(order(PageOrganiser.move(four, indexes: [], to: 2).pages) == [0, 1, 2, 3], "empty move changes nothing")
        try expect(order(PageOrganiser.move(four, indexes: [7], to: 0).pages) == [0, 1, 2, 3], "out-of-range move changes nothing")
        try expect(order(PageOrganiser.moveEarlier(four, indexes: [2]).pages) == [0, 2, 1, 3], "move earlier")
        try expect(order(PageOrganiser.moveLater(four, indexes: [1]).pages) == [0, 2, 1, 3], "move later")
        try expect(order(PageOrganiser.moveLater(four, indexes: [2, 3]).pages) == [0, 1, 2, 3], "move later at the end is unchanged")
        try expect(order(PageOrganiser.moveEarlier(four, indexes: [0]).pages) == [0, 1, 2, 3], "move earlier at the start is unchanged")
        var turned = try PageOrganiser.rotate(four, indexes: [1, 2], by: 90)
        try expect(turned.map(\.rotation) == [0, 90, 90, 0], "rotate right")
        turned = try PageOrganiser.rotate(turned, indexes: [1], by: 90)
        turned = try PageOrganiser.rotate(turned, indexes: [2, 3], by: -90)
        try expect(turned.map(\.rotation) == [0, 180, 0, 270], "rotate left normalises")
        var full = four
        for _ in 0..<4 { full = try PageOrganiser.rotate(full, indexes: [0], by: 90) }
        try expect(full[0].rotation == 0, "four quarter turns return to upright")
        try rejects("partial rotation") { _ = try PageOrganiser.rotate(four, indexes: [0], by: 45) }
        let remaining = try PageOrganiser.delete(four, indexes: [1, 2])
        try expect(order(remaining) == [0, 3], "delete selected pages")
        try rejects("deleting every page") { _ = try PageOrganiser.delete(four, indexes: [0, 1, 2, 3]) }
        let arranged = PageOrganiser.move(turned, indexes: [3], to: 0).pages
        let subset = try PageOrganiser.subset(arranged, indexes: [0, 2])
        try expect(order(subset) == [3, 1] && subset.map(\.rotation) == [270, 180], "extract keeps current order and rotation")
        try rejects("extract with no selection") { _ = try PageOrganiser.subset(four, indexes: []) }
        let chosen = try PageOrganiser.selection("1-2, 4", pageCount: 4)
        try expect(chosen == [0, 1, 3], "pages field selects positions")
        for range in ["0", "5", "a", "2-1"] { try rejects("organiser range \(range)") { _ = try PageOrganiser.selection(range, pageCount: 4) } }

        let folder = root.appendingPathComponent("organise"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("Report pages.pdf")
        try pagesPDF(source, count: 4)
        let turnedSource = PDFDocument(url: source)!; turnedSource.page(at: 1)!.rotation = 90
        try expect(turnedSource.write(to: source), "source with a rotated page")
        let before = try Data(contentsOf: source)
        let document = try engine.loadPDF(source)
        try expect(PageOrganiser.unpreservedFeatures(of: document).isEmpty, "plain PDF has no unpreserved features")
        let plan = [OrganisedPage(source: 3, rotation: 90), OrganisedPage(source: 0), OrganisedPage(source: 1, rotation: 270), OrganisedPage(source: 2, rotation: 180)]
        let saved = try PageOrganiser.save(plan, from: source, expectedPageCount: 4, label: "organised", engine: engine)
        try expect(saved.lastPathComponent == "Report pages (organised).pdf", "organised output name")
        let output = PDFDocument(url: saved)!
        try expect(output.pageCount == 4, "organised page count")
        try expect((0..<4).map { output.page(at: $0)!.string ?? "" } .enumerated().allSatisfy { $0.element.contains("Page \([4, 1, 2, 3][$0.offset])") }, "organised page order")
        try expect((0..<4).map { output.page(at: $0)!.rotation } == [90, 0, 0, 180], "rotation is page rotation, added to the original")
        // PDFKit rewrites line breaks and adds one clip to the page box. Every other
        // content token (operators and operands) must be unchanged: no redrawing or rasterising.
        func operators(_ page: PDFPage?) -> String? {
            contents(page).map { String(decoding: $0, as: UTF8.self).split(whereSeparator: \.isWhitespace).joined(separator: " ")
                .replacingOccurrences(of: #"^q Q q [-0-9. ]+ re W n "#, with: "q Q q ", options: .regularExpression) }
        }
        try expect((0..<4).allSatisfy { operators(output.page(at: $0)) != nil && operators(output.page(at: $0)) == operators(document.page(at: [3, 0, 1, 2][$0])) }, "page drawing operators copied unchanged")
        try expect(output.page(at: 0)!.bounds(for: .mediaBox) == document.page(at: 3)!.bounds(for: .mediaBox), "media box unchanged")
        let again = try PageOrganiser.save(plan, from: source, expectedPageCount: 4, label: "organised", engine: engine)
        try expect(again.lastPathComponent == "Report pages (organised)-1.pdf" && FileManager.default.fileExists(atPath: saved.path), "existing organised file kept and numbered")
        let extracted = try PageOrganiser.save(try PageOrganiser.subset(plan, indexes: [0, 3]), from: source, expectedPageCount: 4, label: "extracted", engine: engine)
        let extractedPDF = PDFDocument(url: extracted)!
        try expect(extracted.lastPathComponent == "Report pages (extracted).pdf" && extractedPDF.pageCount == 2 && extractedPDF.page(at: 1)!.string!.contains("Page 3") && extractedPDF.page(at: 1)!.rotation == 180, "extract selected")
        let removed = try PageOrganiser.save(try PageOrganiser.delete(plan, indexes: [1]), from: source, expectedPageCount: 4, label: "organised", engine: engine)
        try expect(PDFDocument(url: removed)!.pageCount == 3, "remove selected and save")
        try rejects("changed original page count") { _ = try PageOrganiser.save(plan, from: source, expectedPageCount: 5, label: "organised", engine: engine) }
        try rejects("empty organised document") { _ = try PageOrganiser.save([], from: source, expectedPageCount: 4, label: "organised", engine: engine) }
        try rejects("missing source page") { _ = try PageOrganiser.document(from: document, pages: [OrganisedPage(source: 9)]) }
        let after = try Data(contentsOf: source)
        try expect(after == before, "organiser original unchanged")
        let stray = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".rmconvert-") }
        try expect(stray.isEmpty, "organiser staging folders removed")

        // PDFKit does not write outlines, so these one-page fixtures are written directly.
        func rawPDF(_ name: String, catalogue: String, objects: [String]) throws -> URL {
            let body = ["<< /Type /Catalog /Pages 2 0 R \(catalogue) >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> /Contents 4 0 R >>",
                        "<< /Length 17 >>\nstream\n0 0 100 100 re f\nendstream"] + objects
            var text = "%PDF-1.4\n", offsets: [Int] = []
            for (index, object) in body.enumerated() { offsets.append(text.utf8.count); text += "\(index + 1) 0 obj\n\(object)\nendobj\n" }
            let xref = text.utf8.count
            text += "xref\n0 \(body.count + 1)\n0000000000 65535 f \n" + offsets.map { String(format: "%010d 00000 n \n", $0) }.joined()
            text += "trailer\n<< /Size \(body.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
            let url = folder.appendingPathComponent(name); try Data(text.utf8).write(to: url); return url
        }
        let outlined = try rawPDF("Outlined.pdf", catalogue: "/Outlines 5 0 R", objects: ["<< /Type /Outlines /First 6 0 R /Last 6 0 R /Count 1 >>", "<< /Title (Chapter) /Parent 5 0 R /Dest [3 0 R /Fit] >>"])
        let outlinedFeatures = PageOrganiser.unpreservedFeatures(of: try engine.loadPDF(outlined))
        try expect(outlinedFeatures == ["bookmarks"], "bookmarks reported for the footer")
        let signed = try rawPDF("Signed.pdf", catalogue: "/AcroForm << /SigFlags 3 /Fields [] >>", objects: [])
        let signedFeatures = PageOrganiser.unpreservedFeatures(of: try engine.loadPDF(signed))
        try expect(signedFeatures == ["digital signatures"], "signatures reported for the footer")

        let cli = engine.run(JobRequest(action: "pdf.organise", paths: [source.path], pages: "3,1"))
        let cliPDF = cli.outputs.first.flatMap { PDFDocument(url: URL(fileURLWithPath: $0)) }
        try expect(cli.failures == 0 && cliPDF?.pageCount == 2 && cliPDF!.page(at: 0)!.string!.contains("Page 3") && cli.outputs[0].contains("(organised)"), "Terminal organise follows --pages order")
        try expect(engine.run(JobRequest(action: "pdf.organise", paths: [source.path], pages: nil)).failures == 1, "Terminal organise needs --pages")
        let finder = manifest.menus(for: [source], available: engine.available).flatMap(\.items)
        try expect(finder.contains { $0.actionId == "pdf.organise" && $0.label == "Organise pages…" && $0.needsPages }, "Finder offers Organise pages")
        try expect(!finder.contains { ["pdf.extract", "pdf.remove"].contains($0.actionId) }, "old page pickers removed from Finder")
        try expect(manifest.actions.contains { $0.id == "pdf.extract" && $0.terminalOnly == true } && manifest.actions.contains { $0.id == "pdf.remove" && $0.terminalOnly == true }, "extract and remove remain for Terminal")

        let large = folder.appendingPathComponent("Large.pdf")
        try pagesPDF(large, count: 500)
        var start = CFAbsoluteTimeGetCurrent()
        let largeDocument = try engine.loadPDF(large)
        let loadTime = CFAbsoluteTimeGetCurrent() - start
        start = CFAbsoluteTimeGetCurrent()
        var big = PageOrganiser.pages(count: 500)
        big = PageOrganiser.move(big, indexes: IndexSet(stride(from: 0, to: 500, by: 2)), to: 500).pages
        big = try PageOrganiser.rotate(big, indexes: IndexSet(0..<500), by: 90)
        big = try PageOrganiser.delete(big, indexes: try PageOrganiser.selection("1-10", pageCount: 500))
        let editTime = CFAbsoluteTimeGetCurrent() - start
        try expect(big.count == 490 && big[0].source == 21 && big.last?.source == 498, "500-page arrangement edits")
        try expect(editTime < 0.1, "500-page edits are immediate (\(editTime)s)")
        start = CFAbsoluteTimeGetCurrent()
        let largeSaved = try PageOrganiser.save(big, from: large, expectedPageCount: largeDocument.pageCount, label: "organised", engine: engine)
        let saveTime = CFAbsoluteTimeGetCurrent() - start
        let largeOutput = PDFDocument(url: largeSaved)!
        try expect(largeOutput.pageCount == 490 && largeOutput.page(at: 0)!.rotation == 90 && largeOutput.page(at: 0)!.string!.contains("Page 22"), "500-page organised PDF")
        print(String(format: "Organiser 500 pages: load %.2fs, edits %.4fs, save %.2fs", loadTime, editTime, saveTime))
    }

    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("RMCONVERT_LOG_DIRECTORY", root.appendingPathComponent("logs").path, 1)
        let manifest = try ConversionManifest.load(at: URL(fileURLWithPath: "Resources/manifest.json"))
        let engine = ConversionEngine(manifest: manifest)
        try hdrImages(root, engine: engine)
        try pageOrganiser(root, engine: engine, manifest: manifest)
        let colour = CGColorSpace(name: CGColorSpace.sRGB)!
        let canvas = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0, space: colour, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        canvas.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)); canvas.fill(CGRect(x: 10, y: 10, width: 80, height: 60))
        let image = canvas.makeImage()!
        let original = root.appendingPathComponent("O'Brien & Sons (finál) v2 ✨.png")
        let dest = CGImageDestinationCreateWithURL(original as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil); try expect(CGImageDestinationFinalize(dest), "fixture PNG")
        let originalBytes = try Data(contentsOf: original)
        for format in ["jpg", "tiff", "heic", "pdf"] {
            let report = engine.run(JobRequest(action: "convert." + format, paths: [original.path], pages: nil))
            try expect(report.failures == 0 && report.outputs.count == 1, "PNG to \(format): \(report.results)")
            if format != "pdf" {
                let result = try ImageConversion.image(URL(fileURLWithPath: report.outputs[0])); try expect(result.width == 120 && result.height == 80, "image dimensions")
            }
        }
        let jpg = original.deletingPathExtension().appendingPathExtension("jpg")
        let collision = engine.run(JobRequest(action: "convert.png", paths: [jpg.path], pages: nil))
        try expect(collision.failures == 0 && collision.outputs[0].hasSuffix("-1.png"), "suffix preserves existing file")
        let afterBytes = try Data(contentsOf: original); try expect(afterBytes == originalBytes, "original unchanged")
        let current = engine.run(JobRequest(action: "convert.png", paths: [original.path], pages: nil)); try expect(current.results.first?.status == "skipped", "same format skipped")
        let pdfURL = root.appendingPathComponent("Sample pages.pdf")
        var box = CGRect(x: 0, y: 0, width: 420, height: 595)
        let context = CGContext(pdfURL as CFURL, mediaBox: &box, nil)!
        for index in 1...4 {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            ("Page \(index)" as NSString).draw(at: NSPoint(x: 60, y: 450), withAttributes: [.font:NSFont.systemFont(ofSize: 36), .foregroundColor:NSColor.black])
            NSGraphicsContext.restoreGraphicsState(); context.endPDFPage()
        }
        context.closePDF()
        let pdfBytes = try Data(contentsOf: pdfURL)
        func job(_ action: String, _ pages: String? = nil) -> JobReport { engine.run(JobRequest(action: action, paths: [pdfURL.path], pages: pages)) }
        let extracted = job("pdf.extract", "4,1-2,2")
        try expect(extracted.failures == 0, "extract success")
        let ep = PDFDocument(url: URL(fileURLWithPath: extracted.outputs[0]))!
        try expect(ep.pageCount == 3 && ep.page(at: 0)!.string!.contains("Page 4") && ep.page(at: 2)!.string!.contains("Page 2"), "extract order and deduplication")
        let removed = job("pdf.remove", "2-3")
        let rp = PDFDocument(url: URL(fileURLWithPath: removed.outputs[0]))!
        try expect(rp.pageCount == 2 && rp.page(at: 1)!.string!.contains("Page 4"), "remove pages")
        try expect(job("pdf.remove", "all").failures == 1, "cannot remove all pages")
        let split = job("pdf.split")
        try expect(split.failures == 0, "split succeeds")
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: split.outputs[0]), includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
        try expect(files.count == 4 && PDFDocument(url: files[2])!.page(at: 0)!.string!.contains("Page 3"), "split order")
        let rotated = job("pdf.rotate-right")
        try expect(PDFDocument(url: URL(fileURLWithPath: rotated.outputs[0]))!.page(at: 0)!.rotation == 90, "rotation")
        let combined = engine.run(JobRequest(action: "pdf.combine", paths: [files[3].path, files[0].path], pages: nil))
        try expect(combined.failures == 0, "combine success")
        let cp = PDFDocument(url: URL(fileURLWithPath: combined.outputs[0]))!
        try expect(cp.pageCount == 2 && cp.page(at: 0)!.string!.contains("Page 1"), "combine filename order")
        let imageCombine = engine.run(JobRequest(action: "pdf.combine-images", paths: [jpg.path, original.path], pages: nil))
        try expect(imageCombine.failures == 0 && PDFDocument(url: URL(fileURLWithPath: imageCombine.outputs[0]))?.pageCount == 2, "combine images")
        for range in ["", "0", "5", "3-1", "1,", "1--2", "a"] { try rejects("page range \(range)") { _ = try PageRanges.parse(range, pageCount: 4) } }
        let encryptedURL = root.appendingPathComponent("Encrypted.pdf")
        let encryption = PDFDocument(url: pdfURL)!
        try expect(encryption.write(to: encryptedURL, withOptions: [.ownerPasswordOption:"owner", .userPasswordOption:"secret"]), "encrypted fixture")
        try rejects("encrypted PDF") { _ = try engine.loadPDF(encryptedURL) }
        let formURL = root.appendingPathComponent("Form.pdf"), form = PDFDocument(url: pdfURL)!
        form.page(at: 0)!.addAnnotation(PDFAnnotation(bounds: CGRect(x: 10,y: 10,width: 40,height: 20), forType: .widget, withProperties: nil))
        try expect(form.write(to: formURL), "form fixture"); try rejects("form fields") { _ = try engine.loadPDF(formURL) }
        let bad = root.appendingPathComponent("Corrupt.pdf"); try Data("not a PDF".utf8).write(to: bad)
        try rejects("corrupt PDF") { _ = try engine.loadPDF(bad) }
        let menus = manifest.menus(for: [pdfURL], available: engine.available)
        try expect(menus.contains { $0.label == "PDF" && $0.items.contains { $0.actionId == "pdf.organise" } }, "PDF submenu")
        try expect(!menus.flatMap(\.items).contains { $0.actionId == "convert.docx" }, "no PDF to DOCX")
        let imageMenus = manifest.menus(for: [original], available: engine.available)
        try expect(imageMenus.flatMap(\.items).contains { $0.actionId == "convert.png" && !$0.enabled }, "current target disabled")
        var invalid = manifest; invalid.routes.append(invalid.routes[0]); try rejects("ambiguous manifest") { try invalid.validate() }
        let untouchedPDF = try Data(contentsOf: pdfURL); try expect(untouchedPDF == pdfBytes, "PDF original unchanged")
        let raceDirectory = root.appendingPathComponent("race"); try FileManager.default.createDirectory(at: raceDirectory, withIntermediateDirectories: true)
        let lock = NSLock(); var raceOutputs: [URL] = [], errors: [String] = []
        DispatchQueue.concurrentPerform(iterations: 16) { number in
            do {
                let staged = raceDirectory.appendingPathComponent(UUID().uuidString); try Data(String(number).utf8).write(to: staged)
                let result = try AtomicOutput.publish(staged, as: raceDirectory.appendingPathComponent("result.txt"))
                lock.lock(); raceOutputs.append(result); lock.unlock()
            } catch { lock.lock(); errors.append(error.localizedDescription); lock.unlock() }
        }
        try expect(errors.isEmpty && Set(raceOutputs).count == 16, "concurrent atomic publication")
        let raceContents = try raceOutputs.map { try String(contentsOf: $0, encoding: .utf8) }; try expect(Set(raceContents).count == 16, "no overwritten concurrent output")
        let runnerStage = root.appendingPathComponent("runner")
        try FileManager.default.createDirectory(at:runnerStage,withIntermediateDirectories:true)
        let childScript = runnerStage.appendingPathComponent("child.sh"), marker = runnerStage.appendingPathComponent("child-survived")
        try "trap '' TERM\nsleep 2\ntouch child-survived\n".write(to:childScript,atomically:true,encoding:.utf8)
        try rejects("timeout stops child process group") {
            try ProcessRunner.run("/bin/sh",["-c","/bin/sh child.sh & wait"],in:runnerStage,timeout:0.25)
        }
        Thread.sleep(forTimeInterval:2.5)
        try expect(!FileManager.default.fileExists(atPath:marker.path),"timed-out child did not survive")
        let networkProbe = "import socket,sys\ns=socket.socket()\ntry: s.connect(('127.0.0.1',9))\nexcept PermissionError: sys.exit(0)\nexcept OSError: sys.exit(1)\nsys.exit(2)"
        let networkResult = try ProcessRunner.run("/usr/bin/python3",["-c",networkProbe],in:runnerStage)
        try expect(networkResult.status == 0,"backend network connection denied by permissions")
        let mixed = manifest.menus(for:[original,root.appendingPathComponent("note.docx")],available:engine.available)
        try expect(mixed.flatMap(\.items).contains { $0.actionId == "convert.pdf" && $0.enabled },"mixed families retain common PDF")
        let splitDirectories = manifest.menus(for:[pdfURL,root.appendingPathComponent("other/another.pdf")],available:engine.available)
        try expect(!splitDirectories.flatMap(\.items).contains { $0.actionId == "pdf.combine" },"combine excluded across folders")
        let singlePDF = manifest.menus(for:[pdfURL],available:engine.available)
        try expect(singlePDF.flatMap(\.items).contains { $0.actionId == "pdf.organise" },"single PDF offers page organising")
        let multiplePDF = manifest.menus(for:[pdfURL,pdfURL],available:engine.available)
        try expect(!multiplePDF.flatMap(\.items).contains { $0.actionId == "pdf.organise" },"multiple PDFs do not offer page organising")
        let fixtures = Array(repeating: original, count: 500)
        var samples: [Double] = []
        for _ in 0..<100 { let start = CFAbsoluteTimeGetCurrent(); _ = manifest.menus(for: fixtures, available: engine.available); samples.append((CFAbsoluteTimeGetCurrent()-start)*1000) }
        samples.sort(); print("PASS: \(checks) checks. Menu 500 paths p50=\(samples[50])ms p95=\(samples[95])ms")
        print("Fixtures: \(root.path)")
    }
}
