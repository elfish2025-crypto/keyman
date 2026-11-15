// Package.swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Keyman",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KeymanCore", targets: ["KeymanCore"]),
        .library(name: "KeymanCLI", targets: ["KeymanCLI"]),
        .library(name: "KeymanAppSupport", targets: ["KeymanAppSupport"]),
        .executable(name: "Keyman", targets: ["KeymanApp"])
    ],
    targets: [
        .target(name: "KeymanCore"),
        .target(name: "KeymanCLI", dependencies: ["KeymanCore"]),
        .target(name: "KeymanAppSupport", dependencies: ["KeymanCore"]),
        .executableTarget(
            name: "KeymanApp",
            dependencies: ["KeymanCore", "KeymanCLI", "KeymanAppSupport"]
        ),
        .testTarget(
            name: "KeymanCoreTests",
            dependencies: ["KeymanCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "KeymanCLITests", dependencies: ["KeymanCLI", "KeymanCore"]),
        .testTarget(name: "KeymanAppTests", dependencies: ["KeymanAppSupport", "KeymanCore"])
    ],
    swiftLanguageModes: [.v6]
)
