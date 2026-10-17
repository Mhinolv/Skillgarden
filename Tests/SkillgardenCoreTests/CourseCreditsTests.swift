import Foundation
import Testing
@testable import SkillgardenCore

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Tests/Fixtures/sample-course")

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "CourseCreditsTests-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// Copies the fixture into `parent` with text replacements in `skillgarden.yaml`.
private func fixtureCopy(in parent: URL, replacing replacements: [(String, String)]) throws -> URL {
    let copy = parent.appending(path: "course-\(UUID())")
    try FileManager.default.copyItem(at: fixture, to: copy)
    let manifest = copy.appending(path: "skillgarden.yaml")
    var text = try String(contentsOf: manifest, encoding: .utf8)
    for (old, new) in replacements {
        #expect(text.contains(old))
        text = text.replacingOccurrences(of: old, with: new)
    }
    try text.write(to: manifest, atomically: true, encoding: .utf8)
    return copy
}

private func credit(_ url: String?, folder: URL? = nil) -> CourseCredit? {
    CourseCredit(manifest: ManifestCredit(name: "Ada", role: nil, url: url), folder: folder)
}

@MainActor @Test func sampleCourseCreditsMatchTheManifest() async throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = try SnapshotPlan.seedStore(for: .courseCredits, root: root, fixture: fixture)
    let library = LibraryModel(root: root)
    await library.reload()
    #expect(library.selectedCredits.isEmpty)
    library.selectCourse(id)
    #expect(library.selectedCredits == [
        CourseCredit(name: "Skillgarden Team", role: "Author", url: URL(string: "https://example.com/credits")),
        CourseCredit(name: "Garden Photo Library"),
    ])
    library.selectDestination(.credits)
    #expect(library.destination == .credits)
    #expect(library.selectedSection == nil)
    #expect(library.selectedLecture == nil)
    #expect(library.sectionReview == nil)
}

@Test func creditsKeepManifestOrderAndTrimText() throws {
    let data = try Data(contentsOf: fixture.appending(path: "equivalent.json"))
    var manifest = try JSONDecoder().decode(CourseManifest.self, from: data)
    manifest.credits = [
        ManifestCredit(name: " Zoe ", role: "  ", url: nil),
        ManifestCredit(name: " \n", role: "Editor", url: "https://example.com"),
        ManifestCredit(name: "Ada", role: " Narrator ", url: " https://example.com/ada "),
        ManifestCredit(name: "Ben", role: nil, url: ""),
    ]
    #expect(CourseLanding(manifest: manifest).credits == [
        CourseCredit(name: "Zoe"),
        CourseCredit(name: "Ada", role: "Narrator", url: URL(string: "https://example.com/ada")),
        CourseCredit(name: "Ben"),
    ])
    manifest.credits = []
    #expect(CourseLanding(manifest: manifest).credits.isEmpty)
}

@Test(arguments: ["https://example.com/a?b=1", "http://example.com", "HTTPS://Example.com/x"])
func creditKeepsWebLinks(_ text: String) {
    #expect(credit(text)?.url == URL(string: text))
}

@Test(arguments: ["mailto:ada@example.com", "javascript:alert(1)", "ftp://example.com/a", "https://", "https:///path",
                  "file:///etc/hosts", "/etc/hosts", "C:/Windows/notepad.exe", "media/course.svg", "skillgarden://x"])
func creditDropsOtherLinksWithoutAFolder(_ text: String) {
    let credit = credit(text)
    #expect(credit?.name == "Ada")
    #expect(credit?.url == nil)
}

@Test func creditOpensOnlyBundledFilesOfTheSnapshot() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appending(path: "snapshot")
    try FileManager.default.createDirectory(at: folder.appending(path: "docs"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: folder.appending(path: "internal"), withIntermediateDirectories: true)
    try Data("a".utf8).write(to: folder.appending(path: "docs/license.txt"))
    try Data("a".utf8).write(to: folder.appending(path: "internal/notes.txt"))
    try Data("a".utf8).write(to: root.appending(path: "outside.txt"))
    let license = folder.appending(path: "docs/license.txt").standardizedFileURL

    #expect(credit("docs/license.txt", folder: folder)?.url == license)
    #expect(credit("./docs/../docs/license.txt", folder: folder)?.url == license)
    #expect(credit(license.absoluteString, folder: folder)?.url == license)
    // Outside the folder, in internal/, missing, or the folder itself: no link.
    #expect(credit("../outside.txt", folder: folder)?.url == nil)
    #expect(credit("docs/../../outside.txt", folder: folder)?.url == nil)
    #expect(credit(root.appending(path: "outside.txt").absoluteString, folder: folder)?.url == nil)
    #expect(credit(folder.appending(path: "../outside.txt").absoluteString, folder: folder)?.url == nil)
    #expect(credit("internal/notes.txt", folder: folder)?.url == nil)
    #expect(credit(folder.appending(path: "internal/notes.txt").absoluteString, folder: folder)?.url == nil)
    #expect(credit("docs/missing.txt", folder: folder)?.url == nil)
    #expect(credit(".", folder: folder)?.url == nil)
    #expect(credit(folder.appending(path: "docs/license.txt").path, folder: folder)?.url == nil)
}

@MainActor @Test func publishedCreditLinkResolvesInsideTheInstalledSnapshot() async throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try fixtureCopy(in: root, replacing: [("url: https://example.com/credits", "url: media/course.svg")])
    let id = try CoursePublisher.publish(courseFolder: source, root: root.appending(path: "data")).id
    let library = LibraryModel(root: root.appending(path: "data"))
    await library.reload()
    library.selectCourse(id)
    let url = try #require(library.selectedCredits.first?.url)
    #expect(url.isFileURL)
    #expect(url.path.hasPrefix(root.appending(path: "data").standardizedFileURL.path + "/"))
    #expect(!url.path.hasPrefix(source.path))
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@MainActor @Test func courseWithoutCreditsHasNoCreditsPage() async throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let data = root.appending(path: "data")
    let id = try CoursePublisher.publish(courseFolder: fixture, root: data).id
    let library = LibraryModel(root: data)
    await library.reload()
    library.selectCourse(id)
    library.selectDestination(.credits)
    #expect(library.destination == .credits)

    // A republish removes every credit. The reload leaves the credits page.
    let empty = try fixtureCopy(in: root, replacing: [(
        "credits:\n  - name: Skillgarden Team\n    role: Author\n    url: https://example.com/credits\n", "credits: []\n"
    )])
    _ = try CoursePublisher.publish(courseFolder: empty, root: data)
    await library.reload()
    #expect(library.selectedCredits.isEmpty)
    #expect(library.destination == .overview)
    library.selectDestination(.credits)
    #expect(library.destination == .overview)
}

@MainActor @Test func creditsPageNeedsASelectedCourse() async throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try CoursePublisher.publish(courseFolder: fixture, root: root)
    let library = LibraryModel(root: root)
    await library.reload()
    library.selectDestination(.credits)
    #expect(library.destination == nil)
    #expect(library.selectedCredits.isEmpty)
}
