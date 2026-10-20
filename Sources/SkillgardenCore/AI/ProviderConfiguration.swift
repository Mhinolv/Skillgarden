import Foundation
import Observation

extension AnswerProviderKind: Codable {
    /// The group title of the Settings "Answer with" picker and the last part of the row caption (#151).
    public var title: String {
        switch self {
        case .local: "Local"
        case .externalLocal: "External local server"
        case .api: "API"
        case .subscription: "Subscription"
        }
    }

    /// True when the provider sheet asks for an API key. A subscription signs in with its own flow (#157).
    public var usesAPIKey: Bool { self == .api || self == .externalLocal }

    /// True when an API key must be saved before the profile can answer. An external local server can run with no key.
    public var needsAPIKey: Bool { self == .api }
}

/// One answer destination that the learner set up (#151): a remote API, a subscription or a model server on this Mac.
/// The profile holds no secret. `credentialReference` names the Keychain item of the secret.
public struct ProviderProfile: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var kind: AnswerProviderKind
    /// The profile name, for example "OpenAI API".
    public var name: String
    /// The company name of the consent sheet and the Q&A footer, for example "OpenAI".
    public var vendor: String
    /// The scheme, host and port of the service, for example `https://api.openai.com`.
    public var origin: String
    public var modelID: String
    /// The context window of the model in tokens. Nil when the adapter uses its default.
    public var contextTokens: Int?
    /// The answer limit in tokens. Nil when the adapter uses its default.
    public var answerTokens: Int?
    /// The Keychain account of the secret. Nil when the profile has no saved secret.
    public var credentialReference: String?

    public init(id: String = UUID().uuidString, kind: AnswerProviderKind, name: String, vendor: String, origin: String,
                modelID: String, contextTokens: Int? = nil, answerTokens: Int? = nil, credentialReference: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.vendor = vendor
        self.origin = origin
        self.modelID = modelID
        self.contextTokens = contextTokens
        self.answerTokens = answerTokens
        self.credentialReference = credentialReference
    }

    /// Missing optional keys get their defaults, so a later version can add keys.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(AnswerProviderKind.self, forKey: .kind)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        origin = try container.decodeIfPresent(String.self, forKey: .origin) ?? ""
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID) ?? ""
        vendor = try container.decodeIfPresent(String.self, forKey: .vendor) ?? name
        contextTokens = try container.decodeIfPresent(Int.self, forKey: .contextTokens)
        answerTokens = try container.decodeIfPresent(Int.self, forKey: .answerTokens)
        credentialReference = try container.decodeIfPresent(String.self, forKey: .credentialReference)
    }

    /// A new profile of an external local server preset (#152). The model ID is empty until the learner types it.
    public static func preset(_ server: ExternalLocalServer) -> ProviderProfile {
        ProviderProfile(kind: .externalLocal, name: server.rawValue, vendor: server.rawValue, origin: server.defaultBaseURL, modelID: "")
    }

    /// The server preset of an external local server profile (#152). Nil for the other kinds.
    public var externalServer: ExternalLocalServer? {
        kind == .externalLocal ? ExternalLocalServer(rawValue: vendor) : nil
    }

    /// A new profile of a fixed API service (#154). The model ID is empty until the learner types it.
    public static func preset(_ service: APIService) -> ProviderProfile {
        ProviderProfile(kind: .api, name: service.name, vendor: service.rawValue, origin: service.origin, modelID: "",
                        answerTokens: APIService.defaultAnswerTokens)
    }

    /// The fixed API service of an API profile with the fixed origin of the service (#154). Nil for the other profiles.
    public var apiService: APIService? {
        guard kind == .api, let service = APIService(rawValue: vendor), origin == service.origin else { return nil }
        return service
    }

    /// The red caption under the Output limit field of an API service (#154). Nil when the limit is 1 or more,
    /// or not set, so the adapter uses `APIService.defaultAnswerTokens`. The sheet sets 0 for an empty field.
    public var answerTokensProblem: String? {
        apiService != nil && answerTokens.map({ $0 < 1 }) == true ? Self.noAnswerTokensText : nil
    }

    public static let noAnswerTokensText = "Enter an output limit of 1 or more tokens."

    /// The host of `origin`, for example `api.openai.com`. The full origin when it has no host.
    /// An IPv6 host keeps its brackets, for example `[::1]:1234`.
    public var host: String {
        guard let components = URLComponents(string: origin), var host = components.host, !host.isEmpty else { return origin }
        if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
        return components.port.map { "\(host):\($0)" } ?? host
    }

    /// The picker item and the Q&A header: "OpenAI API · gpt-5".
    public var title: String { "\(name) · \(modelID)" }

    /// The row caption: "host · model · kind".
    public var caption: String { "\(host) · \(modelID) · \(kind.title)" }

    /// The VoiceOver label of the row: "OpenAI API, api.openai.com, gpt-5".
    public var accessibilityLabel: String { "\(name), \(host), \(modelID)" }

    /// The destination that a course consent names. A change of kind, host or model needs a new consent.
    public var destination: RemoteDestination {
        RemoteDestination(profileID: id, kind: kind, host: host, modelID: modelID)
    }

    /// The Keychain account for the secret of this profile.
    public var keychainAccount: String { credentialReference ?? id }

    /// The Q&A footer: "Answers come from LM Studio on this Mac and can be wrong." (#152)
    public var answerFooter: String {
        kind == .externalLocal ? "Answers come from \(vendor) on this Mac and can be wrong."
            : "Answers come from \(vendor) and can be wrong."
    }

    /// The red caption under the Base URL field of an external local server (#152). Nil when the URL is valid.
    public var originProblem: String? {
        kind == .externalLocal && Self.loopbackBaseURL(origin) == nil ? Self.loopbackOnlyText : nil
    }

    /// The red caption under the Model ID field (#152). Nil when the field has text.
    public var modelProblem: String? {
        modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.noModelText : nil
    }

    public static let loopbackOnlyText = "Use 127.0.0.1 or [::1]. Use an API provider for other hosts."
    public static let noModelText = "Enter the model ID."

    /// True when the provider sheet can save the fields. `hasSecret` is true when the Keychain has a key or the sheet has one.
    /// The origin is an http or https URL with a host, and no user, password, path, query or fragment,
    /// so no secret goes into a URL. An external local server uses a loopback base URL (#152).
    public func isValid(hasSecret: Bool) -> Bool {
        let trimmed = [name, vendor, modelID].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !trimmed.contains(where: \.isEmpty) else { return false }
        if kind == .externalLocal { return Self.loopbackBaseURL(origin) != nil }
        guard Self.isValidOrigin(origin), answerTokensProblem == nil else { return false }
        return !kind.needsAPIKey || hasSecret
    }

    /// Plain HTTP is valid only for a literal loopback address (#152).
    static func isValidOrigin(_ origin: String) -> Bool {
        guard let components = URLComponents(string: origin), let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = components.host, !host.isEmpty else { return false }
        guard scheme == "https" || isLoopbackHost(host) else { return false }
        return components.user == nil && components.password == nil && components.query == nil && components.fragment == nil
            && (components.path.isEmpty || components.path == "/")
    }

    /// The base URL of an external local server (#152): `http://127.0.0.1` or `http://[::1]`, an optional port and path,
    /// and no user, password, query or fragment. An empty path gives `/v1`. A host name such as `localhost` is not
    /// accepted, because a hosts file can send it to another address. Nil for another URL.
    public static func loopbackBaseURL(_ text: String) -> URL? {
        guard var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "http", let host = parts.host, isLoopbackHost(host),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return nil }
        if let port = parts.port, !(1...65535).contains(port) { return nil }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        if parts.path.isEmpty { parts.path = "/v1" }
        return parts.url
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        ["127.0.0.1", "::1", "[::1]"].contains(host)
    }
}

