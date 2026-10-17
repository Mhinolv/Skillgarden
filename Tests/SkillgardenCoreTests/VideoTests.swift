import AVFoundation
import Foundation
import Testing
@testable import SkillgardenCore

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/sample-course")

/// Gives each test a writable copy of the sample course and an empty library root.
private func withCourse(_ body: (URL, URL) throws -> Void) throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "SkillgardenVideoTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let folder = base.appending(path: "course")
    try FileManager.default.copyItem(at: fixture, to: folder)
    try FileManager.default.removeItem(at: folder.appending(path: "equivalent.json"))
    try body(folder, base.appending(path: "library"))
}

private func edit(_ folder: URL, _ old: String, _ new: String, file: String = "skillgarden.yaml") throws {
    let url = folder.appending(path: file)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains(old))
    try text.replacingOccurrences(of: old, with: new).write(to: url, atomically: true, encoding: .utf8)
}

/// Publishes and returns the diagnostics as "field: message" lines. Returns [] when the publish succeeds.
private func publishErrors(_ folder: URL, _ root: URL) throws -> [String] {
    do {
        _ = try CoursePublisher.publish(courseFolder: folder, root: root)
        return []
    } catch let error as ManifestValidationError {
        return error.diagnostics.map { "\($0.fieldPath): \($0.message)" }
    }
}

private let video = "sections[0].lectures[0].video"

// MARK: Manifest

@Test func manifestReadsTheVideoLecture() throws {
    let manifest = try ManifestLoader.load(courseFolder: fixture)
    let welcome = manifest.sections[0].lectures[0]
    #expect(welcome.video == ManifestVideo(
        path: "content/welcome.mp4", durationSeconds: 4, captions: ManifestCaptions(path: "content/welcome.vtt"),
        poster: ManifestImage(path: "media/poster.svg", alt: "The first frame of the welcome video"), freePreview: true))
    #expect(manifest.sections[0].lectures[1].video == nil)
    // A manifest saved before video support decodes with no video.
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
    var sections = try #require(object["sections"] as? [[String: Any]])
    var lectures = try #require(sections[0]["lectures"] as? [[String: Any]])
    lectures[0].removeValue(forKey: "video")
    sections[0]["lectures"] = lectures
    object["sections"] = sections
    let old = try JSONDecoder().decode(CourseManifest.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(old.sections[0].lectures[0].video == nil)
}

@Test func manifestAcceptsAVideoWithOnlyPathAndDuration() throws {
    try withCourse { folder, root in
        try edit(folder, "          captions:\n            path: content/welcome.vtt\n", "")
        try edit(folder, "          poster:\n            path: media/poster.svg\n            alt: The first frame of the welcome video\n", "")
        try edit(folder, "          free_preview: true\n", "")
        #expect(try publishErrors(folder, root) == [])
        let lecture = try ManifestLoader.load(courseFolder: folder).sections[0].lectures[0]
        #expect(lecture.video == ManifestVideo(path: "content/welcome.mp4", durationSeconds: 4))
    }
    try withCourse { folder, root in
        try edit(folder, "          free_preview: true\n", "          free_preview: false\n")
        #expect(try publishErrors(folder, root) == [])
    }
}

@Test func manifestRequiresVideoOnlyForVideoLectures() throws {
    try withCourse { folder, root in
        try edit(folder, "        video:\n", "        clip:\n")
        #expect(try publishErrors(folder, root) == ["\(video): required field is missing"])
    }
    try withCourse { folder, root in
        // Quiz, article and interactive lectures need their own field, so use an assignment to test only the video rule.
        try edit(folder, "        type: video\n", "        type: assignment\n")
        #expect(try publishErrors(folder, root) == ["\(video): allowed only when type is video"])
    }
    try withCourse { folder, root in
        // An article lecture with a video field is rejected too.
        try edit(folder, "        article:\n", "        video:\n          path: content/welcome.mp4\n          duration_seconds: 4\n        article:\n")
        #expect(try publishErrors(folder, root) == ["sections[0].lectures[1].video: allowed only when type is video"])
    }
}

