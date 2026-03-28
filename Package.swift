// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "activity-happitec",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "WebFingerHandler", targets: ["WebFingerHandler"])
    ],
    dependencies: [
        .package(url: "https://github.com/swift-server/swift-aws-lambda-runtime.git", from: "2.0.0"),
        .package(url: "https://github.com/swift-server/swift-aws-lambda-events.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "WebFingerHandler",
            dependencies: [
                .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
            ]
        )
    ]
)