/// The external local server presets of "Add Provider" (#152). The raw value is the name and the vendor of the profile.
public enum ExternalLocalServer: String, CaseIterable, Identifiable, Sendable {
    case lmStudio = "LM Studio"
    case ollama = "Ollama"

    public var id: String { rawValue }

    /// The "Add Provider" menu item: "LM Studio…".
    public var menuTitle: String { rawValue + "…" }

    /// The OpenAI-compatible base URL of the server at its default port.
    public var defaultBaseURL: String {
        switch self {
        case .lmStudio: "http://127.0.0.1:1234/v1"
        case .ollama: "http://127.0.0.1:11434/v1"
        }
    }

    /// The secondary caption of the provider sheet.
    public var footer: String {
        switch self {
        case .lmStudio: "Skillgarden does not start LM Studio. Start its local server first."
        case .ollama: "Ollama can send text to cloud models. Set OLLAMA_NO_CLOUD=1 to keep text on this Mac."
        }
    }
}

/// The API services of "Add Provider" with a fixed host (#154). The raw value is the vendor of the profile.
public enum APIService: String, CaseIterable, Identifiable, Sendable {
    case anthropic = "Anthropic"

    public var id: String { rawValue }

    /// The output limit of a new profile, in tokens.
    public static let defaultAnswerTokens = 1024

