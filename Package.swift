// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MacImagesConvert",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MacImagesConvertCore", targets: ["MacImagesConvertCore"]),
        .executable(name: "MacImagesConvert", targets: ["MacImagesConvert"])
    ],
    targets: [
        .target(name: "MacImagesConvertCore"),
        .executableTarget(name: "MacImagesConvert", dependencies: ["MacImagesConvertCore"]),
        .testTarget(name: "MacImagesConvertTests", dependencies: ["MacImagesConvertCore"])
    ]
)
