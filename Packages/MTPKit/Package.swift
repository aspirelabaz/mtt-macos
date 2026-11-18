// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MTPKit",
    // Personal-use app: match the macOS version Homebrew's libmtp was built for.
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "MTPKit", targets: ["MTPKit"]),
        .executable(name: "mtt", targets: ["mtt"]),
    ],
    targets: [
        // Thin module map over Homebrew's libmtp (/opt/homebrew/opt/libmtp).
        .systemLibrary(
            name: "CLibMTP",
            providers: [.brew(["libmtp"])]
        ),
        // Small C helpers that reach into libmtp's private device state.
        .target(
            name: "CMTPShim",
            dependencies: ["CLibMTP"]
        ),
        .target(
            name: "MTPKit",
            dependencies: ["CLibMTP", "CMTPShim"],
            cSettings: [.unsafeFlags(["-I/opt/homebrew/opt/libmtp/include"])],
            linkerSettings: [.unsafeFlags(["-L/opt/homebrew/opt/libmtp/lib"])]
        ),
        .executableTarget(
            name: "mtt",
            dependencies: ["MTPKit"],
            linkerSettings: [.unsafeFlags(["-L/opt/homebrew/opt/libmtp/lib"])]
        ),
    ]
)
