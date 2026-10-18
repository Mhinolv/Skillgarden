import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import SkillgardenCore

private let repo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The window of these tests has a 52 pt title bar and toolbar. Window coordinates go down.
private let toolbarBottom: CGFloat = 52

@Test func playerBelowTheToolbarShowsFully() {
    #expect(PlayerClip.hiddenTop(playerMinY: 120, height: 360, visibleTop: toolbarBottom) == 0)
    // The top edge of the player is on the bottom edge of the toolbar.
    #expect(PlayerClip.hiddenTop(playerMinY: 52, height: 360, visibleTop: toolbarBottom) == 0)
}

@Test func playerUnderTheToolbarHidesItsTopPart() {
    #expect(PlayerClip.hiddenTop(playerMinY: 51, height: 360, visibleTop: toolbarBottom) == 1)
    #expect(PlayerClip.hiddenTop(playerMinY: -100, height: 360, visibleTop: toolbarBottom) == 152)
    // One point of the player is below the toolbar.
    #expect(PlayerClip.hiddenTop(playerMinY: -307, height: 360, visibleTop: toolbarBottom) == 359)
}

@Test func playerFullyUnderTheToolbarHidesAll() {
    #expect(PlayerClip.hiddenTop(playerMinY: -308, height: 360, visibleTop: toolbarBottom) == 360)
    #expect(PlayerClip.hiddenTop(playerMinY: -5000, height: 360, visibleTop: toolbarBottom) == 360)
}

@Test func playerClipHandlesEmptyAndInvalidValues() {
    #expect(PlayerClip.hiddenTop(playerMinY: 0, height: 0, visibleTop: toolbarBottom) == 0)
    #expect(PlayerClip.hiddenTop(playerMinY: 0, height: -10, visibleTop: toolbarBottom) == 0)
    #expect(PlayerClip.hiddenTop(playerMinY: .nan, height: 360, visibleTop: toolbarBottom) == 0)
    #expect(PlayerClip.hiddenTop(playerMinY: 0, height: 360, visibleTop: .infinity) == 0)
    // A window with no toolbar hides nothing on a page that starts at the top.
    #expect(PlayerClip.hiddenTop(playerMinY: 0, height: 360, visibleTop: 0) == 0)
}

/// A PNG of `width` × `height` pixels in `fill`, with the top `blackRows` rows in pure black.
/// `blackColumns` adds a full-height black line at these columns, like the dark split view divider.
private func png(width: Int, height: Int, blackRows: Int, fill: CGColor, blackColumns: Range<Int>? = nil) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(fill)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    // CGContext coordinates go up, so the top rows are at the end of the y range.
    context.fill(CGRect(x: 0, y: height - blackRows, width: width, height: blackRows))
    if let blackColumns {
        context.fill(CGRect(x: blackColumns.lowerBound, y: 0, width: blackColumns.count, height: height))
    }
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

@Test func blackPixelsCountOnlyTheTopRows() throws {
    let light = CGColor(red: 0.92, green: 0.94, blue: 0.92, alpha: 1)
    let image = try png(width: 10, height: 20, blackRows: 3, fill: light)
    #expect(SnapshotCheck.blackPixels(png: image, topRows: 0) == 0)
    #expect(SnapshotCheck.blackPixels(png: image, topRows: 2) == 20)
    #expect(SnapshotCheck.blackPixels(png: image, topRows: 3) == 30)
    #expect(SnapshotCheck.blackPixels(png: image, topRows: 10) == 30)
    // More rows than the image has count all rows.
    #expect(SnapshotCheck.blackPixels(png: image, topRows: 500) == 30)
    #expect(SnapshotCheck.blackPixels(png: image, topRows: -1) == 0)
    #expect(SnapshotCheck.blackPixels(png: try png(width: 10, height: 20, blackRows: 0, fill: light), topRows: 20) == 0)
}

@Test func blackPixelsIgnoreTheDarkPageColor() throws {
    // A dark page color is darker than the text but lighter than the black video frame.
    let dark = CGColor(red: 0.08, green: 0.09, blue: 0.08, alpha: 1)
    #expect(SnapshotCheck.blackPixels(png: try png(width: 10, height: 20, blackRows: 0, fill: dark), topRows: 20) == 0)
    #expect(SnapshotCheck.blackPixels(png: Data("not an image".utf8), topRows: 20) == nil)
}

/// #82: in dark mode the split view divider is a 1 pt black line through the title bar. It is not video.
@Test func blackPixelsIgnoreTheDarkDividerLine() throws {
    let dark = CGColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1)
    // A 2-pixel line (1 pt at scale 2) does not count. A line at the left or right edge does not count.
    #expect(SnapshotCheck.blackPixels(png: try png(width: 10, height: 20, blackRows: 0, fill: dark, blackColumns: 4..<6), topRows: 20) == 0)
    #expect(SnapshotCheck.blackPixels(png: try png(width: 10, height: 20, blackRows: 0, fill: dark, blackColumns: 0..<1), topRows: 20) == 0)
    #expect(SnapshotCheck.blackPixels(png: try png(width: 10, height: 20, blackRows: 0, fill: dark, blackColumns: 8..<10), topRows: 20) == 0)
    // A wider black area is video: 3 columns in 5 rows.
    #expect(SnapshotCheck.blackPixels(png: try png(width: 10, height: 20, blackRows: 0, fill: dark, blackColumns: 4..<7), topRows: 5) == 15)
    // Black rows across the line count as one run.
    #expect(SnapshotCheck.blackPixels(png: try png(width: 10, height: 20, blackRows: 2, fill: dark, blackColumns: 4..<6), topRows: 5) == 20)
}

private final class TestBundleMarker {}

/// #55: the lecture page scrolls under the transparent title bar. The AVKit player must not draw over the window title.
/// The test renders the scrolled `video-transcript` screen with the snapshot harness of the app.
@Test func scrolledVideoDoesNotDrawOverTheTitlebar() throws {
    // `swift test` builds the app next to the test bundle.
    let app = Bundle(for: TestBundleMarker.self).bundleURL.deletingLastPathComponent().appending(path: "SkillgardenApp")
    try #require(FileManager.default.isExecutableFile(atPath: app.path), "build SkillgardenApp before the tests")
    let out = FileManager.default.temporaryDirectory.appending(path: "PlayerClipTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: out) }

    let process = Process()
    process.executableURL = app
    process.arguments = ["--snapshot", out.path, "--fixture", repo.appending(path: "Tests/Fixtures/sample-course").path,
                         "--screen", SnapshotScreen.videoTranscript.rawValue]
    let stderr = Pipe()
    process.standardOutput = FileHandle.nullDevice
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    let errorText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(errorText.isEmpty)
    #expect(process.terminationStatus == 0)

    // The compact toolbar row (#74) is 38 pt high.
    let rows = 38 * SnapshotPlan.scale
    // The unthemed capture is the only real dark one: the fixture theme is light (#82).
    for name in ["light", "dark", "unthemed-dark"] {
        let capture = try Data(contentsOf: out.appending(path: "video-transcript-\(name).png"))
        #expect(SnapshotCheck.blackPixels(png: capture, topRows: rows) == 0, "\(name)")
    }
}
