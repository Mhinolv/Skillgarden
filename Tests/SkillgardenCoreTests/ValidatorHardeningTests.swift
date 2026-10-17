import Foundation
import Testing
@testable import SkillgardenCore

private let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures")

/// Gives each test a writable copy of a fixture course and an empty library root.
private func withCourse(_ name: String = "sample-course", _ body: (URL, URL) throws -> Void) throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "SkillgardenValidatorTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let folder = base.appending(path: "course")
    try FileManager.default.copyItem(at: fixtures.appending(path: name), to: folder)
    try? FileManager.default.removeItem(at: folder.appending(path: "equivalent.json"))
    try body(folder, base.appending(path: "library"))
}

private func edit(_ folder: URL, _ old: String, _ new: String) throws {
    let file = folder.appending(path: "skillgarden.yaml")
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text.contains(old))
    try text.replacingOccurrences(of: old, with: new).write(to: file, atomically: true, encoding: .utf8)
}

/// The `fieldPath: message` part of each `validate` error. Empty when the course is valid.
private func problems(_ folder: URL) -> [String] {
    do {
        _ = try CoursePublisher.validate(courseFolder: folder)
        return []
    } catch let error as ManifestValidationError {
        return error.diagnostics.map { "\($0.fieldPath): \($0.message)" }
    } catch {
        return ["\(error)"]
    }
}

private func counts(_ result: PublishResult) -> [Int] {
    [result.created, result.updated, result.unchanged, result.removed]
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

@Test func validateFailsForEmptyRequiredLists() throws {
    try withCourse { folder, _ in
        try edit(folder, "learning_outcomes:\n  - Plan a course\n  - Check your work\n", "learning_outcomes: []\n")
        try edit(folder, "requirements:\n  - A Mac\n", "requirements: []\n")
        try edit(folder, """
            credits:
              - name: Skillgarden Team
                role: Author
                url: https://example.com/credits

            """, "credits: []\n")
        #expect(problems(folder) == [
            "learning_outcomes: must have at least one item",
            "requirements: must have at least one item",
            "credits: must have at least one item",
        ])
    }
    try withCourse { folder, _ in
        let text = try String(contentsOf: folder.appending(path: "skillgarden.yaml"), encoding: .utf8)
        let head = try #require(text.range(of: "sections:\n"))
        let tail = try #require(text.range(of: "internal:\n"))
        try edit(folder, String(text[head.lowerBound..<tail.lowerBound]), "sections: []\n")
        #expect(problems(folder) == ["sections: must have at least one item"])
    }
    try withCourse { folder, _ in
        let text = try String(contentsOf: folder.appending(path: "skillgarden.yaml"), encoding: .utf8)
        let head = try #require(text.range(of: "    lectures:\n      - id: check"))
        let tail = try #require(text.range(of: "internal:\n"))
        try edit(folder, String(text[head.lowerBound..<tail.lowerBound]), "    lectures: []\n")
        #expect(problems(folder) == ["sections[1].lectures: must have at least one item"])
    }
}

@Test func validateFailsForABadAccentColor() throws {
    for color in ["'286644'", "'#28664'", "'#2866440'", "'#28664G'", "red", "'#28 644'", "'＃286644'"] {
        try withCourse { folder, _ in
            try edit(folder, "accent_color: '#286644'", "accent_color: \(color)")
            #expect(problems(folder) == ["theme.accent_color: must be a hex color such as \"#286644\""], "\(color)")
        }
    }
    try withCourse { folder, _ in
        try edit(folder, "accent_color: '#286644'", "accent_color: '#aBcDeF'")
        #expect(problems(folder) == [])
    }
}

@Test func validateFailsForADuplicateOrderAmongSiblings() throws {
    try withCourse { folder, _ in
        try edit(folder, "    state: draft\n    order: 1\n", "    state: draft\n    order: 0\n")
        try edit(folder, "        objective: Describe the course plan\n        state: published\n        order: 1\n",
                 "        objective: Describe the course plan\n        state: published\n        order: 0\n")
        #expect(problems(folder) == [
            "sections[0].lectures[1].order: duplicate order 0 (first used at sections[0].lectures[0].order)",
            "sections[1].order: duplicate order 0 (first used at sections[0].order)",
        ])
    }
    // Lectures in different sections can use the same order. The fixture already does.
    try withCourse { folder, _ in #expect(problems(folder) == []) }
}

