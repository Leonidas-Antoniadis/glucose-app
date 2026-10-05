// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GlucoseCore",
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10)],
    products: [
        .library(name: "GlucoseCore", targets: ["GlucoseCore"]),
    ],
    targets: [
        // Pure logic only: no UIKit, CoreBluetooth or CoreNFC, so it builds and tests on Linux.
        .target(name: "GlucoseCore"),
        .testTarget(name: "GlucoseCoreTests", dependencies: ["GlucoseCore"]),
    ]
)
