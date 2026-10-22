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

/// #93: Dark and Light win over the course. System uses the course, then macOS (nil).
@Test func appAppearanceWinsOverTheCourseAppearance() {
    for course in [CourseAppearance.light, .dark, nil] {
        #expect(AppAppearance.dark.resolved(course: course) == .dark)
        #expect(AppAppearance.light.resolved(course: course) == .light)
        #expect(AppAppearance.system.resolved(course: course) == course)
    }
}

@Test func appAppearanceUsesTheAppDefaultsDomain() {
    #expect(Skillgarden.appearanceKey == "Appearance")
    #expect(Skillgarden.defaultsDomain == "dev.skillgarden.app")
}

/// #219: default contrast keeps the Quiet Garden neutrals from before, bit for bit.
@Test func gardenNeutralsKeepTheDefaultContrastValues() {
    let light = GardenNeutrals(appearance: .light, increasedContrast: false)
    #expect(light.lineOpacity == 0.08 && light.trackOpacity == 0.09 && light.fillOpacity == 0.045)
    #expect(light.muted == 0x6E6E73 && light.faint == 0xAEAEB2)
    let dark = GardenNeutrals(appearance: .dark, increasedContrast: false)
    #expect(dark.lineOpacity == 0.08 && dark.trackOpacity == 0.16 && dark.fillOpacity == 0.06)
    #expect(dark.muted == 0x98989D && dark.faint == 0x5E5E63)
}

/// #219: "Increase contrast" selects the stronger hairline, track, fill and secondary text in both appearances.
@Test func gardenNeutralsUseStrongerValuesForIncreasedContrast() {
    let light = GardenNeutrals(appearance: .light, increasedContrast: true)
    #expect(light.lineOpacity == 0.30 && light.trackOpacity == 0.22 && light.fillOpacity == 0.08)
    #expect(light.muted == 0x48484D && light.faint == 0x6E6E73)
    let dark = GardenNeutrals(appearance: .dark, increasedContrast: true)
    #expect(dark.lineOpacity == 0.32 && dark.trackOpacity == 0.32 && dark.fillOpacity == 0.12)
    #expect(dark.muted == 0xC7C7CC && dark.faint == 0x98989D)
}

/// #219: every token is stronger with "Increase contrast" on. Text gets darker in light mode and lighter in dark mode.
@Test func gardenNeutralsIncreasedContrastIsStrongerForEveryToken() {
    func brightness(_ hex: Int) -> Int { ((hex >> 16) & 0xFF) + ((hex >> 8) & 0xFF) + (hex & 0xFF) }
    for appearance in [CourseAppearance.light, .dark] {
        let normal = GardenNeutrals(appearance: appearance, increasedContrast: false)
        let high = GardenNeutrals(appearance: appearance, increasedContrast: true)
        #expect(high.lineOpacity > normal.lineOpacity)
        #expect(high.trackOpacity > normal.trackOpacity)
        #expect(high.fillOpacity > normal.fillOpacity)
        let darker = appearance == .light
        #expect((brightness(high.muted) < brightness(normal.muted)) == darker)
        #expect((brightness(high.faint) < brightness(normal.faint)) == darker)
    }
}
