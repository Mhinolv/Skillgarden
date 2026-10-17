import CoreGraphics
import Foundation
import Testing
@testable import SkillgardenCore

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/sample-course")
private let worksheet = fixture.appending(path: "content/worksheet.pdf")

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "DownloadTests-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func fixtureObject() throws -> [String: Any] {
    let manifest = try ManifestLoader.load(courseFolder: fixture)
    return try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
}

/// Sets `downloads` on the lecture at `sections[section].lectures[lecture]`. The default is the video lecture.
private func setDownloads(_ object: inout [String: Any], section: Int = 0, lecture: Int = 0, _ downloads: Any) throws {
    var sections = try #require(object["sections"] as? [[String: Any]])
    var lectures = try #require(sections[section]["lectures"] as? [[String: Any]])
    lectures[lecture]["downloads"] = downloads
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

private var worksheetEntry: [String: Any] { [
    "path": "content/worksheet.pdf", "title": "Course plan worksheet", "description": "Fill in one row for each section.",
] }
private var csvEntry: [String: Any] { ["path": "content/sections.csv", "title": "Section list"] }

/// A copy of the fixture with a JSON manifest. `change` edits the manifest object before the write.
private func courseCopy(in base: URL, _ change: (inout [String: Any]) throws -> Void) throws -> URL {
    let folder = base.appending(path: "course")
    try FileManager.default.copyItem(at: fixture, to: folder)
    try FileManager.default.removeItem(at: folder.appending(path: "equivalent.json"))
    try FileManager.default.removeItem(at: folder.appending(path: "skillgarden.yaml"))
    var object = try fixtureObject()
    try change(&object)
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: folder.appending(path: "skillgarden.json"))
    return folder
}

// MARK: Manifest

@Test func manifestParsesDownloadsOnAnyLectureTypeInOrder() throws {
    var object = try fixtureObject()
    try setDownloads(&object, [worksheetEntry, csvEntry])
    try setDownloads(&object, lecture: 1, [csvEntry])
    #expect(try errors(object) == [])
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "skillgarden.json")
    try JSONSerialization.data(withJSONObject: object).write(to: file)
    let manifest = try ManifestLoader.load(file: file)
    let lectures = manifest.sections[0].lectures
    #expect(lectures[0].downloads == [
        ManifestDownload(path: "content/worksheet.pdf", title: "Course plan worksheet", description: "Fill in one row for each section."),
        ManifestDownload(path: "content/sections.csv", title: "Section list", description: nil),
    ])
    #expect(lectures[1].type == .article)
    #expect(lectures[1].downloads?.map(\.title) == ["Section list"])
    // The fixture manifest has no `downloads` field, so older manifests stay valid.
    #expect(try ManifestLoader.load(courseFolder: fixture).sections.flatMap(\.lectures).allSatisfy { $0.downloads == nil })
}

@Test func manifestChecksEachDownloadField() throws {
    var object = try fixtureObject()
    let field = "sections[0].lectures[0].downloads"
    try setDownloads(&object, [["path": "content/sections.csv"], ["title": "No path"], ["path": "", "title": " "],
                                ["path": "content/sections.csv", "title": "Bad description", "description": 3]])
    #expect(Set(try errors(object)) == [
        "\(field)[0].title: required field is missing", "\(field)[1].path: required field is missing",
        "\(field)[2].path: must not be empty", "\(field)[2].title: must not be empty",
        "\(field)[3].description: expected string, found integer",
    ])
    try setDownloads(&object, "content/sections.csv")
    #expect(try errors(object) == ["\(field): expected array, found string"])
    try setDownloads(&object, [])
    #expect(try errors(object) == [])
}

@Test(arguments: ["../secret.pdf", "/tmp/secret.pdf", "C:\\secret.pdf", "file:///tmp/secret.pdf", "internal/research.md"])
func manifestRejectsDownloadPathsOutsideTheLearnerFiles(path: String) throws {
    var object = try fixtureObject()
    try setDownloads(&object, [["path": path, "title": "Secret"]])
    let expected = path.hasPrefix("internal/") ? "path must not be inside internal/" : "path must stay inside the course folder"
    #expect(try errors(object) == ["sections[0].lectures[0].downloads[0].path: \(expected)"])
}

// MARK: Publish

