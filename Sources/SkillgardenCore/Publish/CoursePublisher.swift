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

public struct ValidationResult: Equatable, Sendable {
    public let title: String
    public let id: String
    public let state: ManifestState
    public let sections: Int
    public let lectures: Int

    public var summary: String {
        "Valid \"\(title)\" (\(id), \(state.rawValue)): \(sections) sections, \(lectures) lectures"
    }
}

/// One team-only file of a published course, in manifest order.
public struct InternalFile: Equatable, Sendable {
    public let title: String
    public let path: String
    public let description: String?
}

/// Publishes immutable asset snapshots before the database refers to them.
public enum CoursePublisher {
    public static func publish(courseFolder: URL, root: URL = Skillgarden.defaultDataDirectory) throws -> PublishResult {
        let destination = root.resolvingSymlinksInPath().standardizedFileURL
        let (manifest, source, files, images) = try check(courseFolder: courseFolder, library: destination)
        let manager = FileManager.default
        // Learner snapshots never hold internal/. Internal files go to a separate store area.
        let learnerFiles = files.filter { !$0.hasPrefix(internalPrefix) }
        let internalFiles = files.filter { $0.hasPrefix(internalPrefix) }.map { String($0.dropFirst(internalPrefix.count)) }
        let internalSource = source.appending(path: "internal")
        let store = try CourseStore(root: root)
        let previous = try store.publication(id: manifest.id)
        let oldManifest = try previous.map { try JSONDecoder().decode(CourseManifest.self, from: $0.manifest) }
        let counts = difference(old: oldManifest, new: manifest)
        let result = PublishResult(title: manifest.title, id: manifest.id, state: manifest.state,
                                   created: counts.0, updated: counts.1, unchanged: counts.2, removed: counts.3)
        // Courses saved before media metadata get their images on the next publish.
        if let previous, oldManifest == manifest, try store.loadCourse(id: manifest.id, includeDrafts: true)?.image != nil,
           try equalFiles(learnerFiles, source: source, snapshot: destination.appending(path: previous.directory)),
           try previous.internalDirectory.map({
               try equalFiles(internalFiles, source: internalSource, snapshot: destination.appending(path: $0))
           }) ?? internalFiles.isEmpty {
            return result
        }
        let name = UUID().uuidString
        let relative = "courses/\(name)"
        let snapshot = destination.appending(path: relative)
        let media = "derivatives/\(name)"
        let internalRelative = internalFiles.isEmpty ? nil : "internal/\(name)"
        do {
            try copy(learnerFiles, from: source, to: snapshot)
            if let internalRelative {
                try copy(internalFiles, from: internalSource, to: destination.appending(path: internalRelative))
            }
            // A source edit during the copy must not install a different manifest.
            guard try ManifestLoader.load(courseFolder: snapshot) == manifest else {
                throw diagnostic(courseFolder, "manifest changed during publish")
            }
            let stored = try publishImages(images, snapshot: relative, media: media, root: destination, folder: courseFolder)
            try store.savePublication(course(from: manifest, images: stored), manifest: JSONEncoder().encode(manifest),
                                      directory: relative, internalDirectory: internalRelative)
        } catch {
            try? manager.removeItem(at: snapshot)
            try? manager.removeItem(at: destination.appending(path: media))
            if let internalRelative { try? manager.removeItem(at: destination.appending(path: internalRelative)) }
            if error is ManifestValidationError || error is CourseStoreError { throw error }
            throw CourseStoreError.databaseFailure
        }
        // Prior snapshots remain valid for readers that already hold their paths.
        return result
    }

    /// Runs every publish-time check and writes nothing. The library root is not used.
    public static func validate(courseFolder: URL) throws -> ValidationResult {
        let manifest = try check(courseFolder: courseFolder, library: nil).manifest
        return ValidationResult(title: manifest.title, id: manifest.id, state: manifest.state, sections: manifest.sections.count,
                                lectures: manifest.sections.reduce(0) { $0 + $1.lectures.count })
    }

