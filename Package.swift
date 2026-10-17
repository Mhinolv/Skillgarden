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
    targets: [
        .target(name: "SkillgardenCore"),
        .executableTarget(name: "skillgarden", dependencies: ["SkillgardenCore"]),
        .executableTarget(name: "SkillgardenApp", dependencies: ["SkillgardenCore"]),
        .testTarget(name: "SkillgardenCoreTests", dependencies: ["SkillgardenCore"]),
    ]
)
