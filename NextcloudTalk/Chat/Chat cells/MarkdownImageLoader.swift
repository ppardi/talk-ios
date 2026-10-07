//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import SDWebImage
import UIKit

/// Loads the remote images in an already-parsed message.
///
/// Parsing happens on the main thread — during cell sizing and conversation-list drawing — which is
/// why `MarkdownImageFormatter` never fetches anything, and why CDMarkdownKit's own image element,
/// which calls `Data(contentsOf:)` inline, is unusable here. The fetch happens from this class
/// instead, once the text is about to be shown.
///
/// The image is written into the existing attachment rather than reparsed into a new string, so a
/// message keeps its cached attributed string and only the row's measured height is invalidated.
class MarkdownImageLoader {

    /// Injected so tests can drive the fill-in-place behavior without touching the network.
    typealias Fetch = (URL, @escaping (UIImage?) -> Void) -> Void

    static let shared = MarkdownImageLoader()

    private let fetch: Fetch

    init(fetch: @escaping Fetch = MarkdownImageLoader.fetchWithSDWebImage) {
        self.fetch = fetch
    }

    private static func fetchWithSDWebImage(url: URL, completion: @escaping (UIImage?) -> Void) {
        SDWebImageManager.shared.loadImage(with: url, options: [], progress: nil) { image, _, _, _, _, _ in
            completion(image)
        }
    }

    /// Starts a load for every remote image in `attributed` that is not already drawn or in flight.
    func loadPendingImages(in attributed: NSAttributedString?, maxWidth: CGFloat) {
        guard let attributed, attributed.length > 0 else { return }

        attributed.enumerateAttribute(.attachment,
                                      in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            guard let attachment = value as? MarkdownImageAttachment,
                  attachment.isPending,
                  !attachment.isLoading,
                  case .remote(let url) = MarkdownImageFormatter.source(for: attachment.source)
            else { return }

            attachment.isLoading = true

            self.fetch(url) { image in
                attachment.isLoading = false

                self.onMain { self.finish(attachment, with: image, maxWidth: maxWidth) }
            }
        }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func finish(_ attachment: MarkdownImageAttachment, with image: UIImage?, maxWidth: CGFloat) {
        if let image {
            attachment.image = image
            attachment.bounds = MarkdownImageFormatter.bounds(for: image.size, maxWidth: maxWidth)
        } else {
            // A marker rather than the blank reserved box, so a broken image reads as a broken image.
            // The alt text stays on the attachment as its accessibility label. Setting an image also
            // clears `isPending`, so a failing URL is not retried on every sizing pass.
            attachment.image = UIImage(systemName: "photo")?.withTintColor(.secondaryLabel,
                                                                          renderingMode: .alwaysOriginal)
            attachment.bounds = CGRect(x: 0, y: 0, width: 24, height: 24)
        }

        NotificationCenter.default.post(name: MarkdownImageAttachment.didLoadNotification, object: attachment)
    }
}
