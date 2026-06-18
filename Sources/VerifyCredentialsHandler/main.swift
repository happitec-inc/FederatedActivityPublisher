/// Lambda handler for `GET /api/v1/accounts/verify_credentials` — the endpoint that returns
/// the authenticated account's own profile data.
///
/// This is the first request the iOS client makes after login to populate the profile-editing
/// form. It returns a `CredentialAccount` JSON object, which extends the standard Mastodon
/// `Account` with a `source` object that carries the raw (unrendered) bio text and profile
/// field values. This lets the client pre-populate text fields without reverse-rendering HTML.
///
/// Authentication is bearer-token only. The handler reads from DynamoDB (`DynamoDBStore`)
/// but does not write to it or touch S3 or SQS.
import AWSLambdaEvents
import AWSLambdaRuntime
import AWSSSM
import ActivityPubCore
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

guard let serverDomain = ProcessInfo.processInfo.environment["SERVER_DOMAIN"] else {
    fatalError("SERVER_DOMAIN environment variable is required")
}
let ssmKeyPrefixRaw = ProcessInfo.processInfo.environment["SSM_KEY_PREFIX"] ?? "/activity/stage/keys/"
let ssmKeyPrefix = ssmKeyPrefixRaw.hasSuffix("/") ? String(ssmKeyPrefixRaw.dropLast()) : ssmKeyPrefixRaw

let store = try await DynamoDBStore()
let ssmClient = try await SSMClient()

let runtime = LambdaRuntime {
    (event: APIGatewayRequest, context: LambdaContext) -> APIGatewayResponse in

    do {
        // 1. Authenticate via bearer token
        let authHeader = event.headers["authorization"] ?? event.headers["Authorization"] ?? ""
        let authResult: BearerAuthResult
        do {
            authResult = try await authenticateBearer(
                authHeader: authHeader,
                store: store,
                ssmKeyPrefix: ssmKeyPrefix,
                ssmClient: ssmClient
            )
        } catch BearerAuthError.missingHeader {
            return APIGatewayResponse(
                statusCode: .unauthorized,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Missing or invalid Authorization header"}"#
            )
        } catch BearerAuthError.invalidToken {
            return APIGatewayResponse(
                statusCode: .unauthorized,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Invalid bearer token"}"#
            )
        } catch let error as BearerAuthError {
            context.logger.error("Bearer auth error: \(error)")
            return APIGatewayResponse(
                statusCode: .internalServerError,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Server configuration error"}"#
            )
        }
        let username = authResult.username

        // 2. Load the actor
        guard let actor = try await store.getActor(username: username) else {
            return APIGatewayResponse(
                statusCode: .notFound,
                headers: ["content-type": "application/json"],
                body: #"{"error":"Account not found"}"#
            )
        }

        // 3. Build and return the CredentialAccount JSON
        let body = buildCredentialAccountJSON(actor: actor)
        return APIGatewayResponse(
            statusCode: .ok,
            headers: ["content-type": "application/json"],
            body: body
        )

    } catch {
        context.logger.error("VerifyCredentialsHandler error: \(error)")
        return APIGatewayResponse(
            statusCode: .internalServerError,
            headers: ["content-type": "application/json"],
            body: #"{"error":"Internal server error"}"#
        )
    }
}

/// Returns the `CredentialAccount` JSON response for `GET /api/v1/accounts/verify_credentials`.
///
/// The `source` object in the response carries the raw (unrendered) bio and field values so
/// profile-editing clients can pre-populate edit forms without reverse-rendering HTML.
///
/// - Parameter actor: The authenticated actor's record from DynamoDB.
/// - Returns: A JSON string shaped like a Mastodon `CredentialAccount` entity.
func buildCredentialAccountJSON(actor: Actor) -> String {
    // Parsed raw fields (stored values are already raw plain text).
    let rawFields = actor.fields.map(parseProfileFields) ?? []

    // Rendered fields for the top-level `fields` array (HTML values).
    let renderedFieldsJSON: String
    if rawFields.isEmpty {
        renderedFieldsJSON = "[]"
    } else {
        let items = rawFields.map { field -> String in
            let rendered = formatFieldValueForAPI(field.value)
            return "{\"name\":\(jsonString(field.name)),\"value\":\(jsonString(rendered))}"
        }
        renderedFieldsJSON = "[\(items.joined(separator: ","))]"
    }

    // Raw fields for the `source.fields` array (plain-text name/value pairs).
    let sourceFieldsJSON: String
    if rawFields.isEmpty {
        sourceFieldsJSON = "[]"
    } else {
        let items = rawFields.map { field -> String in
            "{\"name\":\(jsonString(field.name)),\"value\":\(jsonString(field.value))}"
        }
        sourceFieldsJSON = "[\(items.joined(separator: ","))]"
    }

    // Raw note: prefer the stored sourceNote, fall back to plain text stripped from summary.
    let rawNote = actor.sourceNote ?? plainTextFromHTML(actor.summary)

    var parts: [String] = []
    parts.append("\"id\":\(jsonString(actor.username))")
    parts.append("\"username\":\(jsonString(actor.username))")
    parts.append("\"display_name\":\(jsonString(actor.displayName))")
    parts.append("\"note\":\(jsonString(actor.summary))")
    if let avatar = actor.avatarUrl {
        parts.append("\"avatar\":\(jsonString(avatar))")
    }
    if let header = actor.headerUrl {
        parts.append("\"header\":\(jsonString(header))")
    }
    parts.append("\"fields\":\(renderedFieldsJSON)")
    parts.append("\"source\":{\"note\":\(jsonString(rawNote)),\"fields\":\(sourceFieldsJSON)}")

    return "{\(parts.joined(separator: ","))}"
}

try await runtime.run()
