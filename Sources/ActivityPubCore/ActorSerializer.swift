import Foundation

/// Build the full actor JSON-LD document for ActivityPub federation.
///
/// Produces the complete JSON-LD representation of an actor including context,
/// endpoints, public key, profile fields, and Mastodon-compatible extensions.
/// Used by ActorHandler (`GET /users/{username}`) and ProfileUpdateHandler
/// (embedding in Update activities).
///
/// - Parameters:
///   - actor: The local actor to serialize.
///   - serverDomain: The domain hosting ActivityPub endpoints (e.g. `activity.happitec.com`).
///   - handleDomain: The domain used in handles (e.g. `happitec.com`).
/// - Returns: A JSON string containing the actor's JSON-LD document.
public func buildActorJSONLD(
    actor: Actor,
    serverDomain: String,
    handleDomain: String
) -> String {
    let actorUrl = "https://\(serverDomain)/users/\(actor.username)"

    var iconBlock = ""
    if let avatarUrl = actor.avatarUrl {
        iconBlock = """
        ,"icon":{"type":"Image","url":"\(escapeJSON(avatarUrl))"}
        """
    }

    var imageBlock = ""
    if let headerUrl = actor.headerUrl {
        imageBlock = """
        ,"image":{"type":"Image","url":"\(escapeJSON(headerUrl))"}
        """
    }

    var attachmentBlock = ""
    if let fieldsJSON = actor.fields {
        let fields = parseProfileFields(fieldsJSON)
        if !fields.isEmpty {
            let items = fields.map { field -> String in
                let formattedValue = formatFieldValueForActivityPub(field.value)
                return "{\"type\":\"PropertyValue\",\"name\":\(jsonString(field.name)),\"value\":\(jsonString(formattedValue))}"
            }
            attachmentBlock = ",\"attachment\":[\(items.joined(separator: ","))]"
        }
    }

    let json = """
    {"@context":["https://www.w3.org/ns/activitystreams","https://w3id.org/security/v1",{"toot":"http://joinmastodon.org/ns#","discoverable":"toot:discoverable","indexable":"toot:indexable","featured":{"@id":"toot:featured","@type":"@id"},"featuredTags":{"@id":"toot:featuredTags","@type":"@id"},"attributionDomains":{"@id":"toot:attributionDomains","@type":"@id"},"schema":"http://schema.org#","PropertyValue":"schema:PropertyValue","value":"schema:value","manuallyApprovesFollowers":"as:manuallyApprovesFollowers","sensitive":"as:sensitive","quoteUri":"toot:quoteUri"}],"id":"\(actorUrl)","type":"Service","preferredUsername":\(jsonString(actor.username)),"name":\(jsonString(actor.displayName)),"summary":\(jsonString(actor.summary)),"inbox":"\(actorUrl)/inbox","outbox":"\(actorUrl)/outbox","followers":"\(actorUrl)/followers","following":"\(actorUrl)/following","url":"https://\(escapeJSON(serverDomain))/@\(escapeJSON(actor.username))"\(iconBlock)\(imageBlock)\(attachmentBlock),"publicKey":{"id":"\(actorUrl)#main-key","owner":"\(actorUrl)","publicKeyPem":\(jsonString(actor.publicKeyPem))},"discoverable":\(actor.discoverable),"indexable":false,"manuallyApprovesFollowers":\(actor.manuallyApprovesFollowers),"published":"\(escapeJSON(actor.createdAt))","featured":"\(actorUrl)/collections/featured","featuredTags":"\(actorUrl)/collections/tags","attributionDomains":["\(escapeJSON(handleDomain))"],"quoteApprovalPolicy":"https://www.w3.org/ns/activitystreams#Public"}
    """
    return json.trimmingCharacters(in: .whitespacesAndNewlines)
}
