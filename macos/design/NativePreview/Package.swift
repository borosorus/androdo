// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AndrodoNativePreview",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "Androdo", path: "../../..")],
    targets: [
        .executableTarget(name: "AndrodoNativePreview", dependencies: [
            .product(name: "PhoneBackupCore", package: "Androdo"),
            .product(name: "PhoneBackupUI", package: "Androdo"),
        ], path: "Sources")
    ]
)
