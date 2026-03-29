import Foundation

/// Convert plain text to ActivityPub-compatible HTML.
///
/// Rules:
/// 1. HTML-escape special characters (<, >, &, ")
/// 2. Split on double newlines into paragraphs, wrap each in <p>...</p>
/// 3. Convert single newlines within paragraphs to <br>
/// 4. Autolink URLs (https?://...) to <a href="...">...</a>
public func convertTextToHTML(_ text: String) -> String {
    if text.isEmpty {
        return "<p></p>"
    }

    // Split into paragraphs on double newlines
    let paragraphs = text.components(separatedBy: "\n\n")

    let htmlParagraphs = paragraphs.map { paragraph -> String in
        // HTML-escape first (before adding any HTML tags)
        let escaped = htmlEscape(paragraph)

        // Autolink URLs
        let linked = autolinkURLs(escaped)

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

/// Detect and wrap URLs in anchor tags.
func autolinkURLs(_ text: String) -> String {
    // Match http:// or https:// URLs up to whitespace or end of string.
    // Exclude trailing punctuation that is likely sentence-ending.
    let pattern = #"https?://[^\s<>&"]+[^\s<>&".,;:!?\)\]\}]"#

    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
        return text
    }

    let nsText = text as NSString
    let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))

    if matches.isEmpty {
        return text
    }

    var result = ""
    var lastEnd = 0

    for match in matches {
        let matchRange = match.range
        // Append text before this match
        result += nsText.substring(with: NSRange(location: lastEnd, length: matchRange.location - lastEnd))

        let url = nsText.substring(with: matchRange)
        result += "<a href=\"\(url)\">\(url)</a>"

        lastEnd = matchRange.location + matchRange.length
    }

    // Append remaining text
    result += nsText.substring(from: lastEnd)

    return result
}
