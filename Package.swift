// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WoWAddonManager",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AddonCore", targets: ["AddonCore"]),
        .executable(name: "AddonManager", targets: ["AddonManager"])
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19")
    ],
    targets: [
        .target(name: "AddonCore", dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")]),
        .executableTarget(name: "AddonManager", dependencies: ["AddonCore"]),
        .testTarget(name: "AddonCoreTests", dependencies: ["AddonCore", .product(name: "ZIPFoundation", package: "ZIPFoundation")])
    ]
)
