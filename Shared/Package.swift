// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "OctopusHelperShared",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "OctopusHelperShared",
            type: .dynamic,
            targets: ["OctopusHelperShared"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "OctopusHelperShared",
            dependencies: [],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "OctopusHelperSharedTests",
            dependencies: ["OctopusHelperShared"]),
    ]
) 