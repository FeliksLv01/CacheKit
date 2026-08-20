// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CacheKit",
    platforms: [
        .iOS(.v15),
    ],
    products: [
        .library(name: "CacheKit", targets: ["CacheKit"]),
    ],
    targets: [
        .target(
            name: "CacheKit",
            path: "Sources/CacheKit",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "CacheKitTests",
            dependencies: ["CacheKit"],
            path: "Tests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
