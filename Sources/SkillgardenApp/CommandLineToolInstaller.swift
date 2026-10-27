import AppKit
import SkillgardenCore

/// Skillgarden > "Install Command Line Tool…" (#250). One alert shows the result.
/// If a copied CLI is at `~/.local/bin/skillgarden`, the app asks before it replaces it.
@MainActor
enum CommandLineToolInstaller {
    static func start(_ tool: CommandLineTool = CommandLineTool()) {
        do throws(CommandLineTool.InstallError) {
            if try tool.check() == .regularFile, !confirmReplace() { return }
            try tool.install()
        } catch {
            return showFailure(error)
        }
        showSuccess()
    }

    /// `Cancel` is the first button, so it is the default and Return and Escape keep the copy.
    private static func confirmReplace() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = CommandLineTool.replaceMessage
        alert.informativeText = CommandLineTool.replaceInformation
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Replace").hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// The app cannot read the Terminal PATH, so the alert always offers the PATH line.
    private static func showSuccess() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = CommandLineTool.successMessage
        alert.informativeText = CommandLineTool.successInformation
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy PATH Line")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(CommandLineTool.pathLine, forType: .string)
    }

    private static func showFailure(_ error: CommandLineTool.InstallError) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = CommandLineTool.failureMessage
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