@Test func publishRequiresEachDownloadFile() throws {
    let base = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: base) }
    let folder = try courseCopy(in: base) { try setDownloads(&$0, [worksheetEntry, ["path": "content/missing.zip", "title": "Missing"]]) }
    let root = base.appending(path: "library")
    let checks: [() throws -> Void] = [
        { _ = try CoursePublisher.validate(courseFolder: folder) },
        { _ = try CoursePublisher.publish(courseFolder: folder, root: root) },
    ]
    for check in checks {
        let error = try #require(throws: ManifestValidationError.self) { try check() }
        #expect(error.diagnostics.map { "\($0.fieldPath): \($0.message)" } == ["sections[0].lectures[0].downloads[1].path: file does not exist"])
    }
    #expect(try CourseStore(root: root).listCourses(includeDrafts: true).isEmpty)
}

@MainActor @Test func publishCopiesDownloadFilesAndListsThemOnTheLecture() async throws {
    let base = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: base) }
    let folder = try courseCopy(in: base) {
        try setDownloads(&$0, [worksheetEntry, csvEntry])
        try setDownloads(&$0, lecture: 1, [csvEntry])
    }
    let root = base.appending(path: "library")
    let id = try CoursePublisher.publish(courseFolder: folder, root: root).id
    // The source folder can go away after publish. The app reads the snapshot.
    try FileManager.default.removeItem(at: folder)
    let snapshot = try #require(try CoursePublisher.assetDirectory(courseID: id, root: root)).standardizedFileURL
    let library = LibraryModel(root: root)
    await library.reload()
    library.selectCourse(id)
    let downloads = library.downloads(forLecture: "welcome")
    #expect(downloads.map(\.id) == [0, 1])
    #expect(downloads.map(\.title) == ["Course plan worksheet", "Section list"])
    #expect(downloads.map(\.description) == ["Fill in one row for each section.", nil])
    #expect(downloads.map(\.kind) == [.pdf, .csv])
    #expect(downloads.map(\.url.path) == [snapshot.appending(path: "content/worksheet.pdf").path,
                                          snapshot.appending(path: "content/sections.csv").path])
    #expect(downloads.allSatisfy { $0.isAvailable })
    #expect(try downloads.map { try Data(contentsOf: $0.url) }
        == [try Data(contentsOf: worksheet), try Data(contentsOf: fixture.appending(path: "content/sections.csv"))])
    #expect(downloads[1].byteCount == 46)
    #expect(downloads[1].meta == "CSV · 46 bytes")
    #expect(library.downloads(forLecture: "read").map(\.title) == ["Section list"])
    #expect(library.downloads(forLecture: "missing").isEmpty)

    // A file that disappears from the store shows as unavailable after the next reload.
    try FileManager.default.removeItem(at: downloads[1].url)
    await library.reload()
    let reloaded = library.downloads(forLecture: "welcome")
    #expect(reloaded.map(\.isAvailable) == [true, false])
    #expect(reloaded[1].meta == "CSV")
}

@MainActor @Test func coursesWithoutDownloadsListNone() async throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = try CoursePublisher.publish(courseFolder: fixture, root: root).id
    let library = LibraryModel(root: root)
    await library.reload()
    library.selectCourse(id)
    #expect(library.downloads.isEmpty)
    #expect(library.downloads(forLecture: "welcome").isEmpty)
}

// MARK: Model

@Test func downloadsResolveInsideTheSnapshotOnly() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data("a,b\n".utf8).write(to: folder.appending(path: "list.csv"))
    let list = LectureDownload.list([
        ManifestDownload(path: "./list.csv", title: "List", description: "  "),
        ManifestDownload(path: "../outside.csv", title: "Outside", description: nil),
        ManifestDownload(path: "internal/research.md", title: "Internal", description: nil),
        ManifestDownload(path: "gone.zip", title: "Gone", description: "Old"),
    ], folder: folder.standardizedFileURL)
    // Entries outside the snapshot are left out. The ids keep the manifest positions.
    #expect(list.map(\.id) == [0, 3])
    #expect(list[0].description == nil)
    #expect(list[0].byteCount == 4)
    #expect(list[1].isAvailable == false)
    #expect(list[1].kind == .zip)
    #expect(LectureDownload.list(nil, folder: folder).isEmpty)
}

