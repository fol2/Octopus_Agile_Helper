// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Octopus_Agile_Helper",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .executable(
            name: "Octopus_Agile_Helper",
            targets: ["Octopus_Agile_Helper"]),
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "Octopus_Agile_Helper",
            dependencies: [],
            path: "Octopus_Agile_Helper",
            resources: [
                .process("Assets.xcassets"),
                .process("Preview Content"),
                .process("Info.plist"),
                .process("Octopus_Agile_Helper.xcdatamodeld"),
                .process("Octopus_Agile_Helper.entitlements")
            ]
        ),
        .testTarget(
            name: "Octopus_Agile_HelperTests",
            dependencies: ["Octopus_Agile_Helper"],
            path: "Octopus_Agile_HelperTests")
    ]
) 