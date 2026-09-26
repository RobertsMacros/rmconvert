import Foundation
import PDFKit

/// One page of an organised document: the source page it shows and the
/// quarter turns added in the organiser, on top of the page's own rotation.
struct OrganisedPage: Equatable, Hashable {
    var source: Int
    var rotation: Int = 0
}

/// Page edits for the Organise pages window. Edits return a new arrangement
/// and never touch a PDF, so the window can keep a simple undo history.
enum PageOrganiser {
    static func pages(count: Int) -> [OrganisedPage] { (0..<max(count, 0)).map { OrganisedPage(source: $0) } }

    /// Moves the pages at `indexes`, in their current order, so they sit before
    /// the page now at `destination` (`pages.count` means the end).
    static func move(_ pages: [OrganisedPage], indexes: IndexSet, to destination: Int) -> (pages: [OrganisedPage], moved: IndexSet) {
        let valid = indexes.filteredIndexSet { $0 >= 0 && $0 < pages.count }
        guard !valid.isEmpty else { return (pages, []) }
        let target = min(max(destination, 0), pages.count)
        let moving = valid.map { pages[$0] }
        var remaining = pages.enumerated().filter { !valid.contains($0.offset) }.map(\.element)
        let insertion = target - valid.count(in: 0..<target)
        remaining.insert(contentsOf: moving, at: insertion)
        return (remaining, IndexSet(insertion..<insertion + moving.count))
    }
    static func moveEarlier(_ pages: [OrganisedPage], indexes: IndexSet) -> (pages: [OrganisedPage], moved: IndexSet) {
        guard let first = indexes.first else { return (pages, indexes) }
        return move(pages, indexes: indexes, to: first - 1)
    }
    static func moveLater(_ pages: [OrganisedPage], indexes: IndexSet) -> (pages: [OrganisedPage], moved: IndexSet) {
        guard let last = indexes.last else { return (pages, indexes) }
        return move(pages, indexes: indexes, to: last + 2)
    }

    /// Adds a rotation in multiples of 90 degrees; positive is clockwise.
    static func rotate(_ pages: [OrganisedPage], indexes: IndexSet, by degrees: Int) throws -> [OrganisedPage] {
        guard degrees % 90 == 0 else { throw RMError("Pages rotate in quarter turns.") }
        var result = pages
        for index in indexes where index >= 0 && index < result.count { result[index].rotation = normalised(result[index].rotation + degrees) }
        return result
    }

    static func delete(_ pages: [OrganisedPage], indexes: IndexSet) throws -> [OrganisedPage] {
        let result = pages.enumerated().filter { !indexes.contains($0.offset) }.map(\.element)
        guard !result.isEmpty else { throw RMError("Keep at least one page in the PDF.") }
        return result
    }

    /// The selected pages in their current order and rotation.
    static func subset(_ pages: [OrganisedPage], indexes: IndexSet) throws -> [OrganisedPage] {
        let result = indexes.filter { $0 >= 0 && $0 < pages.count }.map { pages[$0] }
        guard !result.isEmpty else { throw RMError("Select at least one page.") }
        return result
    }

    /// Positions (as currently shown, from 1) named by a range such as "1-3, 5, 8".
    static func selection(_ text: String, pageCount: Int) throws -> IndexSet {
        IndexSet(try PageRanges.parse(text, pageCount: pageCount))
    }

    static func normalised(_ degrees: Int) -> Int { ((degrees % 360) + 360) % 360 }

    /// Copies the arranged pages into a new document. Rotation is written as page
    /// rotation, so page content is copied rather than redrawn or rasterised.
    static func document(from source: PDFDocument, pages: [OrganisedPage]) throws -> PDFDocument {
        guard !pages.isEmpty else { throw RMError("Keep at least one page in the PDF.") }
        let output = PDFDocument()
        for entry in pages {
            guard entry.rotation % 90 == 0, entry.source >= 0, entry.source < source.pageCount,
                  let page = source.page(at: entry.source)?.copy() as? PDFPage else { throw RMError("Page \(entry.source + 1) could not be copied.") }
            page.rotation = normalised(page.rotation + entry.rotation)
            output.insert(page, at: output.pageCount)
        }
        return output
    }

    /// "<name> (organised).pdf" beside the original; publication adds a number if taken.
    static func outputBase(for input: URL, label: String) -> URL {
        input.deletingLastPathComponent().appendingPathComponent(input.deletingPathExtension().lastPathComponent + " (\(label)).pdf")
    }

    /// Writes a new PDF beside the original and returns its location. The original
    /// is reread and rechecked; it is never replaced.
    static func save(_ pages: [OrganisedPage], from input: URL, expectedPageCount: Int, label: String, engine: ConversionEngine) throws -> URL {
        let source = try engine.loadPDF(input)
        guard source.pageCount == expectedPageCount else { throw RMError("The original PDF changed after this window opened. Close the window and open it again.") }
        let output = try document(from: source, pages: pages)
        let stage = try AtomicOutput.stage(beside: input)
        defer { try? FileManager.default.removeItem(at: stage) }
        let temporary = stage.appendingPathComponent("output.pdf")
        try engine.writePDF(output, to: temporary)
        return try AtomicOutput.publish(temporary, as: outputBase(for: input, label: label))
    }

    /// Document features that new page documents do not keep, in plain words.
    static func unpreservedFeatures(of document: PDFDocument) -> [String] {
        var features: [String] = []
        if (document.outlineRoot?.numberOfChildren ?? 0) > 0 { features.append("bookmarks") }
        if hasSignatures(document) { features.append("digital signatures") }
        return features
    }

    private static func hasSignatures(_ document: PDFDocument) -> Bool {
        guard let catalog = document.documentRef?.catalog else { return false }
        var permissions: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "Perms", &permissions) { return true }
        var form: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form), let form else { return false }
        var flags: CGPDFInteger = 0
        if CGPDFDictionaryGetInteger(form, "SigFlags", &flags), flags != 0 { return true }
        var fields: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(form, "Fields", &fields), let fields else { return false }
        for index in 0..<CGPDFArrayGetCount(fields) {
            var field: CGPDFDictionaryRef?, type: UnsafePointer<CChar>?
            if CGPDFArrayGetDictionary(fields, index, &field), let field, CGPDFDictionaryGetName(field, "FT", &type), let type, String(cString: type) == "Sig" { return true }
        }
        return false
    }
}
