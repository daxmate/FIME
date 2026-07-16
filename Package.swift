// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FIME",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "FIME",
            targets: ["FIME"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "FIME",
            dependencies: [],
            path: "Sources",
            resources: [
                .copy("../Resources/words.txt")
            ],
            linkerSettings: [
                .linkedFramework("InputMethodKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("Foundation")
            ]
        )
    ]
)
