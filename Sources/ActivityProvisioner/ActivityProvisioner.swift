import ArgumentParser
import AWSDynamoDB
import AWSSSM
import _CryptoExtras
import Foundation

@main
struct ActivityProvisioner: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Provision and manage ActivityPub actors",
        subcommands: [ProvisionActor.self, RegisterPasskey.self],
        defaultSubcommand: ProvisionActor.self
    )
}

struct ProvisionActor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "provision",
        abstract: "Provision an ActivityPub actor in DynamoDB with RSA keypair"
    )

    @Option(help: "Deployment stage (e.g. stage, prod)")
    var stage: String

    @Option(help: "Actor username")
    var username: String

    @Option(name: .customLong("display-name"), help: "Display name")
    var displayName: String

    @Option(help: "Actor summary/bio")
    var summary: String = ""

    @Option(name: .customLong("table-name"), help: "DynamoDB table name (default: activity-{stage})")
    var tableName: String?

    @Option(name: .customLong("server-domain"), help: "Server domain for actor URLs (e.g. example.com)")
    var serverDomain: String

    @Option(name: .customLong("handle-domain"), help: "Handle domain (after the @, e.g. example.com)")
    var handleDomain: String

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