@Test(arguments: [
    ("          path: content/welcome.mp4\n", "", ["\(video).path: required field is missing"]),
    ("          duration_seconds: 4\n", "", ["\(video).duration_seconds: required field is missing"]),
    ("duration_seconds: 4", "duration_seconds: 0", ["\(video).duration_seconds: must be greater than 0"]),
    ("duration_seconds: 4", "duration_seconds: -3", ["\(video).duration_seconds: must be greater than 0"]),
    ("duration_seconds: 4", "duration_seconds: '4'", ["\(video).duration_seconds: expected integer, found string"]),
    ("duration_seconds: 4", "duration_seconds: 4.5", ["\(video).duration_seconds: expected integer, found number"]),
    ("free_preview: true", "free_preview: 'yes'", ["\(video).free_preview: expected boolean, found string"]),
    ("free_preview: true", "free_preview: 1", ["\(video).free_preview: expected boolean, found integer"]),
    ("path: content/welcome.mp4", "path: content/welcome.mov", ["\(video).path: must be an .mp4 file"]),
    ("path: content/welcome.mp4", "path: ../welcome.mp4", ["\(video).path: path must stay inside the course folder"]),
    ("path: content/welcome.mp4", "path: internal/welcome.mp4", ["\(video).path: path must not be inside internal/"]),
    ("path: content/welcome.vtt", "path: content/welcome.srt", ["\(video).captions.path: must be a .vtt file"]),
    ("path: content/welcome.vtt", "path: ' '", ["\(video).captions.path: must not be empty"]),
    ("            path: content/welcome.vtt\n", "            file: content/welcome.vtt\n", ["\(video).captions.path: required field is missing"]),
    ("            alt: The first frame of the welcome video\n", "", ["\(video).poster.alt: alt text is required"]),
    ("          poster:\n", "          poster: media/poster.svg\n          unused:\n", ["\(video).poster: expected object, found string"]),
])
func manifestRejectsInvalidVideoPayloads(old: String, new: String, expected: [String]) throws {
    try withCourse { folder, root in
        try edit(folder, old, new)
        #expect(try publishErrors(folder, root) == expected)
    }
}

@Test func manifestAcceptsUppercaseExtensions() throws {
    try withCourse { folder, root in
        try FileManager.default.moveItem(at: folder.appending(path: "content/welcome.mp4"), to: folder.appending(path: "content/W.MP4"))
        try edit(folder, "path: content/welcome.mp4", "path: content/W.MP4")
        #expect(try publishErrors(folder, root) == [])
    }
}

// MARK: Publish

@Test func missingOrInvalidVideoFilesFailPublishWithClearErrors() throws {
    try withCourse { folder, root in
        for file in ["content/welcome.mp4", "content/welcome.vtt", "media/poster.svg"] {
            try FileManager.default.removeItem(at: folder.appending(path: file))
        }
        #expect(try publishErrors(folder, root) == [
            "\(video).path: file does not exist",
            "\(video).captions.path: file does not exist",
            "\(video).poster.path: file does not exist",
        ])
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "courses").path))
    }
    try withCourse { folder, root in
        try Data("not a video".utf8).write(to: folder.appending(path: "content/welcome.mp4"))
        try Data("1\n00:00.000 --> 00:01.000\nNo header\n".utf8).write(to: folder.appending(path: "content/welcome.vtt"))
        try edit(folder, "            path: media/poster.svg\n", "            path: content/plan.md\n")
        #expect(try publishErrors(folder, root) == [
            "\(video).path: file is not an MP4 video",
            "\(video).captions.path: invalid WebVTT file: the file must start with WEBVTT",
            "\(video).poster.path: unsupported image format (use PNG, JPG or SVG)",
        ])
    }
    try withCourse { folder, root in
        try Data("WEBVTT\n\n00:02.000 --> 00:01.000\nBackwards\n".utf8).write(to: folder.appending(path: "content/welcome.vtt"))
        #expect(try publishErrors(folder, root) == [
            "\(video).captions.path: invalid WebVTT file: invalid cue timing \"00:02.000 --> 00:01.000\"",
        ])
    }
    try withCourse { folder, root in
        try Data([0x57, 0x45, 0x42, 0xFF, 0xFE]).write(to: folder.appending(path: "content/welcome.vtt"))
        #expect(try publishErrors(folder, root) == ["\(video).captions.path: cannot read the captions file as UTF-8 text"])
    }
}

