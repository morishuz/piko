// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Piko",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "Piko", targets: ["Piko"]),
        .library(name: "MTPWire", targets: ["MTPWire"]),
        .executable(name: "PikoTools", targets: ["PikoTools"]),
    ],
    targets: [
        .target(name: "MTPWire"),
        .target(name: "MTPUSB", dependencies: ["MTPWire"],
                linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("IOUSBHost")]),
        .executableTarget(name: "PikoTools", dependencies: ["MTPUSB", "MTPIntegrityKit"]),
        .testTarget(name: "MTPUSBTests", dependencies: ["MTPUSB", "MTPWire"]),
        .target(name: "MTPIntegrityKit"),
        .testTarget(name: "MTPIntegrityKitTests", dependencies: ["MTPIntegrityKit"]),
        .testTarget(name: "MTPWireTests", dependencies: ["MTPWire"]),
        .executableTarget(
            name: "Piko",
            dependencies: ["MTPWire", "MTPUSB"]
        ),
        .testTarget(
            name: "PikoTests",
            dependencies: ["Piko", "MTPWire"]
        ),
    ]
)
