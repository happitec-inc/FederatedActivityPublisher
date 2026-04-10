import Testing
@testable import ActivityPubCore

@Suite("Text-to-HTML conversion")
struct TextToHTMLTests {

    // MARK: - Plain text (no markdown) -- same output as before

    @Test("Single paragraph wraps in <p>")
    func singleParagraph() {
        let result = convertTextToHTML("Hello world")
        #expect(result == "<p>Hello world</p>")
    }

    @Test("Double newline creates separate paragraphs")
    func doubleParagraph() {
        let result = convertTextToHTML("First paragraph\n\nSecond paragraph")
        #expect(result == "<p>First paragraph</p><p>Second paragraph</p>")
    }

    @Test("Single newline becomes <br>")
    func lineBreak() {
        let result = convertTextToHTML("Line one\nLine two")
        #expect(result == "<p>Line one<br>Line two</p>")
    }

    @Test("URL is autolinked in plain text")
    func urlAutolink() {
        let result = convertTextToHTML("Check out https://example.com for more")
        #expect(result == #"<p>Check out <a href="https://example.com">https://example.com</a> for more</p>"#)
    }

    @Test("HTML characters are escaped")
    func htmlEscaping() {
        let result = convertTextToHTML("Use <b>bold</b> & \"quotes\"")
        #expect(result == "<p>Use &lt;b&gt;bold&lt;/b&gt; &amp; &quot;quotes&quot;</p>")
    }

    @Test("Empty string produces empty paragraph")
    func emptyString() {
        let result = convertTextToHTML("")
        #expect(result == "<p></p>")
    }

    @Test("Mixed: paragraphs, URLs, and line breaks")
    func mixed() {
        let text = "Hello world\nVisit https://example.com\n\nNew paragraph"
        let result = convertTextToHTML(text)
        #expect(result == #"<p>Hello world<br>Visit <a href="https://example.com">https://example.com</a></p><p>New paragraph</p>"#)
    }

    @Test("HTTP URL is also linked")
    func httpUrl() {
        let result = convertTextToHTML("Go to http://example.com now")
        #expect(result == #"<p>Go to <a href="http://example.com">http://example.com</a> now</p>"#)
    }

    @Test("Multiple URLs in one paragraph")
    func multipleUrls() {
        let result = convertTextToHTML("See https://a.com and https://b.com here")
        #expect(result == #"<p>See <a href="https://a.com">https://a.com</a> and <a href="https://b.com">https://b.com</a> here</p>"#)
    }

    // MARK: - Markdown: bold, italic, links

    @Test("Bold text renders as <strong>")
    func boldText() {
        let result = convertTextToHTML("This is **bold** text")
        #expect(result == "<p>This is <strong>bold</strong> text</p>")
    }

    @Test("Italic text renders as <em>")
    func italicText() {
        let result = convertTextToHTML("This is *italic* text")
        #expect(result == "<p>This is <em>italic</em> text</p>")
    }

    @Test("Bold and italic combined")
    func boldAndItalic() {
        let result = convertTextToHTML("This is ***bold italic*** text")
        #expect(result.contains("<strong>") && result.contains("<em>"))
    }

    @Test("Markdown links render as <a>")
    func markdownLinks() {
        let result = convertTextToHTML("Visit [Example](https://example.com) today")
        #expect(result == #"<p>Visit <a href="https://example.com">Example</a> today</p>"#)
    }

    // MARK: - Markdown: headers

    @Test("Headers render as bold paragraphs")
    func headers() {
        let result = convertTextToHTML("# Hello World")
        #expect(result == "<p><strong>Hello World</strong></p>")
    }

    @Test("H2 renders as bold paragraph")
    func h2Header() {
        let result = convertTextToHTML("## Subheading")
        #expect(result == "<p><strong>Subheading</strong></p>")
    }

    // MARK: - Markdown: lists

    @Test("Unordered list renders as <ul>")
    func unorderedList() {
        let result = convertTextToHTML("- Item one\n- Item two\n- Item three")
        #expect(result == "<ul><li>Item one</li><li>Item two</li><li>Item three</li></ul>")
    }

    @Test("Ordered list renders as <ol>")
    func orderedList() {
        let result = convertTextToHTML("1. First\n2. Second\n3. Third")
        #expect(result == "<ol><li>First</li><li>Second</li><li>Third</li></ol>")
    }

    // MARK: - Markdown: code

    @Test("Inline code renders as <code>")
    func inlineCode() {
        let result = convertTextToHTML("Use `print()` to debug")
        #expect(result == "<p>Use <code>print()</code> to debug</p>")
    }

    @Test("Code block renders as <pre><code>")
    func codeBlock() {
        let result = convertTextToHTML("```\nlet x = 1\nprint(x)\n```")
        #expect(result == "<pre><code>let x = 1\nprint(x)</code></pre>")
    }

    @Test("Code block with language hint")
    func codeBlockWithLanguage() {
        let result = convertTextToHTML("```swift\nlet x = 1\n```")
        #expect(result == "<pre><code>let x = 1</code></pre>")
    }

    // MARK: - Markdown: blockquotes

    @Test("Blockquote renders as <blockquote>")
    func blockquote() {
        let result = convertTextToHTML("> This is a quote")
        #expect(result == "<blockquote><p>This is a quote</p></blockquote>")
    }

    // MARK: - Markdown: strikethrough

    @Test("Strikethrough renders as <del>")
    func strikethrough() {
        let result = convertTextToHTML("This is ~~deleted~~ text")
        #expect(result == "<p>This is <del>deleted</del> text</p>")
    }

    // MARK: - Mixed markdown + plain URLs

    @Test("Markdown with inline link alongside plain text")
    func markdownWithLink() {
        let result = convertTextToHTML("Check [this](https://example.com) **bold** link")
        #expect(result.contains("<a href=\"https://example.com\">this</a>"))
        #expect(result.contains("<strong>bold</strong>"))
    }

    // MARK: - HTML escaping in markdown

    @Test("HTML entities are escaped in markdown output")
    func htmlEntitiesInMarkdown() {
        let result = convertTextToHTML("**bold <script>** text")
        #expect(result.contains("&lt;script&gt;"))
        #expect(!result.contains("<script>"))
    }

    @Test("Code blocks escape HTML")
    func codeBlockEscapesHTML() {
        let result = convertTextToHTML("```\n<div>test</div>\n```")
        #expect(result.contains("&lt;div&gt;"))
        #expect(!result.contains("<div>"))
    }

    // MARK: - Sanitizer integration

    @Test("Markdown output passes through sanitizer safely")
    func markdownOutputSurvivesSanitizer() {
        let markdown = "**Bold** and *italic* with [link](https://example.com)"
        let html = convertTextToHTML(markdown)
        let sanitized = HTMLSanitizer.sanitize(html)
        // All our output tags are in the sanitizer's allowlist
        #expect(sanitized.contains("<strong>Bold</strong>"))
        #expect(sanitized.contains("<em>italic</em>"))
        #expect(sanitized.contains("https://example.com"))
    }
}
