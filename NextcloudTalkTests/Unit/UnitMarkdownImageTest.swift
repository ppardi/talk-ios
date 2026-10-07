//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

final class UnitMarkdownImageTest: XCTestCase {

    /// A one-pixel transparent GIF, as a base64 payload without the `data:` prefix.
    private static let onePixelGIFBase64 = "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"

    private static func dataURI(mime: String = "image/gif",
                                base64: String = onePixelGIFBase64) -> String {
        return "data:\(mime);base64,\(base64)"
    }

    // MARK: - Finding images

    func testParsesARemoteImage() throws {
        let matches = MarkdownImageFormatter.images(in: "look: ![avatar](https://berylave.com/avatar/claude/64)")

        XCTAssertEqual(matches.count, 1)

        let image = try XCTUnwrap(matches.first).image
        XCTAssertEqual(image.alt, "avatar")
        XCTAssertEqual(image.source, "https://berylave.com/avatar/claude/64")
    }

    func testParsesADataURIImage() throws {
        let uri = Self.dataURI()
        let matches = MarkdownImageFormatter.images(in: "![spinner](\(uri))")

        XCTAssertEqual(matches.count, 1)

        let image = try XCTUnwrap(matches.first).image
        XCTAssertEqual(image.alt, "spinner")
        XCTAssertEqual(image.source, uri)
    }

    func testParsesAnImageWithATitle() throws {
        // `![alt](src "title")` is valid GFM; the title must not end up inside the source.
        let matches = MarkdownImageFormatter.images(in: "![a](https://example.com/x.png \"A picture\")")

        XCTAssertEqual(try XCTUnwrap(matches.first).image.source, "https://example.com/x.png")
    }

    func testIgnoresAnOrdinaryLink() throws {
        // Without the leading bang this is a link, which CDMarkdownKit already handles.
        XCTAssertEqual(MarkdownImageFormatter.images(in: "[avatar](https://berylave.com/a.gif)").count, 0)
    }

    func testIgnoresImagesInsideAFencedCodeBlock() throws {
        // Someone showing a colleague how to embed an image must get their example back verbatim.
        let markdown = """
        Write it like this:

        ```
        ![spinner](https://example.com/spinner.gif)
        ```
        """

        XCTAssertEqual(MarkdownImageFormatter.images(in: markdown).count, 0)
    }

    func testIgnoresImagesInsideInlineCode() throws {
        // More likely than the fenced case for images: explaining the syntax in a sentence.
        let markdown = "Write `![alt](url)` to embed one, like ![real](https://example.com/x.png)"

        let matches = MarkdownImageFormatter.images(in: markdown)

        XCTAssertEqual(matches.count, 1, "only the image outside the backticks should match")
        XCTAssertEqual(try XCTUnwrap(matches.first).image.alt, "real")
    }

    func testFindsEveryImageInAMessage() throws {
        // The substitution walks these in order carrying an offset, so a missed second match or a
        // wrong second range corrupts everything after it.
        let markdown = "![one](https://example.com/1.png) and ![two](https://example.com/2.png)"

        let matches = MarkdownImageFormatter.images(in: markdown)

        XCTAssertEqual(matches.map { $0.image.alt }, ["one", "two"])
        XCTAssertEqual(matches.map { String(markdown[$0.range]) },
                       ["![one](https://example.com/1.png)", "![two](https://example.com/2.png)"])
    }

    func testParsesAnImageWithEmptyAltText() throws {
        XCTAssertEqual(MarkdownImageFormatter.images(in: "![](https://example.com/x.png)").count, 1)
    }

    // MARK: - Deciding what may be loaded

    func testAcceptsAnImageDataURI() throws {
        guard case .data(let data) = MarkdownImageFormatter.source(for: Self.dataURI()) else {
            return XCTFail("an image/gif data URI should be usable")
        }

        // GIF87a/GIF89a magic, so we know the payload really was decoded rather than passed through.
        XCTAssertEqual(String(decoding: data.prefix(3), as: UTF8.self), "GIF")
    }

    func testAcceptsAnHTTPSImage() throws {
        guard case .remote(let url) = MarkdownImageFormatter.source(for: "https://example.com/x.png") else {
            return XCTFail("an https image should be usable")
        }

        XCTAssertEqual(url.absoluteString, "https://example.com/x.png")
    }

    func testRejectsAFileURL() throws {
        // A message is other people's content; it must not be able to name a path on this device.
        guard case .unsupported = MarkdownImageFormatter.source(for: "file:///etc/passwd") else {
            return XCTFail("a file URL must not be loaded")
        }
    }

