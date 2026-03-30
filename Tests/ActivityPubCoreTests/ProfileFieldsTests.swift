import Testing
@testable import ActivityPubCore

@Suite("Profile field formatting")
struct ProfileFieldsTests {

    @Test("URL value gets rel=me link for ActivityPub")
    func urlFieldActivityPub() {
        let result = formatFieldValueForActivityPub("https://randomforms.app")
        #expect(result == #"<a href="https://randomforms.app" rel="me nofollow noopener noreferrer" target="_blank">randomforms.app</a>"#)
    }

    @Test("URL with trailing slash strips slash in display")
    func urlTrailingSlash() {
        let result = formatFieldValueForActivityPub("https://example.com/")
        #expect(result == #"<a href="https://example.com/" rel="me nofollow noopener noreferrer" target="_blank">example.com</a>"#)
    }

    @Test("Non-URL value is HTML-escaped for ActivityPub")
    func plainTextActivityPub() {
        let result = formatFieldValueForActivityPub("Hello <world> & \"friends\"")
        #expect(result == "Hello &lt;world&gt; &amp; &quot;friends&quot;")
    }

    @Test("URL value gets rel=me link for API")
    func urlFieldAPI() {
        let result = formatFieldValueForAPI("https://randomforms.app")
        #expect(result == #"<a href="https://randomforms.app" rel="me">randomforms.app</a>"#)
    }

    @Test("Non-URL value is HTML-escaped for API")
    func plainTextAPI() {
        let result = formatFieldValueForAPI("Some plain text")
        #expect(result == "Some plain text")
    }

    @Test("Parse and encode round-trip")
    func roundTrip() {
        let fields = [
            ProfileField(name: "Website", value: "https://example.com"),
            ProfileField(name: "Location", value: "Earth"),
        ]
        let encoded = encodeProfileFields(fields)
        let decoded = parseProfileFields(encoded)
        #expect(decoded.count == 2)
        #expect(decoded[0].name == "Website")
        #expect(decoded[0].value == "https://example.com")
        #expect(decoded[1].name == "Location")
        #expect(decoded[1].value == "Earth")
    }

    @Test("Parse empty JSON returns empty array")
    func parseEmpty() {
        let result = parseProfileFields("[]")
        #expect(result.isEmpty)
    }

    @Test("Parse invalid JSON returns empty array")
    func parseInvalid() {
        let result = parseProfileFields("not json")
        #expect(result.isEmpty)
    }

    @Test("HTTP URL is also linked")
    func httpUrl() {
        let result = formatFieldValueForActivityPub("http://example.com")
        #expect(result.contains("http://example.com"))
        #expect(result.contains(#"rel="me nofollow noopener noreferrer""#))
    }
}
