import ArgumentParser
import AWSDynamoDB
import AWSSSM
import _CryptoExtras
import Foundation

@main
struct ActivityProvisioner: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
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
            type: .securestring,
            value: privateKeyPem
        )
        _ = try await ssmClient.putParameter(input: putParameterInput)

        // Write actor profile to DynamoDB
        let tableName = "activity-environment-\(stage)"
        print("Writing actor profile to DynamoDB table \(tableName)...")

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
            tableName: tableName
        )
        _ = try await dynamoClient.putItem(input: putItemInput)

        print("Actor provisioned successfully!")
        print("  Actor URI: https://activity.happitec.com/users/\(username)")
        print("  Handle: @\(username)@happitec.com")
        print("  SSM Key: \(ssmParameterPath)")
    }
}
