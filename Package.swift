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
    dependencies: [
        // Used only to read Google's Platform Tools ZIP during explicit local setup.
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
    ],
    targets: [
        .target(name: "PhoneBackupCore"),
        .target(name: "ADBInstallerLock", publicHeadersPath: "include"),
        .target(name: "PhoneBackupUI", dependencies: [
            "PhoneBackupCore",
            "ADBInstallerLock",
            .product(name: "ZIPFoundation", package: "ZIPFoundation"),
        ]),
        .executableTarget(name: "PhoneBackupApp", dependencies: ["PhoneBackupCore", "PhoneBackupUI"]),
        .testTarget(name: "PhoneBackupUITests", dependencies: [
            "PhoneBackupCore", "PhoneBackupUI",
            .product(name: "ZIPFoundation", package: "ZIPFoundation"),
        ],
                    path: "tests/PhoneBackupUITests"),
        .testTarget(
            name: "PhoneBackupCoreTests",
            dependencies: ["PhoneBackupCore"],
            path: "tests/PhoneBackupCoreTests"
        ),
    ]
)
