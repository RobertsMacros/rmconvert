import Foundation

struct TableData {
    var headers: [String]
    var rows: [[String]]

    static func read(_ url: URL, delimiter: Character) throws -> TableData {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 16_000_000 else { throw RMError("Structured-data files are limited to 16 MB.") }
        let raw = try String(contentsOf: url, encoding: .utf8)
        var chars = Array(raw); if chars.first == "\u{feff}" { chars.removeFirst() }
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false, closed = false, index = 0
        func finishField() { row.append(field); field = ""; closed = false }
        while index < chars.count {
            let c = chars[index]
            if quoted {
                if c == "\"" {
                    if index + 1 < chars.count && chars[index + 1] == "\"" { field.append("\""); index += 1 }
                    else { quoted = false; closed = true }
                } else { field.append(c) }
            } else if c == delimiter { finishField() }
            else if c == "\n" || c == "\r" || c == "\r\n" {
                finishField(); rows.append(row); row = []
                if c == "\r", index + 1 < chars.count, chars[index + 1] == "\n" { index += 1 }
            } else if c == "\"" {
                guard field.isEmpty && !closed else { throw RMError("Unexpected quote in the table.") }; quoted = true
            } else { guard !closed else { throw RMError("Unexpected text after a quoted cell.") }; field.append(c) }
            index += 1
        }
        guard !quoted else { throw RMError("An unfinished quoted cell was found.") }
        if !row.isEmpty || !field.isEmpty || closed { finishField(); rows.append(row) }
        guard let header = rows.first, !header.isEmpty, header.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }), Set(header).count == header.count else { throw RMError("Use a non-empty, unique header for each column.") }
        let body = Array(rows.dropFirst())
        guard body.allSatisfy({ $0.count == header.count }) else { throw RMError("Every row must have the same number of columns as the header.") }
        return TableData(headers: header, rows: body)
    }

    func delimited(_ delimiter: Character) -> String {
        func quote(_ value: String) -> String {
            if value.contains(delimiter) || value.contains("\"") || value.contains("\n") || value.contains("\r") { return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            return value
        }
        return ([headers] + rows).map { $0.map(quote).joined(separator: String(delimiter)) }.joined(separator: "\r\n") + "\r\n"
    }

    func markdown() -> String {
        func escape(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\r\n", with: "<br>").replacingOccurrences(of: "\n", with: "<br>").replacingOccurrences(of: "\r", with: "<br>") }
        return ([headers, Array(repeating: "---", count: headers.count)] + rows).map { "| " + $0.map(escape).joined(separator: " | ") + " |" }.joined(separator: "\n") + "\n"
    }

    func records() -> [[String:String]] { rows.map { Dictionary(uniqueKeysWithValues: zip(headers, $0)) } }

    static func fromJSON(_ value: Any) throws -> TableData {
        guard let records = value as? [[String:Any]], !records.isEmpty else { throw RMError("CSV needs a non-empty JSON array of flat records.") }
        let keys = Set(records.flatMap { $0.keys }).sorted()
        guard !keys.isEmpty, keys.allSatisfy({ !$0.isEmpty }) else { throw RMError("CSV records need non-empty column names.") }
        let rows = try records.map { record in try keys.map { key -> String in
            guard let value = record[key], !(value is NSNull) else { return "" }
            if let string = value as? String { return string }
            if let number = value as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
                return number.stringValue
            }
            throw RMError("CSV cannot represent nested objects or arrays.")
        } }
        return TableData(headers: keys, rows: rows)
    }
}

