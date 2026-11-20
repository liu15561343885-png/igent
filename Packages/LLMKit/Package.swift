// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LLMKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "LLMKit", targets: ["LLMKit"])
    ],
    dependencies: [
        .package(path: "../CoreKit")
    ],
    targets: [
        .target(
            name: "LLMKit",
            dependencies: [.product(name: "CoreKit", package: "CoreKit")]
        ),
        .testTarget(
            name: "LLMKitTests",
            dependencies: ["LLMKit"],
            resources: [.copy("Fixtures")]
        )
    ]
)
