import Foundation
import Testing
@testable import SkillgardenCore

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/sample-course")

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "SourceTests-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func fixtureObject() throws -> [String: Any] {
    let manifest = try ManifestLoader.load(courseFolder: fixture)
    return try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
}

/// Changes the `sources` of the lecture at `sections[section].lectures[lecture]`. The default is the article "read".
private func editSources(_ object: inout [String: Any], section: Int = 0, lecture: Int = 1,
                         _ change: (inout [[String: Any]]) throws -> Void) throws {
    var sections = try #require(object["sections"] as? [[String: Any]])
    var lectures = try #require(sections[section]["lectures"] as? [[String: Any]])
    var sources = lectures[lecture]["sources"] as? [[String: Any]] ?? []
    try change(&sources)
    lectures[lecture]["sources"] = sources
    sections[section]["lectures"] = lectures
    object["sections"] = sections
}

/// Loads the manifest object and returns its diagnostics as `fieldPath: message`. Empty means valid.
private func errors(_ object: Any) throws -> [String] {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "skillgarden.json")
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: file)
    do {
        _ = try ManifestLoader.load(file: file)
        return []
    } catch let error as ManifestValidationError {
        return error.diagnostics.map { "\($0.fieldPath): \($0.message)" }
    }
}

private let sourcesPath = "sections[0].lectures[1].sources"

// MARK: Manifest

@Test func manifestParsesTheFixtureSourcesInOrder() throws {
    let manifest = try ManifestLoader.load(courseFolder: fixture)
    let sources = try #require(manifest.sections[0].lectures[1].sources)
    #expect(sources == [
        ManifestSource(title: "Plan a course on one page", channel: "Skillgarden Studio",
                       url: "https://example.com/plan-a-course", timestampStart: 250, timestampEnd: 572),
        ManifestSource(title: "Course outlines that work", channel: "Learning Lab",
                       url: "https://example.com/course-outlines", timestampStart: 3725, timestampEnd: nil),
        ManifestSource(title: "The course plan checklist", channel: "Skillgarden Docs",
                       url: nil, timestampStart: nil, timestampEnd: nil),
    ])
    // Lectures without the field decode as nil.
    #expect(manifest.sections[0].lectures[0].sources == nil)
}

@Test func sourcesAreOptionalAndCanBeEmpty() throws {
    var object = try fixtureObject()
    try editSources(&object) { $0 = [] }
    #expect(try errors(object) == [])
    try editSources(&object, section: 0, lecture: 0) { $0 = [["title": "A video", "channel": "A channel"]] }
    #expect(try errors(object) == [])
}

@Test func parserRequiresTitleAndChannelOnEachSource() throws {
    var object = try fixtureObject()
    try editSources(&object) { sources in
        sources[0]["title"] = nil
        sources[1]["channel"] = nil
        sources[2]["channel"] = "  "
    }
    #expect(try errors(object) == [
        "\(sourcesPath)[0].title: required field is missing",
        "\(sourcesPath)[1].channel: required field is missing",
        "\(sourcesPath)[2].channel: must not be empty",
    ])
}

@Test func parserChecksSourceFieldTypes() throws {
    var object = try fixtureObject()
    try editSources(&object) { sources in
        sources[0]["timestamp_start"] = "4:10"
        sources[1]["url"] = 5
        sources[2]["title"] = ["x"]
    }
    #expect(try errors(object) == [
        "\(sourcesPath)[0].timestamp_start: expected integer, found string",
        "\(sourcesPath)[1].url: expected string, found integer",
        "\(sourcesPath)[2].title: expected string, found array",
    ])
}

@Test func parserAcceptsOnlyWebSourceURLs() throws {
    for url in ["https://example.com/a", "http://example.com", "HTTPS://Example.com/path?q=1"] {
        var object = try fixtureObject()
        try editSources(&object) { $0[0]["url"] = url }
        #expect(try errors(object) == [], "\(url)")
    }
    for url in ["file:///etc/passwd", "javascript:alert(1)", "example.com/a", "https://", "media/course.svg"] {
        var object = try fixtureObject()
        try editSources(&object) { $0[0]["url"] = url }
        #expect(try errors(object) == ["\(sourcesPath)[0].url: must be an http or https URL"], "\(url)")
    }
    var object = try fixtureObject()
    try editSources(&object) { $0[0]["url"] = "" }
    #expect(try errors(object) == ["\(sourcesPath)[0].url: must not be empty"])
}

