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

    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("RMCONVERT_LOG_DIRECTORY", root.appendingPathComponent("logs").path, 1)
        let manifest = try ConversionManifest.load(at: URL(fileURLWithPath: "Resources/manifest.json"))
        let engine = ConversionEngine(manifest: manifest)
        try hdrImages(root, engine: engine)
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
        try expect(menus.contains { $0.label == "PDF" && $0.items.contains { $0.actionId == "pdf.extract" } }, "PDF submenu")
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
        try expect(singlePDF.flatMap(\.items).contains { $0.actionId == "pdf.extract" },"single PDF offers page selection")
        let multiplePDF = manifest.menus(for:[pdfURL,pdfURL],available:engine.available)
        try expect(!multiplePDF.flatMap(\.items).contains { $0.actionId == "pdf.extract" },"multiple PDFs do not offer page selection")
        let fixtures = Array(repeating: original, count: 500)
        var samples: [Double] = []
        for _ in 0..<100 { let start = CFAbsoluteTimeGetCurrent(); _ = manifest.menus(for: fixtures, available: engine.available); samples.append((CFAbsoluteTimeGetCurrent()-start)*1000) }
        samples.sort(); print("PASS: \(checks) checks. Menu 500 paths p50=\(samples[50])ms p95=\(samples[95])ms")
        print("Fixtures: \(root.path)")
    }
}
