// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "openmacbattery",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "openmacbattery", targets: ["OpenMacBattery"]),
        .executable(name: "openmacbattery-gui", targets: ["OpenMacBatteryApp"]),
        .library(name: "OpenMacBatteryCore", targets: ["OpenMacBatteryCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(
            name: "CProcInfo",
            publicHeadersPath: "."
        ),
        .target(
            name: "OpenMacBatteryCore",
            dependencies: ["CProcInfo", "CSQLite"]
        ),
        .executableTarget(
            name: "OpenMacBattery",
            dependencies: [
                "OpenMacBatteryCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .executableTarget(
            name: "OpenMacBatteryApp",
            dependencies: ["OpenMacBatteryCore"],
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Charts")
            ]
        ),
        .testTarget(
            name: "OpenMacBatteryCoreTests",
            dependencies: ["OpenMacBatteryCore"]
        )
    ]
)
