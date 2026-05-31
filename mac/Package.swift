// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Superconnect",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SuperconnectCore", targets: ["SuperconnectCore"]),
        .executable(name: "superconnect-mac", targets: ["superconnect-mac"]),
        .executable(name: "superconnect-app", targets: ["superconnect-app"]),
        .executable(name: "superconnect-probe", targets: ["superconnect-probe"]),
    ],
    targets: [
        // Reverse-engineered private CoreGraphics ObjC interfaces (CGVirtualDisplay*).
        .target(name: "CGVirtualDisplayPrivate"),

        // L0–L3 transport-agnostic core: framing, transport, control session.
        .target(name: "SuperconnectCore"),

        // L4 macOS producer: virtual display, screen capture, hardware encode,
        // input injection. Uses private + system frameworks → macOS only.
        .target(
            name: "SuperconnectProducer",
            dependencies: ["SuperconnectCore", "CGVirtualDisplayPrivate"],
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
            ]
        ),

        // The Mac app: Phase 0 connectivity client + Phase 1 `--produce` host.
        .executableTarget(name: "superconnect-mac", dependencies: ["SuperconnectCore", "SuperconnectProducer"]),

        // Menu-bar GUI app: SwiftUI/AppKit front-end wrapping the produce host.
        .executableTarget(
            name: "superconnect-app",
            dependencies: ["SuperconnectCore", "SuperconnectProducer"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),

        // Phase 1 probe: validate virtual display + capture + encode pipeline.
        .executableTarget(name: "superconnect-probe", dependencies: ["SuperconnectProducer", "SuperconnectCore"]),

        // Cross-language conformance: asserts proto/vectors.json.
        .testTarget(name: "SuperconnectCoreTests", dependencies: ["SuperconnectCore"]),
    ]
)
