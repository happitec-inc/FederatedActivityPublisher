import Testing
@testable import ActivityPubCore

@Suite("Text-to-HTML conversion")
struct TextToHTMLTests {

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

    @Test("URL is autolinked")
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
}
