//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import ImageIO
import UIKit

/// An image reference parsed out of a message.
struct MarkdownImage {
    let alt: String
    let source: String
}

/// An image together with the span of source text it occupies, so a caller can replace it in place.
struct MarkdownImageMatch {
    let image: MarkdownImage
    let range: Range<String.Index>
}

/// What, if anything, we are willing to turn a `![alt](src)` source into.
enum MarkdownImageSource {
    /// A `data:` payload carried in the message itself. Nothing is fetched.
    case data(Data)
    /// An `http(s)` image that has to be loaded before it can be drawn.
    case remote(URL)
    /// A source we refuse: an unknown scheme, a non-image payload, or one too large to be worth
    /// holding in memory.
    case unsupported
}

/// Finds markdown images in a message so they can be drawn inline.
///
/// CDMarkdownKit ships an image element, but it is unusable here: `CDMarkdownImage.match` calls
/// `Data(contentsOf:)` on the parsing thread, and messages are parsed during cell sizing and during
/// conversation-list drawing. Enabling it would put a blocking network round-trip on the main
/// thread. This finds the images first instead, so the loading policy is ours.
enum MarkdownImageFormatter {

    /// Ceiling on a decoded `data:` payload. The bytes live for as long as the message's cached
    /// attributed string does, so a blob past this size is refused rather than held.
    static let maximumDecodedBytes = 2 * 1024 * 1024

    // MARK: - Finding images

    /// `![alt](src)`, with GFM's optional `"title"` after the source. The source may not contain
    /// whitespace or a closing parenthesis, which no `data:` URI or percent-encoded URL does.
    private static let pattern = "!\\[([^\\]]*)\\]\\(\\s*([^)\\s]+)(?:\\s+\"[^\"]*\")?\\s*\\)"

    private static let expression: NSRegularExpression = {
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    static func images(in text: String) -> [MarkdownImageMatch] {
        let nsText = text as NSString
        let whole = NSRange(location: 0, length: nsText.length)
        let protected = protectedRanges(in: text)

        return expression.matches(in: text, options: [], range: whole).compactMap { match in
            // An image inside a code fence or a backtick span is someone demonstrating the syntax,
            // and must reach them verbatim.
            guard !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                  let range = Range(match.range, in: text),
                  let altRange = Range(match.range(at: 1), in: text),
                  let sourceRange = Range(match.range(at: 2), in: text)
            else { return nil }

            let image = MarkdownImage(alt: String(text[altRange]), source: String(text[sourceRange]))

            return MarkdownImageMatch(image: image, range: range)
        }
    }

    // MARK: - Deciding what may be loaded

    /// Classifies a source. Nothing here touches the network: a `data:` payload is decoded from the
    /// message text, and a remote URL is only validated, never fetched.
    static func source(for raw: String) -> MarkdownImageSource {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else { return .unsupported }

        if trimmed.lowercased().hasPrefix("data:") {
            return dataSource(for: trimmed)
        }

        // An allowlist, not a denylist: a message is another user's content, and it must not be able
        // to name a path on this device or hand an arbitrary scheme to the system.
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return .unsupported }

        return .remote(url)
    }

    private static func dataSource(for uri: String) -> MarkdownImageSource {
        // Only base64 image payloads. A `text/html` payload is not something we will decode as an
        // image, whatever the markdown called it.
        guard let comma = uri.firstIndex(of: ","),
              case let header = uri[uri.startIndex..<comma].lowercased(),
              header.hasPrefix("data:image/"),
              header.hasSuffix(";base64")
        else { return .unsupported }

        let payload = String(uri[uri.index(after: comma)...])

        // Estimated from the base64 length rather than measured after decoding, so an oversized
        // payload is refused without ever being materialised.
        guard payload.count / 4 * 3 <= maximumDecodedBytes,
              let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
              data.count <= maximumDecodedBytes,
              !data.isEmpty
        else { return .unsupported }

        return .data(data)
    }

    // MARK: - Substituting into a message

    /// Marks a substituted image and carries its original source, so a tap can hand it to the
    /// markdown viewer without having to reconstruct it.
    static let imageAttribute = NSAttributedString.Key("NCMarkdownImageSource")

