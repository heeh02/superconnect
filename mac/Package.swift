// swift-tools-version: 5.9
import Foundation
import PackageDescription

let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .path
#if arch(arm64)
let coreHostTarget = "aarch64-apple-darwin"
#elseif arch(x86_64)
let coreHostTarget = "x86_64-apple-darwin"
#else
#error("Unsupported Mac build host")
#endif
let defaultCoreFFILibraryPath =
    "\(repositoryRoot)/.build/core-ffi/\(coreHostTarget)/dev-ffi"
let coreFFILibraryPath = ProcessInfo.processInfo.environment["SC_MAC_CORE_FFI_LIBRARY_PATH"]
    ?? defaultCoreFFILibraryPath
let coreArchive = "\(coreFFILibraryPath)/libsuperconnect_core.a"
guard FileManager.default.fileExists(atPath: coreArchive) else {
    fatalError("foss_preview_canonical_rust_core_required: \(coreArchive)")
}

let package = Package(
    name: "SuperconnectFOSSPreview",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SuperconnectCore", targets: ["SuperconnectCore"]),
        .executable(
            name: "superconnect-app-foss-preview",
            targets: ["superconnect-app-foss-preview"]
        ),
    ],
    targets: [
        .target(name: "CGVirtualDisplayPrivate"),
        .target(
            name: "SuperconnectCoreFFI",
            path: "Sources/SuperconnectCoreFFI",
            publicHeadersPath: "include"
        ),
        .target(
            name: "SuperconnectCore",
            dependencies: ["SuperconnectCoreFFI"],
            linkerSettings: [
                .unsafeFlags(["-L", coreFFILibraryPath]),
                .linkedLibrary("superconnect_core"),
                .linkedFramework("Network"),
                .linkedFramework("CryptoKit"),
            ]
        ),
        // Optional, consent-gated input reuses the existing public keyboard and pen effects.
        .target(
            name: "SuperconnectProducer",
            dependencies: ["SuperconnectCore", "CGVirtualDisplayPrivate"],
            path: "Sources/SuperconnectProducer",
            exclude: [
                "InputInjector.swift",
            ],
            sources: [
                "DisplayModeGuard.swift",
                "FOSSPointerInjector.swift",
                "KeyMap.swift",
                "KeyboardInjector.swift",
                "PenInjector.swift",
                "Producer.swift",
                "ScreenCapture.swift",
                "VideoEncoder.swift",
                "VirtualDisplay.swift",
            ],
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "superconnect-app-foss-preview",
            dependencies: ["SuperconnectCore", "SuperconnectProducer"],
            path: "Sources/superconnect-app",
            swiftSettings: [.define("SC_FOSS_PREVIEW")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "SuperconnectCoreTests",
            dependencies: ["SuperconnectCore", "SuperconnectCoreFFI"],
            path: "Tests/SuperconnectCoreTests"
        ),
        .testTarget(
            name: "SuperconnectFOSSPreviewTests",
            dependencies: [
                "superconnect-app-foss-preview",
                "SuperconnectCore",
                "SuperconnectCoreFFI",
            ],
            path: "Tests/SuperconnectFOSSPreviewTests",
            swiftSettings: [.define("SC_RUST_SESSION_TESTS")]
        ),
    ]
)
