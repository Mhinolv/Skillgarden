import Foundation
import Testing
@testable import SkillgardenCore

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/sample-course")

/// Gives each test a writable copy of the sample course and an empty library root.
private func withCourse(_ body: (URL, URL) throws -> Void) throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "SkillgardenArticleTests-\(UUID())")
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

private let article = "sections[0].lectures[1].article"

// MARK: Parser

@Test func markdownParsesEveryBlockType() {
    let document = MarkdownDocument(markdown: """
        # Title #
        ## Steps
        ###### Small
        #NoSpace

        First line
        second line.

        - one
        * two
          more
        + three

        3. third
        4) fourth

        5. fifth after a blank line

        ```swift
        let x = 1

        print(x)
        ```

        > quoted
        > text

        ---
        ![Alt *text*](media/a%20b.png "Title")
        ![](<media/c d.svg>)
        Text with ![inline](i.png) image.
        """)
    #expect(document.blocks == [
        .heading(level: 1, text: "Title"),
        .heading(level: 2, text: "Steps"),
        .heading(level: 6, text: "Small"),
        .paragraph("#NoSpace"),
        .paragraph("First line second line."),
        .list(ordered: false, start: 1, items: ["one", "two more", "three"]),
        .list(ordered: true, start: 3, items: ["third", "fourth", "fifth after a blank line"]),
        .code("let x = 1\n\nprint(x)"),
        .quote("quoted text"),
        .rule,
        .image(source: "media/a%20b.png", alt: "Alt *text*"),
        .image(source: "media/c d.svg", alt: ""),
        .paragraph("Text with ![inline](i.png) image."),
    ])
    #expect(document.imageSources == ["media/a%20b.png", "media/c d.svg"])
}

@Test func markdownEdgeCases() {
    #expect(MarkdownDocument(markdown: "").blocks.isEmpty)
    #expect(MarkdownDocument(markdown: "\n \n\t\n").blocks.isEmpty)
    #expect(MarkdownDocument(markdown: "# A\r\n\r\nB\r\n").blocks == [.heading(level: 1, text: "A"), .paragraph("B")])
    // An unclosed fence runs to the end of the file.
    #expect(MarkdownDocument(markdown: "~~~\ncode").blocks == [.code("code")])
    // Seven # is not a heading. A bullet list ends at an ordered item.
    #expect(MarkdownDocument(markdown: "####### x").blocks == [.paragraph("####### x")])
    #expect(MarkdownDocument(markdown: "- a\n1. b").blocks == [
        .list(ordered: false, start: 1, items: ["a"]), .list(ordered: true, start: 1, items: ["b"]),
    ])
    // A paragraph ends at the start of another block.
    #expect(MarkdownDocument(markdown: "text\n## Head").blocks == [.paragraph("text"), .heading(level: 2, text: "Head")])
}

@Test(arguments: [("", 1), ("word", 1), (Array(repeating: "w", count: 200).joined(separator: " "), 1),
                  (Array(repeating: "w", count: 201).joined(separator: " "), 2),
                  ("# " + Array(repeating: "w", count: 1200).joined(separator: "\n"), 6)])
func readingMinutesRoundUpWithMinimumOne(markdown: String, minutes: Int) {
    #expect(MarkdownDocument(markdown: markdown).readingMinutes == minutes)
}

@Test func imageReferencesResolveInsideTheCourseFolder() {
    let resolve = { LectureArticle.resolve($0, article: "content/plan.md") }
    #expect(resolve("a.png") == "content/a.png")
    #expect(resolve("./img/a.png") == "content/img/a.png")
    #expect(resolve("../media/section.svg") == "media/section.svg")
    #expect(resolve("my%20image.png") == "content/my image.png")
    #expect(LectureArticle.resolve("a.png", article: "plan.md") == "a.png")
    for outside in ["../../a.png", "/tmp/a.png", "https://example.com/a.png", "file:///a.png", "C:\\a.png", "",
                    "../internal/a.png", "data:image/png;base64,AA=="] {
        #expect(resolve(outside) == nil, "\(outside)")
    }
}

// MARK: Manifest

@Test func manifestRequiresArticlePathAndImageAlt() throws {
    try withCourse { folder, root in
        try edit(folder, "          path: content/plan.md\n", "")
        try edit(folder, "              alt: The two sections of the course plan\n", "")
        #expect(try publishErrors(folder, root) == [
            "\(article).images[0].alt: alt text is required",
            "\(article).path: required field is missing",
        ])
    }
    try withCourse { folder, root in
        try edit(folder, "              alt: The two sections of the course plan\n", "              alt: '  '\n")
        #expect(try publishErrors(folder, root) == ["\(article).images[0].alt: alt text is required"])
    }
}

