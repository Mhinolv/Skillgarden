import Foundation
import Security
import Testing
@testable import SkillgardenCore

// #151: provider profiles, Keychain secrets and course consent. No test uses the real Keychain or a network.

private let repo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let fixture = repo.appending(path: "Tests/Fixtures/sample-course")

private let secret = "sk-test-" + String(repeating: "0123456789abcdef", count: 3)

private func openAI(id: String = "openai", modelID: String = "gpt-5") -> ProviderProfile {
    ProviderProfile(id: id, kind: .api, name: "OpenAI API", vendor: "OpenAI", origin: "https://api.openai.com", modelID: modelID)
}

/// A remote provider with no transport. Each request ends at once with a fixed answer.
@MainActor
private final class RemoteFake: AnswerProvider {
    let profile: ProviderProfile
    private(set) var asked: [[ChatMessage]] = []

    init(profile: ProviderProfile) {
        self.profile = profile
    }

    var id: String { profile.id }
    var displayName: String { profile.name }
    var kind: AnswerProviderKind { profile.kind }
    var destination: RemoteDestination? { profile.destination }

    func prepare() -> PreparedAnswer? {
        PreparedAnswer(origin: AnswerOrigin(providerID: id, modelID: profile.modelID)) { [weak self] messages in
            MainActor.assumeIsolated { self!.asked.append(messages) }
            let (updates, continuation) = AsyncStream<AnswerUpdate>.makeStream()
            continuation.yield(.ended(.finished, text: "Remote answer [t1]."))
            continuation.finish()
            return AnswerRequest(id: UUID(), updates: updates)
        }
    }

    func cancel(_ id: UUID) {}
}

/// The bundled model stand-in. The tests check that it gets no question when a profile is the choice.
@MainActor
private final class BundledFake: AnswerProvider {
    let id = BundledAnswerProvider.providerID
    let displayName = "Local Model"
    let kind = AnswerProviderKind.local
    private(set) var prepared = 0

    func prepare() -> PreparedAnswer? {
        prepared += 1
        return nil
    }

    func cancel(_ id: UUID) {}
}

@MainActor
private final class Fakes {
    var remote: [String: RemoteFake] = [:]

    func make(_ profile: ProviderProfile, _ credentials: any CredentialStore) -> (any AnswerProvider)? {
        let fake = RemoteFake(profile: profile)
        remote[profile.id] = fake
        return fake
    }
}

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "ProviderProfileTests-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

@MainActor
private func withLecture(_ body: (LibraryModel, URL) async throws -> Void) async throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let courseID = try #require(try SnapshotPlan.seedStore(for: .qaThread, root: root, fixture: fixture))
    let library = LibraryModel(root: root)
    await library.reload()
    library.selectCourse(courseID)
    library.selectDestination(.lecture(sectionID: "plan", lectureID: "welcome"))
    try await body(library, root)
}