/// Acceptance: the sample video lecture plays the MP4 from the store path, and captions load from the published path.
@MainActor @Test func sampleVideoPlaysFromTheSnapshotWithCaptions() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "SkillgardenVideoTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    let folder = base.appending(path: "course")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: fixture, to: folder)
    let root = base.appending(path: "library")
    _ = try CoursePublisher.publish(courseFolder: folder, root: root)
    // The source can go away. The app reads the installed snapshot.
    try FileManager.default.removeItem(at: folder)

    let library = LibraryModel(root: root)
    await library.reload()
    library.selectCourse("sample-course")
    let lecture = try #require(library.video(forLecture: "welcome"))
    #expect(library.video(forLecture: "read") == nil)
    let snapshot = try #require(try CoursePublisher.assetDirectory(courseID: "sample-course", root: root)).standardizedFileURL
    #expect(lecture.url.standardizedFileURL == snapshot.appending(path: "content/welcome.mp4"))
    #expect(lecture.captionsURL?.standardizedFileURL == snapshot.appending(path: "content/welcome.vtt"))
    #expect(lecture.posterURL?.standardizedFileURL == snapshot.appending(path: "media/poster.svg"))
    #expect(lecture.posterAlt == "The first frame of the welcome video")
    #expect(lecture.metadataLabel == "Video · 0:04")
    #expect(lecture.isFreePreview)

    let media = try await mediaFacts(lecture.url)
    #expect(media.isPlayable)
    #expect(abs(media.seconds - 4) < 0.5)
    #expect(media.videoTracks == 1)

    let captions = try #require(try lecture.loadCaptions())
    #expect(captions.cues.count == 2)
    #expect(captions.text(at: 0.5) == "Welcome to Local Course Basics.")
    #expect(captions.text(at: 3) == "You will plan a course step by step.")
    #expect(captions.text(at: 4) == nil)
}

/// Loads the asset off the main actor and returns only Sendable values.
/// Older Swift 6.0 SDKs reject `[AVAssetTrack]` across an isolation boundary.
private func mediaFacts(_ url: URL) async throws -> (isPlayable: Bool, seconds: Double, videoTracks: Int) {
    let asset = AVURLAsset(url: url)
    let isPlayable = try await asset.load(.isPlayable)
    let seconds = try await asset.load(.duration).seconds
    let videoTracks = try await asset.loadTracks(withMediaType: .video).count
    return (isPlayable, seconds, videoTracks)
}

@MainActor @Test func freePreviewFlagTogglesTheBadgeData() async throws {
    try await withCourseAsync { folder, root in
        _ = try CoursePublisher.publish(courseFolder: folder, root: root)
        let library = LibraryModel(root: root)
        await library.reload()
        library.selectCourse("sample-course")
        #expect(library.isFreePreview("welcome"))
        #expect(!library.isFreePreview("read"))
        #expect(!library.isFreePreview("missing"))

        try edit(folder, "          free_preview: true\n", "          free_preview: false\n")
        _ = try CoursePublisher.publish(courseFolder: folder, root: root)
        await library.reload()
        #expect(!library.isFreePreview("welcome"))

        try edit(folder, "          free_preview: false\n", "")
        try edit(folder, "          captions:\n            path: content/welcome.vtt\n", "")
        _ = try CoursePublisher.publish(courseFolder: folder, root: root)
        await library.reload()
        #expect(!library.isFreePreview("welcome"))
        // Without captions the app hides the Captions toggle.
        #expect(library.video(forLecture: "welcome")?.captionsURL == nil)
        #expect(try library.video(forLecture: "welcome")?.loadCaptions() == nil)
    }
}

@MainActor private func withCourseAsync(_ body: (URL, URL) async throws -> Void) async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "SkillgardenVideoTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let folder = base.appending(path: "course")
    try FileManager.default.copyItem(at: fixture, to: folder)
    try FileManager.default.removeItem(at: folder.appending(path: "equivalent.json"))
    try await body(folder, base.appending(path: "library"))
}

