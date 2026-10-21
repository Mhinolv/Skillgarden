import AppKit
import Foundation
import ImageIO
import SQLite3
import Testing
@testable import SkillgardenCore

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/sample-course")

private func withFolder(_ body: (URL) throws -> Void) throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "SkillgardenMediaTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    try body(base)
}

/// Gives each test a writable copy of the sample course and an empty library root.
private func withCourse(_ body: (URL, URL) throws -> Void) throws {
    try withFolder { base in
        let folder = base.appending(path: "course")
        try FileManager.default.copyItem(at: fixture, to: folder)
        try FileManager.default.removeItem(at: folder.appending(path: "equivalent.json"))
        try body(folder, base.appending(path: "library"))
    }
}

private func edit(_ folder: URL, _ old: String, _ new: String) throws {
    let file = folder.appending(path: "skillgarden.yaml")
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text.contains(old))
    try text.replacingOccurrences(of: old, with: new).write(to: file, atomically: true, encoding: .utf8)
}

/// Writes an opaque red raster image of the given pixel size.
private func writeImage(_ url: URL, width: Int, height: Int, type: String = "public.png") throws {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
}

/// Returns the pixel size and a function that reads the alpha of one pixel (top-left origin).
private func pixels(_ url: URL) throws -> (width: Int, height: Int, alpha: (Int, Int) -> UInt8) {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                         bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let width = image.width, count = image.width * image.height * 4
    let data = Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self), count: count))
    return (image.width, image.height, { x, y in data[(y * width + x) * 4 + 3] })
}

