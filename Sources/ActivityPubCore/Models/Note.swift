import Foundation

/// Build an ActivityPub Note JSON-LD object from a Status.
///
/// Returns the JSON string for the Note, suitable for embedding as the `object`
/// in a Create activity.
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

    let json = """
    {"@context":["https://www.w3.org/ns/activitystreams",{"Hashtag":"as:Hashtag","sensitive":"as:sensitive","blurhash":"toot:blurhash","focalPoint":{"@container":"@list","@id":"toot:focalPoint"},"toot":"http://joinmastodon.org/ns#"}],"id":"\(statusUrl)","type":"Note","attributedTo":"\(actorUrl)","content":\(jsonString(status.content)),"url":"\(escapeJSON(status.url))","published":"\(escapeJSON(status.published))","to":\(toJSON),"cc":\(ccJSON),"sensitive":\(status.sensitive)\(summaryJSON)\(contentMapJSON)\(attachmentJSON)\(tagJSON)}
    """
    return json.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Build a Create activity wrapping a Note.
///
/// Returns the full Create activity JSON string.
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

/// Compute to/cc arrays based on visibility.
///
/// - `public`: to=[as:Public], cc=[followers collection]
/// - `unlisted`: to=[followers collection], cc=[as:Public]
/// - `private`: to=[followers collection], cc=[] (no mentions for MVP)
/// - `direct`: not supported for MVP
///
/// Returns (to, cc) arrays, or nil if visibility is unsupported (direct).
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

/// Escape a string for embedding in manually-built JSON.
public func escapeJSON(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
         .replacingOccurrences(of: "\t", with: "\\t")
}

/// Produce a properly quoted JSON string value.
public func jsonString(_ value: String) -> String {
    "\"\(escapeJSON(value))\""
}

/// Produce a JSON array of strings.
public func jsonArray(_ values: [String]) -> String {
    let items = values.map { jsonString($0) }
    return "[\(items.joined(separator: ","))]"
}
