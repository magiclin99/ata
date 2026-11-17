// swift-tools-version:5.10
import PackageDescription

// ATA macOS receiver (SPEC.md v2).
//   ATACore        protocol codec, crypto, pairing store, session engine, BLE / TCP / WebRTC transports. No UI.
//   ATAFakePhone   a scripted "phone" (handshake, encrypted messages, LAN TCP / WebRTC sender) used by the
//                  unit tests and by the ata-fakephone CLI.
//   ATA            the SwiftUI menu bar app. scripts/build-app.sh wraps it into ATA.app.
//
// ATA_DEBUG_HOOKS (debug configuration only) enables the SPEC §9 launch flags and the loopback signaling port.
let debugHooks: [SwiftSetting] = [.define("ATA_DEBUG_HOOKS", .when(configuration: .debug))]

let package = Package(
    name: "ATA",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ATA", targets: ["ATA"]),
        .executable(name: "ata-fakephone", targets: ["ata-fakephone"]),
    ],
    targets: [
        // Google libwebrtc M157 prebuilt by github.com/stasel/WebRTC (same artifact as the v1 lab).
        .binaryTarget(
            name: "WebRTC",
            url: "https://github.com/stasel/WebRTC/releases/download/157.0.0/WebRTC-M157.xcframework.zip",
            checksum: "ffb1221be2138ecc6bc92300ae4f0157e18694d652db9921e4251992ea91a328"
        ),
        .target(
            name: "ATACore",
            dependencies: ["WebRTC"],
            swiftSettings: debugHooks,
            linkerSettings: [.linkedFramework("CoreBluetooth"), .linkedFramework("Security"),
                             .linkedFramework("SystemConfiguration"), .linkedFramework("CoreWLAN")]
        ),
        .target(
            name: "ATAFakePhone",
            dependencies: ["ATACore", "WebRTC"]
        ),
        .executableTarget(
            name: "ata-fakephone",
            dependencies: ["ATAFakePhone"]
        ),
        .executableTarget(
            name: "ATA",
            dependencies: ["ATACore"],
            swiftSettings: debugHooks,
            linkerSettings: [
                // Inside ATA.app the framework lives in Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(
            name: "ATACoreTests",
            // Reads ../spec/vectors.json directly (see VectorTests), so the canonical file is the one tested.
            dependencies: ["ATACore", "ATAFakePhone"]
        ),
    ]
)
