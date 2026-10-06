//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// A GFM table parsed out of a message or document.
struct MarkdownTable {
    let headers: [String]
    let rows: [[String]]
}

/// A table together with the span of source text it occupies, so a caller can replace it in place.
struct MarkdownTableMatch {
    let table: MarkdownTable
    let range: Range<String.Index>
}

/// CDMarkdownKit, which renders chat messages, has no table element and no block-level concept to
/// extend — its elements are all inline styling. This finds GFM tables before CDMarkdownKit runs so
/// they can be replaced with something readable, rather than reaching the user as raw pipes.
enum MarkdownTableFormatter {

    static func tables(in text: String) -> [MarkdownTableMatch] {
        let lines = lineRanges(in: text)
        var matches: [MarkdownTableMatch] = []
        var index = 0
        var insideCodeFence = false

        while index < lines.count {
            // Someone demonstrating table syntax must get their example back verbatim, so anything
            // between fences is off limits.
            if isCodeFence(text[lines[index]]) {
                insideCodeFence.toggle()
                index += 1
                continue
            }

            guard !insideCodeFence else {
                index += 1
                continue
            }

            // A table is a header row, then a delimiter row, then zero or more body rows. Both of the
            // first two must be present: a lone pipe-bearing line is ordinary prose.
            guard index + 1 < lines.count,
                  isCandidateRow(text[lines[index]]),
                  isDelimiterRow(text[lines[index + 1]])
            else {
                index += 1
                continue
            }

            let headers = cells(in: text[lines[index]])
            var rows: [[String]] = []
            var last = index + 1
            var body = index + 2

            while body < lines.count, isCandidateRow(text[lines[body]]) {
                rows.append(cells(in: text[lines[body]]))
                last = body
                body += 1
            }

            matches.append(MarkdownTableMatch(table: MarkdownTable(headers: headers, rows: rows),
                                              range: lines[index].lowerBound..<lines[last].upperBound))
            index = body
        }

        return matches
    }

    // MARK: - Substituting into a message

    /// Replaces every table in `attributed` with its rendered block, returning the ranges the blocks
    /// occupy in the result so the caller can apply a monospaced font and a tap target.
    ///
    /// Attributes outside the tables are preserved: mentions are carried as attributes on the message
    /// text, and losing them would strip a mention of both its styling and its link.
    static func substituting(in attributed: NSAttributedString,
                             maxCharactersPerLine: Int = .max) -> (NSMutableAttributedString, [NSRange]) {
        let result = NSMutableAttributedString(attributedString: attributed)
        let matches = tables(in: attributed.string)

        guard !matches.isEmpty else { return (result, []) }

        var ranges: [NSRange] = []
        var offset = 0

        // Forwards, carrying an offset: each replacement changes the length of the string, so ranges
        // measured against the original have to be shifted by everything replaced before them.
        for match in matches {
            let original = NSRange(match.range, in: attributed.string)
            let target = NSRange(location: original.location + offset, length: original.length)
            let source = String(attributed.string[match.range])

            // A block wider than the bubble wraps every line, and a wrapped monospaced grid is
            // harder to read than no grid at all — the separator row alone sprawls over several
            // lines. Past that width, show a stand-in and let the viewer render the real table.
            let grid = render(match.table)
            let rendered = widestLine(of: grid) <= maxCharactersPerLine ? grid : placeholder(for: match.table)
            let renderedLength = (rendered as NSString).length

            result.replaceCharacters(in: target, with: rendered)

            let replaced = NSRange(location: target.location, length: renderedLength)

            // Carried on both paths: an inline table is tappable too, so the full grid, with its
            // real columns and horizontal scrolling, is always one tap away.
            result.addAttribute(tableAttribute, value: source, range: replaced)

            ranges.append(replaced)
            offset += renderedLength - original.length
        }

        return (result, ranges)
    }