@Test func lectureVideoIgnoresPathsOutsideTheSnapshot() {
    let folder = URL(fileURLWithPath: "/tmp/snapshot")
    let outside = ManifestVideo(path: "../a.mp4", durationSeconds: 1)
    #expect(LectureVideo(folder: folder, video: outside) == nil)
    let video = LectureVideo(folder: folder, video: ManifestVideo(
        path: "a.mp4", durationSeconds: 1, captions: ManifestCaptions(path: "internal/a.vtt"),
        poster: ManifestImage(path: "../p.png", alt: "Poster")))
    #expect(video?.url.path == "/tmp/snapshot/a.mp4")
    #expect(video?.captionsURL == nil)
    #expect(video?.posterURL == nil)
    #expect(video?.isFreePreview == false)
}

// MARK: Duration label

@Test(arguments: [(0, "0:00"), (4, "0:04"), (59, "0:59"), (60, "1:00"), (754, "12:34"), (3599, "59:59"),
                  (3600, "1:00:00"), (3661, "1:01:01"), (36_000, "10:00:00"), (-5, "0:00")])
func durationLabelUsesMinutesOrHours(seconds: Int, label: String) {
    #expect(LectureVideo.durationLabel(seconds: seconds) == label)
}

// MARK: WebVTT

@Test func webVTTParsesCuesSettingsAndTags() throws {
    let captions = try WebVTT(text: """
        \u{FEFF}WEBVTT - Sample

        NOTE This is a comment
        that spans two lines

        STYLE
        ::cue { color: yellow }

        intro
        00:00:01.000 --> 00:00:02.500 align:start line:0
        <v Ana>Hello &amp; <i>welcome</i></v>
        Second line

        00:01.000 --> 00:03.000
        Overlap &lt;tag&gt;

        01:00:00.000 --> 01:00:01.000
        One hour
        """.replacingOccurrences(of: "\n", with: "\r\n"))
    #expect(captions.cues == [
        CaptionCue(start: 1, end: 2.5, text: "Hello & welcome\nSecond line"),
        CaptionCue(start: 1, end: 3, text: "Overlap <tag>"),
        CaptionCue(start: 3600, end: 3601, text: "One hour"),
    ])
    #expect(captions.text(at: 0.999) == nil)
    #expect(captions.text(at: 1) == "Hello & welcome\nSecond line\nOverlap <tag>")
    #expect(captions.text(at: 2.5) == "Overlap <tag>")
    #expect(captions.text(at: 3600.5) == "One hour")
}

@Test func webVTTEdgeCases() throws {
    #expect(try WebVTT(text: "WEBVTT").cues.isEmpty)
    #expect(try WebVTT(text: "WEBVTT\n\n\n").cues.isEmpty)
    // A cue with no text is kept but never shows.
    let empty = try WebVTT(text: "WEBVTT\n\n00:00.000 --> 00:01.000\n")
    #expect(empty.cues == [CaptionCue(start: 0, end: 1, text: "")])
    #expect(empty.text(at: 0.5) == nil)
    for bad in ["", "WEBVTTX", "webvtt", "Hello\nWEBVTT"] {
        #expect(throws: WebVTTError(message: "the file must start with WEBVTT")) { try WebVTT(text: bad) }
    }
    for timing in ["00:00.000 --> 00:01", "0:00.000 --> 00:01.000", "00:60.000 --> 01:00.000", "00:00.000 --> ", "aa:00.000 --> 00:01.000", "00:00:00.000 --> 00:61:00.000",
                   "00:00.000 --> 00:01.000 --> 00:02.000"] {
        #expect(throws: WebVTTError.self, "\(timing)") { try WebVTT(text: "WEBVTT\n\n\(timing)\nText") }
    }
    #expect(WebVTT.seconds("00:00.000") == 0)
    #expect(WebVTT.seconds("59:59.999") == 3599.999)
    #expect(WebVTT.seconds("100:00:00.000") == 360_000)
}

// MARK: Transcript

