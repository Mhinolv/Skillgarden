// swift-tools-version:5.7
// Vendored copy of https://github.com/jpsim/Yams (MIT, see LICENSE), commit df801bc.
// Vendored so builds need no network (the agent sandbox has none).
import PackageDescription

let package = Package(
    name: "Yams",
    products: [.library(name: "Yams", targets: ["Yams"])],
    targets: [
        .target(name: "CYaml", cSettings: [.define("YAML_DECLARE_STATIC")]),
        .target(name: "Yams", dependencies: ["CYaml"], cSettings: [.define("YAML_DECLARE_STATIC")]),
    ]
)
