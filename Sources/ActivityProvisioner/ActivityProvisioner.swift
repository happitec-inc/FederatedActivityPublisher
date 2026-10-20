/// Root command and default `provision` subcommand for the ActivityProvisioner CLI.
///
/// `ActivityProvisioner` is a swift-argument-parser tool for operating the FAP server out of band.
/// It creates and manages ActivityPub actors directly in the same DynamoDB table the Lambda
/// handlers read from, without going through the HTTP API.
///
/// This tool is run locally with AWS credentials that have write access to DynamoDB and SSM.
/// Sensitive output (bearer tokens, SSM paths) is printed to the operator's terminal (and, for
/// `mint-token`, optionally written to an `--out` file); it never touches CI.
///
/// Subcommands:
/// - `provision` (default): create a new actor with an RSA keypair
/// - `register-passkey`: generate a one-time passkey registration URL
/// - `mint-token`: mint a bearer token and store its SHA-256 hash in DynamoDB
/// - `list-tokens`: list stored token hashes for auditing
/// - `revoke-token`: delete one or all tokens for a username
/// - `rotate-token`: mint a new token and revoke all older ones atomically
import ActivityPubCore
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
/// Provisioning only creates actors. If the SSM key or the DynamoDB profile already exists,
/// the command fails and changes nothing: replacing the key would break signature
/// verification on every server that cached the old public key, and replacing the profile
/// would reset its counts. Change an existing actor's profile with `PATCH /api/v1/accounts/update_credentials`.
///
/// Run this locally with AWS credentials that have write access to both DynamoDB and SSM.
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
        let resolvedTableName = tableName ?? "activity-\(stage)"
        let now = ISO8601DateFormatter().string(from: Date())

        let ssmClient = try await SSMClient()
        let dynamoClient = try await DynamoDBClient()

        // Both writes are create-only: an existing actor is never replaced. If the profile
        // write is refused, the key written just before it is deleted again.
        do {
            try await provisionActorRecords(
                keyPath: ssmParameterPath,
                username: username,
                writeKey: {
                    print("Storing private key in SSM at \(ssmParameterPath)...")
                    do {
                        _ = try await ssmClient.putParameter(input: actorKeyParameterInput(
                            path: ssmParameterPath,
                            privateKeyPem: privateKeyPem
                        ))
                        return true
                    } catch is ParameterAlreadyExists {
                        return false
                    }
                },
                writeProfile: {
                    print("Writing actor profile to DynamoDB table \(resolvedTableName)...")
                    do {
                        _ = try await dynamoClient.putItem(input: actorProfileInput(
                            tableName: resolvedTableName,
                            username: username,
                            displayName: displayName,
                            summary: summary,
                            publicKeyPem: publicKeyPem,
                            privateKeyPath: ssmParameterPath,
                            createdAt: now
                        ))
                        return true
                    } catch is ConditionalCheckFailedException {
                        return false
                    }
                },
                deleteKey: {
                    print("Profile exists; deleting the key just written to \(ssmParameterPath)...")
                    _ = try await ssmClient.deleteParameter(input: DeleteParameterInput(name: ssmParameterPath))
                }
            )
        } catch let error as ActorProvisioningError {
            print("Error: \(error)")
            throw ExitCode.failure
        }

        print("Actor provisioned successfully!")
        print("  Actor URI: https://\(serverDomain)/users/\(username)")
        print("  Handle: @\(username)@\(handleDomain)")
        print("  SSM Key: \(ssmParameterPath)")
    }
}
