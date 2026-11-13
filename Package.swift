// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Androdo",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PhoneBackupCore", targets: ["PhoneBackupCore"]),
        .library(name: "PhoneBackupUI", targets: ["PhoneBackupUI"]),
        .executable(name: "Androdo", targets: ["PhoneBackupApp"]),
    ],
    targets: [
        .target(name: "PhoneBackupCore"),
        .target(name: "PhoneBackupUI", dependencies: ["PhoneBackupCore"]),
        .executableTarget(name: "PhoneBackupApp", dependencies: ["PhoneBackupCore", "PhoneBackupUI"]),
        .testTarget(name: "PhoneBackupUITests", dependencies: ["PhoneBackupCore", "PhoneBackupUI"],
                    path: "tests/PhoneBackupUITests"),
        .testTarget(
            name: "PhoneBackupCoreTests",
            dependencies: ["PhoneBackupCore"],
            path: "tests/PhoneBackupCoreTests"
        ),
    ]
)
