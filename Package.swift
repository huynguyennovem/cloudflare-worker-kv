// swift-tools-version: 6.0
// The Swift package lives at the repository root so that SwiftPM can resolve it
// straight from the Git URL. Its sources and tests are under ios/.
import PackageDescription

let package = Package(
    name: "CloudflareWorkerKV",
    platforms: [.iOS(.v15), .macOS(.v12), .tvOS(.v15), .watchOS(.v8), .visionOS(.v1)],
    products: [
        .library(name: "CloudflareWorkerKV", targets: ["CloudflareWorkerKV"]),
    ],
    targets: [
        .target(
            name: "CloudflareWorkerKV",
            path: "ios/Sources/CloudflareWorkerKV",
            resources: [.copy("PrivacyInfo.xcprivacy")],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "CloudflareWorkerKVTests",
            dependencies: ["CloudflareWorkerKV"],
            path: "ios/Tests/CloudflareWorkerKVTests",
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
