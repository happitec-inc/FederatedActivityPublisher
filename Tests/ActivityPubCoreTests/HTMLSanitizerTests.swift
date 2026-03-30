import Testing
@testable import ActivityPubCore

@Suite("HTML Sanitizer")
struct HTMLSanitizerTests {

    @Test("Allowed tags pass through unchanged")
    func allowedTagsPassThrough() {
        #expect(HTMLSanitizer.sanitize("<p>Hello</p>") == "<p>Hello</p>")
        #expect(HTMLSanitizer.sanitize("<em>italic</em>") == "<em>italic</em>")
        #expect(HTMLSanitizer.sanitize("<strong>bold</strong>") == "<strong>bold</strong>")
        #expect(HTMLSanitizer.sanitize("<b>bold</b>") == "<b>bold</b>")
        #expect(HTMLSanitizer.sanitize("<i>italic</i>") == "<i>italic</i>")
        #expect(HTMLSanitizer.sanitize("<u>underline</u>") == "<u>underline</u>")
        #expect(HTMLSanitizer.sanitize("<del>deleted</del>") == "<del>deleted</del>")
        #expect(HTMLSanitizer.sanitize("<pre>preformatted</pre>") == "<pre>preformatted</pre>")
        #expect(HTMLSanitizer.sanitize("<code>code</code>") == "<code>code</code>")
        #expect(HTMLSanitizer.sanitize("<blockquote>quote</blockquote>") == "<blockquote>quote</blockquote>")
        #expect(HTMLSanitizer.sanitize("<ul><li>item</li></ul>") == "<ul><li>item</li></ul>")
        #expect(HTMLSanitizer.sanitize("<ol><li>item</li></ol>") == "<ol><li>item</li></ol>")
    }

    @Test("Disallowed tags stripped, content preserved")
    func disallowedTagsStrippedContentPreserved() {
        #expect(HTMLSanitizer.sanitize("<script>alert('xss')</script>") == "alert('xss')")
        #expect(HTMLSanitizer.sanitize("<div><p>text</p></div>") == "<p>text</p>")
        #expect(HTMLSanitizer.sanitize("<img src=\"evil.jpg\">visible text") == "visible text")
    }

