//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

final class UnitMarkdownTableTest: XCTestCase {

    func testParsesASimpleTable() throws {
        let markdown = """
        | Name | Qty |
        | --- | --- |
        | Apples | 3 |
        | Pears | 12 |
        """

        let tables = MarkdownTableFormatter.tables(in: markdown)

        XCTAssertEqual(tables.count, 1)

        let table = try XCTUnwrap(tables.first).table
        XCTAssertEqual(table.headers, ["Name", "Qty"])
        XCTAssertEqual(table.rows, [["Apples", "3"], ["Pears", "12"]])
    }

    func testRendersColumnsPaddedToAFixedWidth() throws {
        let table = MarkdownTable(headers: ["Name", "Qty"],
                                  rows: [["Apples", "3"], ["Pears", "12"]])

        // Column width is the widest cell in that column, header included, so the pipes line up
        // when shown in a monospaced font. Trailing padding is trimmed so the block carries no
        // invisible whitespace.
        let expected = """
        Name   | Qty
        -------+----
        Apples | 3
        Pears  | 12
        """

        XCTAssertEqual(MarkdownTableFormatter.render(table), expected)
    }

    func testIgnoresTablesInsideAFencedCodeBlock() throws {
        // Someone showing a colleague how to write a table must get their example back verbatim.
        let markdown = """
        Write it like this:

        ```
        | Name | Qty |
        | --- | --- |
        | Apples | 3 |
        ```
        """

        XCTAssertEqual(MarkdownTableFormatter.tables(in: markdown).count, 0)
    }

    func testSubstitutesTablesInPlaceAndReportsTheirRanges() throws {
        let source = NSAttributedString(string: """
        Here are the numbers:

        | Name | Qty |
        | --- | --- |
        | Apples | 3 |

        Thanks!
        """)

        let (result, ranges) = MarkdownTableFormatter.substituting(in: source)

        // The surrounding prose is untouched...
        XCTAssertTrue(result.string.hasPrefix("Here are the numbers:"))
        XCTAssertTrue(result.string.hasSuffix("Thanks!"))

        // ...the delimiter row is gone, replaced by the aligned block...
        XCTAssertFalse(result.string.contains("| --- |"))
        XCTAssertTrue(result.string.contains("Name   | Qty"))
        XCTAssertTrue(result.string.contains("Apples | 3"))

        // ...and the caller is told where the table landed, so it can style and make it tappable.
        XCTAssertEqual(ranges.count, 1)
        let substituted = (result.string as NSString).substring(with: try XCTUnwrap(ranges.first))
        XCTAssertEqual(substituted, "Name   | Qty\n-------+----\nApples | 3")
    }

    func testSubstitutingPreservesAttributesOnSurroundingText() throws {
        // Mentions are carried as attributes on the message text. Replacing a table must not
        // disturb them, or a mention next to a table would lose its styling and its link.
        let source = NSMutableAttributedString(string: "@bill\n\n| A | B |\n| --- | --- |\n| 1 | 2 |")
        let mention = NSRange(location: 0, length: 5)
        source.addAttribute(.link, value: "mention://bill", range: mention)

        let (result, _) = MarkdownTableFormatter.substituting(in: source)

        XCTAssertEqual(result.attribute(.link, at: 0, effectiveRange: nil) as? String, "mention://bill")
    }

    func testBridgeRendersATableAsAlignedMonospacedText() throws {
        let message = NSAttributedString(string: "| Name | Qty |\n| --- | --- |\n| Apples | 3 |")

        let parsed = SwiftMarkdownObjCBridge.parseMarkdown(markdownString: message)

        XCTAssertTrue(parsed.string.contains("Name   | Qty"), "columns should be padded, got: \(parsed.string)")
        XCTAssertFalse(parsed.string.contains("| --- |"), "the delimiter row should be gone")

        let font = parsed.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        XCTAssertEqual(font, .monospacedPreferredFont(forTextStyle: .body))
    }

    func testBridgeLeavesOrdinaryMessagesAlone() throws {
        // Regression guard on the shared message pipeline: the table pre-pass must be invisible to
        // every message that is not a table.
        let message = NSAttributedString(string: "**bold** and `code` and a list:\n- one\n- two")

        let parsed = SwiftMarkdownObjCBridge.parseMarkdown(markdownString: message)

        XCTAssertTrue(parsed.string.contains("bold"))
        XCTAssertTrue(parsed.string.contains("code"))
        XCTAssertTrue(parsed.string.contains("one"))
        XCTAssertTrue(parsed.string.contains("two"))
        XCTAssertFalse(parsed.string.contains("**"), "bold markers should still be consumed")
    }

