// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PhoneBackup",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PhoneBackupCore", targets: ["PhoneBackupCore"]),
        .executable(name: "PhoneBackupApp", targets: ["PhoneBackupApp"]),
    ],
    targets: [
        .target(name: "PhoneBackupCore"),
        .executableTarget(name: "PhoneBackupApp", dependencies: ["PhoneBackupCore"]),
        .testTarget(
            name: "PhoneBackupCoreTests",
            dependencies: ["PhoneBackupCore"],
            path: "tests/PhoneBackupCoreTests"
        ),
    ]
)
