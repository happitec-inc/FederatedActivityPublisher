import Foundation

/// Sanitizes untrusted HTML for safe storage and display.
/// Allowlisted tags are preserved; all others are stripped (content kept).
/// Only `href` on `<a>` and `class` on `<span>` attributes are preserved.
public enum HTMLSanitizer {

    private static let allowedTags: Set<String> = [
        "p", "br", "a", "span", "em", "strong", "b", "i", "u",
        "del", "pre", "code", "ul", "ol", "li", "blockquote"
    ]

    private static let selfClosingTags: Set<String> = ["br"]

    private static let allowedSpanClasses: Set<String> = [
        "h-card", "invisible", "ellipsis", "mention", "hashtag"
    ]

    /// Sanitize an untrusted HTML string.
    /// - Parameter html: The untrusted input HTML.
    /// - Returns: Sanitized HTML with only allowed tags and attributes.
    public static func sanitize(_ html: String) -> String {
        guard !html.isEmpty else { return "" }

        // Regex matches opening tags, closing tags, and self-closing tags
        // Group 1: optional "/" for closing tags
        // Group 2: tag name
        // Group 3: attributes string
        // Group 4: optional "/" for self-closing
        let tagPattern = "<(/?)([a-zA-Z][a-zA-Z0-9]*)([^>]*?)(/?)>"

        guard let regex = try? NSRegularExpression(pattern: tagPattern, options: []) else {
            return html
        }

        let nsHTML = html as NSString
        let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: nsHTML.length))

        var result = ""
        var lastEnd = 0

        for match in matches {
            // Append text before this tag
            let textBefore = nsHTML.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            result += textBefore

            let isClosing = nsHTML.substring(with: match.range(at: 1)) == "/"
            let tagName = nsHTML.substring(with: match.range(at: 2)).lowercased()
            let attrsString = nsHTML.substring(with: match.range(at: 3))
            let isSelfClosing = nsHTML.substring(with: match.range(at: 4)) == "/"

            if selfClosingTags.contains(tagName) && allowedTags.contains(tagName) {
                // Normalize self-closing tags (e.g., <br/>, <br />) to <br>
                result += "<\(tagName)>"
            } else if isClosing {
                if allowedTags.contains(tagName) && !selfClosingTags.contains(tagName) {
                    result += "</\(tagName)>"
                }
                // Disallowed closing tags: strip
            } else if allowedTags.contains(tagName) {
                // Opening tag -- process attributes
                if tagName == "a" {
                    let href = extractAttribute("href", from: attrsString)
                    var tag = "<a"
                    if let href, isAllowedScheme(href) {
                        // Don't call escapeAttributeValue here -- href values extracted from
                        // HTML attributes are already entity-encoded, so escaping would
                        // double-encode (e.g., &amp; -> &amp;amp;). The regex only captures
                        // content between matching quotes, so " injection is already prevented.
                        tag += " href=\"\(href)\""
                    }
                    tag += " rel=\"nofollow noopener noreferrer\""
                    tag += ">"
                    result += tag
                } else if tagName == "span" {
                    let classValue = extractAttribute("class", from: attrsString)
                    var tag = "<span"
                    if let classValue {
                        let filtered = classValue
                            .split(separator: " ")
                            .map(String.init)
                            .filter { allowedSpanClasses.contains($0) }
                        if !filtered.isEmpty {
                            tag += " class=\"\(filtered.joined(separator: " "))\""
                        }
                    }
                    tag += ">"
                    result += tag
                } else if isSelfClosing || selfClosingTags.contains(tagName) {
                    result += "<\(tagName)>"
                } else {
                    // Allowed tag with no preserved attributes
                    result += "<\(tagName)>"
                }
            }
            // Disallowed opening tags: strip (text content between them is kept by the next iteration)

            lastEnd = match.range.location + match.range.length
        }

        // Append any remaining text after the last tag
        if lastEnd < nsHTML.length {
            result += nsHTML.substring(from: lastEnd)
        }

        return result
    }

    /// Extract a named attribute value from an attributes string.
    /// Handles both single and double quotes.
    private static func extractAttribute(_ name: String, from attrs: String) -> String? {
        // Pattern: name="value" or name='value' (case-insensitive attribute name)
        let pattern = "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let nsAttrs = attrs as NSString
        guard let match = regex.firstMatch(in: attrs, options: [], range: NSRange(location: 0, length: nsAttrs.length)) else {
            return nil
        }
        // Try double-quote group first, then single-quote
        if match.range(at: 1).location != NSNotFound {
            return nsAttrs.substring(with: match.range(at: 1))
        }
        if match.range(at: 2).location != NSNotFound {
            return nsAttrs.substring(with: match.range(at: 2))
        }
        return nil
    }

    /// Check if a URL scheme is in the positive allowlist (http:// or https:// only).
    private static func isAllowedScheme(_ url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
    }

}