@Test func validateFailsForNonNormalizedPaths() throws {
    let video = "sections[0].lectures[0].video"
    let cases: [(String, String, String)] = [
        ("path: content/welcome.mp4", "path: ./content/welcome.mp4", "\(video).path: path must be normalized: use \"content/welcome.mp4\""),
        ("path: content/welcome.mp4", "path: content//welcome.mp4", "\(video).path: path must be normalized: use \"content/welcome.mp4\""),
        ("path: content/welcome.mp4", "path: content/./welcome.mp4", "\(video).path: path must be normalized: use \"content/welcome.mp4\""),
        ("path: content/welcome.vtt", "path: content/welcome.vtt/",
         "\(video).captions.path: path must be normalized: use \"content/welcome.vtt\""),
        ("path: internal/research.md", "path: ./internal/research.md",
         "internal.files[0].path: path must be normalized: use \"internal/research.md\""),
    ]
    for (old, new, expected) in cases {
        try withCourse { folder, _ in
            try edit(folder, old, new)
            // Only the path error. No `file does not exist` line.
            #expect(problems(folder) == [expected], "\(new)")
        }
    }
    try withCourse("interactive-course") { folder, _ in
        try edit(folder, "bundle_path: modules/order", "bundle_path: modules/order/")
        #expect(problems(folder) == [
            "sections[0].lectures[0].interactive.bundle_path: path must be normalized: use \"modules/order\"",
        ])
    }
}

@Test func validateFailsWhenTheDurationDoesNotMatchTheVideo() throws {
    try withCourse { folder, _ in
        try edit(folder, "duration_seconds: 4", "duration_seconds: 5")
        #expect(problems(folder) == ["sections[0].lectures[0].video.duration_seconds: must match the video length (4 seconds)"])
    }
    try withCourse { folder, _ in #expect(problems(folder) == []) }
}

/// Builds an MP4 file in memory: `ftyp`, an optional large `mdat`, then `moov` with `mvhd`.
private func mp4(version: UInt8, timescale: UInt32, duration: UInt64, largeMediaBox: Bool = false,
                 fragmentDuration: UInt32? = nil) -> Data {
    func box(_ type: String, _ body: Data) -> Data {
        var data = Data()
        withUnsafeBytes(of: UInt32(8 + body.count).bigEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: Array(type.utf8))
        return data + body
    }
    func bytes<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    var mvhd = Data([version, 0, 0, 0])
    if version == 1 {
        mvhd += bytes(UInt64(0)) + bytes(UInt64(0)) + bytes(timescale) + bytes(duration)
    } else {
        mvhd += bytes(UInt32(0)) + bytes(UInt32(0)) + bytes(timescale) + bytes(UInt32(duration))
    }
    mvhd += Data(count: 80)
    var data = box("ftyp", Data("isom".utf8) + bytes(UInt32(512)))
    if largeMediaBox {
        // A 64-bit box size: size field 1, then the real size after the type.
        let payload = Data(count: 32)
        data += bytes(UInt32(1)) + Data("mdat".utf8) + bytes(UInt64(16 + payload.count)) + payload
    }
    // A fragmented MP4 keeps its length in `moov/mvex/mehd`.
    let mvex = fragmentDuration.map { box("mvex", box("mehd", Data(count: 4) + bytes($0))) } ?? Data()
    return data + box("moov", box("mvhd", mvhd) + mvex)
}

@Test func videoLengthReadsTheMovieHeader() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "SkillgardenMP4-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    func length(_ data: Data) throws -> Int? {
        let url = folder.appending(path: "\(UUID()).mp4")
        try data.write(to: url)
        return LectureVideo.length(of: url)
    }
    #expect(try length(mp4(version: 0, timescale: 600, duration: 2400)) == 4)
    // The length rounds to the nearest second.
    #expect(try length(mp4(version: 0, timescale: 1000, duration: 94_499)) == 94)
    #expect(try length(mp4(version: 0, timescale: 1000, duration: 94_500)) == 95)
    #expect(try length(mp4(version: 1, timescale: 90_000, duration: 90_000 * 7_200, largeMediaBox: true)) == 7_200)
    #expect(try length(mp4(version: 0, timescale: 600, duration: 0, fragmentDuration: 1_800)) == 3)
    #expect(try length(mp4(version: 0, timescale: 600, duration: 0)) == nil)
    #expect(try length(mp4(version: 0, timescale: 0, duration: 10)) == nil)
    #expect(try length(Data("not a video".utf8)) == nil)
    #expect(try length(mp4(version: 0, timescale: 600, duration: 2400).prefix(40)) == nil)
    #expect(LectureVideo.length(of: fixtures.appending(path: "sample-course/content/welcome.mp4")) == 4)
}

