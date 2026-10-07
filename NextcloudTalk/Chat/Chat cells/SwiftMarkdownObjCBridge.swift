//
// SPDX-FileCopyrightText: 2023 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import CDMarkdownKit
import UIKit

@objcMembers class SwiftMarkdownObjCBridge: NSObject {

    static let markdownParser: CDMarkdownParser = {
        let markdownParser = CDMarkdownParser(font: .preferredFont(forTextStyle: .body), fontColor: .label)

        markdownParser.code.backgroundColor = .tertiarySystemBackground
        markdownParser.code.font = .monospacedPreferredFont(forTextStyle: .body)

        markdownParser.syntax.backgroundColor = .tertiarySystemBackground
        markdownParser.syntax.font = .monospacedPreferredFont(forTextStyle: .body)

        markdownParser.squashNewlines = false
        markdownParser.overwriteExistingStyle = false
        markdownParser.trimLeadingWhitespaces = false
        markdownParser.automaticLinkDetectionEnabled = false

        markdownParser.image.enabled = false

        // Don't update the font when we have a listing/quote (to not override any mentions), just the paragraph style
        markdownParser.list.font = nil
        markdownParser.list.color = nil
        markdownParser.task.font = nil
        markdownParser.task.color = nil

        // To correctly position list elements, we need to tell CDMarkdownKit the font to use for sizing
        markdownParser.list.indicatorFont = .preferredFont(forTextStyle: .body)
        markdownParser.task.indicatorFont = .preferredFont(forTextStyle: .body)

        markdownParser.quote.font = nil
        markdownParser.quote.color = nil

        return markdownParser
    }()

    /// How many monospaced characters fit across a message bubble.
    ///
    /// The parsed result is cached on the message, which has no view, so this is an estimate from
    /// the screen rather than a measurement of the bubble: screen width less the avatar column, the
    /// cell margins and the bubble's own padding. It is re-read on every parse, so a Dynamic Type
    /// change is picked up. A rotation or an iPad split-view resize is not, until the message is
    /// re-parsed — a table near the boundary may then stay in whichever form it was built as.
    private static var maxCharactersPerLine: Int {
        let characterWidth = ("0" as NSString)
            .size(withAttributes: [.font: UIFont.monospacedPreferredFont(forTextStyle: .body)]).width

        guard characterWidth > 0 else { return 32 }

        return max(16, Int((UIScreen.main.bounds.width - 96) / characterWidth))
    }

    static func parseMarkdown(markdownString: NSAttributedString) -> NSMutableAttributedString {
        return parseMarkdown(markdownString: markdownString, renderImages: false)
    }

    /// - Parameter renderImages: draw markdown images inline. Only the chat bubbles pass true.
    ///   `NCChatMessage.parsedMarkdown`, which feeds the conversation list, is not cached and
    ///   re-parses on every draw, and `NCChatTitleView` renders a single truncated line — neither is
    ///   somewhere to be decoding images.
    static func parseMarkdown(markdownString: NSAttributedString,
                              renderImages: Bool) -> NSMutableAttributedString {
        var source: NSAttributedString = markdownString

        if renderImages {
            // Before the table pass: a table's grid is rebuilt as plain text, which would drop an
            // attachment sitting inside a cell. The image attributes are carried on the text itself,
            // so the ranges do not have to survive what the table pass does to the string.
            (source, _) = MarkdownImageFormatter.substituting(in: markdownString,
                                                              maxWidth: MarkdownImageFormatter.preferredMaxWidth)
        }

        // CDMarkdownKit has no table element, so tables would otherwise reach the user as raw pipes.
        // Substitute them for an aligned monospaced block first.
        let (substituted, tableRanges) = MarkdownTableFormatter.substituting(in: source,
                                                                            maxCharactersPerLine: maxCharactersPerLine)

        // The font is applied *before* parsing, not after: CDMarkdownKit strips syntax characters as
        // it goes, so any range measured against the pre-parse string is stale by the time it
        // returns. Attributes, unlike ranges, travel with the text. `overwriteExistingStyle` is
        // false above, so the parser leaves this font alone.
        for range in tableRanges {
            substituted.addAttribute(.font,
                                     value: UIFont.monospacedPreferredFont(forTextStyle: .body),
                                     range: range)

            // Made a real link rather than a custom hit-test: the text view already routes link taps
            // through its delegate, which is the path room links use, and it renders the range as
            // something that visibly invites a tap. A bespoke gesture recognizer competed with the
            // text view's own and silently did nothing on device.
            if let url = MarkdownTableFormatter.tapURL {
                substituted.addAttribute(.link, value: url, range: range)
            }
        }

        return NSMutableAttributedString(attributedString: markdownParser.parse(substituted))
    }

    static func getLayoutManager() -> CDMarkdownLayoutManager {
        let manager = CDMarkdownLayoutManager()
        manager.roundAllCorners = true
        return manager
    }
}
