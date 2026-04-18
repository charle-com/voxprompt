// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "VoxPrompt",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "0.18.0"),
    ],
    targets: [
        .executableTarget(
            name: "VoxPrompt",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/VoxPrompt"
        ),
    ]
)
