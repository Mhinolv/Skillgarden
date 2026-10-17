import Testing
@testable import SkillgardenCore

@Test func versionIsSet() {
    #expect(!Skillgarden.version.isEmpty)
}