    /// Loads the manifest and checks every file it names. `library` must be outside the course folder.
    private static func check(courseFolder: URL, library: URL?) throws
        -> (manifest: CourseManifest, source: URL, files: [String], images: [ImageField]) {
        let manifest = try ManifestLoader.load(courseFolder: courseFolder)
        let source = courseFolder.resolvingSymlinksInPath().standardizedFileURL
        if let library, library.path.hasPrefix(source.path + "/") || library == source {
            throw diagnostic(courseFolder, "library must be outside the course folder")
        }
        let files = try sourceFiles(in: source)
        let images = [ImageField(field: "course_image", image: manifest.courseImage, role: .course)]
            + manifest.sections.enumerated().map {
                ImageField(field: "sections[\($0.offset)].header_image", image: $0.element.headerImage, role: .sectionHeader)
            }
        var problems: [ManifestDiagnostic] = []
        for item in images {
            guard files.contains(item.image.path) else {
                problems.append(ManifestDiagnostic(file: courseFolder.path, fieldPath: item.field + ".path", message: "file does not exist"))
                continue
            }
            do throws(ImagePipelineError) { _ = try ImagePipeline.format(of: source.appending(path: item.image.path)) }
            catch { problems.append(ManifestDiagnostic(file: courseFolder.path, fieldPath: item.field + ".path", message: error.message)) }
        }
        // Question images stay in the snapshot as they are. The app reads them from there.
        for (field, image) in questionImages(manifest) {
            guard files.contains(image.path) else {
                problems.append(ManifestDiagnostic(file: courseFolder.path, fieldPath: field + ".path", message: "file does not exist"))
                continue
            }
            do throws(ImagePipelineError) { _ = try ImagePipeline.format(of: source.appending(path: image.path)) }
            catch { problems.append(ManifestDiagnostic(file: courseFolder.path, fieldPath: field + ".path", message: error.message)) }
        }
        for (index, file) in (manifest.internalMaterial?.files ?? []).enumerated() where !files.contains(file.path) {
            problems.append(ManifestDiagnostic(file: courseFolder.path, fieldPath: "internal.files[\(index)].path", message: "file does not exist"))
        }
        for (sectionIndex, section) in manifest.sections.enumerated() {
            for (lectureIndex, lecture) in section.lectures.enumerated() {
                let field = "sections[\(sectionIndex)].lectures[\(lectureIndex)]"
                if let interactive = lecture.interactive {
                    // The bundle stays in the snapshot as it is. The app loads its `index.html` from there.
                    let path = LectureArticle.normalize(interactive.bundlePath)
                    if path.map({ !files.contains($0 + "/" + InteractiveModule.entryFile) }) ?? true {
                        problems.append(ManifestDiagnostic(file: courseFolder.path, fieldPath: field + ".interactive.bundle_path",
                                                           message: "folder must contain \(InteractiveModule.entryFile)"))
                    }
                }
                if let article = lecture.article {
                    problems += articleProblems(article, field: field + ".article", files: files, source: source, folder: courseFolder)
                }
                // The brief is Markdown with the same image rules as an article.
                if let brief = lecture.assignment?.brief {
                    problems += articleProblems(brief, field: field + ".assignment.brief", files: files, source: source, folder: courseFolder)
                }
                if let video = lecture.video {
                    problems += videoProblems(video, field: field + ".video", files: files, source: source, folder: courseFolder)
                }
                // Download files stay in the snapshot as they are. The app saves them from there.
                for (index, download) in (lecture.downloads ?? []).enumerated()
                    where LectureArticle.normalize(download.path).map({ !files.contains($0) }) ?? true {
                    problems.append(ManifestDiagnostic(file: courseFolder.path, fieldPath: field + ".downloads[\(index)].path",
                                                       message: "file does not exist"))
                }
            }
        }
        guard problems.isEmpty else { throw ManifestValidationError(diagnostics: problems) }
        return (manifest, source, files, images)
    }

    /// Returns the installed snapshot. Source files can be removed after publish.
    public static func assetDirectory(courseID: String, root: URL = Skillgarden.defaultDataDirectory) throws -> URL? {
        try CourseStore(root: root).publication(id: courseID).map { root.appending(path: $0.directory) }
    }

    /// Returns nil for an unknown course. Draft courses also list their internal files.
    public static func internalFiles(courseID: String, root: URL = Skillgarden.defaultDataDirectory) throws -> [InternalFile]? {
        guard let publication = try CourseStore(root: root).publication(id: courseID) else { return nil }
        guard let manifest = try? JSONDecoder().decode(CourseManifest.self, from: publication.manifest) else {
            throw CourseStoreError.invalidData
        }
        return (manifest.internalMaterial?.files ?? []).map {
            InternalFile(title: $0.title, path: $0.path, description: $0.description)
        }
    }

    private static let internalPrefix = "internal/"

    private static func copy(_ files: [String], from source: URL, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for path in files {
            let target = directory.appending(path: path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source.appending(path: path), to: target)
        }
    }

    private static func questionImages(_ manifest: CourseManifest) -> [(field: String, image: ManifestImage)] {
        manifest.sections.enumerated().flatMap { sectionIndex, section in
            section.lectures.enumerated().flatMap { lectureIndex, lecture in
                (lecture.quiz?.questions ?? []).enumerated().compactMap { questionIndex, question in
                    question.image.map {
                        ("sections[\(sectionIndex)].lectures[\(lectureIndex)].quiz.questions[\(questionIndex)].image", $0)
                    }
                }
            }
        }
    }

    private struct ImageField {
        let field: String
        let image: ManifestImage
        let role: ImageRole
    }