    /// The profile name and the start of the Q&A header: "Anthropic API".
    public var name: String { rawValue + " API" }

    /// The "Add Provider" menu item: "Anthropic API…".
    public var menuTitle: String { name + "…" }

    /// The only origin that the adapter sends to.
    public var origin: String {
        switch self {
        case .anthropic: "https://api.anthropic.com"
        }
    }

    /// The prompt of the empty API key field.
    public var keyPrompt: String {
        switch self {
        case .anthropic: "sk-ant-…"
        }
    }

    /// The prompt of the empty Model ID field.
    public var modelPrompt: String {
        switch self {
        case .anthropic: "Model ID, for example claude-sonnet-5-5"
        }
    }

    /// The secondary caption of the provider sheet.
    public var footer: String {
        switch self {
        case .anthropic: "Claude Pro and Max plans do not work here. Use an API key from the Anthropic Console."
        }
    }

    public static let noKeyText = "Enter an API key."
}

/// The saved provider choices: `Providers.json` in Application Support (#151).
/// It holds the profiles, the app-wide "Answer with" choice and the course consents. It holds no secret.
struct SavedProviders: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    /// The `AnswerProvider.id` of the "Answer with" choice.
    var selectedID: String
    var profiles: [ProviderProfile]
    var consents: [RemoteConsent]

    init(selectedID: String = BundledAnswerProvider.providerID, profiles: [ProviderProfile] = [], consents: [RemoteConsent] = []) {
        version = Self.currentVersion
        self.selectedID = selectedID
        self.profiles = profiles
        self.consents = consents
    }

    /// Each missing key gets its default. A profile or a consent that this version can't read is left out.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        selectedID = (try? container.decodeIfPresent(String.self, forKey: .selectedID)) ?? BundledAnswerProvider.providerID
        profiles = ((try? container.decodeIfPresent([Lossy<ProviderProfile>].self, forKey: .profiles)) ?? []).compactMap(\.value)
        consents = ((try? container.decodeIfPresent([Lossy<RemoteConsent>].self, forKey: .consents)) ?? []).compactMap(\.value)
    }
}

/// One array item that can fail to decode without a failure of the array.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// Reads and writes `Providers.json` (#151).
public struct ProviderSettingsStore: Sendable {
    public let fileURL: URL

    /// `directory` is Application Support/Skillgarden in the app and a temporary folder in tests.
    public init(directory: URL = Skillgarden.defaultDataDirectory) {
        fileURL = directory.appending(path: "Providers.json")
    }

    /// The saved choices. A missing or unreadable file gives the defaults: the bundled model and no profiles.
    func load() -> SavedProviders {
        guard let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(SavedProviders.self, from: data) else {
            return SavedProviders()
        }
        return saved
    }

    func save(_ saved: SavedProviders) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(saved).write(to: fileURL, options: .atomic)
    }
}

/// The result of "Test Connection" in the provider sheet.
public enum ConnectionTestResult: Equatable, Sendable {
    case connected
    case failed(reason: String)

    public static let connectedText = "Connected. The model answered."
}

/// The Settings "Q&A" section state (#151): the profiles, the app-wide "Answer with" choice, the Keychain state
/// of each profile and the course consents. The bundled model is the default.
@MainActor @Observable
public final class ProviderSettings {
    /// Why Skillgarden can't use a profile now.
    public enum Problem: Error, Equatable, Sendable {
        case credential(CredentialError)
        /// The app can't write `Providers.json`.
        case saveFailed

        public var message: String {
            switch self {
            case .credential(let error): error.message
            case .saveFailed: "Skillgarden can't save the provider settings."
            }
        }
    }

    public static let bundledTitle = "Bundled model"
    public static let footerText = "Lecture text leaves this Mac only after you allow it for each course."

