import Foundation
import Testing
@testable import SkillgardenCore

private let repo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private final class TestBundleMarker {}

private func bytes(_ color: ThemeColor) -> [UInt8] {
    [color.red, color.green, color.blue].map { UInt8(($0 * 255).rounded()) }
}

/// #89: the selection fill is a soft accent tint, so ink text stays readable in light and dark mode.
@Test(arguments: [CourseAppearance.light, .dark], ["#286644", "#7FD3A0", "#2F6FED", "#000000", "#FFFFFF", "#C2412C"])
func sidebarSelectionKeepsInkReadable(appearance: CourseAppearance, hex: String) throws {
    let accent = try #require(CourseTheme(accentColor: hex, appearance: appearance).accent ?? ThemeColor(hex: "#007AFF"))
    let selection = SidebarSelection.color(accent: accent, appearance: appearance)
    #expect(SidebarSelection.ink(for: appearance).contrastRatio(with: selection) >= 4.5)
    // The tint must show on the sidebar: it is not the plain sidebar base.
    #expect(selection != appearance.sidebarBase)
}

@Test func sidebarSelectionUsesTheDesignFractions() {
    #expect(SidebarSelection.fraction(for: .light) == 0.14)
    #expect(SidebarSelection.fraction(for: .dark) == 0.24)
    let accent = ThemeColor(hex: "#286644")!
    #expect(SidebarSelection.color(accent: accent, appearance: .light) == ThemeColor(hex: "#F4F4F3")!.mixed(with: accent, by: 0.14))
    #expect(SidebarSelection.color(accent: accent, appearance: .dark)
        == ThemeColor(hex: "#262628")!.mixed(with: accent.displayAccent(for: .dark), by: 0.24))
}

/// #89: the selected outline row shows the quiet accent tint, not the system selection fill.
/// The test renders the selected lecture (light theme) and the selected overview (dark theme) in each app appearance,
/// then counts the pixels with the selection color in one column of the sidebar.
@Test func selectedOutlineRowUsesTheAccentTint() throws {
    // `swift test` builds the app next to the test bundle.
    let app = Bundle(for: TestBundleMarker.self).bundleURL.deletingLastPathComponent().appending(path: "SkillgardenApp")
    try #require(FileManager.default.isExecutableFile(atPath: app.path), "build SkillgardenApp before the tests")
    let out = FileManager.default.temporaryDirectory.appending(path: "SidebarSelectionTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: out) }

    let screens: [SnapshotScreen] = [.lecture, .courseLandingDarkTheme]
    let process = Process()
    process.executableURL = app
    process.arguments = ["--snapshot", out.path, "--fixture", repo.appending(path: "Tests/Fixtures/sample-course").path]
        + screens.flatMap { ["--screen", $0.rawValue] }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)

    /// The pixels in the sidebar column at x = 260 pt, from 100 pt to 400 pt, within 3 of `expected` in each channel.
    func selectionPixels(_ name: String, _ expected: [UInt8]) -> Int {
        guard let png = try? Data(contentsOf: out.appending(path: "\(name).png")) else { return 0 }
        let x = 260 * SnapshotPlan.scale
        return (100 * SnapshotPlan.scale..<400 * SnapshotPlan.scale).filter { y in
            guard let color = SnapshotCheck.color(png: png, x: x, y: y) else { return false }
            return zip(color, expected).allSatisfy { abs(Int($0) - Int($1)) <= 3 }
        }.count
    }

    let lightAccent = ThemeColor(hex: "#286644")!
    let darkAccent = ThemeColor(hex: SnapshotPlan.darkThemeAccent)!
    // #93: the app setting (the capture appearance) wins over the theme appearance. The theme keeps its accent.
    let cases: [(name: String, accent: ThemeColor, appearance: CourseAppearance)] = [
        ("lecture-light", lightAccent, .light), ("lecture-dark", lightAccent, .dark),
        ("course-landing-dark-theme-light", darkAccent, .light), ("course-landing-dark-theme-dark", darkAccent, .dark),
    ]
    // One 26 pt row is 52 pixels. Allow a few pixels for the rounded corners and antialiasing.
    for item in cases {
        let selection = bytes(SidebarSelection.color(accent: item.accent, appearance: item.appearance))
        let count = selectionPixels(item.name, selection)
        #expect(count >= 40, "\(item.name): \(count) pixels with the selection tint \(selection)")
    }
}