    /// Marks a substituted table and carries its original markdown, so a tap can hand the source to
    /// `MarkdownViewerViewController` without having to reconstruct it.
    static let tableAttribute = NSAttributedString.Key("NCMarkdownTableSource")

    /// Scheme used to route a tap on a table through the text view's own link handling, which is
    /// where room links already go. The host carries no data; the markdown comes from
    /// ``tableAttribute`` on the tapped range.
    static let tapURLScheme = "nctalk-table"
    static let tapURL = URL(string: "\(tapURLScheme)://open")

    private static func widestLine(of text: String) -> Int {
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(\.count).max() ?? 0
    }

    private static func placeholder(for table: MarkdownTable) -> String {
        let columns = ([table.headers] + table.rows).map(\.count).max() ?? 0
        let format = NSLocalizedString("Table, %1$d columns and %2$d rows. Tap to view.",
                                       comment: "Stand-in for a table too wide to show in a message")

        return String(format: format, columns, table.rows.count)
    }

    // MARK: - Rendering

    /// Lays the table out as monospaced text with the columns padded so the pipes line up. This is
    /// not a real table — `NSTextTable` is not usable inside the chat cells' height calculation —
    /// but it keeps the data aligned and readable in a bubble.
    static func render(_ table: MarkdownTable) -> String {
        let widths = columnWidths(of: table)

        guard !widths.isEmpty else { return "" }

        let separator = widths.map { String(repeating: "-", count: $0) }.joined(separator: "-+-")
        let body = table.rows.map { line(cells: $0, widths: widths) }

        return ([line(cells: table.headers, widths: widths), separator] + body).joined(separator: "\n")
    }

    private static func line(cells: [String], widths: [Int]) -> String {
        let padded = widths.enumerated().map { index, width -> String in
            let cell = index < cells.count ? cells[index] : ""
            return cell.padding(toLength: max(width, cell.count), withPad: " ", startingAt: 0)
        }

        // Trailing padding would be invisible but would still widen the text view's measured size.
        return padded.joined(separator: " | ").replacingOccurrences(of: "\\s+$", with: "",
                                                                   options: .regularExpression)
    }

    /// Rows may be ragged — GFM tolerates a row with more or fewer cells than the header.
    private static func columnWidths(of table: MarkdownTable) -> [Int] {
        let count = ([table.headers] + table.rows).map(\.count).max() ?? 0

        return (0..<count).map { index in
            ([table.headers] + table.rows).reduce(0) { widest, cells in
                max(widest, index < cells.count ? cells[index].count : 0)
            }
        }
    }

    // MARK: - Recognising rows

    private static func isCandidateRow(_ line: Substring) -> Bool {
        return line.contains("|")
    }

    private static func isCodeFence(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    /// `| --- | :-- |` and friends. Every cell must be dashes, optionally anchored by colons.
    private static func isDelimiterRow(_ line: Substring) -> Bool {
        let cells = self.cells(in: line)

        guard !cells.isEmpty else { return false }

        return cells.allSatisfy { cell in
            guard !cell.isEmpty else { return false }

            var body = Substring(cell)
            if body.hasPrefix(":") { body = body.dropFirst() }
            if body.hasSuffix(":") { body = body.dropLast() }

            return !body.isEmpty && body.allSatisfy { $0 == "-" }
        }
    }

    private static func cells(in line: Substring) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)

        // The outer pipes are optional in GFM; dropping them avoids a phantom empty cell at each end.
        if trimmed.hasPrefix("|") { trimmed = String(trimmed.dropFirst()) }
        if trimmed.hasSuffix("|") { trimmed = String(trimmed.dropLast()) }

        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Line scanning

    private static func lineRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start = text.startIndex

        while start <= text.endIndex {
            let end = text[start...].firstIndex(of: "\n") ?? text.endIndex
            ranges.append(start..<end)

            if end == text.endIndex { break }
            start = text.index(after: end)
        }

        return ranges
    }
}
