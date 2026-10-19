import Foundation

public enum CourseScaffoldError: Error, Equatable {
    /// The folder holds entries other than `.DS_Store`.
    case notEmpty(String)
    /// A file, not a folder, is at the path.
    case notAFolder(String)
    /// A read or a write failed. Init deleted the files that it wrote.
    case write(String)
}

/// The starter course of `skillgarden init` (#110): a draft course with one article lecture and two local SVG images.
/// The layout is the same as `Tests/Fixtures/sample-course`. The output passes `validate`.
public struct CourseScaffold: Equatable, Sendable {
    /// The section and lecture ids. The course id must be different, because ids are unique in the manifest.
    public static let reservedIDs = ["start", "welcome"]
    /// Finder writes this file. A folder that holds only this file counts as empty.
    static let ignoredEntries: Set<String> = [".DS_Store"]

    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    /// The relative path and the contents of each file, in write order.
    public var files: [(path: String, contents: String)] {
        [("skillgarden.yaml", manifest), ("content/welcome.md", article),
         ("media/course.svg", image(width: 1600, height: 900, fontSize: 96)),
         ("media/section.svg", image(width: 1600, height: 400, fontSize: 72))]
    }

    var manifest: String {
        """
        schema_version: 1
        id: \(Self.yaml(id))
        title: \(Self.yaml(title))
        subtitle: Replace this subtitle before you publish
        description: Replace this description. Say what the learner can do after the course.
        learning_outcomes:
          - Identify the goal of the course
        requirements:
          - A Mac
        target_audience: New learners
        # Learners do not see a draft course. Change state to published when the course is ready.
        state: draft
        theme:
          accent_color: '#286644'
          appearance: light
        # Replace media/course.svg with your course image before you publish. Then update the alt text.
        course_image:
          path: media/course.svg
          alt: \(Self.yaml("Course image for \(title)"))
        credits:
          - name: Course author
            role: Author
        sections:
          - id: start
            title: Get started
            objective: Identify the course goal
            state: published
            order: 0
            header_image:
              path: media/section.svg
              alt: \(Self.yaml("Section header for \(title)"))
            lectures:
              - id: welcome
                title: Welcome
                type: article
                objective: Identify the course goal
                state: published
                order: 0
                article:
                  path: content/welcome.md

        """
    }

    var article: String {
        """
        # \(title)

        Welcome to the course. Replace this paragraph with the first lesson, then add more lectures to skillgarden.yaml.

        """
    }

    /// A flat accent field with the title in white system sans.
    func image(width: Int, height: Int, fontSize: Int) -> String {
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(width)\" height=\"\(height)\" viewBox=\"0 0 \(width) \(height)\">"
            + "<rect width=\"\(width)\" height=\"\(height)\" fill=\"#286644\"/>"
            + "<text x=\"\(width / 2)\" y=\"\(height / 2)\" fill=\"#fff\" font-family=\"-apple-system, system-ui, sans-serif\" "
            + "font-size=\"\(fontSize)\" font-weight=\"600\" text-anchor=\"middle\" dominant-baseline=\"central\">"
            + Self.xml(title) + "</text></svg>\n"
    }

    /// A YAML double-quoted scalar. JSON string escapes are valid YAML escapes.
    static func yaml(_ text: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }

    static func xml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Writes the files into `folder`. A missing folder and its parents are created.
    /// If a write fails, init deletes each file and folder that it created, and throws `.write`.
    /// `write` is for tests.
    public func create(at folder: URL,
                       write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .withoutOverwriting) })
        throws(CourseScaffoldError) {
        let manager = FileManager.default
        let path = folder.path
        var isDirectory: ObjCBool = false
        var created: [URL] = []
        if manager.fileExists(atPath: path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw .notAFolder(path) }
            let entries: [String]
            do { entries = try manager.contentsOfDirectory(atPath: path) }
            catch { throw .write(error.localizedDescription) }
            guard entries.allSatisfy(Self.ignoredEntries.contains) else { throw .notEmpty(path) }
        } else {
            // Remember the highest missing folder, so that a failure deletes the parents that init created too.
            var missing = folder
            while !manager.fileExists(atPath: missing.deletingLastPathComponent().path), missing.pathComponents.count > 1 {
                missing = missing.deletingLastPathComponent()
            }
            created.append(missing)
        }
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            for (relative, contents) in files {
                let url = folder.appending(path: relative)
                let parent = url.deletingLastPathComponent()
                if !manager.fileExists(atPath: parent.path) {
                    try manager.createDirectory(at: parent, withIntermediateDirectories: true)
                    created.append(parent)
                }
                try write(Data(contents.utf8), url)
                created.append(url)
            }
        } catch {
            for url in created.reversed() { try? manager.removeItem(at: url) }
            throw .write(error.localizedDescription)
        }
    }
}
