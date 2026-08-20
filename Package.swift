// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "VoxPrompt",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "0.18.0"),
    ],
    targets: [
        // Traitement de texte pur (nettoyage des repetitions, glossaire). Isole dans sa
        // propre bibliotheque pour etre couvert par des tests unitaires : un executable
        // ne se teste pas directement avec XCTest.
        .target(
            name: "VoxPromptCore",
            path: "Sources/VoxPromptCore"
        ),
        .executableTarget(
            name: "VoxPrompt",
            dependencies: [
                "VoxPromptCore",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/VoxPrompt"
        ),
        .testTarget(
            name: "VoxPromptCoreTests",
            dependencies: ["VoxPromptCore"],
            path: "Tests/VoxPromptCoreTests"
        ),
    ]
)