    public private(set) var profiles: [ProviderProfile]
    /// The `AnswerProvider.id` of the "Answer with" choice.
    public private(set) var selectedID: String
    public private(set) var consents: [RemoteConsent]
    /// The Keychain problem of each profile, by profile ID. The row shows it in red with "Try Again".
    public private(set) var problems: [String: Problem] = [:]

    @ObservationIgnored private let store: ProviderSettingsStore?
    @ObservationIgnored private let credentials: any CredentialStore
    /// Makes the answer provider of a profile. Nil when the kind has no shipped adapter.
    @ObservationIgnored private let makeProvider: @MainActor (ProviderProfile, any CredentialStore) -> (any AnswerProvider)?
    /// Runs "Test Connection" with the profile and its token. Nil while no adapter ships, so the sheet shows no button.
    @ObservationIgnored public let testConnection: (@MainActor (ProviderProfile, String?) async -> ConnectionTestResult)?
    /// The kinds with a shipped adapter (#152). "Add Provider" and "Test Connection" show only for them.
    @ObservationIgnored public let adapterKinds: Set<AnswerProviderKind>
    @ObservationIgnored private var providers: [String: (profile: ProviderProfile, provider: any AnswerProvider)] = [:]

    /// `store` nil saves nothing: the snapshot harness and previews inject the profiles.
    public init(store: ProviderSettingsStore?, credentials: any CredentialStore = KeychainCredentialStore(),
                profiles: [ProviderProfile] = [], selectedID: String = BundledAnswerProvider.providerID,
                adapterKinds: Set<AnswerProviderKind> = [],
                makeProvider: @escaping @MainActor (ProviderProfile, any CredentialStore) -> (any AnswerProvider)? = { _, _ in nil },
                testConnection: (@MainActor (ProviderProfile, String?) async -> ConnectionTestResult)? = nil) {
        let saved = store?.load() ?? SavedProviders(selectedID: selectedID, profiles: profiles)
        self.store = store
        self.credentials = credentials
        self.adapterKinds = adapterKinds
        self.makeProvider = makeProvider
        self.testConnection = testConnection
        self.profiles = saved.profiles
        consents = saved.consents
        // A choice of a removed profile falls back to the bundled model.
        self.selectedID = saved.profiles.contains { $0.id == saved.selectedID } ? saved.selectedID : BundledAnswerProvider.providerID
    }

    /// The profile of the "Answer with" choice. Nil for the bundled model.
    public var selected: ProviderProfile? { profiles.first { $0.id == selectedID } }

    /// The profiles of one picker group, in saved order.
    public func profiles(of kind: AnswerProviderKind) -> [ProviderProfile] { profiles.filter { $0.kind == kind } }

    /// The provider that answers the next question: the bundled model, or the provider of the chosen profile.
    /// A profile with no shipped adapter gets a provider that can't answer.
    public func activeProvider(bundled: any AnswerProvider) -> any AnswerProvider {
        guard let profile = selected else { return bundled }
        if let cached = providers[profile.id], cached.profile == profile { return cached.provider }
        let provider = makeProvider(profile, credentials) ?? UnavailableAnswerProvider(profile: profile)
        providers[profile.id] = (profile, provider)
        return provider
    }

    /// The source text of a saved turn: "via OpenAI API · gpt-5". Nil for the bundled model and for removed profiles.
    public func sourceText(for origin: AnswerOrigin) -> String? {
        guard origin.providerID != BundledAnswerProvider.providerID,
              let profile = profiles.first(where: { $0.id == origin.providerID }) else { return nil }
        return "via \(profile.name) · \(origin.modelID ?? profile.modelID)"
    }

    /// The "Answer with" choice. Each change is saved at once.
    public func select(_ id: String) {
        guard id == BundledAnswerProvider.providerID || profiles.contains(where: { $0.id == id }), id != selectedID else { return }
        let previous = selectedID
        selectedID = id
        if !persist() { selectedID = previous }
    }

    /// Saves a new or changed profile. A non-empty `secret` goes into the Keychain only.
    /// A new kind, host or model removes the course consents of the profile, so each course asks again.
    public func save(_ profile: ProviderProfile, secret: String?) throws(Problem) {
        var profile = profile
        // An edit with no new key keeps the saved key.
        if profile.credentialReference == nil {
            profile.credentialReference = profiles.first { $0.id == profile.id }?.credentialReference
        }
        if let secret = secret?.trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty {
            do { try credentials.save(secret, account: profile.keychainAccount) } catch { throw .credential(error) }
            profile.credentialReference = profile.keychainAccount
        }
        let previous = (profiles, consents)
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            if profiles[index].destination != profile.destination { consents.removeAll { $0.destination.profileID == profile.id } }
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        guard persist() else { (profiles, consents) = previous; throw .saveFailed }
        problems[profile.id] = nil
    }

