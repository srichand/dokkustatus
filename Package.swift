// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DokkuStatus",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "DokkuStatus"
        ),
        .testTarget(
            name: "DokkuStatusTests",
            dependencies: ["DokkuStatus"],
            resources: [
                .process("Fixtures/live"),
            ]
        ),
    ]
)