    func testRejectsANonImageDataURI() throws {
        guard case .unsupported = MarkdownImageFormatter.source(for: Self.dataURI(mime: "text/html")) else {
            return XCTFail("only image payloads may be decoded")
        }
    }

    func testRejectsAnUnknownScheme() throws {
        for source in ["javascript:alert(1)", "nctalk-table://open", "ftp://example.com/x.png", ""] {
            guard case .unsupported = MarkdownImageFormatter.source(for: source) else {
                return XCTFail("should not be usable: \(source)")
            }
        }
    }

    func testRejectsAnOversizedDataURI() throws {
        // The payload is held for the lifetime of the message's cached attributed string, so a blob
        // that would never render usefully is refused before it is decoded.
        let oversized = String(repeating: "A", count: (MarkdownImageFormatter.maximumDecodedBytes + 1024) * 2)

        guard case .unsupported = MarkdownImageFormatter.source(for: Self.dataURI(base64: oversized)) else {
            return XCTFail("an oversized payload must be refused")
        }
    }

    // MARK: - Substituting into a message

    /// A solid-color PNG of a known point size, as a `data:` URI.
    private static func imageDataURI(width: CGFloat, height: CGFloat) -> String {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1

        let size = CGSize(width: width, height: height)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }

        return "data:image/png;base64,\(image.pngData()!.base64EncodedString())"
    }

    private func attachments(in attributed: NSAttributedString) -> [NSTextAttachment] {
        var found: [NSTextAttachment] = []

        attributed.enumerateAttribute(.attachment,
                                      in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { found.append(attachment) }
        }

        return found
    }

    func testSubstitutesADataImageInline() throws {
        let source = NSAttributedString(string: "before ![spinner](\(Self.dataURI())) after")

        let (result, ranges) = MarkdownImageFormatter.substituting(in: source, maxWidth: 300)

        // The surrounding prose survives and the markup is gone.
        XCTAssertTrue(result.string.hasPrefix("before "))
        XCTAssertTrue(result.string.hasSuffix(" after"))
        XCTAssertFalse(result.string.contains("data:image"), "the payload should not reach the user as text")

        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(attachments(in: result).count, 1)
        XCTAssertNotNil(try XCTUnwrap(attachments(in: result).first).image,
                        "a data image is available immediately, with no loading")
    }

    func testScalesAWideImageDownToTheBubble() throws {
        let source = NSAttributedString(string: "![wide](\(Self.imageDataURI(width: 1000, height: 500)))")

        let (result, _) = MarkdownImageFormatter.substituting(in: source, maxWidth: 300)

        let attachment = try XCTUnwrap(attachments(in: result).first)
        XCTAssertEqual(attachment.bounds.width, 300, accuracy: 1, "should fill, not exceed, the bubble")
        XCTAssertEqual(attachment.bounds.height, 150, accuracy: 1, "aspect ratio should be kept")
    }

    func testDoesNotScaleASmallImageUp() throws {
        // A 64px avatar should stay a 64px avatar rather than stretching across the message.
        let source = NSAttributedString(string: "![avatar](\(Self.imageDataURI(width: 64, height: 64)))")

        let (result, _) = MarkdownImageFormatter.substituting(in: source, maxWidth: 300)

        let attachment = try XCTUnwrap(attachments(in: result).first)
        XCTAssertEqual(attachment.bounds.width, 64, accuracy: 1)
    }

    func testFallsBackToAltTextWhenTheSourceIsRefused() throws {
        // A refused source must leave something readable behind, not an invisible hole.
        let source = NSAttributedString(string: "![a diagram](file:///etc/passwd)")

        let (result, ranges) = MarkdownImageFormatter.substituting(in: source, maxWidth: 300)

        XCTAssertTrue(result.string.contains("a diagram"), "got: \(result.string)")
        XCTAssertFalse(result.string.contains("file://"), "the refused source should not be shown")
        XCTAssertEqual(attachments(in: result).count, 0)
        XCTAssertEqual(ranges.count, 0, "nothing to tap: there is no image")
    }

    func testCarriesTheSourceAndATapTargetOnTheImage() throws {
        let uri = Self.dataURI()
        let source = NSAttributedString(string: "![spinner](\(uri))")

        let (result, ranges) = MarkdownImageFormatter.substituting(in: source, maxWidth: 300)
        let range = try XCTUnwrap(ranges.first)

        let carried = result.attribute(MarkdownImageFormatter.imageAttribute,
                                       at: range.location, effectiveRange: nil) as? String
        XCTAssertEqual(carried, uri, "the viewer needs the original source to render it full size")

        let link = result.attribute(.link, at: range.location, effectiveRange: nil) as? URL
        XCTAssertEqual(link?.scheme, MarkdownImageFormatter.tapURLScheme)
        XCTAssertNotEqual(link?.scheme, MarkdownTableFormatter.tapURLScheme,
                          "image taps and table taps must not collide in the delegate")
    }

    func testSubstitutesEveryImageAndPreservesSurroundingAttributes() throws {
        // Two images exercise the offset arithmetic, and the mention guards the shared pipeline:
        // mentions are attributes on the message text and must survive the replacement.
        let uri = Self.dataURI()
        let text = NSMutableAttributedString(string: "@bill ![one](\(uri)) middle ![two](\(uri)) end")
        text.addAttribute(.link, value: "mention://bill", range: NSRange(location: 0, length: 5))

        let (result, ranges) = MarkdownImageFormatter.substituting(in: text, maxWidth: 300)

        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(attachments(in: result).count, 2)
        XCTAssertTrue(result.string.contains(" middle "), "text between the images should survive")
        XCTAssertTrue(result.string.hasSuffix(" end"))
        XCTAssertEqual(result.attribute(.link, at: 0, effectiveRange: nil) as? String, "mention://bill")

        // The second range must point at the second image, not at stale text.
        let second = try XCTUnwrap(ranges.last)
        XCTAssertNotNil(result.attribute(.attachment, at: second.location, effectiveRange: nil))
    }

    func testARemoteImageIsPendingRatherThanFetchedInline() throws {
        let source = NSAttributedString(string: "![avatar](https://berylave.com/avatar/claude/64)")

        let (result, ranges) = MarkdownImageFormatter.substituting(in: source, maxWidth: 300)

        XCTAssertEqual(ranges.count, 1)

        let attachment = try XCTUnwrap(attachments(in: result).first as? MarkdownImageAttachment)
        XCTAssertNil(attachment.image, "nothing may be fetched on the parsing thread")
        XCTAssertEqual(attachment.source, "https://berylave.com/avatar/claude/64")
        XCTAssertGreaterThan(attachment.bounds.height, 0, "a pending image still needs to reserve space")
    }

    // MARK: - The shared parse entry point

    func testImagesAreOffByDefault() throws {
        // `parseMarkdown` is shared by the chat bubbles, the conversation list and the navigation
        // bar subtitle. Only the bubbles want images: the list path is uncached and re-parses on
        // every draw, and the title is a single truncated line.
        let message = NSAttributedString(string: "![spinner](\(Self.dataURI()))")

        let parsed = SwiftMarkdownObjCBridge.parseMarkdown(markdownString: message)

        XCTAssertEqual(attachments(in: parsed).count, 0, "the default path must not decode images")
    }

    func testImagesRenderWhenTheChatAsksForThem() throws {
        let message = NSAttributedString(string: "![spinner](\(Self.dataURI()))")

        let parsed = SwiftMarkdownObjCBridge.parseMarkdown(markdownString: message, renderImages: true)

        XCTAssertEqual(attachments(in: parsed).count, 1)
    }

    func testImageAttributesSurviveTheMarkdownParser() throws {
        // CDMarkdownKit rebuilds the attributed string as it strips syntax. If it drops the image
        // attribute or the link, the tap silently does nothing — the bug that shipped in 25.99.2
        // for tables.
        let uri = Self.dataURI()
        let message = NSAttributedString(string: "![spinner](\(uri))")

        let parsed = SwiftMarkdownObjCBridge.parseMarkdown(markdownString: message, renderImages: true)

        var carried: String?
        parsed.enumerateAttribute(MarkdownImageFormatter.imageAttribute,
                                  in: NSRange(location: 0, length: parsed.length)) { value, _, _ in
            if let value = value as? String { carried = value }
        }

        XCTAssertEqual(carried, uri, "the image source did not survive parsing")
    }

    // MARK: - Loading remote images

    private func parsedRemoteImage() throws -> (NSAttributedString, MarkdownImageAttachment) {
        let source = NSAttributedString(string: "![avatar](https://example.com/avatar.png)")
        let (result, _) = MarkdownImageFormatter.substituting(in: source, maxWidth: 300)
        let attachment = try XCTUnwrap(attachments(in: result).first as? MarkdownImageAttachment)

        return (result, attachment)
    }

    func testLoadingFillsTheAttachmentInPlaceAndAnnouncesIt() throws {
        // Filling the attachment in place is what lets the message keep its cached attributed
        // string: only the row's measured height has to be thrown away, not the parse.
        let (message, attachment) = try parsedRemoteImage()
        XCTAssertTrue(attachment.isPending)

        let loaded = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { _ in }
        let loader = MarkdownImageLoader { _, completion in completion(loaded) }

        let announced = expectation(forNotification: MarkdownImageAttachment.didLoadNotification,
                                    object: attachment, handler: nil)

        loader.loadPendingImages(in: message, maxWidth: 300)

        wait(for: [announced], timeout: 2)

        XCTAssertFalse(attachment.isPending)
        XCTAssertEqual(attachment.bounds.width, 64, accuracy: 1, "bounds should follow the real image")
    }

    func testLoadingDoesNotStartTwiceForTheSameImage() throws {
        // A message is parsed once but sized repeatedly, so this runs far more often than it looks.
        let (message, _) = try parsedRemoteImage()

        var fetches = 0
        let loader = MarkdownImageLoader { _, _ in fetches += 1 }

        loader.loadPendingImages(in: message, maxWidth: 300)
        loader.loadPendingImages(in: message, maxWidth: 300)

        XCTAssertEqual(fetches, 1, "a load already in flight should not be started again")
    }

    func testLoadingIgnoresAnImageThatIsAlreadyThere() throws {
        // A data: image is drawn at parse time; there is nothing to fetch and no network to touch.
        let source = NSAttributedString(string: "![spinner](\(Self.dataURI()))")
        let (message, _) = MarkdownImageFormatter.substituting(in: source, maxWidth: 300)

        var fetches = 0
        let loader = MarkdownImageLoader { _, _ in fetches += 1 }

        loader.loadPendingImages(in: message, maxWidth: 300)

        XCTAssertEqual(fetches, 0)
    }

    func testAFailedLoadLeavesSomethingVisible() throws {
        let (message, attachment) = try parsedRemoteImage()

        let loader = MarkdownImageLoader { _, completion in completion(nil) }
        let announced = expectation(forNotification: MarkdownImageAttachment.didLoadNotification,
                                    object: attachment, handler: nil)

        loader.loadPendingImages(in: message, maxWidth: 300)

        wait(for: [announced], timeout: 2)

        XCTAssertNotNil(attachment.image, "a broken image should still show a marker, not a blank gap")
        XCTAssertLessThan(attachment.bounds.width, 100, "and should not keep reserving a full-size box")
    }

    func testFindsTheMessageCarryingAnAttachment() throws {
        // The chat view uses this to work out which visible rows need re-measuring when an image
        // arrives. If it misses, the image loads but the row never grows to show it.
        let (message, attachment) = try parsedRemoteImage()

        XCTAssertTrue(message.containsAttachment(attachment))
        XCTAssertFalse(NSAttributedString(string: "no images here").containsAttachment(attachment))
    }

    func testAnImageWrappedInALinkDegradesSanely() throws {
        // `[![alt](img)](href)` is common in READMEs. The image pass replaces the inner image and
        // CDMarkdownKit then consumes the surrounding link, so the image is what remains: not the
        // viewer tap, but no raw markup left on screen either.
        let message = NSAttributedString(string: "[![badge](\(Self.dataURI()))](https://example.com)")

        let parsed = SwiftMarkdownObjCBridge.parseMarkdown(markdownString: message, renderImages: true)

        XCTAssertEqual(attachments(in: parsed).count, 1)
        XCTAssertFalse(parsed.string.contains("]("), "link markup should not survive: \(parsed.string)")
        XCTAssertFalse(parsed.string.contains("https://example.com"), "the href should not be shown as text")
    }

    func testOrdinaryMessagesAreUnaffected() throws {
        let message = NSAttributedString(string: "**bold** and `code` and a [link](https://example.com)")

        let parsed = SwiftMarkdownObjCBridge.parseMarkdown(markdownString: message, renderImages: true)

        XCTAssertTrue(parsed.string.contains("bold"))
        XCTAssertTrue(parsed.string.contains("link"))
        XCTAssertFalse(parsed.string.contains("**"), "bold markers should still be consumed")
        XCTAssertEqual(attachments(in: parsed).count, 0)
    }
}
