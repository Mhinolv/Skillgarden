import AppKit
import SkillgardenCore

/// Skillgarden > "Copy Course Playbook" and "Save Course Playbook…" (#252).
/// A copy shows one informational alert, because a menu item gives no other feedback.
/// A save uses the `DownloadSaver` pattern: a save panel, then a write. Only a failure shows an alert.
@MainActor
enum CoursePlaybookActions {
    static func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(CoursePlaybook.text, forType: .string)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = CoursePlaybook.copiedMessage
        alert.informativeText = CoursePlaybook.copiedInformativeText
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// A cancel does nothing.
    static func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = CoursePlaybook.fileName
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let target = panel.url else { return }
            Task {
                // Write the file off the main actor.
                let failure = await Task.detached { () -> String? in
                    do { try CoursePlaybook.write(to: target); return nil } catch { return error.localizedDescription }
                }.value
                guard let failure else { return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = CoursePlaybook.saveFailureMessage
                alert.informativeText = failure
                alert.runModal()
            }
        }
    }
}