@Test func downloadKindAndMeta() {
    #expect(DownloadKind(path: "a/Worksheet.PDF") == .pdf)
    #expect(DownloadKind(path: "a.csv") == .csv)
    #expect(DownloadKind(path: "a.zip") == .zip)
    #expect(DownloadKind(path: "a.txt") == .other("txt"))
    #expect(DownloadKind(path: "README") == .other(""))
    #expect([DownloadKind.pdf, .csv, .zip, .other("txt"), .other("")].map(\.symbolName)
        == ["doc.richtext", "tablecells", "doc.zipper", "doc", "doc"])
    #expect([DownloadKind.pdf, .csv, .zip, .other("txt"), .other("")].map(\.label) == ["PDF", "CSV", "ZIP", "TXT", "File"])
    func download(_ path: String, title: String = "Plan", bytes: Int64?) -> LectureDownload {
        LectureDownload(id: 0, title: title, description: nil, url: URL(fileURLWithPath: "/tmp/s/\(path)"), byteCount: bytes)
    }
    #expect(download("a.pdf", bytes: 1_200_000).meta == "PDF · 1.2 MB")
    #expect(download("a.pdf", bytes: 0).meta == "PDF · Zero KB")
    #expect(download("a.pdf", bytes: nil).meta == "PDF")
    #expect(download("a.pdf", bytes: 2_500_000_000).meta == "PDF · 2.5 GB")
    #expect(download("a.pdf", bytes: 1).suggestedFileName == "Plan.pdf")
    #expect(download("a.pdf", title: "Plan.PDF", bytes: 1).suggestedFileName == "Plan.PDF")
    #expect(download("a.tar.gz", title: "Week 1/2: notes", bytes: 1).suggestedFileName == "Week 1-2- notes.gz")
    #expect(download("README", bytes: 1).suggestedFileName == "Plan")
    #expect(download("notes.txt", title: "  ", bytes: 1).suggestedFileName == "notes.txt")
}

@Test func saveWritesTheFileBytesToTheChosenPath() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = fixture.appending(path: "content/sections.csv")
    let download = LectureDownload(id: 0, title: "Section list", description: nil, url: source, byteCount: 46)
    let target = folder.appending(path: download.suggestedFileName)
    try download.save(to: target)
    #expect(try Data(contentsOf: target) == (try Data(contentsOf: source)))
    // A second save replaces the file at the chosen path.
    try Data("old".utf8).write(to: target)
    try download.save(to: target)
    #expect(try Data(contentsOf: target) == (try Data(contentsOf: source)))
    // A binary PDF keeps every byte.
    let pdfTarget = folder.appending(path: "copy.pdf")
    try LectureDownload(id: 1, title: "Worksheet", description: nil, url: worksheet, byteCount: nil).save(to: pdfTarget)
    #expect(try Data(contentsOf: pdfTarget) == (try Data(contentsOf: worksheet)))
    // A missing source or a folder that does not exist throws, and the target does not change.
    let missing = LectureDownload(id: 2, title: "Gone", description: nil, url: folder.appending(path: "gone.csv"), byteCount: nil)
    #expect(throws: (any Error).self) { try missing.save(to: target) }
    #expect(try Data(contentsOf: target) == (try Data(contentsOf: source)))
    #expect(throws: (any Error).self) { try download.save(to: folder.appending(path: "no/such/folder.csv")) }
}

// MARK: PDF preview

/// The RGBA bytes of the pixel at `x`, `y`, where `y` counts from the top row.
private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 4)
    let context = try #require(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
    return bytes
}

@Test func pdfPreviewRendersTheFirstPageOfTheFixture() throws {
    #expect(PDFPreview.pageCount(of: worksheet) == 2)
    #expect(PDFPreview.pageLabel(page: 1, of: 2) == "Page 1 of 2")
    // The row thumbnail is 64 × 83 pt. Page 1 is portrait (612 × 792), page 2 is landscape and red.
    let thumbnail = try #require(PDFPreview.firstPage(of: worksheet, width: 64, height: 83))
    #expect(thumbnail.width == 128)
    #expect(thumbnail.height == 166)
    // Page 1 has a green band at the top and a white page below it.
    let top = try pixel(thumbnail, x: 64, y: 5)
    #expect(abs(Int(top[0]) - 40) < 12 && abs(Int(top[1]) - 102) < 12 && abs(Int(top[2]) - 68) < 12, "\(top)")
    #expect(try pixel(thumbnail, x: 120, y: 160) == [255, 255, 255, 255])
    // A larger box keeps the page aspect ratio.
    let sheet = try #require(PDFPreview.firstPage(of: worksheet, width: 560, height: 560, scale: 1))
    #expect(sheet.height == 560)
    #expect(sheet.width == 433)
}

@Test func pdfPreviewRejectsFilesThatAreNotPDFs() throws {
    let csv = fixture.appending(path: "content/sections.csv")
    #expect(PDFPreview.pageCount(of: csv) == nil)
    #expect(PDFPreview.firstPage(of: csv, width: 64, height: 83) == nil)
    #expect(PDFPreview.firstPage(of: fixture.appending(path: "content/missing.pdf"), width: 64, height: 83) == nil)
    #expect(PDFPreview.firstPage(of: worksheet, width: 0, height: 83) == nil)
}
