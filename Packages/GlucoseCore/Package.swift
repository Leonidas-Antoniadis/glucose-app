// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GlucoseCore",
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10)],
    products: [
        .library(name: "GlucoseCore", targets: ["GlucoseCore"]),
        .library(name: "LibreProtocol", targets: ["LibreProtocol"]),
    ],
    targets: [
        // Pure logic only: no UIKit, CoreBluetooth or CoreNFC, so everything builds and tests on Linux.
        .target(name: "GlucoseCore"),
        // Libre 2 / 2 Plus (EU) byte-level protocol: crypto, FRAM and BLE packet parsing.
        .target(name: "LibreProtocol", dependencies: ["GlucoseCore"]),
        .testTarget(name: "GlucoseCoreTests", dependencies: ["GlucoseCore"]),
        .testTarget(name: "LibreProtocolTests", dependencies: ["LibreProtocol", "GlucoseCore"]),
    ]
)
