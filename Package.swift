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
    dependencies: [
        // Add any external dependencies here if needed
    ],
    targets: [
        .target(
            name: "Octopus_Agile_Helper",
            path: "Octopus_Agile_Helper"),
        .testTarget(
            name: "Octopus_Agile_HelperTests",
            dependencies: ["Octopus_Agile_Helper"],
            path: "Octopus_Agile_HelperTests")
    ]
) 