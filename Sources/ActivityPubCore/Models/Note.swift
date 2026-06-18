/// Functions that build ActivityPub Note and Create activity JSON strings from ``Status`` records.
///
/// These are free functions rather than methods because the JSON is constructed by hand (no
/// `Codable` round-trip) to produce a compact, spec-compliant JSON-LD payload without relying
/// on Foundation's `JSONEncoder` key ordering or escaping behavior. `PostHandler` calls
/// ``buildNoteJSON(status:serverDomain:username:)`` and ``buildCreateActivityJSON(status:noteJSON:serverDomain:username:)``
/// to assemble the activity, then passes the result to ``DeliveryJob`` for SQS fan-out.
/// ``computeAddressing(visibility:serverDomain:username:)`` is also called by `PostHandler` to
/// populate the `to`/`cc` fields on the ``Status`` record before it is written to DynamoDB.
import Foundation

/// Build an ActivityPub Note JSON-LD object from a Status.
///
/// Produces the JSON string for the Note, suitable for embedding as the `object` value in a
/// Create activity. Attachments are typed as `Image`, `Video`, `Audio`, or `Document` based on
/// the MIME type prefix. Quote URIs are only emitted when the quote is accepted or local.
///
/// - Parameters:
///   - status: The source ``Status`` record; its `content` field must already be HTML.
///   - serverDomain: The server's domain (e.g. `activity.happitec.com`), used to build canonical URIs.
///   - username: The local actor's username, used to build the actor and status URLs.
/// - Returns: A compact JSON-LD string for the Note object.
public func buildNoteJSON(status: Status, serverDomain: String, username: String) -> String {
    let actorUrl = "https://\(serverDomain)/users/\(username)"
    let statusUrl = "https://\(serverDomain)/users/\(username)/statuses/\(status.id)"

    // Build to/cc arrays as JSON
    let toJSON = jsonArray(status.to)
    let ccJSON = jsonArray(status.cc)

    // Build attachment array
    var attachmentJSON = ""
    if let attachments = status.attachments, !attachments.isEmpty {
        let items = attachments.map { att -> String in
            // Determine type from content type
            let apType: String
            if att.contentType.hasPrefix("image/") {
                apType = "Image"
            } else if att.contentType.hasPrefix("video/") {
                apType = "Video"
            } else if att.contentType.hasPrefix("audio/") {
                apType = "Audio"
            } else {
                apType = "Document"
            }

            var fields = """
            "type":"\(apType)","mediaType":"\(escapeJSON(att.contentType))","url":"\(escapeJSON(att.url))"
            """
            if let desc = att.description {
                fields += ",\"name\":\(jsonString(desc))"
            }
            if let blurhash = att.blurhash {
                fields += ",\"blurhash\":\(jsonString(blurhash))"
            }
            return "{\(fields)}"
        }
        attachmentJSON = ",\"attachment\":[\(items.joined(separator: ","))]"
    }

    // Build tags array
    var tagJSON = ""
    if let tags = status.tags, !tags.isEmpty {
        let items = tags.map { tag -> String in
            var fields = "\"type\":\(jsonString(tag.type)),\"name\":\(jsonString(tag.name))"
            if let href = tag.href {
                fields += ",\"href\":\(jsonString(href))"
            }
            return "{\(fields)}"
        }
        tagJSON = ",\"tag\":[\(items.joined(separator: ","))]"
    }

    // Content warning / summary
    var summaryJSON = ""
    if let cw = status.contentWarning, !cw.isEmpty {
        summaryJSON = ",\"summary\":\(jsonString(cw))"
    }

    // Language map
    var contentMapJSON = ""
    if let lang = status.language {
        contentMapJSON = ",\"contentMap\":{\(jsonString(lang)):\(jsonString(status.content))}"
    }

    // Quote URI -- only include when quote is accepted (or local-to-local)
    var quoteJSON = ""
    if let quotedUri = status.quotedStatusUri {
        // Use a proper URL prefix check (not substring `contains`) to determine
        // if the quoted status is local. A `contains` check is fragile -- the
        // domain could appear as a substring in a remote URI.
        let isLocalQuote = quotedUri.hasPrefix("https://\(serverDomain)/")

        // Emit quoteUri when:
        // - The quote is explicitly accepted (remote quote, approval received)
        // - The quote is local-to-local (quoteApprovalState is nil, always approved)
        if status.quoteApprovalState == "accepted" || (isLocalQuote && status.quoteApprovalState == nil) {
            quoteJSON = ",\"quoteUri\":\(jsonString(quotedUri)),\"_misskey_quote\":\(jsonString(quotedUri))"
        }
    }

    // Interaction policy — allow public quoting by default
    let interactionPolicyJSON = ",\"interactionPolicy\":{\"canQuote\":{\"automaticApproval\":[\"https://www.w3.org/ns/activitystreams#Public\"]}}"

    let json = """
    {"@context":["https://www.w3.org/ns/activitystreams",{"Hashtag":"as:Hashtag","sensitive":"as:sensitive","blurhash":"toot:blurhash","focalPoint":{"@container":"@list","@id":"toot:focalPoint"},"toot":"http://joinmastodon.org/ns#","quoteUri":"toot:quoteUri"}],"id":"\(statusUrl)","type":"Note","attributedTo":"\(actorUrl)","content":\(jsonString(status.content)),"url":"\(escapeJSON(status.url))","published":"\(escapeJSON(status.published))","to":\(toJSON),"cc":\(ccJSON),"sensitive":\(status.sensitive)\(summaryJSON)\(contentMapJSON)\(quoteJSON)\(attachmentJSON)\(tagJSON)\(interactionPolicyJSON)}
    """
    return json.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Build a Create activity wrapping a Note.
///
/// - Parameters:
///   - status: The source ``Status``, used for `published`, `to`, and `cc` fields.
///   - noteJSON: The Note JSON string produced by ``buildNoteJSON(status:serverDomain:username:)``.
///   - serverDomain: The server's domain, used to build the activity and actor URIs.
///   - username: The local actor's username.
/// - Returns: A compact JSON string for the Create activity.
public func buildCreateActivityJSON(status: Status, noteJSON: String, serverDomain: String, username: String) -> String {
    let actorUrl = "https://\(serverDomain)/users/\(username)"
    let activityId = "https://\(serverDomain)/users/\(username)/statuses/\(status.id)/activity"

    let toJSON = jsonArray(status.to)
    let ccJSON = jsonArray(status.cc)

    let json = """
    {"@context":"https://www.w3.org/ns/activitystreams","id":"\(activityId)","type":"Create","actor":"\(actorUrl)","published":"\(escapeJSON(status.published))","to":\(toJSON),"cc":\(ccJSON),"object":\(noteJSON)}
    """
    return json.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Compute ActivityPub `to` and `cc` arrays from a visibility value.
///
/// | Visibility | `to` | `cc` |
/// |---|---|---|
/// | `public` | `[as:Public]` | `[followers collection]` |
/// | `unlisted` | `[followers collection]` | `[as:Public]` |
/// | `private` | `[followers collection]` | `[]` |
/// | `direct` | not supported | — |
///
/// - Parameters:
///   - visibility: One of `"public"`, `"unlisted"`, or `"private"`.
///   - serverDomain: The server's domain, used to build the followers collection URI.
///   - username: The local actor's username.
/// - Returns: A `(to:, cc:)` tuple, or `nil` for unsupported visibilities (e.g. `"direct"`).
public func computeAddressing(
    visibility: String,
    serverDomain: String,
    username: String
) -> (to: [String], cc: [String])? {
    let publicURI = "https://www.w3.org/ns/activitystreams#Public"
    let followersCollection = "https://\(serverDomain)/users/\(username)/followers"

    switch visibility {
    case "public":
        return (to: [publicURI], cc: [followersCollection])
    case "unlisted":
        return (to: [followersCollection], cc: [publicURI])
    case "private":
        return (to: [followersCollection], cc: [])
    default:
        // "direct" and unknown visibilities are not supported for MVP
        return nil
    }
}

// MARK: - JSON Helpers

/// Escape a string for safe embedding in manually-built JSON.
///
/// Handles backslash, double quote, newline, carriage return, and tab characters.
/// - Parameter value: The raw string to escape.
/// - Returns: The escaped string (without surrounding quotes).
public func escapeJSON(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
         .replacingOccurrences(of: "\t", with: "\\t")
}

/// Produce a properly quoted and escaped JSON string value.
///
/// - Parameter value: The raw string to encode.
/// - Returns: The value wrapped in double quotes with special characters escaped.
public func jsonString(_ value: String) -> String {
    "\"\(escapeJSON(value))\""
}

/// Produce a JSON array of quoted, escaped strings.
///
/// - Parameter values: The strings to encode.
/// - Returns: A JSON array string like `["value1","value2"]`.
public func jsonArray(_ values: [String]) -> String {
    let items = values.map { jsonString($0) }
    return "[\(items.joined(separator: ","))]"
}
