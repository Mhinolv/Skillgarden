import Foundation
import SkillgardenCore

// The release acceptance check of local AI (#130). Run it with scripts/check_local_ai.sh. See `LocalAICheck`.
exit(await LocalAICheck.main(arguments: Array(CommandLine.arguments.dropFirst())))
