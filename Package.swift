// swift-tools-version: 6.2
import PackageDescription

// MudroomCore and the `mudroom` CLI build on macOS and Linux. The SwiftUI app
// is macOS only, so it is left out of the package everywhere else.

var products: [Product] = [
    .library(name: "MudroomCore", targets: ["MudroomCore"]),
    .executable(name: "mudroom", targets: ["mudroom"]),
]

var targets: [Target] = [
    .target(
        name: "MudroomCore",
        dependencies: [
            // CryptoKit on Apple platforms, swift-crypto (same API) elsewhere.
            .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
        ]
    ),
    .executableTarget(
        name: "mudroom",
        dependencies: [
            "MudroomCore",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]
    ),
    .testTarget(name: "MudroomCoreTests", dependencies: ["MudroomCore"]),
]

#if os(macOS)
products.append(.executable(name: "MudroomApp", targets: ["MudroomApp"]))
targets.append(.executableTarget(name: "MudroomApp", dependencies: ["MudroomCore"]))
#endif

let package = Package(
    name: "Mudroom",
    platforms: [.macOS(.v26)],
    products: products,
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto", "3.0.0"..<"5.0.0"),
    ],
    targets: targets,
    swiftLanguageModes: [.v6]
)