@Test func parserChecksTimestampRanges() throws {
    var object = try fixtureObject()
    try editSources(&object) { sources in
        sources[0]["timestamp_start"] = -1
        sources[1]["timestamp_end"] = 3725
        sources[2]["timestamp_end"] = -5
    }
    #expect(try errors(object) == [
        "\(sourcesPath)[0].timestamp_start: must be 0 or greater",
        "\(sourcesPath)[1].timestamp_end: must be greater than timestamp_start",
        "\(sourcesPath)[2].timestamp_end: must be 0 or greater",
    ])
    // The smallest values: a start of 0, and an end one second after the start.
    object = try fixtureObject()
    try editSources(&object) { sources in
        sources[0]["timestamp_start"] = 0
        sources[0]["timestamp_end"] = 1
        sources[2]["timestamp_end"] = 0
    }
    #expect(try errors(object) == [])
}

@Test func yamlAndJSONFixturesHaveTheSameSources() throws {
    let yaml = try ManifestLoader.load(courseFolder: fixture)
    let json = try ManifestLoader.load(file: fixture.appending(path: "equivalent.json"))
    #expect(yaml.sections[0].lectures[1].sources == json.sections[0].lectures[1].sources)
}

// MARK: Card text

@Test func rangeTextCoversEveryFieldCombination() {
    #expect(LectureSource(title: "T", channel: "C", start: 250, end: 572).rangeText == "4:10 – 9:32")
    #expect(LectureSource(title: "T", channel: "C", start: 250).rangeText == "From 4:10")
    #expect(LectureSource(title: "T", channel: "C", end: 572).rangeText == "Until 9:32")
    #expect(LectureSource(title: "T", channel: "C").rangeText == nil)
    // m:ss below one hour, h:mm:ss from one hour.
    #expect(LectureSource(title: "T", channel: "C", start: 0, end: 59).rangeText == "0:00 – 0:59")
    #expect(LectureSource(title: "T", channel: "C", start: 3599, end: 3600).rangeText == "59:59 – 1:00:00")
    #expect(LectureSource(title: "T", channel: "C", start: 36_000).rangeText == "From 10:00:00")
}

@Test func accessibilityLabelHasTitleChannelAndRange() {
    #expect(LectureSource(title: "Plan", channel: "Studio", start: 250, end: 572).accessibilityLabel
            == "Plan, Studio, 4:10 – 9:32")
    #expect(LectureSource(title: "Plan", channel: "Studio").accessibilityLabel == "Plan, Studio")
}

@Test func lectureSourceKeepsOnlyWebURLs() {
    let web = LectureSource(manifest: ManifestSource(title: "T", channel: "C", url: " https://example.com/a "))
    #expect(web.url == URL(string: "https://example.com/a"))
    let file = LectureSource(manifest: ManifestSource(title: "T", channel: "C", url: "file:///tmp/a"))
    #expect(file.url == nil)
    #expect(LectureSource(manifest: ManifestSource(title: "T", channel: "C")).url == nil)
}

// MARK: Library

@MainActor @Test func libraryShowsAllFixtureSourcesOnTheSampleLecture() async throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = try CoursePublisher.publish(courseFolder: fixture, root: root).id
    let library = LibraryModel(root: root)
    await library.reload()
    library.selectCourse(id)
    library.selectDestination(.lecture(sectionID: "plan", lectureID: "read"))
    let sources = library.selectedSources
    #expect(sources.map(\.title) == ["Plan a course on one page", "Course outlines that work", "The course plan checklist"])
    #expect(sources.map(\.channel) == ["Skillgarden Studio", "Learning Lab", "Skillgarden Docs"])
    #expect(sources.map(\.url) == [URL(string: "https://example.com/plan-a-course"),
                                   URL(string: "https://example.com/course-outlines"), nil])
    #expect(sources.map(\.rangeText) == ["4:10 – 9:32", "From 1:02:05", nil])
    // A lecture without sources has no cards, so the block is hidden.
    library.selectDestination(.lecture(sectionID: "plan", lectureID: "welcome"))
    #expect(library.selectedSources.isEmpty)
    // The overview has no lecture.
    library.selectDestination(.overview)
    #expect(library.selectedSources.isEmpty)
}