    /// "Disconnect": deletes the secret from the Keychain, the course consents and the profile.
    /// The bundled model answers if the profile was the "Answer with" choice. If the Keychain refuses, the profile stays.
    public func disconnect(_ id: String) throws(Problem) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        if profile.credentialReference != nil {
            do { try credentials.delete(account: profile.keychainAccount) } catch {
                problems[id] = .credential(error)
                throw .credential(error)
            }
        }
        let previous = (profiles, consents, selectedID)
        profiles.removeAll { $0.id == id }
        consents.removeAll { $0.destination.profileID == id }
        if selectedID == id { selectedID = BundledAnswerProvider.providerID }
        guard persist() else {
            (profiles, consents, selectedID) = previous
            problems[id] = .saveFailed
            throw .saveFailed
        }
        problems[id] = nil
        providers[id] = nil
    }

    /// Reads the secret of each profile, so the rows show a Keychain problem. "Try Again" reads one profile again.
    public func checkCredentials(_ id: String? = nil) {
        for profile in profiles where id == nil || profile.id == id {
            guard profile.credentialReference != nil else { problems[profile.id] = nil; continue }
            do {
                _ = try credentials.secret(account: profile.keychainAccount)
                problems[profile.id] = nil
            } catch {
                problems[profile.id] = .credential(error)
            }
        }
    }

    /// True when a saved secret exists for the profile.
    public func hasSecret(_ profile: ProviderProfile) -> Bool { profile.credentialReference != nil }

    /// True when the provider sheet of `kind` shows "Test Connection" (#152).
    public func canTest(_ kind: AnswerProviderKind) -> Bool { testConnection != nil && adapterKinds.contains(kind) }

    /// "Test Connection" (#152): one synthetic message with the key of the sheet, else the saved key of the profile.
    /// Nil when the kind has no test.
    public func test(_ profile: ProviderProfile, secret: String?) async -> ConnectionTestResult? {
        guard canTest(profile.kind), let testConnection else { return nil }
        var key = secret?.trimmingCharacters(in: .whitespacesAndNewlines)
        if key?.isEmpty != false {
            key = nil
            if let saved = profiles.first(where: { $0.id == profile.id }), saved.credentialReference != nil {
                do { key = try credentials.secret(account: saved.keychainAccount) } catch { return .failed(reason: error.message) }
            }
        }
        return await testConnection(profile, key)
    }

    /// True when the learner allowed the course to send lecture text to this exact destination.
    public func hasConsent(courseID: String, destination: RemoteDestination) -> Bool {
        consents.contains { $0.courseID == courseID && $0.destination == destination }
    }

    /// "Allow and Send": records the consent of the course for the destination. It throws when the save fails,
    /// so no request runs without a saved consent.
    public func allow(courseID: String, destination: RemoteDestination, at date: Date = Date()) throws(Problem) {
        guard !hasConsent(courseID: courseID, destination: destination) else { return }
        let previous = consents
        consents.removeAll { $0.courseID == courseID && $0.destination.profileID == destination.profileID }
        consents.append(RemoteConsent(courseID: courseID, destination: destination, allowedAt: date))
        guard persist() else { consents = previous; throw .saveFailed }
    }

    /// Writes `Providers.json`. True with no store.
    private func persist() -> Bool {
        guard let store else { return true }
        do {
            try store.save(SavedProviders(selectedID: selectedID, profiles: profiles, consents: consents))
            return true
        } catch {
            return false
        }
    }
}

/// The provider of a profile whose adapter has not shipped (#151). It never answers and never sends.
@MainActor
public final class UnavailableAnswerProvider: AnswerProvider {
    public let id: String
    public let displayName: String
    public let kind: AnswerProviderKind
    public let destination: RemoteDestination?

    public init(profile: ProviderProfile) {
        id = profile.id
        displayName = profile.name
        kind = profile.kind
        destination = profile.destination
    }

    public func prepare() -> PreparedAnswer? { nil }
    public func cancel(_ id: UUID) {}
}
