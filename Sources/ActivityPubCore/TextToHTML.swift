import Foundation

/// Convert plain text to ActivityPub-compatible HTML.
///
/// Applies the following transformations in order:
/// 1. Split on double newlines into paragraphs, wrap each in `<p>...</p>`
/// 2. Autolink URLs (`https?://...`) to `<a href="...">...</a>` with proper escaping
/// 3. HTML-escape non-URL text portions
/// 4. Convert single newlines within paragraphs to `<br>`
///
/// - Parameter text: Plain text input from the posting API.
/// - Returns: HTML string suitable for ActivityPub Note content.
public func convertTextToHTML(_ text: String) -> String {
    if text.isEmpty {
        return "<p></p>"
    }

    // Split into paragraphs on double newlines
    let paragraphs = text.components(separatedBy: "\n\n")

    let htmlParagraphs = paragraphs.map { paragraph -> String in
        // Autolink URLs first (on raw text so & in query params is intact),
        // then HTML-escape the non-URL text segments.
        let linked = autolinkAndEscape(paragraph)

        // Convert single newlines to <br>
        let withBreaks = linked.replacingOccurrences(of: "\n", with: "<br>")

        return "<p>\(withBreaks)</p>"
    }

    return htmlParagraphs.joined()
}

/// Escape HTML special characters.
func htmlEscape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

/// Detect URLs, wrap them in anchor tags with escaped href and display text,
/// and HTML-escape the non-URL portions of the text.
func autolinkAndEscape(_ text: String) -> String {
    let pattern = #"https?://[^\s<>"]+[^\s<>".,;:!?\)\]\}]"#

    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
        return htmlEscape(text)
    }

    let nsText = text as NSString
    let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))

    if matches.isEmpty {
        return htmlEscape(text)
    }

    var result = ""
    var lastEnd = 0

    for match in matches {
        let matchRange = match.range
        // HTML-escape text before this URL
        let before = nsText.substring(with: NSRange(location: lastEnd, length: matchRange.location - lastEnd))
        result += htmlEscape(before)

        let url = nsText.substring(with: matchRange)
        // Escape & in the URL for valid HTML href and display
        let escapedUrl = url.replacingOccurrences(of: "&", with: "&amp;")
        result += "<a href=\"\(escapedUrl)\">\(escapedUrl)</a>"

        lastEnd = matchRange.location + matchRange.length
    }

    // HTML-escape remaining text after last URL
    result += htmlEscape(nsText.substring(from: lastEnd))

    return result
}
