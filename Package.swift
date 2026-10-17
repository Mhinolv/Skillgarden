// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Skillgarden",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SkillgardenCore", targets: ["SkillgardenCore"]),
        .executable(name: "skillgarden", targets: ["skillgarden"]),
        .executable(name: "SkillgardenApp", targets: ["SkillgardenApp"]),
    ],
    dependencies: [
        .package(path: "Vendor/Yams"),
    ],
    targets: [
        .target(name: "SkillgardenCore", dependencies: [.product(name: "Yams", package: "Yams")]),
        .executableTarget(name: "skillgarden", dependencies: ["SkillgardenCore"]),
        .executableTarget(name: "SkillgardenApp", dependencies: ["SkillgardenCore"]),
        .testTarget(name: "SkillgardenCoreTests", dependencies: ["SkillgardenCore"]),
    ]
)
