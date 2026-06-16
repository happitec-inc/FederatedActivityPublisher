import Testing
@testable import ActivityPubCore

@Test func plainTextStripsTagsAndUnescapesEntities() {
    let html = "<p>Hello &amp; welcome to &lt;bots&gt;</p>"
    #expect(plainTextFromHTML(html) == "Hello & welcome to <bots>")
}

@Test func plainTextConvertsBreaksToNewlines() {
    let html = "<p>Line one<br>Line two</p><p>Para two</p>"
    #expect(plainTextFromHTML(html) == "Line one\nLine two\n\nPara two")
}

@Test func plainTextStripsAnchorTagsKeepingText() {
    let html = #"<p>Visit <a href="https://example.com">my site</a> today</p>"#
    #expect(plainTextFromHTML(html) == "Visit my site today")
}

@Test func plainTextEmptyInputReturnsEmpty() {
    #expect(plainTextFromHTML("") == "")
}

@Test func plainTextPlainStringPassesThrough() {
    #expect(plainTextFromHTML("just text") == "just text")
}
