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

/// HTML-escape special characters for profile field values.
func htmlEscapeField(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}
