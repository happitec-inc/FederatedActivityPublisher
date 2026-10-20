/// The create-only writes behind `ActivityProvisioner provision`.
///
/// Provisioning an actor writes two records: the RSA private key to SSM Parameter Store and
/// the actor profile (with the matching public key) to DynamoDB. Both writes refuse to replace
/// an existing record. Replacing the key would invalidate every remote server's cached copy of
/// the public key, and replacing the profile would reset its follower, following and status
/// counts. ``provisionActorRecords(writeKey:writeProfile:deleteKey:)`` orders the two writes
/// and undoes the key write when the profile turns out to exist, so a refused run leaves the
/// actor as it was. The SSM and DynamoDB calls are passed in so the ordering can be tested
/// without AWS.
import AWSDynamoDB
import AWSSSM
import Foundation

/// Why `provision` refused to create an actor.
public enum ActorProvisioningError: Error, CustomStringConvertible, Equatable {
    /// An SSM parameter already exists at the actor's key path.
    case keyExists(path: String)
    /// A DynamoDB profile already exists for the username.
    case profileExists(username: String)

    public var description: String {
        switch self {
        case .keyExists(let path):
            return "A private key already exists in SSM at \(path). Nothing was changed. "
                + "If the actor exists, provisioning it again would replace its keypair and "
                + "reset its profile; edit the profile instead. If the key is left over from "
                + "an incomplete provisioning run and no profile exists, delete the SSM "
                + "parameter and run provision again."
        case .profileExists(let username):
            return "Actor \(username) already exists in DynamoDB. Nothing was changed."
        }
    }
}

/// Create an actor's private key and profile, refusing to replace either.
///
/// Writes the key first. If the profile write then finds an existing profile, the key just
/// written is deleted again before the error is thrown.
///
/// - Parameters:
///   - keyPath: The SSM parameter path of the key, for the error message.
///   - username: The actor's username, for the error message.
///   - writeKey: Creates the private key parameter. Returns `false` if one already exists.
///   - writeProfile: Creates the profile. Returns `false` if one already exists.
///   - deleteKey: Deletes the key parameter written by `writeKey`.
/// - Throws: ``ActorProvisioningError`` if the key or profile exists, or any error from the calls.
public func provisionActorRecords(
    keyPath: String,
    username: String,
    writeKey: () async throws -> Bool,
    writeProfile: () async throws -> Bool,
    deleteKey: () async throws -> Void
) async throws {
    guard try await writeKey() else {
        throw ActorProvisioningError.keyExists(path: keyPath)
    }
    guard try await writeProfile() else {
        try await deleteKey()
        throw ActorProvisioningError.profileExists(username: username)
    }
}

/// Build the create-only SSM write for an actor's private key.
///
/// `overwrite: false` makes SSM reject the write with `ParameterAlreadyExists` if the
/// parameter exists.
public func actorKeyParameterInput(path: String, privateKeyPem: String) -> PutParameterInput {
    PutParameterInput(
        name: path,
        overwrite: false,
        type: .secureString,
        value: privateKeyPem
    )
}

/// Build the create-only DynamoDB write for a new actor profile.
///
/// The condition makes DynamoDB reject the write with `ConditionalCheckFailedException` if a
/// profile exists for the username.
public func actorProfileInput(
    tableName: String,
    username: String,
    displayName: String,
    summary: String,
    publicKeyPem: String,
    privateKeyPath: String,
    createdAt: String
) -> PutItemInput {
    PutItemInput(
        conditionExpression: "attribute_not_exists(SK)",
        item: [
            "PK": .s("ACTOR#\(username)"),
            "SK": .s("PROFILE"),
            "username": .s(username),
            "displayName": .s(displayName),
            "summary": .s(summary),
            "publicKeyPem": .s(publicKeyPem),
            "privateKeyArn": .s(privateKeyPath),
            "createdAt": .s(createdAt),
            "discoverable": .bool(true),
            "manuallyApprovesFollowers": .bool(false),
            "followerCount": .n("0"),
            "followingCount": .n("0"),
            "statusCount": .n("0"),
        ],
        tableName: tableName
    )
}
