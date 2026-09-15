import Foundation
import PDFKit

enum DocumentConversion {
    struct BatchResult { var outputs: [URL:URL]; var errors: [URL:String] }
    static func office(_ input: URL, format: String, stage: URL, backends: [String:String]) throws -> URL {
        let batch = try officeBatch([input],format:format,stage:stage,backends:backends)
        guard let output = batch.outputs[input] else { throw RMError(batch.errors[input] ?? "No document output was produced.") }
        return output
    }
    static func officeBatch(_ inputs: [URL], format: String, stage: URL, backends: [String:String]) throws -> BatchResult {
        guard !inputs.isEmpty, inputs.count <= 20 else { throw RMError("Office batches must contain between 1 and 20 files.") }
        guard let executable = backends["soffice"] else { throw RMError("Install LibreOffice to convert this document.") }
        var invalid: [URL:String] = [:]
        let inputs = inputs.filter { source in
            do { try validateInput(source, stage:stage); return true }
            catch { invalid[source] = error.localizedDescription; return false }
        }
        guard let input = inputs.first else { return BatchResult(outputs:[:],errors:invalid) }
        let lock = try ProcessLock(name: "libreoffice", timeout: 600)
        return try withExtendedLifetime(lock) {
            let profile = stage.appendingPathComponent("office-profile", isDirectory: true)
            let user = profile.appendingPathComponent("user", isDirectory: true)
            try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
            let configuration = """
            <?xml version="1.0" encoding="UTF-8"?>
            <oor:items xmlns:oor="http://openoffice.org/2001/registry">
            <item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop></item>
            <item oor:path="/org.openoffice.Office.Calc/Content/Update"><prop oor:name="Link" oor:op="fuse"><value>0</value></prop></item>
            <item oor:path="/org.openoffice.Office.Writer/Content/Update"><prop oor:name="Link" oor:op="fuse"><value>0</value></prop></item>
            <item oor:path="/org.openoffice.Office.Jobs/Jobs/org.openoffice.Office.Jobs:Job['UpdateCheck']/Arguments"><prop oor:name="AutoCheckEnabled" oor:op="fuse"><value>false</value></prop></item>
            </oor:items>
            """
            try configuration.write(to: user.appendingPathComponent("registrymodifications.xcu"), atomically: true, encoding: .utf8)
            let directory = stage.appendingPathComponent("office-output", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let ext = ConversionManifest.extensionOf(input)
            var target = format
            if format == "pdf" {
                let family = ["xlsx","xls","ods","csv","tsv"].contains(ext) ? "calc" : ["pptx","ppt","odp"].contains(ext) ? "impress" : "writer"
                target = "pdf:\(family)_pdf_Export:{\"SinglePageSheets\":{\"type\":\"boolean\",\"value\":\"false\"}}"
            }
            var args = ["-env:UserInstallation=" + profile.absoluteString, "--headless", "--nologo", "--nodefault", "--norestore", "--nofirststartwizard"]
            if ext == "csv" || ext == "tsv" {
                let table = try TableData.read(input, delimiter: ext == "csv" ? "," : "\t")
                let columns = table.headers.indices.map { "\($0 + 1)/2" }.joined(separator: "/")
                args += ["--infilter=Text - txt - csv (StarCalc):\(ext == "csv" ? 44 : 9),34,76,1,\(columns),1033,false,false,false,false,false,0,false,false"]
            }
            if format == "csv" { target = "csv:Text - txt - csv (StarCalc):44,34,76,1,,0,false,true,true,false,false,-1,false" }
            args += ["--convert-to", target, "--outdir", directory.path] + inputs.map(\.path)
            var executionError: String?
            do { try ProcessRunner.run(executable, args, in: stage, timeout: 600) }
            catch { executionError = error.localizedDescription }
            if format == "csv" {
                guard executionError == nil else { throw RMError(executionError!) }
                let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                guard !files.isEmpty, files.allSatisfy({ $0.pathExtension.lowercased() == "csv" }) else { throw RMError("LibreOffice did not export the workbook’s sheets.") }
                for file in files { _ = try String(contentsOf: file, encoding: .utf8) }
                return BatchResult(outputs:[input:directory],errors:[:])
            }
            var result = BatchResult(outputs:[:],errors:invalid)
            for source in inputs {
                let output = directory.appendingPathComponent(source.deletingPathExtension().lastPathComponent + "." + format)
                do { try validate(output,format:format); result.outputs[source] = output }
                catch { result.errors[source] = executionError ?? error.localizedDescription }
            }
            return result
        }
    }

    static func validateInput(_ url: URL, stage: URL) throws {
        let ext = ConversionManifest.extensionOf(url)
        let members = ["docx":"word/document.xml", "xlsx":"xl/workbook.xml", "pptx":"ppt/presentation.xml", "odt":"content.xml", "ods":"content.xml", "odp":"content.xml"]
        guard let member = members[ext] else { return }
        let handle = try FileHandle(forReadingFrom:url); defer { try? handle.close() }
        guard try handle.read(upToCount:2) == Data([0x50,0x4b]) else { throw RMError("The source is not a valid \(ext.uppercased()) document.") }
        let listing = try ProcessRunner.run("/usr/bin/unzip",["-Z1",url.path],in:stage)
        guard listing.output.split(separator:"\n").contains(Substring(member)) else { throw RMError("The source is missing its \(ext.uppercased()) document content.") }
        try ProcessRunner.run("/usr/bin/unzip",["-t",url.path],in:stage)
    }

    static func validate(_ url: URL, format: String) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw RMError("The document converter did not produce an output.") }
        if format == "pdf" {
            guard let document = PDFDocument(url: url), document.pageCount > 0 else { throw RMError("The converted PDF is unreadable.") }
        } else if ["docx","odt","xlsx","epub"].contains(format) {
            let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
            guard try file.read(upToCount: 2) == Data([0x50,0x4b]) else { throw RMError("The document has an invalid file signature.") }
            try ProcessRunner.run("/usr/bin/unzip",["-t",url.path],in:url.deletingLastPathComponent())
        } else if format != "rtfd" {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 else { throw RMError("The document converter produced an empty file.") }
        }
    }

    static func pandoc(_ input: URL, format: String, output: URL, assets: URL, stage: URL, backends: [String:String]) throws {
        guard let executable = backends["pandoc"] else { throw RMError("Install Pandoc to convert this document.") }
        let ext = ConversionManifest.extensionOf(input)
        if ["md","html","rst","tex"].contains(ext) {
            try checkLocalResources(input)
        }
        let reader = ["md":"markdown", "tex":"latex"][ext] ?? ext
        let writer = ["md":"gfm", "txt":"plain"][format] ?? format
        try ProcessRunner.run(executable, ["--from",reader,"--to",writer,"--standalone","--fail-if-warnings","--resource-path",input.deletingLastPathComponent().path,"--extract-media",assets.path,"--output",output.path,input.path], in: stage, timeout: 180)
        try validate(output, format: format)
    }
    static func checkLocalResources(_ input: URL) throws {
        let contents = try String(contentsOf: input,encoding:.utf8)
        let patterns = [#"(?i)(?:src|background|poster)\s*=\s*["'](?:https?:)?//"#, #"(?i)<link\b[^>]*href\s*=\s*["'](?:https?:)?//"#, #"(?i)url\(\s*["']?(?:https?:)?//"#, #"!\[[^\]]*\]\(\s*(?:https?:)?//"#]
        guard !patterns.contains(where: { contents.range(of:$0,options:.regularExpression) != nil }) else { throw RMError("This document references remote resources. Save a copy with local resources first.") }
    }
}
