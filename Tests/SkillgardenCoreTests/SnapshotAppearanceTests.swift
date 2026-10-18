import Foundation
import Testing
@testable import SkillgardenCore

private let repo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private final class TestBundleMarker {}

/// The dark Garden page `#1E1E20` and the light page (white).
private let darkPage: [UInt8] = [0x1E, 0x1E, 0x20]
private let lightPage: [UInt8] = [0xFF, 0xFF, 0xFF]

/// True when each channel is within 3 of the expected value. The capture converts the page color to device RGB.
private func matches(_ color: [UInt8]?, _ expected: [UInt8]) -> Bool {
    guard let color else { return false }
    return zip(color, expected).allSatisfy { abs(Int($0) - Int($1)) <= 3 }
}

/// #82: the `-dark` captures must reach SwiftUI as dark mode, like the real app in dark mode.
/// The test reads the page color near the bottom right corner of each capture.
@Test func darkSnapshotsUseTheDarkAppearance() throws {
    // `swift test` builds the app next to the test bundle.
    let app = Bundle(for: TestBundleMarker.self).bundleURL.deletingLastPathComponent().appending(path: "SkillgardenApp")
    try #require(FileManager.default.isExecutableFile(atPath: app.path), "build SkillgardenApp before the tests")
    let out = FileManager.default.temporaryDirectory.appending(path: "SnapshotAppearanceTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: out) }

    let screens: [SnapshotScreen] = [.libraryEmpty, .courseLandingDarkTheme, .lecture]
    let process = Process()
    process.executableURL = app
    process.arguments = ["--snapshot", out.path, "--fixture", repo.appending(path: "Tests/Fixtures/sample-course").path]
        + screens.flatMap { ["--screen", $0.rawValue] }
    let stderr = Pipe()
    process.standardOutput = FileHandle.nullDevice
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    let errorText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(errorText.isEmpty)
    #expect(process.terminationStatus == 0)

    func capture(_ name: String) -> Data? { try? Data(contentsOf: out.appending(path: "\(name).png")) }
    func pageColor(_ name: String) -> [UInt8]? {
        let x = (SnapshotPlan.width - 20) * SnapshotPlan.scale, y = (SnapshotPlan.height - 20) * SnapshotPlan.scale
        return capture(name).flatMap { SnapshotCheck.color(png: $0, x: x, y: y) }
    }
    func expectPage(_ name: String, _ expected: [UInt8]) {
        let color = pageColor(name)
        #expect(matches(color, expected), "\(name): page color \(color.map { "\($0)" } ?? "missing")")
    }

    // No course theme: the window follows the light or dark appearance.
    expectPage("library-empty-light", lightPage)
    expectPage("library-empty-dark", darkPage)
    #expect(capture("library-empty-light") != capture("library-empty-dark"))
    // A dark course theme is dark in both appearances.
    expectPage("course-landing-dark-theme-dark", darkPage)
    // The light fixture theme stays light in dark mode, like the real app (owner decision).
    expectPage("lecture-dark", lightPage)
    // The fixture copy without a theme follows the dark appearance.
    expectPage("lecture-unthemed-dark", darkPage)
    #expect(!FileManager.default.fileExists(atPath: out.appending(path: "lecture-unthemed-light.png").path))
    #expect(!FileManager.default.fileExists(atPath: out.appending(path: "course-landing-dark-theme-unthemed-dark.png").path))
}
