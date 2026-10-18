import AppKit
import SwiftUI
import SkillgardenCore

/// The import flow (#111): an open panel for one course folder, the check, the alerts, then the publish into the library.
/// A cancel does nothing. A check or publish error does not change the library.
@MainActor
enum CourseImporter {
    static func start(_ library: LibraryModel) {
        guard library.canImport else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Course"
        panel.prompt = "Import"
        panel.message = "Choose a course folder with skillgarden.yaml or skillgarden.json."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { await run(folder: folder, library: library) }
    }

    private static func run(folder: URL, library: LibraryModel) async {
        let check: CourseImportCheck
        do { check = try await library.checkImport(folder: folder) }
        catch { return showFailure(error) }
        let course: ValidationResult
        switch check {
        case let .invalid(diagnostics): return showErrors(diagnostics)
        case let .new(result): course = result
        case let .replaces(result, oldTitle):
            guard confirmReplace(oldTitle: oldTitle, course: result) else { return }
            course = result
        }
        do {
            let result = try await library.importCourse(folder: folder, title: course.title)
            if result.state == .draft { showDraft(title: result.title) }
        } catch let error as ManifestValidationError {
            // The folder changed after the check.
            showErrors(error.diagnostics)
        } catch {
            showFailure(error)
        }
    }

    /// `Cancel` is the first button, so it is the default and Return and Escape do not replace the course.
    private static func confirmReplace(oldTitle: String, course: ValidationResult) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = CourseImport.replaceMessage(oldTitle: oldTitle)
        alert.informativeText = CourseImport.replaceInformation(id: course.id, newTitle: course.title)
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Replace").hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// `Copy Errors` copies all lines, not only the shown lines, and closes the alert.
    private static func showErrors(_ diagnostics: [ManifestDiagnostic]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Can't import the course."
        alert.informativeText = CourseImport.shownErrors(diagnostics)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy Errors")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(CourseImport.allErrors(diagnostics), forType: .string)
    }

    private static func showFailure(_ error: any Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Can't import the course."
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private static func showDraft(title: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = CourseImport.draftMessage(title: title)
        alert.informativeText = CourseImport.draftInformation
        alert.runModal()
    }
}

/// The course title of the progress sheet. The sheet keeps it while it closes.
struct ImportingCourse: Identifiable {
    let title: String
    var id: String { title }
}

/// The sheet while an import publishes a course. It has no buttons.
struct ImportProgressSheet: View {
    let title: String

    var body: some View {
        ProgressView("Import \"\(title)\"")
            .padding(GardenSpacing.xl)
            .frame(minWidth: 320)
            .interactiveDismissDisabled()
    }
}

struct ImportProgressSheet_Previews: PreviewProvider {
    static var previews: some View {
        ImportProgressSheet(title: "Local Course Basics")
    }
}