@Test(arguments: [
    // Tall, square, wide and exact sources for both roles.
    ((100, 400), (750, 422)), ((400, 400), (750, 422)), ((2000, 400), (750, 422)), ((1500, 844), (750, 422)),
    ((300, 900), (1920, 1080)), ((40, 30), (960, 540)), ((1, 1), (375, 211)),
])
func derivativeMatchesTargetSizeWithLetterbox(source: (Int, Int), target: (Int, Int)) throws {
    try withFolder { folder in
        let input = folder.appending(path: "source.png"), output = folder.appending(path: "out.png")
        try writeImage(input, width: source.0, height: source.1)
        try ImagePipeline.renderDerivative(from: input, width: target.0, height: target.1, to: output)
        let result = try pixels(output)
        #expect(result.width == target.0 && result.height == target.1)
        let frame = ImagePipeline.fitRect(source: source, target: target)
        // The full source is visible: the fit rectangle keeps the source aspect and stays inside the target.
        #expect(frame.minX >= 0 && frame.minY >= 0 && frame.maxX <= CGFloat(target.0) && frame.maxY <= CGFloat(target.1))
        #expect(frame.width == CGFloat(target.0) || frame.height == CGFloat(target.1))
        #expect(abs(frame.width / frame.height - Double(source.0) / Double(source.1)) < 0.05 * Double(source.0) / Double(source.1) + 0.02)
        #expect(result.alpha(target.0 / 2, target.1 / 2) == 255)
        let tall = source.0 * target.1 < source.1 * target.0
        let wide = source.0 * target.1 > source.1 * target.0
        if tall { #expect(result.alpha(0, target.1 / 2) == 0 && result.alpha(target.0 - 1, target.1 / 2) == 0) }
        if wide { #expect(result.alpha(target.0 / 2, 0) == 0 && result.alpha(target.0 / 2, target.1 - 1) == 0) }
        if !tall && !wide { #expect(result.alpha(0, 0) == 255 && result.alpha(target.0 - 1, target.1 - 1) == 255) }
    }
}

@Test func formatDetectionAcceptsPNGJPGAndSVG() throws {
    try withFolder { folder in
        try writeImage(folder.appending(path: "a.png"), width: 4, height: 3)
        try writeImage(folder.appending(path: "b.jpg"), width: 4, height: 3, type: "public.jpeg")
        try writeImage(folder.appending(path: "c.JPEG"), width: 4, height: 3, type: "public.jpeg")
        #expect(try ImagePipeline.format(of: folder.appending(path: "a.png")) == .png)
        #expect(try ImagePipeline.format(of: folder.appending(path: "b.jpg")) == .jpeg)
        #expect(try ImagePipeline.format(of: folder.appending(path: "c.JPEG")) == .jpeg)
        #expect(try ImagePipeline.format(of: fixture.appending(path: "media/course.svg")) == .svg)
        #expect(ImageFormat.svg.rawValue == "image/svg+xml")
    }
}

@Test func formatDetectionRejectsOtherAndBrokenFiles() throws {
    try withFolder { folder in
        try writeImage(folder.appending(path: "a.gif"), width: 4, height: 3, type: "com.compuserve.gif")
        try writeImage(folder.appending(path: "gif-named.png"), width: 4, height: 3, type: "com.compuserve.gif")
        try Data("text".utf8).write(to: folder.appending(path: "a.txt"))
        try Data("not a png".utf8).write(to: folder.appending(path: "broken.png"))
        try Data().write(to: folder.appending(path: "empty.jpg"))
        try Data("<html></html>".utf8).write(to: folder.appending(path: "html.svg"))
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\"><rect".utf8).write(to: folder.appending(path: "cut.svg"))
        for name in ["a.gif", "gif-named.png", "a.txt"] {
            #expect(throws: ImagePipelineError.unsupportedFormat) { try ImagePipeline.format(of: folder.appending(path: name)) }
        }
        for name in ["broken.png", "empty.jpg", "html.svg", "cut.svg"] {
            #expect(throws: ImagePipelineError.unreadable) { try ImagePipeline.format(of: folder.appending(path: name)) }
        }
        #expect(ImagePipelineError.unsupportedFormat.message == "unsupported image format (use PNG, JPG or SVG)")
        #expect(ImagePipelineError.unreadable.message == "the image cannot be read")
    }
}

@Test func appPicksSmallestDerivativeThatCoversDisplay() {
    let image = CourseImage(path: "source.png", alt: "Alt", mimeType: "image/png", derivatives: [
        ImageDerivative(path: "large", width: 750, height: 422), ImageDerivative(path: "small", width: 375, height: 211),
    ])
    #expect(image.derivatives.map(\.path) == ["small", "large"])
    #expect(image.path(forPixelWidth: 128, height: 72) == "small")
    #expect(image.path(forPixelWidth: 375, height: 211) == "small")
    #expect(image.path(forPixelWidth: 376, height: 100) == "large")
    #expect(image.path(forPixelWidth: 750, height: 422) == "large")
    #expect(image.path(forPixelWidth: 1500, height: 844) == "source.png")
    let svg = CourseImage(path: "course.svg", alt: "Alt", mimeType: "image/svg+xml")
    #expect(svg.path(forPixelWidth: 64, height: 36) == "course.svg")
}

@Test func svgFixturePublishesAsVectorMetadata() throws {
    try withCourse { folder, root in
        try CoursePublisher.publish(courseFolder: folder, root: root)
        let course = try #require(try CourseStore(root: root).loadCourse(id: "sample-course", includeDrafts: true))
        let image = try #require(course.image)
        #expect(image.mimeType == "image/svg+xml")
        #expect(image.alt == "Local Course Basics, with a notebook and leafy branch on pale green.")
        #expect(image.derivatives.isEmpty)
        #expect(image.path.hasPrefix("courses/") && image.path.hasSuffix("/media/course.svg"))
        #expect(course.sections.map { $0.headerImage?.mimeType } == ["image/svg+xml", "image/svg+xml"])
        // AppKit keeps the SVG as a vector representation, so it draws sharp at the display size.
        let drawn = try #require(NSImage(data: Data(contentsOf: root.appending(path: image.path))))
        #expect(!drawn.representations.contains { $0 is NSBitmapImageRep })
    }
}

@Test func rasterImagesPublishDerivativesForEachRole() throws {
    try withCourse { folder, root in
        try writeImage(folder.appending(path: "media/tall.png"), width: 300, height: 600)
        try writeImage(folder.appending(path: "media/header.jpg"), width: 800, height: 800, type: "public.jpeg")
        try edit(folder, "path: media/course.svg", "path: media/tall.png")
        // The article image also uses media/section.svg. Change only the section header images.
        try edit(folder, "header_image:\n      path: media/section.svg", "header_image:\n      path: media/header.jpg")
        try CoursePublisher.publish(courseFolder: folder, root: root)
        let course = try #require(try CourseStore(root: root).loadCourse(id: "sample-course", includeDrafts: true))
        let image = try #require(course.image)
        #expect(image.mimeType == "image/png")
        #expect(image.derivatives.map { [$0.width, $0.height] } == [[375, 211], [750, 422]])
        let headers = course.sections.compactMap(\.headerImage)
        #expect(headers.count == 2)
        #expect(headers.allSatisfy { $0.mimeType == "image/jpeg" })
        #expect(headers[0].derivatives.map { [$0.width, $0.height] } == [[960, 540], [1920, 1080]])
        // Sections that share one file share one set of derivative files.
        #expect(headers[0].derivatives == headers[1].derivatives)
        for derivative in image.derivatives + headers[0].derivatives {
            let result = try pixels(root.appending(path: derivative.path))
            #expect(result.width == derivative.width && result.height == derivative.height)
            #expect(result.alpha(0, derivative.height / 2) == 0)
            #expect(result.alpha(derivative.width / 2, derivative.height / 2) == 255)
        }
        // A repeat publish keeps the same snapshot and derivatives.
        try CoursePublisher.publish(courseFolder: folder, root: root)
        #expect(try CourseStore(root: root).loadCourse(id: "sample-course", includeDrafts: true)?.image == image)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "derivatives").path).count == 1)
    }
}

@Test func publishFailsWhenAnyImageOmitsAlt() throws {
    try withCourse { folder, root in
        let manifest = folder.appending(path: "skillgarden.yaml").path
        try edit(folder, "  alt: Local Course Basics, with a notebook and leafy branch on pale green.\n", "")
        #expect(SkillgardenCommand.run(arguments: ["publish", folder.path], root: root) == CommandResult(
            exitCode: 1, stdout: "", stderr: "error: \(manifest): course_image.alt: alt text is required\n"))
        try edit(folder, "  path: media/course.svg\n", "  path: media/course.svg\n  alt: \"  \"\n")
        try edit(folder, """
                  path: media/section.svg
                  alt: Two course sections
                lectures:
                  - id: check
            """, """
                  path: media/section.svg
                  alt: null
                lectures:
                  - id: check
            """)
        #expect(SkillgardenCommand.run(arguments: ["publish", folder.path], root: root) == CommandResult(exitCode: 1, stdout: "", stderr: """
            error: \(manifest): course_image.alt: alt text is required
            error: \(manifest): sections[1].header_image.alt: alt text is required

            """))
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}

@Test func publishRejectsBadImageFormatsAndFiles() throws {
    try withCourse { folder, root in
        try writeImage(folder.appending(path: "media/cover.gif"), width: 4, height: 3, type: "com.compuserve.gif")
        try Data("not a png".utf8).write(to: folder.appending(path: "media/broken.png"))
        try edit(folder, "path: media/course.svg", "path: media/cover.gif")
        try edit(folder, """
                  path: media/section.svg
                  alt: Two course sections
                lectures:
                  - id: check
            """, """
                  path: media/broken.png
                  alt: Two course sections
                lectures:
                  - id: check
            """)
        #expect(SkillgardenCommand.run(arguments: ["publish", folder.path], root: root) == CommandResult(exitCode: 1, stdout: "", stderr: """
            error: \(folder.path): course_image.path: unsupported image format (use PNG, JPG or SVG)
            error: \(folder.path): sections[1].header_image.path: the image cannot be read

            """))
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}

@Test func schemaVersionTwoDataLoadsAndGainsImagesOnRepublish() throws {
    try withCourse { folder, root in
        // Publish with the version 2 store and layout, as the app did before media metadata.
        let old = try CourseStore(root: root, migrations: Array(CourseStore.migrations.prefix(2)))
        #expect(try old.schemaVersion == 2)
        let manifest = try ManifestLoader.load(courseFolder: folder)
        let saved = Course(id: "sample-course", title: manifest.title, subtitle: manifest.subtitle, state: .published, sections: [
            CourseSection(id: "plan", title: "Plan the course", order: 0, state: .published, lectures: [
                Lecture(id: "welcome", title: "Welcome", type: .video, order: 0, state: .published),
            ]),
        ])
        let directory = "courses/old"
        try FileManager.default.createDirectory(at: root.appending(path: "courses"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: folder, to: root.appending(path: directory))
        // Write the rows with version 2 SQL. Current store code writes the image columns.
        let v2 = try SQLiteDatabase(url: old.databaseURL)
        try v2.execute("INSERT INTO courses (id, title, subtitle, state) VALUES ('sample-course', ?, ?, 'published')",
                       [manifest.title, manifest.subtitle])
        try v2.execute("INSERT INTO sections (course_id, id, title, objective, sort_order, state) VALUES ('sample-course', 'plan', 'Plan the course', '', 0, 'published')")
        try v2.execute("INSERT INTO lectures (course_id, section_id, id, title, type, objective, sort_order, state) VALUES ('sample-course', 'plan', 'welcome', 'Welcome', 'video', '', 0, 'published')")
        try v2.execute("INSERT INTO course_publications (course_id, manifest, directory) VALUES ('sample-course', ?, ?)",
                       [String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self), directory])
        let upgraded = try CourseStore(root: root)
        #expect(try upgraded.schemaVersion == CourseStore.currentSchemaVersion)
        #expect(try upgraded.loadCourse(id: "sample-course") == saved)
        let db = try SQLiteDatabase(url: upgraded.databaseURL)
        #expect(try db.query("SELECT image IS NULL FROM courses") { sqlite3_column_int64($0, 0) } == [1])
        // The manifest and files are unchanged, but the course still gains image metadata.
        try CoursePublisher.publish(courseFolder: folder, root: root)
        let course = try #require(try upgraded.loadCourse(id: "sample-course", includeDrafts: true))
        #expect(course.image?.mimeType == "image/svg+xml")
        #expect(course.sections.allSatisfy { $0.headerImage != nil })
    }
}

@Test func corruptImageMetadataThrowsInvalidData() throws {
    try withCourse { folder, root in
        try CoursePublisher.publish(courseFolder: folder, root: root)
        let store = try CourseStore(root: root)
        try SQLiteDatabase(url: store.databaseURL).execute("UPDATE courses SET image = 'not json'")
        #expect(throws: CourseStoreError.invalidData) { try store.listCourses() }
    }
}