@Test func manifestRequiresArticleOnlyForArticleLectures() throws {
    try withCourse { folder, root in
        try edit(folder, "        article:\n", "        notes:\n")
        #expect(try publishErrors(folder, root) == ["\(article): required field is missing"])
    }
    try withCourse { folder, root in
        // Every other type needs its own field. An assignment adds only its own "required" error.
        try edit(folder, "        type: article\n", "        type: assignment\n")
        #expect(try publishErrors(folder, root) == ["\(article): allowed only when type is article",
                                                    "sections[0].lectures[1].assignment: required field is missing"])
    }
    try withCourse { folder, root in
        try edit(folder, "        article:\n          path: content/plan.md\n          images:\n            - path: media/section.svg\n              alt: The two sections of the course plan\n",
                 "        article: null\n")
        #expect(try publishErrors(folder, root) == ["\(article): required field is missing"])
    }
    try withCourse { folder, root in
        try edit(folder, "          path: content/plan.md\n", "          path: ../plan.md\n")
        #expect(try publishErrors(folder, root) == ["\(article).path: path must stay inside the course folder"])
    }
}

@Test func manifestArticleImagesAreOptionalAndRoundTrip() throws {
    let manifest = try ManifestLoader.load(courseFolder: fixture)
    let read = manifest.sections[0].lectures[1]
    #expect(read.article == ManifestArticle(path: "content/plan.md",
                                            images: [ManifestImage(path: "media/section.svg", alt: "The two sections of the course plan")]))
    #expect(manifest.sections[0].lectures[0].article == nil)
    // A manifest saved before article support decodes with no article.
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
    var sections = try #require(object["sections"] as? [[String: Any]])
    var lectures = try #require(sections[0]["lectures"] as? [[String: Any]])
    lectures[1].removeValue(forKey: "article")
    sections[0]["lectures"] = lectures
    object["sections"] = sections
    let old = try JSONDecoder().decode(CourseManifest.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(old.sections[0].lectures[1].article == nil)
    try withCourse { folder, root in
        // An article without images publishes.
        try edit(folder, "          images:\n            - path: media/section.svg\n              alt: The two sections of the course plan\n", "")
        try edit(folder, "![Course sections](../media/section.svg)\n", "", file: "content/plan.md")
        #expect(try publishErrors(folder, root) == [])
    }
}

// MARK: Publish

@Test func missingArticleFilesFailPublishWithClearErrors() throws {
    try withCourse { folder, root in
        try FileManager.default.removeItem(at: folder.appending(path: "content/plan.md"))
        #expect(try publishErrors(folder, root) == ["\(article).path: file does not exist"])
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "courses").path))
    }
    try withCourse { folder, root in
        try edit(folder, "../media/section.svg", "../media/missing.png", file: "content/plan.md")
        #expect(try publishErrors(folder, root) == [
            "\(article).path: image \"../media/missing.png\" does not exist (expected media/missing.png)",
        ])
    }
    try withCourse { folder, root in
        try edit(folder, "            - path: media/section.svg\n", "            - path: media/missing.svg\n")
        #expect(try publishErrors(folder, root) == [
            "\(article).images[0].path: file does not exist",
            "\(article).images: image \"media/section.svg\" needs an entry with alt text",
        ])
    }
    try withCourse { folder, root in
        try edit(folder, "            - path: media/section.svg\n", "            - path: content/plan.md\n")
        #expect(try publishErrors(folder, root).first == "\(article).images[0].path: unsupported image format (use PNG, JPG or SVG)")
    }
    try withCourse { folder, root in
        try edit(folder, "../media/section.svg", "https://example.com/a.png", file: "content/plan.md")
        #expect(try publishErrors(folder, root) == [
            "\(article).path: image \"https://example.com/a.png\" must be a file inside the course folder",
        ])
    }
    try withCourse { folder, root in
        try Data([0xFF, 0xFE, 0x00]).write(to: folder.appending(path: "content/plan.md"))
        #expect(try publishErrors(folder, root) == ["\(article).path: cannot read the Markdown file as UTF-8 text"])
    }
}

@MainActor @Test func sampleArticleLoadsHeadingAndImageFromTheSnapshot() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "SkillgardenArticleTests-\(UUID())")
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
    #expect(library.article(forLecture: "welcome") == nil)
    let lecture = try #require(library.article(forLecture: "read"))
    let snapshot = try #require(try CoursePublisher.assetDirectory(courseID: "sample-course", root: root))
    #expect(lecture.url.standardizedFileURL == snapshot.appending(path: "content/plan.md").standardizedFileURL)

    let document = try lecture.load()
    #expect(document.blocks.first == .heading(level: 1, text: "Course plan"))
    #expect(document.blocks.contains(.list(ordered: true, start: 1, items: [
        "Write the **goal** of the course.", "Put the lectures in order.", "Check each lecture with the `skillgarden` CLI.",
    ])))
    #expect(document.blocks.contains(.code("skillgarden publish ./course")))
    #expect(document.readingMinutes == 1)
    let source = try #require(document.imageSources.first)
    let image = try #require(lecture.image(for: source))
    #expect(image.alt == "The two sections of the course plan")
    #expect(image.url.lastPathComponent == "section.svg")
    #expect(FileManager.default.fileExists(atPath: image.url.path))
    // An unlisted reference resolves to a file but has no manifest alt text.
    #expect(lecture.image(for: "other.png")?.alt == nil)
    #expect(lecture.image(for: "https://example.com/a.png") == nil)
}

