//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
import WebKit
@testable import NextcloudTalk

/// Exercises the bundled markdown shell and marked.js directly. This covers what the pure table
/// tests cannot: that the resources actually reach the app bundle, that marked loads beside the
/// shell, and that raw HTML in a document is neutralised. All three fail silently at runtime —
/// a missing resource just renders a blank page.
final class UnitMarkdownViewerTest: XCTestCase {

    private var webView: WKWebView!

    override func setUpWithError() throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        self.webView = WKWebView(frame: .init(x: 0, y: 0, width: 390, height: 844),
                                 configuration: configuration)

        let bundle = Bundle(for: MarkdownViewerViewController.self)
        let shell = try XCTUnwrap(bundle.url(forResource: "MarkdownViewer", withExtension: "html",
                                             subdirectory: "Markdown")
                                  ?? bundle.url(forResource: "MarkdownViewer", withExtension: "html"),
                                  "MarkdownViewer.html is not in the bundle")

        self.webView.loadFileURL(shell, allowingReadAccessTo: shell.deletingLastPathComponent())
        try self.waitForLoad()
    }

    func testMarkedIsBundledAndLoads() throws {
        let type = try self.evaluate("typeof marked")

        XCTAssertEqual(type as? String, "object", "marked.min.js did not load beside the shell")
    }

    func testRendersATableAsARealTableElement() throws {
        let html = try self.render("| Name | Qty |\n| --- | --- |\n| Apples | 3 |")
        let rendered = try XCTUnwrap(html as? String)

        XCTAssertTrue(rendered.contains("<table"), "expected a real table, got: \(rendered)")
        XCTAssertTrue(rendered.contains("<th"), "expected header cells")
        XCTAssertTrue(rendered.contains("Apples"))

        // The scrolling wrapper is what keeps a wide table from forcing the whole page sideways,
        // matching the web client's `overflow-x: auto`.
        XCTAssertTrue(rendered.contains("table-scroll"), "table should be wrapped for scrolling")
    }

    func testEscapesRawHtmlInTheDocument() throws {
        // The document comes from another user. marked dropped its own sanitizer in v5, so the
        // shell re-escapes every html token; a script tag must arrive as visible text.
        let html = try self.render("Hello <script>window.pwned = true</script> there")
        let rendered = try XCTUnwrap(html as? String)

        XCTAssertFalse(rendered.lowercased().contains("<script"), "raw HTML was passed through: \(rendered)")
    }

    func testDoesNotRunInlineEventHandlersFromTheDocument() throws {
        // This is the vector that matters. `innerHTML` does NOT execute a `<script>` tag, so a test
        // that only checks for script execution passes even with escaping switched off — verified by
        // removing the escaping and watching it still pass. An inline handler on a broken image does
        // fire, so this is what proves the escaping is load-bearing.
        _ = try self.render("![x](data:,) <img src=x onerror=\"window.pwned=true\">")

        // Asserting on the HTML text would be wrong: escaped, inert markup still *contains* the
        // substring "onerror=". What matters is whether any live element carries the attribute.
        let live = try self.evaluate("document.querySelectorAll('[onerror],[onload],[onclick]').length")
        XCTAssertEqual(live as? Int, 0, "a live event-handler attribute reached the DOM")

        // Give a handler that did slip through a turn of the run loop to fire before asserting.
        let settled = self.expectation(description: "run loop turned")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        self.wait(for: [settled], timeout: 5)

        let pwned = try self.evaluate("String(window.pwned)")
        XCTAssertEqual(pwned as? String, "undefined", "an inline event handler from the document ran")
    }

    func testRendersHeadingsAndCode() throws {
        let rendered = try XCTUnwrap(try self.render("# Title\n\nSome `code` here") as? String)

        XCTAssertTrue(rendered.contains("<h1"))
        XCTAssertTrue(rendered.contains("<code"))
    }

    // MARK: - Helpers

    private func render(_ markdown: String) throws -> Any? {
        return try self.evaluate("renderMarkdown(\(Self.jsString(markdown))); " +
                                 "document.getElementById('content').innerHTML")
    }

    /// Encodes a Swift string as a JavaScript literal so test input cannot break the expression.
    private static func jsString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"

        return String(array.dropFirst().dropLast())
    }

    private func evaluate(_ script: String) throws -> Any? {
        let expectation = self.expectation(description: "evaluate \(script.prefix(40))")
        var outcome: Result<Any?, Error>!

        self.webView.evaluateJavaScript(script) { value, error in
            outcome = error.map { .failure($0) } ?? .success(value)
            expectation.fulfill()
        }

        self.wait(for: [expectation], timeout: 10)

        return try outcome.get()
    }

    private func waitForLoad() throws {
        let expectation = self.expectation(description: "shell loaded")

        // The shell is a local file with one local script; polling is simpler here than standing up
        // a navigation delegate just to learn it finished.
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            self.webView.evaluateJavaScript("typeof renderMarkdown") { value, _ in
                if value as? String == "function" {
                    timer.invalidate()
                    expectation.fulfill()
                }
            }
        }

        self.wait(for: [expectation], timeout: 15)
        timer.invalidate()
    }
}
