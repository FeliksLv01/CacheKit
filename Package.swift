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
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .target(
            name: "CacheKitObjC",
            path: "Sources/CacheKitObjC",
            publicHeadersPath: "include"
        ),
        .target(
            name: "CacheKit",
            dependencies: [
                "CacheKitObjC",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/CacheKit"
        ),
        .testTarget(
            name: "CacheKitTests",
            dependencies: ["CacheKit"],
            path: "Tests"
        ),
    ]
)