@MainActor @Test func noRemoteRequestRunsWithoutTheConsentOfTheCourseForTheProfile() async throws {
    try await withLecture { library, root throws in
        let fakes = Fakes()
        let store = ProviderSettingsStore(directory: root)
        let credentials = MemoryCredentialStore()
        let providers = ProviderSettings(store: store, credentials: credentials, makeProvider: fakes.make)
        try providers.save(openAI(), secret: secret)
        providers.select("openai")
        let bundled = BundledFake()
        let qa = LectureQA(library: library, provider: bundled, providers: providers, draftInterval: .zero)
        qa.show(LectureQA.key(library: library))
        await qa.load()
        #expect(qa.provider.id == "openai")

        // No consent: the sheet opens, nothing is sent, and the question stays.
        #expect(!qa.send("What is the goal of this course?"))
        let request = try #require(qa.consentRequest)
        #expect(request.courseID == "sample-course")
        #expect(request.destination == openAI().destination)
        #expect(request.title == "Send this question to OpenAI?")
        #expect(fakes.remote["openai"]?.asked.isEmpty == true)
        #expect(qa.draft == nil)
        qa.cancelConsent()
        #expect(qa.consentRequest == nil)
        #expect(fakes.remote["openai"]?.asked.isEmpty == true)
        #expect(!providers.hasConsent(courseID: "sample-course", destination: openAI().destination))

        // "Allow and Send" saves the consent, then sends the exact messages of the sheet.
        #expect(!qa.send("What is the goal of this course?"))
        let shown = try #require(qa.consentRequest)
        #expect(qa.allowAndSend())
        await qa.waitForRequest()
        #expect(fakes.remote["openai"]?.asked == [shown.messages])
        #expect(providers.hasConsent(courseID: "sample-course", destination: openAI().destination))
        #expect(bundled.prepared == 0)
        let conversation = try #require(try await library.lectureConversation(forLecture: "welcome"))
        #expect(conversation.turns.last?.origin == AnswerOrigin(providerID: "openai", modelID: "gpt-5"))
        #expect(providers.sourceText(for: try #require(conversation.turns.last).origin) == "via OpenAI API · gpt-5")

        // The consent is saved: a new settings object reads it, and the next question needs no sheet.
        let reloaded = ProviderSettings(store: store, credentials: credentials)
        #expect(reloaded.hasConsent(courseID: "sample-course", destination: openAI().destination))
        #expect(!reloaded.hasConsent(courseID: "other-course", destination: openAI().destination))
        #expect(qa.send("Which tools do I need?"))
        await qa.waitForRequest()
        #expect(qa.consentRequest == nil)
        #expect(fakes.remote["openai"]?.asked.count == 2)

        // A new model is a new destination: the consent goes, and the course asks again.
        try providers.save(openAI(modelID: "gpt-5-mini"), secret: nil)
        #expect(!providers.hasConsent(courseID: "sample-course", destination: openAI().destination))
        #expect(!qa.send("How long is the course?"))
        #expect(qa.consentRequest?.destination.modelID == "gpt-5-mini")
        #expect(fakes.remote["openai"]?.asked.isEmpty == true)

        // A lecture change removes the sheet. "Allow and Send" then sends nothing.
        qa.show(nil)
        #expect(qa.consentRequest == nil)
        #expect(!qa.allowAndSend())
    }
}

@MainActor @Test func theConsentSheetShowsTheExactTextWithTheEligibleHistory() async throws {
    try await withLecture { library, root throws in
        let fakes = Fakes()
        let providers = ProviderSettings(store: ProviderSettingsStore(directory: root), credentials: MemoryCredentialStore(),
                                         makeProvider: fakes.make)
        try providers.save(openAI(), secret: secret)
        providers.select("openai")
        let qa = LectureQA(library: library, provider: BundledFake(), providers: providers, draftInterval: .zero)
        qa.show(LectureQA.key(library: library))
        await qa.load()

        #expect(!qa.send("What is the goal of this course?"))
        let first = try #require(qa.consentRequest)
        #expect(first.earlierMessageCount == 0)
        #expect(first.titles == ["Local Course Basics", "Welcome"])
        #expect(first.items[1] == "Titles: \"Local Course Basics\", \"Welcome\"")
        #expect(first.passageCount > 0)
        #expect(first.messages.first?.role == .system)
        #expect(first.exactText.hasPrefix("[system]\n"))
        #expect(first.exactText.hasSuffix("[user]\nWhat is the goal of this course?"))
        #expect(first.exactText.contains(try #require(first.messages.first).content))
        #expect(first.items.count == 4)
        #expect(first.items.last == "0 earlier messages")
        #expect(qa.allowAndSend())
        await qa.waitForRequest()

        // A new destination asks again. The complete turn of this lecture version is in the request and the sheet.
        try providers.save(openAI(modelID: "gpt-5-mini"), secret: nil)
        #expect(!qa.send("Which tools do I need?"))
        let second = try #require(qa.consentRequest)
        #expect(second.earlierMessageCount == 2)
        #expect(second.items.last == "2 earlier messages")
        #expect(second.exactText.contains("[user]\nWhat is the goal of this course?\n\n[assistant]\nRemote answer [t1]."))
        #expect(second.exactText == second.messages.map { "[\($0.role.rawValue)]\n\($0.content)" }.joined(separator: "\n\n"))
        // The secret never goes into the text.
        #expect(!second.exactText.contains(secret))
    }
}

