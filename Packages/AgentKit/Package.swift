// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "AgentKit", targets: ["AgentKit"])
    ],
    dependencies: [
        .package(path: "../CoreKit"),
        .package(path: "../LLMKit"),
        .package(path: "../StorageKit")
    ],
    targets: [
        .target(
            name: "AgentKit",
            dependencies: [
                .product(name: "CoreKit", package: "CoreKit"),
                .product(name: "LLMKit", package: "LLMKit"),
                .product(name: "StorageKit", package: "StorageKit")
            ]
        ),
        .testTarget(name: "AgentKitTests", dependencies: ["AgentKit"])
    ]
)
