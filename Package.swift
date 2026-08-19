// swift-tools-version: 5.9

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
            name: "CacheKitObjC",
            path: "Sources/CacheKitObjC",
            publicHeadersPath: "include"
        ),
        .target(
            name: "CacheKit",
            dependencies: ["CacheKitObjC"],
            path: "Sources/CacheKit",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "CacheKitTests",
            dependencies: ["CacheKit"],
            path: "Tests"
        ),
    ]
)