@Test func interactiveFixturePassesValidate() throws {
    try withCourse("interactive-course") { folder, _ in #expect(problems(folder) == []) }
}

@Test func validateFailsForBlockedURLsInTheBundle() throws {
    try withCourse("interactive-course") { folder, _ in
        let bundle = folder.appending(path: "modules/order")
        try write("""
            <!DOCTYPE html>
            <html><head>
            <link rel="stylesheet" href="https://cdn.example.com/a.css">
            <script src='//cdn.example.com/lib.js'></script>
            </head><body>
            <a href="mailto:team@example.com">Mail</a> <a href="javascript:void(0)">Run</a>
            <a href="../../media/course.svg">Out</a> <img src="/etc/hosts">
            <a href="#top">Top</a> <img src="data:image/png;base64,AAAA"> <iframe src="about:blank"></iframe>
            <img src="pics/a.png"> <a href="sub/../index.html">Home</a> <a href="?step=2">Next</a>
            <svg xmlns="http://www.w3.org/2000/svg"></svg>
            </body></html>
            """, to: bundle.appending(path: "extra.html"))
        try write("""
            body { background: url("../../media/section.svg"); }
            @import 'http://example.com/theme.css';
            .ok { background: url(img/ok.png); }
            """, to: bundle.appending(path: "css/more.css"))
        try write("""
            // Load the data. The comment is not a URL: //example.com
            fetch("https://api.example.com/data");
            const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
            const blob = URL.createObjectURL(new Blob([]));
            """, to: bundle.appending(path: "js/more.js"))
        // Other file types are not scanned.
        try write("https://example.com/", to: bundle.appending(path: "notes.txt"))
        let field = "sections[0].lectures[0].interactive.bundle_path"
        #expect(problems(folder) == [
            "\(field): css/more.css line 1: URL \"../../media/section.svg\" is blocked in the app",
            "\(field): css/more.css line 2: URL \"http://example.com/theme.css\" is blocked in the app",
            "\(field): extra.html line 3: URL \"https://cdn.example.com/a.css\" is blocked in the app",
            "\(field): extra.html line 4: URL \"//cdn.example.com/lib.js\" is blocked in the app",
            "\(field): extra.html line 6: URL \"mailto:team@example.com\" is blocked in the app",
            "\(field): extra.html line 6: URL \"javascript:void(0)\" is blocked in the app",
            "\(field): extra.html line 7: URL \"../../media/course.svg\" is blocked in the app",
            "\(field): extra.html line 7: URL \"/etc/hosts\" is blocked in the app",
            "\(field): js/more.js line 2: URL \"https://api.example.com/data\" is blocked in the app",
        ])
    }
}

@Test func validateReportsTheOldFixtureLink() throws {
    try withCourse("interactive-course") { folder, _ in
        let index = folder.appending(path: "modules/order/index.html")
        let text = try String(contentsOf: index, encoding: .utf8)
        try text.replacingOccurrences(of: "  <script src=\"app.js\"></script>",
                                      with: "  <p><a href=\"https://example.com/\">A link outside the course</a></p>\n  <script src=\"app.js\"></script>")
            .write(to: index, atomically: true, encoding: .utf8)
        #expect(problems(folder) == [
            "sections[0].lectures[0].interactive.bundle_path: index.html line 14: URL \"https://example.com/\" is blocked in the app",
        ])
    }
}

@Test func publishSummaryCountsCourseLevelChanges() throws {
    try withCourse { folder, root in
        let first = try CoursePublisher.publish(courseFolder: folder, root: root)
        #expect(counts(first) == [7, 0, 0, 0])
        try edit(folder, "state: published\ntheme:", "state: draft\ntheme:")
        let second = try CoursePublisher.publish(courseFolder: folder, root: root)
        #expect(second.summary == "Published \"Local Course Basics\" (sample-course, draft): created 0, updated 1, unchanged 6, removed 0")
        try edit(folder, "accent_color: '#286644'", "accent_color: '#224466'")
        let third = try CoursePublisher.publish(courseFolder: folder, root: root)
        #expect(counts(third) == [0, 1, 6, 0])
        let fourth = try CoursePublisher.publish(courseFolder: folder, root: root)
        #expect(counts(fourth) == [0, 0, 7, 0])
    }
}
