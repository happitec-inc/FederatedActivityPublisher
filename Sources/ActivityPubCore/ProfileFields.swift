import Foundation

/// A profile metadata field displayed as a key-value pair on an actor's profile.
///
/// Stored as a JSON-encoded array in the ``Actor/fields`` property. Values that are
/// URLs are automatically converted to anchor tags during serialization.
public struct ProfileField: Codable, Sendable {
    /// The field label (e.g. "Website", "Location").
    public let name: String
    /// The field value (plain text or URL).
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// Format a profile field value for ActivityPub serialization.
/// URLs become `<a href="..." rel="me nofollow noopener noreferrer" target="_blank">display</a>`.
/// Non-URL values are HTML-escaped and returned as-is.
public func formatFieldValueForActivityPub(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
        let escaped = htmlEscapeField(trimmed)
        // Display text: strip scheme for cleaner display
        var display = trimmed
        if display.hasPrefix("https://") {
            display = String(display.dropFirst("https://".count))
        } else if display.hasPrefix("http://") {
            display = String(display.dropFirst("http://".count))
        }
        // Remove trailing slash for display
        if display.hasSuffix("/") {
            display = String(display.dropLast())
        }
        let escapedDisplay = htmlEscapeField(display)
        return "<a href=\"\(escaped)\" rel=\"me nofollow noopener noreferrer\" target=\"_blank\">\(escapedDisplay)</a>"
    } else {
        return htmlEscapeField(trimmed)
    }
}

/// Format a profile field value for the Mastodon API response.
/// URLs get `rel="me"` links. Non-URLs are HTML-escaped.
public func formatFieldValueForAPI(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
        let escaped = htmlEscapeField(trimmed)
        var display = trimmed
        if display.hasPrefix("https://") {
            display = String(display.dropFirst("https://".count))
        } else if display.hasPrefix("http://") {
            display = String(display.dropFirst("http://".count))
        }
        if display.hasSuffix("/") {
            display = String(display.dropLast())
        }
        let escapedDisplay = htmlEscapeField(display)
        return "<a href=\"\(escaped)\" rel=\"me\">\(escapedDisplay)</a>"
    } else {
        return htmlEscapeField(trimmed)
    }
}

/// Parse the JSON-encoded fields string from DynamoDB into ProfileField array.
public func parseProfileFields(_ json: String) -> [ProfileField] {
    guard let data = json.data(using: .utf8),
          let fields = try? JSONDecoder().decode([ProfileField].self, from: data) else {
        return []
    }
    return fields
}

/// Encode ProfileField array to JSON string for DynamoDB storage.
public func encodeProfileFields(_ fields: [ProfileField]) -> String {
    guard let data = try? JSONEncoder().encode(fields),
          let json = String(data: data, encoding: .utf8) else {
        return "[]"
    }
    return json
}

/// Strip HTML tags and unescape basic entities to recover plain text.
///
/// Intended as a fallback to recover a plain-text bio from a rendered HTML
/// `summary` when no raw `sourceNote` was stored. Block-level closing tags
/// (`</p>`) and `<br>` become newlines; all other tags are removed.
/// A small set of common entities is decoded.
public func plainTextFromHTML(_ html: String) -> String {
    guard !html.isEmpty else { return "" }

    // Convert paragraph/line breaks to newlines before stripping remaining tags.
    var text = html
    let breakPatterns = [
        "(?i)</p>": "\n\n",
        "(?i)<br\\s*/?>": "\n",
    ]
    for (pattern, replacement) in breakPatterns {
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let ns = text as NSString
            text = regex.stringByReplacingMatches(
                in: text,
                options: [],
                range: NSRange(location: 0, length: ns.length),
                withTemplate: replacement
            )
        }
    }

    // Remove all remaining tags.
    if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
        let ns = text as NSString
        text = regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: ns.length),
            withTemplate: ""
        )
    }

    // Unescape basic HTML entities (ampersand last to avoid double-decoding).
    text = text
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&#39;", with: "'")
        .replacingOccurrences(of: "&apos;", with: "'")
        .replacingOccurrences(of: "&amp;", with: "&")

    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// HTML-escape special characters for profile field values.
func htmlEscapeField(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}
