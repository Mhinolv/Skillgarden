import Foundation
import Testing
@testable import SkillgardenCore

private let repo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Test func theaterStartsOffWithTheCappedPlayer() {
    let theater = TheaterMode()
    #expect(!theater.isOn)
    #expect(theater.playerMaxWidth == 960)
    #expect(TheaterMode.videoWidth == 960)
}

@Test func theaterHidesTheSidebarAndRestoresIt() {
    var theater = TheaterMode()
    #expect(theater.set(true, sidebarHidden: false) == true)
    #expect(theater.isOn)
    #expect(theater.playerMaxWidth == nil)
    // A second start changes nothing.
    #expect(theater.set(true, sidebarHidden: true) == nil)
    #expect(theater.set(false, sidebarHidden: true) == false)
    #expect(!theater.isOn)
    #expect(theater.playerMaxWidth == 960)
    // A second end changes nothing.
    #expect(theater.set(false, sidebarHidden: false) == nil)
}

@Test func theaterKeepsAHiddenSidebarHiddenAtTheEnd() {
    var theater = TheaterMode()
    #expect(theater.set(true, sidebarHidden: true) == true)
    #expect(theater.end() == true)
    #expect(!theater.isOn)
}

@Test func escapeEndsTheaterOnlyWhenItIsOn() {
    var theater = TheaterMode()
    #expect(theater.end() == nil)
    _ = theater.set(true, sidebarHidden: false)
    #expect(theater.end() == false)
    #expect(theater.end() == nil)
}

@Test func showingTheSidebarEndsTheater() {
    var theater = TheaterMode()
    _ = theater.set(true, sidebarHidden: false)
    // Theater hides the sidebar itself. That change does not end theater.
    theater.sidebarChanged(hidden: true)
    #expect(theater.isOn)
    theater.sidebarChanged(hidden: false)
    #expect(!theater.isOn)
    // The sidebar shows already, so the end has nothing to restore.
    #expect(theater.end() == nil)
    // Off: a sidebar change does not start theater.
    theater.sidebarChanged(hidden: true)
    #expect(!theater.isOn)
}

@Test func theaterStaysOnVideoLecturesAndEndsOnOtherPages() {
    var theater = TheaterMode()
    _ = theater.set(true, sidebarHidden: false)
    #expect(theater.pageChanged(showsVideo: true) == nil)
    #expect(theater.isOn)
    #expect(theater.pageChanged(showsVideo: false) == false)
    #expect(!theater.isOn)
    #expect(theater.pageChanged(showsVideo: false) == nil)
    #expect(theater.pageChanged(showsVideo: true) == nil)
    #expect(!theater.isOn)
}

@Test func theaterSnapshotOpensThePlayerInTheater() {
    #expect(SnapshotScreen.videoTheater.rawValue == "video-theater")
    #expect(SnapshotScreen.allCases.filter(\.startsTheater) == [.videoTheater, .videoUpNextTheater, .qaTheater])
    #expect(SnapshotScreen.videoTheater.opensVideoPlayer)
    #expect(SnapshotPlan.destination(for: .videoTheater) == .lecture(sectionID: "plan", lectureID: "welcome"))
}

private final class TestBundleMarker {}

/// #85: the harness fails if the player in theater is not wider than 960 pt, if the sidebar shows,
/// or if a player has no full-screen button.
@Test func theaterSnapshotRendersAWidePlayerWithTheFullScreenButton() throws {
    // `swift test` builds the app next to the test bundle.
    let app = Bundle(for: TestBundleMarker.self).bundleURL.deletingLastPathComponent().appending(path: "SkillgardenApp")
    try #require(FileManager.default.isExecutableFile(atPath: app.path), "build SkillgardenApp before the tests")
    let out = FileManager.default.temporaryDirectory.appending(path: "TheaterModeTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: out) }

    let process = Process()
    process.executableURL = app
    process.arguments = ["--snapshot", out.path, "--fixture", repo.appending(path: "Tests/Fixtures/sample-course").path,
                         "--screen", SnapshotScreen.videoTheater.rawValue, "--screen", SnapshotScreen.videoPlayer.rawValue]
    let stderr = Pipe()
    process.standardOutput = FileHandle.nullDevice
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    let errorText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(errorText.isEmpty)
    #expect(process.terminationStatus == 0)
    for name in ["light", "dark", "unthemed-dark"] {
        #expect(FileManager.default.fileExists(atPath: out.appending(path: "video-theater-\(name).png").path), "\(name)")
    }
}
