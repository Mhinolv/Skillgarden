import Testing
@testable import SkillgardenCore

@Test func appAppearanceDefaultsToDark() {
    #expect(AppAppearance(savedValue: nil) == .dark)
    #expect(AppAppearance(savedValue: "") == .dark)
    #expect(AppAppearance(savedValue: "auto") == .dark)
    #expect(AppAppearance(savedValue: "Light") == .dark)
}

@Test func appAppearanceReadsEverySavedValue() {
    for appearance in AppAppearance.allCases {
        #expect(AppAppearance(savedValue: appearance.rawValue) == appearance)
    }
    #expect(AppAppearance.allCases.map(\.rawValue) == ["dark", "light", "system"])
}

@Test func appAppearanceMenuOrderAndTitles() {
    #expect(AppAppearance.allCases.map(\.title) == ["Dark", "Light", "System"])
}

@Test func appAppearanceMapsToTheCourseAppearance() {
    #expect(AppAppearance.dark.courseAppearance == .dark)
    #expect(AppAppearance.light.courseAppearance == .light)
    #expect(AppAppearance.system.courseAppearance == nil)
}

@Test func appAppearanceUsesTheAppDefaultsDomain() {
    #expect(Skillgarden.appearanceKey == "Appearance")
    #expect(Skillgarden.defaultsDomain == "dev.skillgarden.app")
}
