// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Octopus_Agile_Helper",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "Octopus_Agile_Helper",
            targets: ["Octopus_Agile_Helper"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "Octopus_Agile_Helper",
            dependencies: [],
            path: "Octopus_Agile_Helper",
            resources: [
                .process("Resources"),
                .process("Assets.xcassets"),
                .process("Preview Content")
            ]
        ),
        .testTarget(
            name: "Octopus_Agile_HelperTests",
            dependencies: ["Octopus_Agile_Helper"],
            path: "Octopus_Agile_HelperTests")
    ]
) 