/// Acceptance (#13): the parser loads the cues of the fixture file with start, end and text.
@Test func transcriptLoadsTheFixtureCues() throws {
    let captions = try LectureVideo.captions(at: fixture.appending(path: "content/welcome.vtt"))
    #expect(captions.cues == [
        CaptionCue(start: 0, end: 2, text: "Welcome to Local Course Basics."),
        CaptionCue(start: 2, end: 4, text: "You will plan a course step by step."),
    ])
    let transcript = Transcript(captions: captions)
    #expect(transcript.lines.map(\.id) == [0, 1])
    #expect(transcript.lines.map(\.start) == [0, 2])
    #expect(transcript.lines.map(\.end) == [2, 4])
    #expect(transcript.lines.map(\.timeLabel) == ["0:00", "0:02"])
    #expect(transcript.lines[1].accessibilityLabel == "0:02, You will plan a course step by step.")
}

/// Acceptance (#13): the active line changes when the playback time crosses a cue boundary.
@Test func transcriptActiveLineFollowsCueBoundaries() throws {
    let transcript = Transcript(captions: try WebVTT(text: """
        WEBVTT

        00:01.000 --> 00:03.000
        First

        00:03.000 --> 00:05.000
        Second

        00:08.000 --> 00:10.000
        After a gap
        """))
    let expected: [(Double, Int?)] = [(0, nil), (0.999, nil), (1, 0), (2.999, 0), (3, 1), (4.999, 1),
                                      (5, nil), (7.999, nil), (8, 2), (9.999, 2), (10, nil), (3600, nil)]
    for (seconds, line) in expected {
        #expect(transcript.activeLine(at: seconds) == line, "\(seconds)")
    }
    // A click seeks to the line start, and that line is then active.
    for line in transcript.lines { #expect(transcript.activeLine(at: line.start) == line.id) }
}

@Test func transcriptOrdersLinesAndSkipsEmptyCues() throws {
    let transcript = Transcript(captions: try WebVTT(text: """
        WEBVTT

        00:05.000 --> 00:06.000
        Late

        00:00.000 --> 00:10.000
        Long
        two lines

        00:02.000 --> 00:03.000

        00:05.000 --> 00:07.000
        Same start

        01:02:03.000 --> 01:02:04.000
        One hour
        """))
    #expect(transcript.lines.map(\.text) == ["Long two lines", "Late", "Same start", "One hour"])
    #expect(transcript.lines.map(\.id) == [0, 1, 2, 3])
    #expect(transcript.lines.map(\.timeLabel) == ["0:00", "0:05", "0:05", "1:02:03"])
    // Overlap: the line that started last is active.
    #expect(transcript.activeLine(at: 1) == 0)
    #expect(transcript.activeLine(at: 2.5) == 0)
    #expect(transcript.activeLine(at: 5.5) == 2)
    #expect(transcript.activeLine(at: 6.5) == 2)
    #expect(transcript.activeLine(at: 7) == 0)
    #expect(transcript.activeLine(at: 3723.5) == 3)
    // An empty file gives an empty transcript.
    #expect(Transcript(captions: try WebVTT(text: "WEBVTT")).lines.isEmpty)
    #expect(Transcript(captions: try WebVTT(text: "WEBVTT\n\n00:00.000 --> 00:01.000\n")).lines.isEmpty)
}

@Test func transcriptAutoScrollPausesForFiveSecondsAfterALearnerScroll() {
    let start = Date(timeIntervalSinceReferenceDate: 1000)
    var autoScroll = TranscriptAutoScroll()
    #expect(autoScroll.allowsAutoScroll(at: start))
    autoScroll.learnerScrolled(at: start)
    #expect(!autoScroll.allowsAutoScroll(at: start))
    #expect(!autoScroll.allowsAutoScroll(at: start + 4.999))
    #expect(autoScroll.allowsAutoScroll(at: start + TranscriptAutoScroll.pause))
    // A second scroll starts the pause again.
    autoScroll.learnerScrolled(at: start + 4)
    #expect(!autoScroll.allowsAutoScroll(at: start + 8.9))
    #expect(autoScroll.allowsAutoScroll(at: start + 9))
}