/// #238: the large view never draws a bitmap past its pixel size. A vector image has no limit.
@Test func enlargedImageLimitIsThePixelSizeInPoints() {
    // A 2x screenshot on a 2x display: one image pixel for each display pixel.
    #expect(ImageEnlargement.maximumSize(pixelSize: CGSize(width: 2400, height: 1600), displayScale: 2)
        == CGSize(width: 1200, height: 800))
    #expect(ImageEnlargement.maximumSize(pixelSize: CGSize(width: 640, height: 480), displayScale: 1)
        == CGSize(width: 640, height: 480))
    // The smallest bitmap: one pixel stays one display pixel.
    #expect(ImageEnlargement.maximumSize(pixelSize: CGSize(width: 1, height: 1), displayScale: 2)
        == CGSize(width: 0.5, height: 0.5))
    // A very large bitmap keeps its full limit. The window inset then makes it fit.
    #expect(ImageEnlargement.maximumSize(pixelSize: CGSize(width: 20_000, height: 100), displayScale: 2)
        == CGSize(width: 10_000, height: 50))
    // An SVG or PDF has no pixel size, so it has no limit.
    #expect(ImageEnlargement.maximumSize(pixelSize: nil, displayScale: 2) == nil)
    // An empty bitmap or an unknown display scale does not give a zero or an infinite limit.
    #expect(ImageEnlargement.maximumSize(pixelSize: CGSize(width: 0, height: 300), displayScale: 2) == nil)
    #expect(ImageEnlargement.maximumSize(pixelSize: CGSize(width: 300, height: 200), displayScale: 0)
        == CGSize(width: 300, height: 200))
}

/// #238: the large view sizes the image frame to the image ratio, so the alt text sits just below the image.
@Test func enlargedImageAspectRatioPrefersThePixelSize() {
    // A bitmap uses its pixel ratio, even when the point size is different.
    #expect(ImageEnlargement.aspectRatio(pixelSize: CGSize(width: 2400, height: 1600),
                                         pointSize: CGSize(width: 1000, height: 1000)) == 1.5)
    // A vector image has no pixel size, so it uses its point size.
    #expect(ImageEnlargement.aspectRatio(pixelSize: nil, pointSize: CGSize(width: 100, height: 400)) == 0.25)
    // An empty pixel size falls back to the point size.
    #expect(ImageEnlargement.aspectRatio(pixelSize: CGSize(width: 0, height: 10),
                                         pointSize: CGSize(width: 30, height: 10)) == 3)
    // The extremes: a 1 x 1 image and a very wide image.
    #expect(ImageEnlargement.aspectRatio(pixelSize: CGSize(width: 1, height: 1), pointSize: .zero) == 1)
    #expect(ImageEnlargement.aspectRatio(pixelSize: CGSize(width: 20_000, height: 100), pointSize: .zero) == 200)
    // No usable size gives no ratio.
    #expect(ImageEnlargement.aspectRatio(pixelSize: nil, pointSize: .zero) == nil)
    #expect(ImageEnlargement.aspectRatio(pixelSize: CGSize(width: 10, height: 0),
                                         pointSize: CGSize(width: 0, height: 5)) == nil)
}

@Test func articleAudioUsesOnlyBundledLearnerFiles() throws {
    try withCourse { folder, _ in
        let media = folder.appending(path: "content/podcast.mp3")
        try Data([0, 1, 2]).write(to: media)
        let article = LectureArticle(folder: folder, path: "content/plan.md", images: [])
        let audio = try #require(ArticleAudio(paragraph: "[Listen to the podcast](podcast.mp3)", article: article))
        #expect(audio.url == media.resolvingSymlinksInPath())
        #expect(audio.title == "Listen to the podcast")
        for source in ["https://example.com/podcast.mp3", "file:///tmp/podcast.mp3", "../../podcast.mp3",
                       "../internal/podcast.mp3", "missing.mp3", "plan.md"] {
            #expect(ArticleAudio(paragraph: "[Listen](\(source))", article: article) == nil)
        }
        #expect(ArticleAudio(paragraph: "Text [Listen](podcast.mp3)", article: article) == nil)
        let external = folder.deletingLastPathComponent().appending(path: "outside.mp3")
        try Data([0]).write(to: external)
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "content/link.mp3"), withDestinationURL: external)
        #expect(ArticleAudio(paragraph: "[Listen](link.mp3)", article: article) == nil)
    }
}
