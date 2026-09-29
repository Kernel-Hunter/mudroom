// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Mudroom",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MudroomCore", targets: ["MudroomCore"]),
        .executable(name: "mudroom", targets: ["mudroom"]),
        .executable(name: "MudroomApp", targets: ["MudroomApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "MudroomCore"),
        .executableTarget(
            name: "mudroom",
            dependencies: [
                "MudroomCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "MudroomApp",
            dependencies: ["MudroomCore"]
        ),
        .testTarget(name: "MudroomCoreTests", dependencies: ["MudroomCore"]),
    ],
    swiftLanguageModes: [.v6]
)
