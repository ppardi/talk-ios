//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit
import WebKit

/// Renders markdown in-app.
///
/// `QLPreviewController` has no markdown renderer — the `.md` UTI conforms to `public.plain-text`,
/// so QuickLook shows the source — and CDMarkdownKit, which styles chat messages, has no table
/// element. This hosts the same markdown the web client shows, rendered locally from the file we
/// already downloaded, so it needs no authenticated session and works offline.
@objcMembers class MarkdownViewerViewController: UIViewController {

    private let markdown: String
    private let webView: WKWebView

    private static let resourceDirectory = "Markdown"
    private static let shellName = "MarkdownViewer"

    /// Extensions QuickLook would show as plain text. `markdown` and `mdown` are the other spellings
    /// the Files app and Nextcloud Text accept.
    static let supportedFileExtensions = ["md", "markdown", "mdown", "mkd"]

    // MARK: - Lifecycle

    init(markdown: String, title: String) {
        self.markdown = markdown

        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.allowsInlineMediaPlayback = false
        // The document is another user's content; nothing in it should be able to reach the network
        // or persist anything, so give it an ephemeral, cookie-less store.
        configuration.websiteDataStore = .nonPersistent()

        self.webView = WKWebView(frame: .zero, configuration: configuration)

        super.init(nibName: nil, bundle: nil)

        self.title = title
    }

    /// Reads a downloaded markdown file. Returns nil when the bytes are not text we can show, so the
    /// caller can fall back to QuickLook rather than presenting an empty viewer.
    convenience init?(fileURL: URL) {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }

        // Most markdown is UTF-8, but a file written on Windows may not be.
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)

        guard let text else { return nil }

        self.init(markdown: text, title: fileURL.lastPathComponent)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        self.view.backgroundColor = .systemBackground
        self.webView.navigationDelegate = self
        self.webView.scrollView.contentInsetAdjustmentBehavior = .always
        self.webView.isOpaque = false
        self.webView.backgroundColor = .systemBackground

        self.webView.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(self.webView)
        NSLayoutConstraint.activate([
            self.webView.topAnchor.constraint(equalTo: self.view.topAnchor),
            self.webView.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
            self.webView.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            self.webView.trailingAnchor.constraint(equalTo: self.view.trailingAnchor)
        ])

        self.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done,
                                                                 primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })

        self.loadShell()
    }

    // MARK: - Loading

    private func loadShell() {
        guard let shell = Bundle.main.url(forResource: Self.shellName, withExtension: "html",
                                          subdirectory: Self.resourceDirectory)
                ?? Bundle.main.url(forResource: Self.shellName, withExtension: "html") else {
            assertionFailure("MarkdownViewer.html is missing from the bundle")
            return
        }

        // Xcode flattens these resources into the bundle root, so this grants read access to the
        // bundle rather than to a private folder. That is acceptable only because no script from
        // the document can ever run here: every html token is re-escaped in the shell, so a
        // `<script>` in the markdown becomes visible text. The escaping is the control, not this
        // path.
        self.webView.loadFileURL(shell, allowingReadAccessTo: shell.deletingLastPathComponent())
    }

    /// The document is passed as a JavaScript *argument*, never interpolated into the page source,
    /// so no amount of quoting or escaping in the file can break out of its string context.
    private func render() {
        self.webView.callAsyncJavaScript("return renderMarkdown(source)",
                                         arguments: ["source": self.markdown],
                                         in: nil,
                                         in: .page) { result in
            if case .failure(let error) = result {
                print("Rendering markdown failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - WKNavigationDelegate

extension MarkdownViewerViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.render()
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        // Only our own bundled shell may load in this web view.
        if url.isFileURL {
            decisionHandler(.allow)
            return
        }

        // A link the user deliberately tapped opens outside the app; the viewer itself never
        // navigates anywhere, so a document cannot redirect it or load remote content on its own.
        if navigationAction.navigationType == .linkActivated,
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            UIApplication.shared.open(url)
        }

        decisionHandler(.cancel)
    }
}