@MainActor @Test func secretsLiveInTheCredentialStoreAndProfilesHoldReferences() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ProviderSettingsStore(directory: root)
    let credentials = MemoryCredentialStore()
    let providers = ProviderSettings(store: store, credentials: credentials)
    try providers.save(openAI(), secret: "  \(secret)\n")
    #expect(try credentials.secret(account: "openai") == secret)
    #expect(providers.profiles.first?.credentialReference == "openai")
    #expect(providers.hasSecret(try #require(providers.profiles.first)))
    let text = try String(contentsOf: store.fileURL, encoding: .utf8)
    #expect(!text.contains(secret))
    #expect(!text.contains("sk-test"))
    #expect(text.contains("\"credentialReference\" : \"openai\""))

    // An empty secret keeps the saved key.
    try providers.save(openAI(modelID: "gpt-5-mini"), secret: "")
    #expect(try credentials.secret(account: "openai") == secret)
    #expect(providers.profiles.first?.credentialReference == "openai")

    // Disconnect deletes the key, the course consents and the profile. The bundled model answers again.
    providers.select("openai")
    try providers.allow(courseID: "sample-course", destination: try #require(providers.selected).destination)
    try providers.disconnect("openai")
    #expect(try credentials.secret(account: "openai") == nil)
    #expect(providers.profiles.isEmpty)
    #expect(providers.consents.isEmpty)
    #expect(providers.selectedID == BundledAnswerProvider.providerID)
    #expect(ProviderSettings(store: store, credentials: credentials).profiles.isEmpty)
}

@MainActor @Test func aDeniedKeychainShowsTheProblemAndKeepsTheProfile() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ProviderSettingsStore(directory: root)
    var profile = openAI()
    profile.credentialReference = "openai"
    try store.save(SavedProviders(selectedID: "openai", profiles: [profile]))

    let denied = ProviderSettings(store: store, credentials: MemoryCredentialStore(deniedAccounts: ["openai"]))
    denied.checkCredentials()
    #expect(denied.problems["openai"] == .credential(.denied))
    #expect(denied.problems["openai"]?.message == "Skillgarden can't read the key from the Keychain.")
    #expect(throws: ProviderSettings.Problem.credential(.denied)) { try denied.disconnect("openai") }
    #expect(denied.profiles.map(\.id) == ["openai"])
    #expect(throws: ProviderSettings.Problem.credential(.denied)) { try denied.save(openAI(), secret: secret) }

    // "Try Again" reads the key again and clears the problem.
    let allowed = ProviderSettings(store: store, credentials: MemoryCredentialStore(secrets: ["openai": secret]))
    allowed.checkCredentials("openai")
    #expect(allowed.problems.isEmpty)
}

@MainActor @Test func theBundledModelStaysTheDefaultOnUpgrade() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ProviderSettingsStore(directory: root)
    let bundled = BundledFake()

    // No `Providers.json`: the bundled model answers, and the panel has no source text.
    let fresh = ProviderSettings(store: store, credentials: MemoryCredentialStore())
    #expect(fresh.selectedID == "bundled-local")
    #expect(fresh.selected == nil)
    #expect(fresh.profiles.isEmpty)
    #expect(fresh.activeProvider(bundled: bundled) === bundled)
    #expect(fresh.sourceText(for: .legacy) == nil)
    #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))

    // A file with missing keys, an unknown kind, an unknown key and a choice of a removed profile still loads.
    try Data("""
    {"profiles": [{"id": "a", "kind": "api", "name": "OpenAI API", "origin": "https://api.openai.com", "modelID": "gpt-5", "later": 1},
                  {"id": "b", "kind": "carrierPigeon"}],
     "selectedID": "removed", "consents": [{"courseID": "x"}]}
    """.utf8).write(to: store.fileURL)
    let old = ProviderSettings(store: store, credentials: MemoryCredentialStore())
    #expect(old.profiles.map(\.id) == ["a"])
    #expect(old.profiles.first?.vendor == "OpenAI API")
    #expect(old.profiles.first?.credentialReference == nil)
    #expect(old.consents.isEmpty)
    #expect(old.selectedID == "bundled-local")
    #expect(old.activeProvider(bundled: bundled) === bundled)

    // A file that is not JSON gives the defaults.
    try Data("not json".utf8).write(to: store.fileURL)
    #expect(ProviderSettings(store: store, credentials: MemoryCredentialStore()).selectedID == "bundled-local")
}

