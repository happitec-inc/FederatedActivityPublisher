// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "activity-happitec",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "WebFingerHandler", targets: ["WebFingerHandler"]),
        .executable(name: "ActorHandler", targets: ["ActorHandler"]),
        .executable(name: "NodeInfoHandler", targets: ["NodeInfoHandler"]),
        .executable(name: "OutboxHandler", targets: ["OutboxHandler"]),
        .executable(name: "FollowersHandler", targets: ["FollowersHandler"]),
        .executable(name: "FollowingHandler", targets: ["FollowingHandler"]),
        .executable(name: "FeaturedHandler", targets: ["FeaturedHandler"]),
        .executable(name: "FeaturedTagsHandler", targets: ["FeaturedTagsHandler"]),
        .executable(name: "ObjectHandler", targets: ["ObjectHandler"]),
        .executable(name: "ProfileHandler", targets: ["ProfileHandler"]),
        .executable(name: "ActivityProvisioner", targets: ["ActivityProvisioner"]),
        .executable(name: "InboxHandler", targets: ["InboxHandler"]),
        .executable(name: "DeliverHandler", targets: ["DeliverHandler"]),
        .executable(name: "PostHandler", targets: ["PostHandler"]),
        .executable(name: "MediaUploadHandler", targets: ["MediaUploadHandler"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swift-server/swift-aws-lambda-runtime.git", from: "2.0.0"),
        .package(url: "https://github.com/swift-server/swift-aws-lambda-events.git", from: "1.0.0"),
        .package(url: "https://github.com/awslabs/aws-sdk-swift.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.7.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.0.0"),
    ],
    targets: [
        // Shared library
        .target(
            name: "ActivityPubCore",
            dependencies: [
                .product(name: "AWSDynamoDB", package: "aws-sdk-swift"),
                .product(name: "AWSSQS", package: "aws-sdk-swift"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ]
        ),

        // Lambda handlers
        .executableTarget(
            name: "WebFingerHandler",
            dependencies: [
                "ActivityPubCore",
                .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
            ]
        ),
        .executableTarget(
            name: "ActorHandler",
            dependencies: [
                "ActivityPubCore",
                .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
            ]
        ),
        .executableTarget(
            name: "NodeInfoHandler",
            dependencies: [
                .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
            ]
        ),
        .executableTarget(
            name: "OutboxHandler",
            dependencies: [
                "ActivityPubCore",
                .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
            ]
        ),
        .executableTarget(
            name: "FollowersHandler",
            dependencies: [
                "ActivityPubCore",
                .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
            ]
        ),
        .executableTarget(
            name: "FollowingHandler",
            dependencies: [
                "ActivityPubCore",
                .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
            ]
        ),
        .executableTarget(
            name: "FeaturedHandler",
            dependencies: [
                "ActivityPubCore",
                .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
            ]
        ),
        .executableTarget(
            name: "FeaturedTagsHandler",
            dependencies: [
                "ActivityPubCore",
                .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
            ]
        ),
        .executableTarget(
            name: "ObjectHandler",
            dependencies: [
                "ActivityPubCore",
                .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
            ]
        ),
        .executableTarget(
            name: "ProfileHandler",
            dependencies: [
                "ActivityPubCore",
                .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
            ]
        ),
        .executableTarget(
            name: "InboxHandler",
            dependencies: [
                "ActivityPubCore",
                .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
            ]
        ),
        .executableTarget(
            name: "DeliverHandler",
            dependencies: [
                "ActivityPubCore",
                .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
                .product(name: "AWSSSM", package: "aws-sdk-swift"),
            ]
        ),

        .executableTarget(
            name: "PostHandler",
            dependencies: [
                "ActivityPubCore",
                .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
                .product(name: "AWSSSM", package: "aws-sdk-swift"),
                .product(name: "AWSCloudFront", package: "aws-sdk-swift"),
            ]
        ),
        .executableTarget(
            name: "MediaUploadHandler",
            dependencies: [
                "ActivityPubCore",
                .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
                .product(name: "AWSS3", package: "aws-sdk-swift"),
                .product(name: "AWSSSM", package: "aws-sdk-swift"),
            ]
        ),

        // Provisioning CLI
        .executableTarget(
            name: "ActivityProvisioner",
            dependencies: [
                "ActivityPubCore",
                .product(name: "AWSDynamoDB", package: "aws-sdk-swift"),
                .product(name: "AWSSSM", package: "aws-sdk-swift"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        // OpenAPI-generated client
        .target(
            name: "APIClient",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ],
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator"),
            ]
        ),

        // Unit tests
        .testTarget(
            name: "ActivityPubCoreTests",
            dependencies: [
                "ActivityPubCore",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ]
        ),

        // Integration tests (require deployed stack + TEST_API_URL env var)
        .testTarget(
            name: "IntegrationTests",
            dependencies: [
                "APIClient",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ]
        ),
    ]
)