    /// Routes a tap on an image through the text view's own link handling, the same path room links
    /// and tables use. Deliberately distinct from the table scheme so the delegate can tell them
    /// apart.
    static let tapURLScheme = "nctalk-image"
    static let tapURL = URL(string: "\(tapURLScheme)://open")

    /// Beyond this, the remaining images fall back to their alt text. A message is free to contain a
    /// hundred of them; the cached attributed string that results is not.
    static let maximumImages = 10

    /// Keeps one tall image from taking over the conversation.
    static let maximumHeight: CGFloat = 320

    /// How wide an image may be drawn in a bubble: the screen less the avatar column, the cell
    /// margins and the bubble's own padding. Estimated from the screen rather than measured, because
    /// a message is parsed once and cached while it has no view — the same approximation
    /// `SwiftMarkdownObjCBridge` uses to decide whether a table fits.
    static var preferredMaxWidth: CGFloat {
        return max(120, UIScreen.main.bounds.width - 96)
    }

    /// Replaces every image in `attributed` with a text attachment, returning the ranges the
    /// attachments occupy so the caller can make them tappable.
    ///
    /// Nothing is fetched here. A `data:` image is decoded from the message text and is ready to
    /// draw; a remote one gets a pending attachment that reserves space until something loads it.
    static func substituting(in attributed: NSAttributedString,
                             maxWidth: CGFloat) -> (NSMutableAttributedString, [NSRange]) {
        let result = NSMutableAttributedString(attributedString: attributed)
        let matches = images(in: attributed.string)

        guard !matches.isEmpty else { return (result, []) }

        var ranges: [NSRange] = []
        var offset = 0
        var rendered = 0

        // Forwards, carrying an offset: each replacement changes the length of the string, so ranges
        // measured against the original have to be shifted by everything replaced before them.
        for match in matches {
            let original = NSRange(match.range, in: attributed.string)
            let target = NSRange(location: original.location + offset, length: original.length)

            let attachment = rendered < maximumImages
                ? attachment(for: match.image, maxWidth: maxWidth)
                : nil

            guard let attachment else {
                // Alt text rather than an empty hole, so a refused or broken image still says what
                // it was meant to be.
                let fallback = fallbackText(for: match.image)

                result.replaceCharacters(in: target, with: fallback)
                offset += (fallback as NSString).length - original.length
                continue
            }

            let replacement = NSAttributedString(attachment: attachment)

            result.replaceCharacters(in: target, with: replacement)

            let replaced = NSRange(location: target.location, length: replacement.length)

            result.addAttribute(imageAttribute, value: match.image.source, range: replaced)

            if let url = tapURL {
                result.addAttribute(.link, value: url, range: replaced)
            }

            ranges.append(replaced)
            rendered += 1
            offset += replacement.length - original.length
        }

        return (result, ranges)
    }

    private static func fallbackText(for image: MarkdownImage) -> String {
        let alt = image.alt.trimmingCharacters(in: .whitespacesAndNewlines)

        guard alt.isEmpty else { return alt }

        return NSLocalizedString("Image", comment: "Stand-in for an image that cannot be shown")
    }

    private static func attachment(for image: MarkdownImage, maxWidth: CGFloat) -> MarkdownImageAttachment? {
        switch source(for: image.source) {
        case .data(let data):
            guard let decoded = decode(data, maxWidth: maxWidth) else { return nil }

            let attachment = MarkdownImageAttachment(source: image.source, accessibilityLabel: image.alt)
            attachment.image = decoded
            attachment.bounds = bounds(for: decoded.size, maxWidth: maxWidth)

            return attachment

        case .remote:
            let attachment = MarkdownImageAttachment(source: image.source, accessibilityLabel: image.alt)

            // Space is reserved so the message does not visibly reflow around the image arriving;
            // the real aspect ratio is only known once it has loaded.
            attachment.bounds = CGRect(x: 0, y: 0, width: min(200, maxWidth), height: 120)

            return attachment

        case .unsupported:
            return nil
        }
    }

