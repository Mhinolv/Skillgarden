import Foundation
import SkillgardenCore

// Agent-facing CLI. Subcommands (publish, ...) arrive with the MVP issues.
let args = CommandLine.arguments.dropFirst()
switch args.first {
case "--version", "version":
    print("skillgarden \(Skillgarden.version)")
default:
    print("usage: skillgarden <command>\n  version    print the version")
}
