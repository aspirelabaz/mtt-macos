// swift-tools-version: 6.0
import Foundation
import PackageDescription

/// Vendored libmtp + libusb (see Vendor/libmtp/README.md), relative to this file.
let vendorLib = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../../Vendor/libmtp/lib")
    .standardizedFileURL.path

let package = Package(
    name: "MTPKit",
    // Personal-use app: match the macOS version the vendored libmtp was built for.
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "MTPKit", targets: ["MTPKit"]),
        .library(name: "MTTShared", targets: ["MTTShared"]),
        .executable(name: "mtt", targets: ["mtt"]),
    ],
    targets: [
        // Module map over the vendored libmtp header; links -lmtp.
        .systemLibrary(name: "CLibMTP"),
        // XPC protocol + DTOs shared by the app and the Finder extension (no libmtp).
        .target(name: "MTTShared"),
        // Small C helpers that reach into libmtp's private device state.
        .target(
            name: "CMTPShim",
            dependencies: ["CLibMTP"]
        ),
        .target(
            name: "MTPKit",
            dependencies: ["CLibMTP", "CMTPShim"],
            linkerSettings: [.unsafeFlags(["-L\(vendorLib)"])]
        ),
        .executableTarget(
            name: "mtt",
            dependencies: ["MTPKit"],
            // The CLI loads the vendored dylibs straight from Vendor/.
            linkerSettings: [.unsafeFlags(["-L\(vendorLib)", "-Xlinker", "-rpath", "-Xlinker", vendorLib])]
        ),
    ]
)
