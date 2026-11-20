// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StorageKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "StorageKit", targets: ["StorageKit"])
    ],
    dependencies: [
        .package(path: "../CoreKit"),
        .package(path: "../LLMKit")
    ],
    targets: [
        .target(
            name: "StorageKit",
            dependencies: [
                .product(name: "CoreKit", package: "CoreKit"),
                .product(name: "LLMKit", package: "LLMKit")
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "StorageKitTests", dependencies: ["StorageKit"])
    ]
)