enum DataConversion {
    static func convert(_ input: URL, to output: URL, format: String, stage: URL, backends: [String:String]) throws {
        guard (try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 16_000_000 else { throw RMError("Structured-data files are limited to 16 MB.") }
        let source = ConversionManifest.extensionOf(input)
        if source == "xml" {
            let value = try XMLMapping.read(input)
            try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:output)
            return
        }
        if source == "csv" || source == "tsv" {
            let table = try TableData.read(input, delimiter: source == "csv" ? "," : "\t")
            if format == "json" { try JSONSerialization.data(withJSONObject: table.records(), options: [.prettyPrinted,.sortedKeys]).write(to: output) }
            else { try (format == "md" ? table.markdown() : table.delimited(format == "csv" ? "," : "\t")).write(to: output, atomically: false, encoding: .utf8) }
            return
        }
        if source == "json" {
            let value = try JSONSerialization.jsonObject(with: Data(contentsOf: input), options: [.fragmentsAllowed])
            if format == "csv" { try TableData.fromJSON(value).delimited(",").write(to: output, atomically: false, encoding: .utf8); return }
            if format == "toml" {
                func representable(_ item: Any) -> Bool {
                    if item is NSNull { return false }
                    if let object = item as? [String:Any] { return object.values.allSatisfy(representable) }
                    if let array = item as? [Any] { return array.allSatisfy(representable) }
                    return true
                }
                guard value is [String:Any], representable(value) else { throw RMError("TOML needs an object containing no null values.") }
            }
            if format == "xml" {
                guard let object = value as? [String:Any] else { throw RMError("XML output needs a flat JSON object.") }
                func escaped(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;") }
                var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<root>\n"
                for key in object.keys.sorted() {
                    guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil else { throw RMError("Invalid XML element name: \(key).") }
                    let items = object[key] as? [Any] ?? [object[key]!]
                    guard !items.isEmpty else { throw RMError("XML output cannot represent empty arrays.") }
                    for value in items {
                        guard value is String || value is NSNumber else { throw RMError("XML output supports only scalar values or arrays of scalars, without nulls.") }
                        let text: String
                        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { text = number.boolValue ? "true" : "false" }
                        else { text = (value as? String) ?? String(describing: value) }
                        xml += "  <\(key)>\(escaped(text))</\(key)>\n"
                    }
                }
                xml += "</root>\n"
                guard XMLParser(data:Data(xml.utf8)).parse() else { throw RMError("The data contains characters XML cannot represent.") }
                try xml.write(to: output, atomically: false, encoding: .utf8); return
            }
        }
        guard let executable = backends["yq"] else { throw RMError("Install yq for this data conversion.") }
        if source == "yaml" {
            let tags = try ProcessRunner.run(executable, ["-p","yaml","-o","json","[.. | tag] | unique",input.path], in: stage)
            let allowed = Set(["!!map","!!seq","!!str","!!int","!!float","!!bool","!!null"])
            guard let data = tags.output.data(using: .utf8), let values = try JSONSerialization.jsonObject(with: data) as? [String], Set(values).isSubset(of: allowed) else { throw RMError("This YAML uses tags that JSON cannot preserve.") }
        }
        let result = try ProcessRunner.run(executable, ["-p",source,"-o",format,".",input.path], in: stage)
        guard !result.output.isEmpty, result.output.utf8.count < 1_000_000 else { throw RMError("The converted data exceeds this route’s 1 MB output limit.") }
        if format == "json" { _ = try JSONSerialization.jsonObject(with: Data(result.output.utf8), options: [.fragmentsAllowed]) }
        try result.output.write(to: output, atomically: false, encoding: .utf8)
    }
}

private final class XMLMapping: NSObject, XMLParserDelegate {
    private final class Node {
        var name: String, attributes: [String:String], text = "", children: [Node] = []
        init(_ name: String,_ attributes: [String:String]) { self.name = name; self.attributes = attributes }
        func value() throws -> Any {
            if children.isEmpty && attributes.isEmpty { return text }
            guard children.isEmpty || text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw RMError("Mixed XML text and child elements are not supported.") }
            var object: [String:Any] = [:]
            for (key,value) in attributes { object["@"+key] = value }
            if !text.isEmpty && children.isEmpty { object["#text"] = text }
            var grouped: [String:[Any]] = [:]
            for child in children { grouped[child.name,default:[]].append(try child.value()) }
            for (name,values) in grouped { object[name] = values.count == 1 ? values[0] : values }
            return object
        }
    }
    private var nodes: [Node] = [], root: Node?, failure: String?, count = 0
    static func read(_ url: URL) throws -> [String:Any] {
        let data = try Data(contentsOf:url), text = String(decoding:data,as:UTF8.self)
        guard text.range(of:"<!DOCTYPE",options:.caseInsensitive) == nil, text.range(of:"<!ENTITY",options:.caseInsensitive) == nil else { throw RMError("XML DTDs and entities are not supported.") }
        let delegate = XMLMapping(), parser = XMLParser(data:data); parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else { throw RMError(delegate.failure ?? "The XML is malformed.") }
        return [root.name:try root.value()]
    }
    func parser(_ parser: XMLParser,didStartElement elementName: String,namespaceURI: String?,qualifiedName qName: String?,attributes: [String:String]) {
        count += 1
        guard nodes.count < 64, count <= 100_000, !elementName.contains(":"), !attributes.keys.contains(where: { $0.hasPrefix("xmlns") || $0.contains(":") }) else { failure = "XML namespaces or excessive nesting are not supported."; parser.abortParsing(); return }
        let node = Node(elementName,attributes)
        if let parent = nodes.last { parent.children.append(node) } else { root = node }
        nodes.append(node)
    }
    func parser(_ parser: XMLParser,foundCharacters string: String) { nodes.last?.text += string }
    func parser(_ parser: XMLParser,foundCDATA CDATABlock: Data) { nodes.last?.text += String(decoding:CDATABlock,as:UTF8.self) }
    func parser(_ parser: XMLParser,didEndElement elementName: String,namespaceURI: String?,qualifiedName qName: String?) { _ = nodes.popLast() }
}
