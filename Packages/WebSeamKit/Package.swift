// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WebSeamKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "WebSeamKit", targets: ["WebSeamKit"])
    ],
    dependencies: [
        .package(path: "../CoreKit")
    ],
    targets: [
        .target(
            name: "WebSeamKit",
            dependencies: [.product(name: "CoreKit", package: "CoreKit")]
        ),
        .testTarget(name: "WebSeamKitTests", dependencies: ["WebSeamKit"])
    ]
)