@MainActor @Test func aProfileWithNoShippedAdapterCantAnswer() throws {
    let providers = ProviderSettings(store: nil, credentials: MemoryCredentialStore(), profiles: [openAI()], selectedID: "openai")
    let provider = providers.activeProvider(bundled: BundledFake())
    #expect(provider is UnavailableAnswerProvider)
    #expect(provider.id == "openai")
    #expect(provider.destination == openAI().destination)
    #expect(provider.prepare() == nil)
    // The same profile gives the same provider. "Answer with" Bundled model gives the bundled provider back.
    #expect(providers.activeProvider(bundled: BundledFake()) === provider)
    providers.select("bundled-local")
    #expect(providers.activeProvider(bundled: BundledFake()).kind == .local)
    // An unknown ID is not a choice.
    providers.select("missing")
    #expect(providers.selectedID == "bundled-local")
}

@Test func profileTextAndValidation() {
    let profile = openAI()
    #expect(profile.host == "api.openai.com")
    #expect(profile.title == "OpenAI API · gpt-5")
    #expect(profile.caption == "api.openai.com · gpt-5 · API")
    #expect(profile.accessibilityLabel == "OpenAI API, api.openai.com, gpt-5")
    let local = ProviderProfile(id: "lm", kind: .externalLocal, name: "LM Studio", vendor: "LM Studio",
                                origin: "http://127.0.0.1:1234/v1", modelID: "qwen")
    #expect(local.host == "127.0.0.1:1234")
    #expect(local.caption == "127.0.0.1:1234 · qwen · External local server")
    #expect(AnswerProviderKind.allCases.map(\.title) == ["Local", "External local server", "API", "Subscription"])

    #expect(profile.isValid(hasSecret: true))
    // An API profile needs a key. An external local server does not.
    #expect(!profile.isValid(hasSecret: false))
    #expect(local.isValid(hasSecret: false))
    for origin in ["", "api.openai.com", "ftp://api.openai.com", "https://user:pass@api.openai.com",
                   "https://api.openai.com?key=abc", "https://api.openai.com/v1#x", "https://api.openai.com/v1"] {
        var bad = profile
        bad.origin = origin
        #expect(!bad.isValid(hasSecret: true), "\(origin)")
    }
    var noModel = profile
    noModel.modelID = "  "
    #expect(!noModel.isValid(hasSecret: true))
    // A destination names the profile, the kind, the host and the model.
    var moved = profile
    moved.origin = "https://eu.api.openai.com"
    #expect(moved.destination != profile.destination)
    var renamed = profile
    renamed.name = "Work OpenAI"
    #expect(renamed.destination == profile.destination)
}

@Test func keychainItemsDoNotSyncAndStayOnThisMac() {
    let store = KeychainCredentialStore()
    #expect(store.service == "com.skillgarden.providers")
    let query = store.query(account: "openai")
    #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
    #expect(query[kSecAttrAccount as String] as? String == "openai")
    #expect((query[kSecAttrSynchronizable as String] as? Bool) == false)
    let add = store.addQuery(secret, account: "openai")
    #expect(add[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    #expect(add[kSecValueData as String] as? Data == Data(secret.utf8))
    #expect((add[kSecAttrSynchronizable as String] as? Bool) == false)

    #expect(KeychainCredentialStore.error(errSecSuccess) == nil)
    for status in [errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled, errSecNoAccessForItem] {
        #expect(KeychainCredentialStore.error(status) == .denied)
    }
    #expect(KeychainCredentialStore.error(errSecDuplicateItem) == .failed(errSecDuplicateItem))
    #expect(!CredentialError.failed(-25299).message.contains(secret))
}

@Test func docsStateThatRemoteQAIsOptIn() throws {
    let agents = try String(contentsOf: repo.appending(path: "AGENTS.md"), encoding: .utf8)
    let doc = try String(contentsOf: repo.appending(path: "docs/local-ai.md"), encoding: .utf8)
    #expect(agents.contains("Remote Q&A is opt-in"))
    #expect(doc.contains("Remote Q&A is opt-in"))
}
