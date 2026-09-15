import Foundation

enum PageRanges {
    static func parse(_ text: String, pageCount: Int) throws -> [Int] {
        guard pageCount > 0 else { throw RMError("This PDF has no pages.") }
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw RMError("Enter pages, for example 1-3, 5, 8.") }
        if input.lowercased() == "all" { return Array(0..<pageCount) }
        var pages: [Int] = [], seen = Set<Int>()
        for raw in input.split(separator: ",", omittingEmptySubsequences: false) {
            let piece = raw.trimmingCharacters(in: .whitespaces)
            let parts = piece.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard (1...2).contains(parts.count), let start = Int(parts[0]), start > 0, start <= pageCount else {
                throw RMError("Use page numbers from 1 to \(pageCount), separated by commas or ranges.")
            }
            let end: Int
            if parts.count == 2 {
                guard let number = Int(parts[1]), number >= start, number <= pageCount else { throw RMError("Invalid range \(piece). Pages run from 1 to \(pageCount).") }
                end = number
            } else { end = start }
            for page in start...end where seen.insert(page - 1).inserted { pages.append(page - 1) }
        }
        return pages
    }
}