    func testKeepsANarrowTableInlineAndTagsIt() throws {
        let source = NSAttributedString(string: "| A | B |\n| --- | --- |\n| 1 | 2 |")

        let (result, ranges) = MarkdownTableFormatter.substituting(in: source, maxCharactersPerLine: 80)

        XCTAssertTrue(result.string.contains("A | B"), "a table this narrow should stay inline")

        // Even an inline table is tappable, so the full grid is always reachable.
        let range = try XCTUnwrap(ranges.first)
        let carried = result.attribute(MarkdownTableFormatter.tableAttribute, at: range.location,
                                       effectiveRange: nil) as? String
        XCTAssertEqual(carried, source.string, "the original markdown should ride along for the viewer")
    }

    func testReplacesATooWideTableWithATapTarget() throws {
        // Paul's real case: a column of prose makes the block far wider than a phone bubble, and
        // rendering it inline wraps every line into an unreadable mess — worse than showing nothing.
        let source = NSAttributedString(string: """
        | name | dates | purpose |
        | --- | --- | --- |
        | fit | Jan 2022 - Dec 2024 | the part I was allowed to look at freely: explore, test ideas, form rules |
        """)

        let (result, ranges) = MarkdownTableFormatter.substituting(in: source, maxCharactersPerLine: 32)

        XCTAssertFalse(result.string.contains("---+---"), "the grid should not be rendered inline")
        XCTAssertFalse(result.string.contains("explore, test ideas"), "cell prose should not be inlined")
        XCTAssertEqual(ranges.count, 1)

        // The stand-in says what it is and that it can be opened.
        XCTAssertTrue(result.string.contains("3"), "should mention the shape, got: \(result.string)")

        let carried = result.attribute(MarkdownTableFormatter.tableAttribute,
                                       at: try XCTUnwrap(ranges.first).location,
                                       effectiveRange: nil) as? String
        XCTAssertEqual(carried, source.string, "the viewer needs the original markdown to render")
    }

    func testTableAttributeSurvivesTheMarkdownParser() throws {
        // The tap handler reads this attribute off the *parsed* string. CDMarkdownKit rebuilds the
        // attributed string as it strips syntax, so if it drops unknown keys the tap silently does
        // nothing — which is exactly what a device test showed.
        let message = NSAttributedString(string: "| A | B |\n| --- | --- |\n| 1 | 2 |")

        let parsed = SwiftMarkdownObjCBridge.parseMarkdown(markdownString: message)

        var found: String?
        parsed.enumerateAttribute(MarkdownTableFormatter.tableAttribute,
                                  in: NSRange(location: 0, length: parsed.length)) { value, _, _ in
            if let value = value as? String { found = value }
        }

        XCTAssertEqual(found, message.string, "the table attribute did not survive parsing")
    }

    func testParsedTableCarriesATappableLink() throws {
        // The tap is routed through the text view's own link handling. Without a .link attribute on
        // the range the delegate is never called and tapping does nothing, which is what shipped in
        // 25.99.2.
        let message = NSAttributedString(string: "| A | B |\n| --- | --- |\n| 1 | 2 |")

        let parsed = SwiftMarkdownObjCBridge.parseMarkdown(markdownString: message)

        var link: URL?
        parsed.enumerateAttribute(.link, in: NSRange(location: 0, length: parsed.length)) { value, _, _ in
            if let value = value as? URL { link = value }
        }

        XCTAssertEqual(link?.scheme, MarkdownTableFormatter.tapURLScheme,
                       "the table range should carry the table tap link")
    }

    func testIgnoresProseThatMerelyContainsPipes() throws {
        // Regression guard: every ordinary message with a pipe in it must survive untouched. A
        // delimiter row is what makes a table a table.
        let notTables = [
            "Run `ps aux | grep talk` and tell me what you see",
            "a | b",
            "| this looks like a row but has no delimiter |",
            "| --- | --- |",
            "Pipes | in | prose\nand a second line | with more"
        ]

        for text in notTables {
            XCTAssertEqual(MarkdownTableFormatter.tables(in: text).count, 0,
                           "should not have found a table in: \(text)")
        }
    }
}
