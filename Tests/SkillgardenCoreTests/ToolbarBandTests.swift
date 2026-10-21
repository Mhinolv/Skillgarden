import Foundation
import Testing
@testable import SkillgardenCore

private let repo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private final class TestBundleMarker {}

private func bytes(_ color: ThemeColor) -> [UInt8] {
    [color.red, color.green, color.blue].map { UInt8(($0 * 255).rounded()) }
}

/// True when each channel is within 3 of the expected value. The capture converts the palette color to device RGB.
private func matches(_ color: [UInt8]?, _ expected: [UInt8]) -> Bool {
    guard let color else { return false }
    return zip(color, expected).allSatisfy { abs(Int($0) - Int($1)) <= 3 }
}

/// #101: each toolbar band has the solid color of the column below it, so the window is one surface.
/// The test renders the course screens and the Library home, then reads the toolbar row
/// over the sidebar and over the page. It compares each pixel with the palette color of the column.
/// Runs the snapshot harness for `screens` into `out`. Returns the exit status and the error text.
private func runSnapshots(_ screens: [SnapshotScreen], into out: URL) throws -> (status: Int32, errorText: String) {
    // `swift test` builds the app next to the test bundle.
    let app = Bundle(for: TestBundleMarker.self).bundleURL.deletingLastPathComponent().appending(path: "SkillgardenApp")
    try #require(FileManager.default.isExecutableFile(atPath: app.path), "build SkillgardenApp before the tests")
    let process = Process()
    process.executableURL = app
    process.arguments = ["--snapshot", out.path, "--fixture", repo.appending(path: "Tests/Fixtures/sample-course").path]
        + screens.flatMap { ["--screen", $0.rawValue] }
    let stderr = Pipe()
    process.standardOutput = FileHandle.nullDevice
    process.standardError = stderr
    try process.run()
    let errorText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return (process.terminationStatus, errorText)
}

@Test func toolbarBandsUseTheColumnColors() throws {
    let out = FileManager.default.temporaryDirectory.appending(path: "ToolbarBandTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: out) }

    let screens: [SnapshotScreen] = [.lecture, .courseLandingDarkTheme, .quizQuestion, .library, .videoTheater]
    let run = try runSnapshots(screens, into: out)
    // The capture does not draw the AppKit toolbar material, so the harness checks for visible material views.
    #expect(run.errorText.isEmpty)
    #expect(run.status == 0)

    /// The pixels of the toolbar row at `x` pt that do not have the `expected` color.
    /// The rows from 4 pt to 34 pt are inside the 38 pt compact row (#74), so the toolbar buttons are the only other marks.
    func offPixels(_ png: Data, x: Int, _ expected: [UInt8]) -> [[UInt8]] {
        (4 * SnapshotPlan.scale..<34 * SnapshotPlan.scale).compactMap { y in
            let color = SnapshotCheck.color(png: png, x: x * SnapshotPlan.scale, y: y)
            return matches(color, expected) ? nil : color ?? []
        }
    }

    // The sidebar is the system accent at 4% (6% in dark mode) on the sidebar gray. The page is white or #1E1E20.
    // #182: every course uses the system accent. The fixture accents #286644 and #7FD3A0 do not show.
    func sidebar(_ appearance: CourseAppearance) -> [UInt8] {
        bytes(appearance.sidebarBase.mixed(with: systemAccent(for: appearance), by: appearance == .dark ? 0.06 : 0.04))
    }
    let page: [CourseAppearance: [UInt8]] = [.light: [0xFF, 0xFF, 0xFF], .dark: [0x1E, 0x1E, 0x20]]
    // #93: the app setting (the capture appearance) wins over the theme appearance.
    let cases: [(name: String, hasSidebar: Bool, appearance: CourseAppearance)] = [
        ("lecture-light", true, .light), ("lecture-dark", true, .dark),
        ("course-landing-dark-theme-light", true, .light), ("course-landing-dark-theme-dark", true, .dark),
        ("quiz-question-light", true, .light), ("quiz-question-dark", true, .dark),
        ("library-light", false, .light), ("library-dark", false, .dark),
        // Theater hides the sidebar, so the whole toolbar row is the page band.
        ("video-theater-light", false, .light), ("video-theater-dark", false, .dark),
    ]
    for item in cases {
        let png = try #require(try? Data(contentsOf: out.appending(path: "\(item.name).png")), "\(item.name)")
        // The page band: the middle of the window has no toolbar button.
        let pageOff = offPixels(png, x: SnapshotPlan.width / 2, page[item.appearance]!)
        #expect(pageOff.isEmpty, "\(item.name): the page band has \(pageOff.count) pixels not \(page[item.appearance]!), first \(pageOff.first ?? [])")
        // The sidebar band: right of the sidebar button, left of the sidebar edge. The Library home and theater have no sidebar.
        if item.hasSidebar {
            let expected = sidebar(item.appearance)
            let sidebarOff = offPixels(png, x: 200, expected)
            #expect(sidebarOff.isEmpty, "\(item.name): the sidebar band has \(sidebarOff.count) pixels not \(expected), first \(sidebarOff.first ?? [])")
        }
    }
    // #182: two courses with different manifest accents draw the same sidebar band.
    for appearance in ["light", "dark"] {
        let lecture = try #require(try? Data(contentsOf: out.appending(path: "lecture-\(appearance).png")))
        let darkTheme = try #require(try? Data(contentsOf: out.appending(path: "course-landing-dark-theme-\(appearance).png")))
        let x = 200 * SnapshotPlan.scale, y = 20 * SnapshotPlan.scale
        #expect(SnapshotCheck.color(png: lecture, x: x, y: y) == SnapshotCheck.color(png: darkTheme, x: x, y: y), "\(appearance)")
    }
}

/// #101 QA attempt 1: the Settings screen has no main-window toolbar, so the material check must not fail it.
@Test func settingsSnapshotSkipsTheToolbarMaterialCheck() throws {
    let out = FileManager.default.temporaryDirectory.appending(path: "ToolbarBandTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: out) }
    let run = try runSnapshots([.settings, .settingsModelMissing, .settingsAIOff, .settingsAIError], into: out)
    #expect(run.errorText.isEmpty)
    #expect(run.status == 0)
    for name in ["settings-light", "settings-dark", "settings-model-missing-light", "settings-model-missing-dark",
                 "settings-ai-off-light", "settings-ai-off-dark", "settings-ai-error-light", "settings-ai-error-dark"] {
        #expect(FileManager.default.fileExists(atPath: out.appending(path: "\(name).png").path), "\(name)")
    }
}

@Test func onlyTheSettingsScreensSkipTheToolbarMaterialCheck() {
    for screen in SnapshotScreen.allCases {
        #expect(screen.checksToolbarMaterial == !screen.isSettings, "\(screen)")
    }
    #expect(SnapshotScreen.allCases.filter(\.isSettings) == [.settings, .settingsModelMissing, .settingsAIOff, .settingsAIError,
                                                               .settingsProviders, .providerSheetLMStudio, .providerSheetOllamaError,
                                                               .providerSheetOpenAI, .providerSheetOpenAIEdit, .providerSheetAnthropic,
                                                               .providerSheetAnthropicEdit, .chatGPTSheetSignedOut,
                                                               .chatGPTSheetWaiting, .chatGPTSheetSignedIn, .chatGPTSheetFailed,
                                                               .chatGPTSheetModelsLoading, .chatGPTSheetModelsEmpty, .chatGPTSheetModelsFailed, .chatGPTSheetModelGone,
                                                               .settingsChatGPTSignInAgain])
}