    /// Fits an image to the bubble without ever enlarging it, so a 64px avatar stays a 64px avatar.
    static func bounds(for size: CGSize, maxWidth: CGFloat) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }

        var width = min(size.width, maxWidth)
        var height = width * (size.height / size.width)

        if height > maximumHeight {
            height = maximumHeight
            width = height * (size.width / size.height)
        }

        return CGRect(x: 0, y: 0, width: width.rounded(), height: height.rounded())
    }

    /// Decodes at a bounded pixel size rather than decoding fully and shrinking afterwards: the
    /// encoded payload cap says nothing about the bitmap it expands to, and these images are held
    /// for as long as the message's cached attributed string is.
    static func decode(_ data: Data, maxWidth: CGFloat) -> UIImage? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData,
                                                            [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }

        // Enough pixels to stay sharp when drawn into a `maxWidth`-point box on this screen.
        let maximumPixels = max(1, maxWidth * UIScreen.main.scale)

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixels
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary)
        else { return nil }

        // Scale 1, so a pixel in the file is a point on screen before fitting — the same natural
        // size the web client gives an image.
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    // MARK: - Protected spans

    /// Ranges that look like markdown but must be shown as written: fenced code blocks and inline
    /// backtick spans.
    private static func protectedRanges(in text: String) -> [NSRange] {
        return fencedRanges(in: text) + inlineCodeRanges(in: text)
    }

    private static let inlineCodeExpression: NSRegularExpression = {
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: "`+[^`]*`+", options: [])
    }()

    private static func inlineCodeRanges(in text: String) -> [NSRange] {
        let whole = NSRange(location: 0, length: (text as NSString).length)

        return inlineCodeExpression.matches(in: text, options: [], range: whole).map(\.range)
    }

    private static func fencedRanges(in text: String) -> [NSRange] {
        let nsText = text as NSString
        var ranges: [NSRange] = []
        var openedAt: Int?

        nsText.enumerateSubstrings(in: NSRange(location: 0, length: nsText.length),
                                   options: [.byLines, .substringNotRequired]) { _, _, enclosing, _ in
            let line = nsText.substring(with: enclosing).trimmingCharacters(in: .whitespacesAndNewlines)

            guard line.hasPrefix("```") || line.hasPrefix("~~~") else { return }

            if let start = openedAt {
                ranges.append(NSRange(location: start, length: NSMaxRange(enclosing) - start))
                openedAt = nil
            } else {
                openedAt = enclosing.location
            }
        }

        // An unterminated fence protects the rest of the message, the way a renderer would treat it.
        if let start = openedAt {
            ranges.append(NSRange(location: start, length: nsText.length - start))
        }

        return ranges
    }
}

/// A markdown image placed in the text flow of a message.
///
/// Carries the source it came from, so a remote image can be loaded after parsing and so a tap can
/// hand the source to the viewer. Deliberately contains no networking: the share and notification
/// extensions compile this file, and the loader that fetches remote images does not live there.
class MarkdownImageAttachment: NSTextAttachment {

    let source: String

    /// Posted on the main thread once a remote image has been drawn into the attachment. The
    /// attachment is the notification's object, so an observer can find the rows to re-measure.
    static let didLoadNotification = Notification.Name("NCMarkdownImageAttachmentDidLoad")

    /// Set while a load is in flight. A message is parsed once but sized repeatedly, so without
    /// this every sizing pass would start another fetch.
    var isLoading = false

    /// A remote image that has not arrived yet. A `data:` image is never pending.
    var isPending: Bool {
        return self.image == nil
    }

    init(source: String, accessibilityLabel: String) {
        self.source = source

        super.init(data: nil, ofType: nil)

        let label = accessibilityLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accessibilityLabel = label.isEmpty
            ? NSLocalizedString("Image", comment: "Spoken description of an image in a message")
            : label
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension NSAttributedString {

    /// Whether this string draws `attachment`, compared by identity.
    ///
    /// The chat view uses this to find which visible rows have to be re-measured when a remote image
    /// arrives: the attachment is filled in place, so the row that contains it is the row whose
    /// cached height is now wrong.
    func containsAttachment(_ attachment: NSTextAttachment) -> Bool {
        var found = false

        self.enumerateAttribute(.attachment,
                                in: NSRange(location: 0, length: self.length)) { value, _, stop in
            if value as AnyObject === attachment {
                found = true
                stop.pointee = true
            }
        }

        return found
    }
}