    @Test("Attributes stripped except href on <a> and class on <span>")
    func attributesStrippedExceptAllowed() {
        #expect(HTMLSanitizer.sanitize(
            "<a href=\"https://example.com\" onclick=\"evil()\">link</a>"
        ) == "<a href=\"https://example.com\" rel=\"nofollow noopener noreferrer\">link</a>")
        #expect(HTMLSanitizer.sanitize(
            "<p style=\"color:red\">text</p>"
        ) == "<p>text</p>")
    }

    @Test("Non-http(s) URI schemes stripped from href (positive allowlist)")
    func hrefPositiveAllowlist() {
        #expect(HTMLSanitizer.sanitize(
            "<a href=\"javascript:alert(1)\">link</a>"
        ) == "<a rel=\"nofollow noopener noreferrer\">link</a>")
        #expect(HTMLSanitizer.sanitize(
            "<a href=\"data:text/html,test\">link</a>"
        ) == "<a rel=\"nofollow noopener noreferrer\">link</a>")
        #expect(HTMLSanitizer.sanitize(
            "<a href=\"vbscript:MsgBox\">link</a>"
        ) == "<a rel=\"nofollow noopener noreferrer\">link</a>")
        #expect(HTMLSanitizer.sanitize(
            "<a href=\"blob:https://evil.com/abc\">link</a>"
        ) == "<a rel=\"nofollow noopener noreferrer\">link</a>")
        #expect(HTMLSanitizer.sanitize(
            "<a href=\"https://example.com\">link</a>"
        ) == "<a href=\"https://example.com\" rel=\"nofollow noopener noreferrer\">link</a>")
        #expect(HTMLSanitizer.sanitize(
            "<a href=\"http://example.com\">link</a>"
        ) == "<a href=\"http://example.com\" rel=\"nofollow noopener noreferrer\">link</a>")
    }

    @Test("Self-closing tags handled")
    func selfClosingTagsHandled() {
        #expect(HTMLSanitizer.sanitize("<br>") == "<br>")
        #expect(HTMLSanitizer.sanitize("<br/>") == "<br>")
        #expect(HTMLSanitizer.sanitize("<br />") == "<br>")
    }

    @Test("Nested allowed and disallowed tags")
    func nestedAllowedAndDisallowed() {
        #expect(HTMLSanitizer.sanitize(
            "<div><p><strong>bold</strong></p></div>"
        ) == "<p><strong>bold</strong></p>")
    }

    @Test("Malformed HTML handled gracefully")
    func malformedHTML() {
        // Unclosed tags -- best effort
        let result = HTMLSanitizer.sanitize("<p>text")
        #expect(result.contains("text"))
        // Extra closing tags stripped
        let result2 = HTMLSanitizer.sanitize("</p>text</p>")
        #expect(result2.contains("text"))
    }

    @Test("HTML entities preserved")
    func htmlEntitiesPreserved() {
        #expect(HTMLSanitizer.sanitize("<p>&amp; &lt; &gt; &#39;</p>") == "<p>&amp; &lt; &gt; &#39;</p>")
    }

    @Test("Empty and whitespace input")
    func emptyAndWhitespaceInput() {
        #expect(HTMLSanitizer.sanitize("") == "")
        #expect(HTMLSanitizer.sanitize("   ") == "   ")
    }

    @Test("Real-world Mastodon Note HTML")
    func realWorldMastodonHTML() {
        let input = """
        <p><span class="h-card"><a href="https://mastodon.social/@user" class="u-url mention">@<span>user</span></a></span> Check out <a href="https://example.com" target="_blank" rel="nofollow noopener noreferrer">example.com</a></p>
        """
        let expected = """
        <p><span class="h-card"><a href="https://mastodon.social/@user" rel="nofollow noopener noreferrer">@<span>user</span></a></span> Check out <a href="https://example.com" rel="nofollow noopener noreferrer">example.com</a></p>
        """
        #expect(HTMLSanitizer.sanitize(input) == expected)
    }

    @Test("Span class allowlist filtering")
    func spanClassAllowlist() {
        #expect(HTMLSanitizer.sanitize(
            "<span class=\"h-card mention\">@user</span>"
        ) == "<span class=\"h-card mention\">@user</span>")
        #expect(HTMLSanitizer.sanitize(
            "<span class=\"h-card evil-class\">@user</span>"
        ) == "<span class=\"h-card\">@user</span>")
        #expect(HTMLSanitizer.sanitize(
            "<span class=\"evil-only\">text</span>"
        ) == "<span>text</span>")
        // All five allowed classes
        #expect(HTMLSanitizer.sanitize(
            "<span class=\"invisible\">hidden</span>"
        ) == "<span class=\"invisible\">hidden</span>")
        #expect(HTMLSanitizer.sanitize(
            "<span class=\"ellipsis\">...</span>"
        ) == "<span class=\"ellipsis\">...</span>")
        #expect(HTMLSanitizer.sanitize(
            "<span class=\"hashtag\">#tag</span>"
        ) == "<span class=\"hashtag\">#tag</span>")
    }

    @Test("rel attribute always added to <a> tags")
    func relAttributeAlwaysAdded() {
        #expect(HTMLSanitizer.sanitize(
            "<a href=\"https://example.com\">link</a>"
        ) == "<a href=\"https://example.com\" rel=\"nofollow noopener noreferrer\">link</a>")
        // Existing rel is replaced
        #expect(HTMLSanitizer.sanitize(
            "<a href=\"https://example.com\" rel=\"nofollow\">link</a>"
        ) == "<a href=\"https://example.com\" rel=\"nofollow noopener noreferrer\">link</a>")
    }

    @Test("Case-insensitive tag matching")
    func caseInsensitiveTagMatching() {
        #expect(HTMLSanitizer.sanitize("<SCRIPT>xss</SCRIPT>") == "xss")
        #expect(HTMLSanitizer.sanitize(
            "<A HREF=\"https://example.com\">link</A>"
        ) == "<a href=\"https://example.com\" rel=\"nofollow noopener noreferrer\">link</a>")
    }
}
