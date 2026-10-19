import SkillgardenCore

// The helper that owns the llama-server process of the app (#123). See `LocalAIHost`.
LocalAIHost.run(arguments: Array(CommandLine.arguments.dropFirst()))
