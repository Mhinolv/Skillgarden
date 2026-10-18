import Testing
@testable import SkillgardenCore

/// A dictionary in place of the defaults domain, so the tests never touch `dev.skillgarden.app`.
private final class MemoryDefaults {
    var values: [String: Any] = [:]

    func load() -> VideoTextChoices { VideoTextChoices { self.values[$0] } }

    func save(_ choices: VideoTextChoices) {
        for (key, value) in choices.savedValues { values[key] = value }
    }
}

/// #97: the last Captions and Transcript choice loads again for the next lecture and after the app starts again.
@Test func videoTextChoicesStayAfterTheAppStartsAgain() {
    for captions in [false, true] {
        for transcript in [false, true] {
            let defaults = MemoryDefaults()
            var choices = defaults.load()
            choices.showsCaptions = captions
            choices.showsTranscript = transcript
            defaults.save(choices)
            let loaded = defaults.load()
            #expect(loaded.showsCaptions == captions)
            #expect(loaded.showsTranscript == transcript)
        }
    }
}

@Test func videoTextChoicesAreOnWithNoSavedValue() {
    #expect(MemoryDefaults().load() == VideoTextChoices(showsCaptions: true, showsTranscript: true))
    #expect(VideoTextChoices() == VideoTextChoices(showsCaptions: true, showsTranscript: true))
}

@Test func videoTextChoicesKeepEachChoiceSeparate() {
    let defaults = MemoryDefaults()
    defaults.values = ["Captions": false]
    #expect(defaults.load() == VideoTextChoices(showsCaptions: false, showsTranscript: true))
    defaults.values = ["Transcript": false]
    #expect(defaults.load() == VideoTextChoices(showsCaptions: true, showsTranscript: false))
}

@Test func videoTextChoicesSkipAValueThatIsNotABoolean() {
    let defaults = MemoryDefaults()
    defaults.values = ["Captions": "off", "Transcript": [false]]
    #expect(defaults.load() == VideoTextChoices())
}

@Test func videoTextChoicesUseTheAppDefaultsDomain() {
    #expect(VideoTextChoices.captionsKey == "Captions")
    #expect(VideoTextChoices.transcriptKey == "Transcript")
    let saved = Dictionary(uniqueKeysWithValues: VideoTextChoices(showsCaptions: false, showsTranscript: true).savedValues)
    #expect(saved == ["Captions": false, "Transcript": true])
}