    /// Reads images from the snapshot and writes raster derivatives. SVG stays vector and has no derivatives.
    private static func publishImages(_ images: [ImageField], snapshot: String, media: String, root: URL,
                                      folder: URL) throws -> [CourseImage] {
        try FileManager.default.createDirectory(at: root.appending(path: media), withIntermediateDirectories: true)
        var rendered: [String: [ImageDerivative]] = [:]
        return try images.enumerated().map { index, item in
            let url = root.appending(path: snapshot).appending(path: item.image.path)
            do throws(ImagePipelineError) {
                let format = try ImagePipeline.format(of: url)
                var derivatives: [ImageDerivative] = []
                // Sections often share one header file. Render each file once for each role.
                let key = "\(item.role)|\(item.image.path)"
                if format != .svg {
                    if let cached = rendered[key] { derivatives = cached }
                    else {
                        for size in item.role.sizes {
                            let path = "\(media)/\(index)-\(size.width)x\(size.height).png"
                            try ImagePipeline.renderDerivative(from: url, width: size.width, height: size.height,
                                                               to: root.appending(path: path))
                            derivatives.append(ImageDerivative(path: path, width: size.width, height: size.height))
                        }
                        rendered[key] = derivatives
                    }
                }
                return CourseImage(path: "\(snapshot)/\(item.image.path)", alt: item.image.alt,
                                   mimeType: format.rawValue, derivatives: derivatives)
            } catch {
                throw ManifestValidationError(diagnostics: [
                    ManifestDiagnostic(file: folder.path, fieldPath: item.field + ".path", message: error.message),
                ])
            }
        }
    }

    /// Each listed image must be a readable image file. Each Markdown image must exist and have alt text in `images`.
    private static func articleProblems(_ article: ManifestArticle, field: String, files: [String], source: URL,
                                        folder: URL) -> [ManifestDiagnostic] {
        func problem(_ path: String, _ message: String) -> ManifestDiagnostic {
            ManifestDiagnostic(file: folder.path, fieldPath: "\(field).\(path)", message: message)
        }
        var problems: [ManifestDiagnostic] = []
        for (index, image) in (article.images ?? []).enumerated() {
            guard files.contains(image.path) else { problems.append(problem("images[\(index)].path", "file does not exist")); continue }
            do throws(ImagePipelineError) { _ = try ImagePipeline.format(of: source.appending(path: image.path)) }
            catch { problems.append(problem("images[\(index)].path", error.message)) }
        }
        guard files.contains(article.path) else { return problems + [problem("path", "file does not exist")] }
        let lecture = LectureArticle(folder: source, path: article.path, images: article.images ?? [])
        guard let document = try? lecture.load() else { return problems + [problem("path", "cannot read the Markdown file as UTF-8 text")] }
        for reference in document.imageSources {
            guard let target = LectureArticle.resolve(reference, article: article.path) else {
                problems.append(problem("path", "image \"\(reference)\" must be a file inside the course folder"))
                continue
            }
            if !files.contains(target) {
                problems.append(problem("path", "image \"\(reference)\" does not exist (expected \(target))"))
            } else if lecture.alts[target] == nil {
                problems.append(problem("images", "image \"\(target)\" needs an entry with alt text"))
            }
        }
        return problems
    }

    /// The video must be an MP4 file, the captions a WebVTT file and the poster a readable image file.
    private static func videoProblems(_ video: ManifestVideo, field: String, files: [String], source: URL,
                                      folder: URL) -> [ManifestDiagnostic] {
        func problem(_ path: String, _ message: String) -> ManifestDiagnostic {
            ManifestDiagnostic(file: folder.path, fieldPath: "\(field).\(path)", message: message)
        }
        var problems: [ManifestDiagnostic] = []
        if !files.contains(video.path) { problems.append(problem("path", "file does not exist")) }
        else if !LectureVideo.isMP4(source.appending(path: video.path)) { problems.append(problem("path", "file is not an MP4 video")) }
        if let captions = video.captions {
            if !files.contains(captions.path) { problems.append(problem("captions.path", "file does not exist")) }
            else {
                do { _ = try LectureVideo.captions(at: source.appending(path: captions.path)) }
                catch let error as WebVTTError { problems.append(problem("captions.path", "invalid WebVTT file: \(error.message)")) }
                catch { problems.append(problem("captions.path", "cannot read the captions file as UTF-8 text")) }
            }
        }
        if let poster = video.poster {
            if !files.contains(poster.path) { problems.append(problem("poster.path", "file does not exist")) }
            else {
                do throws(ImagePipelineError) { _ = try ImagePipeline.format(of: source.appending(path: poster.path)) }
                catch { problems.append(problem("poster.path", error.message)) }
            }
        }
        return problems
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

    /// `images` holds the course image first, then one header image for each section in manifest order.
    private static func course(from manifest: CourseManifest, images: [CourseImage]) -> Course {
        Course(id: manifest.id, title: manifest.title, subtitle: manifest.subtitle,
               state: manifest.state == .draft ? .draft : .published, sections: manifest.sections.enumerated().map { index, section in
            CourseSection(id: section.id, title: section.title, objective: section.objective, order: section.order,
                          state: section.state == .draft ? .draft : .published, lectures: section.lectures.map { lecture in
                Lecture(id: lecture.id, title: lecture.title, type: LectureType(rawValue: lecture.type.rawValue)!,
                        objective: lecture.objective, order: lecture.order, state: lecture.state == .draft ? .draft : .published,
                        recommendedNext: lecture.recommendedNext)
            }, headerImage: images[index + 1])
        }, image: images[0])
    }
}
