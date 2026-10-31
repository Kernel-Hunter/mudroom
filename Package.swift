// swift-tools-version: 6.2
import PackageDescription

// MudroomCore and the `mudroom` CLI build on macOS, Linux and Windows. The
// SwiftUI app is macOS only, so it is left out of the package everywhere else.

var products: [Product] = [
    .library(name: "MudroomCore", targets: ["MudroomCore"]),
    .executable(name: "mudroom", targets: ["mudroom"]),
]

var targets: [Target] = [
    .target(
        name: "MudroomCore",
        dependencies: [
            // CryptoKit on Apple platforms, swift-crypto (same API) elsewhere.
            .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux, .windows])),
        ],
        linkerSettings: [
            // Winsock for the proxy, Advapi32 for Credential Manager.
            .linkedLibrary("ws2_32", .when(platforms: [.windows])),
            .linkedLibrary("advapi32", .when(platforms: [.windows])),
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

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    .package(url: "https://github.com/apple/swift-crypto", "3.0.0"..<"5.0.0"),
]

#if os(macOS)
products.append(.executable(name: "MudroomApp", targets: ["MudroomApp"]))
targets.append(.executableTarget(
    name: "MudroomApp",
    dependencies: ["MudroomCore", .product(name: "Sparkle", package: "Sparkle")],
    linkerSettings: [
        // scripts/build-app.sh puts Sparkle.framework in Contents/Frameworks.
        .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
    ]
))
// The app's updater. Pinned: an update to it is a change to how Mudroom
// replaces itself, so it should be a deliberate one.
dependencies.append(.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"))
#endif

let package = Package(
    name: "Mudroom",
    platforms: [.macOS(.v26)],
    products: products,
    dependencies: dependencies,
    targets: targets,
    swiftLanguageModes: [.v6]
)
