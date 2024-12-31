// swift-tools-version: 5.9
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
            targets: ["OctopusHelperShared"]),
    ],
    targets: [
        .target(
            name: "OctopusHelperShared",
            dependencies: []),
    ]
) 