import Foundation

public struct PublishResult: Equatable, Sendable {
    public let title: String
    public let id: String
    public let state: ManifestState
    public let created: Int
    public let updated: Int
    public let unchanged: Int
    public let removed: Int

    public var summary: String {
        "Published \"\(title)\" (\(id), \(state.rawValue)): created \(created), updated \(updated), unchanged \(unchanged), removed \(removed)"
    }
}

/// Publishes immutable asset snapshots before the database refers to them.
public enum CoursePublisher {
    public static func publish(courseFolder: URL, root: URL = Skillgarden.defaultDataDirectory) throws -> PublishResult {
        let manifest = try ManifestLoader.load(courseFolder: courseFolder)
        let manager = FileManager.default
        let source = courseFolder.resolvingSymlinksInPath().standardizedFileURL
        let destination = root.resolvingSymlinksInPath().standardizedFileURL
        guard !destination.path.hasPrefix(source.path + "/"), destination != source else {
            throw diagnostic(courseFolder, "library must be outside the course folder")
        }
        let files = try sourceFiles(in: source)
        for (field, path) in [("course_image.path", manifest.courseImage.path)] + manifest.sections.enumerated().map({
            ("sections[\($0.offset)].header_image.path", $0.element.headerImage.path)
        }) {
            guard files.contains(path) else {
                throw ManifestValidationError(diagnostics: [ManifestDiagnostic(file: courseFolder.path, fieldPath: field, message: "file does not exist")])
            }
        }
        let store = try CourseStore(root: root)
        let previous = try store.publication(id: manifest.id)
        let oldManifest = try previous.map { try JSONDecoder().decode(CourseManifest.self, from: $0.manifest) }
        let counts = difference(old: oldManifest, new: manifest)
        let result = PublishResult(title: manifest.title, id: manifest.id, state: manifest.state,
                                   created: counts.0, updated: counts.1, unchanged: counts.2, removed: counts.3)
        if let previous, oldManifest == manifest,
           try equalFiles(files, source: source, snapshot: destination.appending(path: previous.directory)) {
            return result
        }
        let relative = "courses/\(UUID().uuidString)"
        let snapshot = destination.appending(path: relative)
        do {
            try manager.createDirectory(at: snapshot, withIntermediateDirectories: true)
            for path in files {
                let target = snapshot.appending(path: path)
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.copyItem(at: source.appending(path: path), to: target)
            }
            // A source edit during the copy must not install a different manifest.
            guard try ManifestLoader.load(courseFolder: snapshot) == manifest else {
                throw diagnostic(courseFolder, "manifest changed during publish")
            }
            try store.savePublication(course(from: manifest), manifest: JSONEncoder().encode(manifest), directory: relative)
        } catch {
            try? manager.removeItem(at: snapshot)
            if error is ManifestValidationError || error is CourseStoreError { throw error }
            throw CourseStoreError.databaseFailure
        }
        // Prior snapshots remain valid for readers that already hold their paths.
        return result
    }

    /// Returns the installed snapshot. Source files can be removed after publish.
    public static func assetDirectory(courseID: String, root: URL = Skillgarden.defaultDataDirectory) throws -> URL? {
        try CourseStore(root: root).publication(id: courseID).map { root.appending(path: $0.directory) }
    }

    private static func sourceFiles(in folder: URL) throws -> [String] {
        var files: [String] = []
        func visit(_ directory: URL, prefix: String) throws {
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let path = prefix + url.lastPathComponent
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
                guard values.isSymbolicLink != true else { throw diagnostic(folder, "symbolic links are not supported: \(path)") }
                if values.isDirectory == true { try visit(url, prefix: path + "/") }
                else if values.isRegularFile == true { files.append(path) }
                else { throw diagnostic(folder, "unsupported file: \(path)") }
            }
        }
        do { try visit(folder, prefix: "") }
        catch let error as ManifestValidationError { throw error }
        catch { throw diagnostic(folder, "cannot read course files") }
        return files
    }

    private static func equalFiles(_ files: [String], source: URL, snapshot: URL) throws -> Bool {
        guard (try? sourceFiles(in: snapshot)) == files else { return false }
        return files.allSatisfy {
            FileManager.default.contentsEqual(atPath: source.appending(path: $0).path, andPath: snapshot.appending(path: $0).path)
        }
    }

    private static func diagnostic(_ folder: URL, _ message: String) -> ManifestValidationError {
        ManifestValidationError(diagnostics: [ManifestDiagnostic(file: folder.path, fieldPath: "$", message: message)])
    }

    private static func difference(old: CourseManifest?, new: CourseManifest) -> (Int, Int, Int, Int) {
        func rows(_ manifest: CourseManifest?) -> [String: Data] {
            guard let manifest else { return [:] }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            var result: [String: Data] = [:]
            for var section in manifest.sections {
                for lecture in section.lectures { result["lecture:" + lecture.id] = try? encoder.encode(lecture) }
                section.lectures = []
                result["section:" + section.id] = try? encoder.encode(section)
            }
            return result
        }
        let before = rows(old), after = rows(new)
        let created = after.keys.filter { before[$0] == nil }.count
        let updated = after.keys.filter { before[$0] != nil && before[$0] != after[$0] }.count
        let unchanged = after.count - created - updated
        let removed = before.keys.filter { after[$0] == nil }.count
        return (created, updated, unchanged, removed)
    }

    private static func course(from manifest: CourseManifest) -> Course {
        Course(id: manifest.id, title: manifest.title, subtitle: manifest.subtitle,
               state: manifest.state == .draft ? .draft : .published, sections: manifest.sections.map { section in
            CourseSection(id: section.id, title: section.title, objective: section.objective, order: section.order,
                          state: section.state == .draft ? .draft : .published, lectures: section.lectures.map { lecture in
                Lecture(id: lecture.id, title: lecture.title, type: LectureType(rawValue: lecture.type.rawValue)!,
                        objective: lecture.objective, order: lecture.order, state: lecture.state == .draft ? .draft : .published,
                        recommendedNext: lecture.recommendedNext)
            })
        })
    }
}
