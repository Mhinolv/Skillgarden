// swift-tools-version:5.7
// Vendored copy of https://github.com/jpsim/Yams (MIT, see LICENSE), commit df801bc.
// Vendored so builds need no network (the agent sandbox has none).
import PackageDescription

let package = Package(
    name: "Yams",
    products: [.library(name: "Yams", targets: ["Yams"])],
    targets: [
        // CYaml is libyaml (MIT). Its LICENSE is the libyaml notice that the app bundle ships (#213).
        .target(name: "CYaml", exclude: ["LICENSE"], cSettings: [.define("YAML_DECLARE_STATIC")]),
        .target(name: "Yams", dependencies: ["CYaml"], cSettings: [.define("YAML_DECLARE_STATIC")]),
    ]
)
