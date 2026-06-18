/// Root command and default `provision` subcommand for the ActivityProvisioner CLI.
///
/// `ActivityProvisioner` is a swift-argument-parser tool for operating the FAP server out of band.
/// It creates and manages ActivityPub actors directly in the same DynamoDB table the Lambda
/// handlers read from, without going through the HTTP API.
///
/// In production this tool is normally invoked via the `provision-actor.yml` GitHub Actions
/// workflow rather than with local AWS credentials. The workflow logs sensitive output (bearer
/// tokens, SSM paths) to the job summary, which is visible only to repository members.
///
/// Subcommands:
/// - `provision` (default): create a new actor with an RSA keypair
/// - `register-passkey`: generate a one-time passkey registration URL
/// - `mint-token`: mint a bearer token and store its SHA-256 hash in DynamoDB
/// - `list-tokens`: list stored token hashes for auditing
/// - `revoke-token`: delete one or all tokens for a username
/// - `rotate-token`: mint a new token and revoke all older ones atomically
import ArgumentParser
import AWSDynamoDB
import AWSSSM
import _CryptoExtras
import Foundation

/// The top-level CLI entry point. Dispatches to the registered subcommands.
@main
struct ActivityProvisioner: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Provision and manage ActivityPub actors",
        subcommands: [
            ProvisionActor.self,
            RegisterPasskey.self,
            MintToken.self,
            ListTokens.self,
            RevokeToken.self,
            RotateToken.self,
        ],
        defaultSubcommand: ProvisionActor.self
    )
}

/// Creates a new ActivityPub actor in DynamoDB and stores its RSA private key in SSM.
///
/// Generates a 2048-bit RSA keypair. The public key is written inline to the DynamoDB actor
/// profile item so the Lambda handlers can verify HTTP Signatures without an SSM lookup on
/// every request. The private key is stored as a `SecureString` in SSM Parameter Store at
/// `/activity/{stage}/keys/{username}` and referenced by path in the DynamoDB item.
///
/// Run this via the `provision-actor.yml` workflow in normal operation. Running locally
/// requires AWS credentials with write access to both DynamoDB and SSM.
struct ProvisionActor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "provision",
        abstract: "Provision an ActivityPub actor in DynamoDB with RSA keypair"
    )

    /// Deployment stage, e.g. `stage` or `prod`. Used to derive the DynamoDB table name
    /// and the SSM parameter path when neither is given explicitly.
    @Option(help: "Deployment stage (e.g. stage, prod)")
    var stage: String

    /// The actor's username. Becomes the DynamoDB partition key (`ACTOR#{username}`) and
    /// appears in the actor URI and the SSM parameter path.
    @Option(help: "Actor username")
    var username: String

    /// Human-readable display name shown in ActivityPub clients.
    @Option(name: .customLong("display-name"), help: "Display name")
    var displayName: String

    /// Short bio or description for the actor profile. Defaults to empty.
    @Option(help: "Actor summary/bio")
    var summary: String = ""

    /// Overrides the default table name of `activity-{stage}`.
    @Option(name: .customLong("table-name"), help: "DynamoDB table name (default: activity-{stage})")
    var tableName: String?

    /// The domain that appears in actor URIs, e.g. `activity.happitec.com`.
    @Option(name: .customLong("server-domain"), help: "Server domain for actor URLs (e.g. example.com)")
    var serverDomain: String

    /// The domain that appears in the `@username@domain` handle, e.g. `happitec.com`.
    /// May differ from `serverDomain` when WebFinger proxying is in use.
    @Option(name: .customLong("handle-domain"), help: "Handle domain (after the @, e.g. example.com)")
    var handleDomain: String

    /// AWS region for both the DynamoDB and SSM clients.
    @Option(help: "AWS region")
    var region: String = "us-east-1"

    func run() async throws {
        print("Generating RSA 2048 keypair...")
        let privateKey = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let publicKeyPem = privateKey.publicKey.pemRepresentation
        let privateKeyPem = privateKey.pemRepresentation

        let ssmParameterPath = "/activity/\(stage)/keys/\(username)"

        // Store private key in SSM Parameter Store
        print("Storing private key in SSM at \(ssmParameterPath)...")
        let ssmClient = try await SSMClient()
        let putParameterInput = PutParameterInput(
            name: ssmParameterPath,
            overwrite: true,
            type: .secureString,
            value: privateKeyPem
        )
        _ = try await ssmClient.putParameter(input: putParameterInput)

        // Write actor profile to DynamoDB
        let resolvedTableName = tableName ?? "activity-\(stage)"
        print("Writing actor profile to DynamoDB table \(resolvedTableName)...")

        let now = ISO8601DateFormatter().string(from: Date())

        let dynamoClient = try await DynamoDBClient()
        let putItemInput = PutItemInput(
            item: [
                "PK": .s("ACTOR#\(username)"),
                "SK": .s("PROFILE"),
                "username": .s(username),
                "displayName": .s(displayName),
                "summary": .s(summary),
                "publicKeyPem": .s(publicKeyPem),
                "privateKeyArn": .s(ssmParameterPath),
                "createdAt": .s(now),
                "discoverable": .bool(true),
                "manuallyApprovesFollowers": .bool(false),
                "followerCount": .n("0"),
                "followingCount": .n("0"),
                "statusCount": .n("0"),
            ],
            tableName: resolvedTableName
        )
        _ = try await dynamoClient.putItem(input: putItemInput)

        print("Actor provisioned successfully!")
        print("  Actor URI: https://\(serverDomain)/users/\(username)")
        print("  Handle: @\(username)@\(handleDomain)")
        print("  SSM Key: \(ssmParameterPath)")
    }
}
