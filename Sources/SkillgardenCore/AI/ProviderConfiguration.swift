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
    /// The Chat Completions endpoint of an API profile that the compatible adapter serves (#155). Nil for the other profiles.
    public var endpoint: CompatibleEndpoint?
    /// The upstream routing of an OpenRouter profile (#155). Nil for the other profiles.
    public var routing: OpenRouterRouting?

    public init(id: String = UUID().uuidString, kind: AnswerProviderKind, name: String, vendor: String, origin: String,
                modelID: String, contextTokens: Int? = nil, answerTokens: Int? = nil, credentialReference: String? = nil,
                endpoint: CompatibleEndpoint? = nil, routing: OpenRouterRouting? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.vendor = vendor
        self.origin = origin
        self.modelID = modelID
        self.contextTokens = contextTokens
        self.answerTokens = answerTokens
        self.credentialReference = credentialReference
        self.endpoint = endpoint
        self.routing = routing
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
        // A file of an earlier version has no endpoint and no routing (#155). An unknown endpoint is left out.
        endpoint = try? container.decodeIfPresent(CompatibleEndpoint.self, forKey: .endpoint)
        routing = try? container.decodeIfPresent(OpenRouterRouting.self, forKey: .routing)
    }

    /// A new profile of an external local server preset (#152). The model ID is empty until the learner types it.
    public static func preset(_ server: ExternalLocalServer) -> ProviderProfile {
        ProviderProfile(kind: .externalLocal, name: server.rawValue, vendor: server.rawValue, origin: server.defaultBaseURL, modelID: "")
    }

    /// The server preset of an external local server profile (#152). Nil for the other kinds.
    public var externalServer: ExternalLocalServer? {
        kind == .externalLocal ? ExternalLocalServer(rawValue: vendor) : nil
    }

    /// A new profile of a fixed API service (#153, #154). The model ID is empty until the learner types it.
    public static func preset(_ service: APIService) -> ProviderProfile {
        ProviderProfile(kind: .api, name: service.name, vendor: service.rawValue, origin: service.origin, modelID: "",
                        answerTokens: APIService.defaultAnswerTokens)
    }

    /// The fixed API service of an API profile with the fixed origin of the service (#153, #154). Nil for the other profiles.
    /// A compatible endpoint (#155) is never a fixed service, also with the same name and host.
    public var apiService: APIService? {
        guard kind == .api, endpoint == nil, let service = APIService(rawValue: vendor), origin == service.origin else { return nil }
        return service
    }

    /// A new profile of a compatible endpoint (#155). OpenRouter has its fixed host, no upstream and fallback off.
    /// A custom endpoint has no name, base URL or model until the learner types them.
    public static func preset(_ endpoint: CompatibleEndpoint) -> ProviderProfile {
        switch endpoint {
        case .openRouter:
            ProviderProfile(kind: .api, name: CompatibleEndpoint.openRouterName, vendor: CompatibleEndpoint.openRouterName,
                            origin: CompatibleEndpoint.openRouterBaseURL, modelID: "", endpoint: .openRouter, routing: OpenRouterRouting())
        case .custom:
            ProviderProfile(kind: .api, name: "", vendor: "", origin: "", modelID: "", endpoint: .custom)
        }
    }

    /// The `chat/completions` URL of a profile that the compatible adapter serves: an external local server (#152),
    /// OpenRouter or a custom HTTPS endpoint (#155). Nil when the base URL is not valid for the profile.
    public var chatCompletionsURL: URL? {
        let base: URL? = switch (kind, endpoint) {
        case (.externalLocal, _): Self.loopbackBaseURL(origin)
        case (.api, .openRouter?): origin == CompatibleEndpoint.openRouterBaseURL ? URL(string: origin) : nil
        case (.api, .custom?): Self.httpsBaseURL(origin)
        default: nil
        }
        return base?.appending(path: "chat/completions")
    }

    /// The secondary caption under the Base URL field of a custom endpoint (#155). Nil while the URL is not valid.
    public var requestURLCaption: String? {
        guard endpoint == .custom, let url = chatCompletionsURL else { return nil }
        return "Requests go to \(url.absoluteString)"
    }

    /// The red caption under the Upstream providers field of OpenRouter (#155). Nil when the list has a provider.
    public var upstreamProblem: String? {
        endpoint == .openRouter && (routing?.upstreams ?? []).isEmpty ? Self.noUpstreamText : nil
    }

    public static let httpsOnlyText = "Use an https:// URL."
    public static let urlCredentialsText = "Remove the user name and password from the URL."
    public static let noUpstreamText = "Enter at least one upstream provider."

    /// The red caption under the Output limit field of an API service (#153, #154). Nil when the limit is
    /// `APIService.minimumAnswerTokens` or more, or not set, so the adapter uses `APIService.defaultAnswerTokens`.
    /// The sheet sets 0 for an empty field.
    public var answerTokensProblem: String? {
        guard let service = apiService, let tokens = answerTokens, tokens < service.minimumAnswerTokens else { return nil }
        switch service {
        case .openAI: return tokens == 0 ? Self.noOutputLimitText : Self.smallAnswerTokensText
        case .anthropic: return Self.noAnswerTokensText
        }
    }

    public static let noAnswerTokensText = "Enter an output limit of 1 or more tokens."
    /// The OpenAI caption of an empty Output limit field (#153).
    public static let noOutputLimitText = "Enter the output limit."
    /// The OpenAI caption of an Output limit under 16 (#153).
    public static let smallAnswerTokensText = "Enter 16 or more."
    public static let noKeyText = APIService.noKeyText

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
    /// For OpenRouter, a change of the upstreams, the fallback or the data policy also needs a new consent (#155).
    public var destination: RemoteDestination {
        RemoteDestination(profileID: id, kind: kind, host: host, modelID: modelID, routing: endpoint == .openRouter ? routing : nil)
    }

    /// The Keychain account for the secret of this profile.
    public var keychainAccount: String { credentialReference ?? id }

    /// The Q&A footer: "Answers come from LM Studio on this Mac and can be wrong." (#152)
    /// A ChatGPT plan: "Answers come from ChatGPT and can be wrong." (#157)
    public var answerFooter: String {
        if isChatGPTPlan { return "Answers come from ChatGPT and can be wrong." }
        return kind == .externalLocal ? "Answers come from \(vendor) on this Mac and can be wrong."
            : "Answers come from \(vendor) and can be wrong."
    }

    /// The red caption under the Base URL field of an external local server (#152) or a custom endpoint (#155).
    /// Nil when the URL is valid.
    public var originProblem: String? {
        if kind == .externalLocal { return Self.loopbackBaseURL(origin) == nil ? Self.loopbackOnlyText : nil }
        guard endpoint == .custom else { return nil }
        let parts = URLComponents(string: origin.trimmingCharacters(in: .whitespacesAndNewlines))
        if parts?.user != nil || parts?.password != nil { return Self.urlCredentialsText }
        return Self.httpsBaseURL(origin) == nil ? Self.httpsOnlyText : nil
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
        // A custom endpoint can run with no key. OpenRouter needs a key and an upstream (#155).
        if let endpoint {
            guard chatCompletionsURL != nil, upstreamProblem == nil else { return false }
            return endpoint == .custom || hasSecret
        }
        guard Self.isValidOrigin(origin), answerTokensProblem == nil else { return false }
        return !kind.needsAPIKey || hasSecret
    }

    /// The base URL of a custom endpoint (#155): `https`, a host, an optional port and path, and no user, password,
    /// query or fragment. Empty segments and a trailing `/chat/completions` go, and a repeated `v1` becomes one,
    /// so the request never goes to `/v1/v1`. An empty path gives `/v1`. Nil for another URL.
    public static func httpsBaseURL(_ text: String) -> URL? {
        guard var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return nil }
        if let port = parts.port, !(1...65535).contains(port) { return nil }
        var segments = parts.path.split(separator: "/").map(String.init)
        if segments.suffix(2) == ["chat", "completions"] { segments.removeLast(2) }
        segments = segments.enumerated().filter { $0.offset == 0 || $0.element != "v1" || segments[$0.offset - 1] != "v1" }.map(\.element)
        if segments.isEmpty { segments = ["v1"] }
        parts.scheme = "https"
        parts.path = "/" + segments.joined(separator: "/")
        return parts.url
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

/// The API services of "Add Provider" with a fixed host: OpenAI (#153) and Anthropic (#154).
/// The raw value is the vendor of the profile.
public enum APIService: String, CaseIterable, Identifiable, Sendable {
    case openAI = "OpenAI"
    case anthropic = "Anthropic"

    public var id: String { rawValue }

    /// The output limit of a new profile, in tokens.
    public static let defaultAnswerTokens = 1024

    /// The smallest output limit that the service accepts. OpenAI needs 16 or more `max_output_tokens` (#153).
    public var minimumAnswerTokens: Int {
        switch self {
        case .openAI: OpenAIAnswerProvider.minimumAnswerTokens
        case .anthropic: 1
        }
    }

    /// The profile name and the start of the Q&A header: "OpenAI API", "Anthropic API".
    public var name: String { rawValue + " API" }

    /// The "Add Provider" menu item: "Anthropic API…".
    public var menuTitle: String { name + "…" }

    /// The only origin that the adapter sends to.
    public var origin: String {
        switch self {
        case .openAI: "https://api.openai.com"
        case .anthropic: "https://api.anthropic.com"
        }
    }

    /// The only URL that the OpenAI adapter sends to (#153).
    var endpoint: URL {
        switch self {
        case .openAI: URL(string: "https://api.openai.com/v1/responses")!
        case .anthropic: URL(string: "https://api.anthropic.com/v1/messages")!
        }
    }

    /// The prompt of the empty API key field.
    public var keyPrompt: String {
        switch self {
        case .openAI: "sk-…"
        case .anthropic: "sk-ant-…"
        }
    }

    /// The prompt of the empty Model ID field.
    public var modelPrompt: String {
        switch self {
        case .openAI: "Model ID, for example gpt-5"
        case .anthropic: "Model ID, for example claude-sonnet-5-5"
        }
    }

    /// The secondary caption of the provider sheet. Nil when the service has none.
    public var footer: String? {
        switch self {
        case .openAI: nil
        case .anthropic: "Claude Pro and Max plans do not work here. Use an API key from the Anthropic Console."
        }
    }

    public static let noKeyText = "Enter an API key."
}

/// The API profiles of "Add Provider" that the compatible Chat Completions adapter serves (#155).
public enum CompatibleEndpoint: String, Codable, CaseIterable, Identifiable, Sendable {
    case openRouter
    case custom

    public var id: String { rawValue }

    public static let openRouterName = "OpenRouter"
    /// The only base URL of an OpenRouter profile.
    public static let openRouterBaseURL = "https://openrouter.ai/api/v1"

    /// The "Add Provider" menu item: "OpenRouter…", "Custom HTTPS Endpoint…".
    public var menuTitle: String {
        switch self {
        case .openRouter: Self.openRouterName + "…"
        case .custom: "Custom HTTPS Endpoint…"
        }
    }
}

/// The upstream routing of an OpenRouter profile (#155). The consent names it, so a change needs a new consent.
public struct OpenRouterRouting: Codable, Hashable, Sendable {
    /// The OpenRouter provider slugs, in the order to try, for example `openai`. Lowercase, with no empty or repeated slug.
    public var upstreams: [String]
    /// True when OpenRouter can send the request to a provider that is not in `upstreams`. The default is off (owner decision).
    public var allowsFallback: Bool
    /// True when an upstream that keeps or trains on prompts can get the request. The default is off.
    public var allowsDataCollection: Bool

    public init(upstreams: [String] = [], allowsFallback: Bool = false, allowsDataCollection: Bool = false) {
        self.upstreams = upstreams
        self.allowsFallback = allowsFallback
        self.allowsDataCollection = allowsDataCollection
    }

    /// Each missing key gets its default, which is the safe value.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        upstreams = try container.decodeIfPresent([String].self, forKey: .upstreams) ?? []
        allowsFallback = try container.decodeIfPresent(Bool.self, forKey: .allowsFallback) ?? false
        allowsDataCollection = try container.decodeIfPresent(Bool.self, forKey: .allowsDataCollection) ?? false
    }

    /// The upstream slugs of the comma-separated field text: trimmed, lowercase, with no empty or repeated slug.
    public static func upstreams(from text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public static let denyDataCollectionText = "Deny data collection"
    public static let allowDataCollectionText = "Allow data collection"

    /// The Data policy value of the sheet picker and the consent sheet.
    public var dataPolicyText: String { allowsDataCollection ? Self.allowDataCollectionText : Self.denyDataCollectionText }

    /// The Fallback value of the consent sheet.
    public var fallbackText: String { allowsFallback ? "On" : "Off" }
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
    /// The signed-in account of each ChatGPT plan profile, by profile ID (#156). It comes from the Keychain session.
    public private(set) var accounts: [String: ChatGPTAccount] = [:]
    /// The ChatGPT plan profiles whose session can't refresh (#156). The row shows "Sign in again." and "Sign In…".
    public private(set) var expiredSessions: Set<String> = []

    @ObservationIgnored private let store: ProviderSettingsStore?
    @ObservationIgnored private let credentials: any CredentialStore
    /// Makes the answer provider of a profile. Nil when the kind has no shipped adapter.
    @ObservationIgnored private let makeProvider: @MainActor (ProviderProfile, any CredentialStore) -> (any AnswerProvider)?
    /// Runs "Test Connection" with the profile and its token. Nil while no adapter ships, so the sheet shows no button.
    @ObservationIgnored public let testConnection: (@MainActor (ProviderProfile, String?) async -> ConnectionTestResult)?
    /// The kinds with a shipped adapter (#152). "Add Provider" and "Test Connection" show only for them.
    @ObservationIgnored public let adapterKinds: Set<AnswerProviderKind>
    @ObservationIgnored private var providers: [String: (profile: ProviderProfile, provider: any AnswerProvider)] = [:]
    /// Sign in with ChatGPT (#156). Nil hides "ChatGPT Plan…" in "Add Provider".
    @ObservationIgnored public let chatGPT: ChatGPTAuthorizer?
    /// The transport of the ChatGPT plan answers and model list (#157). Nil makes the real one on first use.
    @ObservationIgnored private var chatGPTTransport: (any LlamaTransport)?
    /// The running refresh of each ChatGPT plan profile, so two callers never use one refresh token twice.
    @ObservationIgnored private var refreshes: [String: Task<Result<ChatGPTSession, ChatGPTAuthError>, Never>] = [:]

    /// `store` nil saves nothing: the snapshot harness and previews inject the profiles.
    public init(store: ProviderSettingsStore?, credentials: any CredentialStore = KeychainCredentialStore(),
                profiles: [ProviderProfile] = [], selectedID: String = BundledAnswerProvider.providerID,
                adapterKinds: Set<AnswerProviderKind> = [],
                makeProvider: @escaping @MainActor (ProviderProfile, any CredentialStore) -> (any AnswerProvider)? = { _, _ in nil },
                testConnection: (@MainActor (ProviderProfile, String?) async -> ConnectionTestResult)? = nil,
                chatGPT: ChatGPTAuthorizer? = nil, chatGPTTransport: (any LlamaTransport)? = nil) {
        let saved = store?.load() ?? SavedProviders(selectedID: selectedID, profiles: profiles)
        self.store = store
        self.credentials = credentials
        self.adapterKinds = adapterKinds
        self.makeProvider = makeProvider
        self.testConnection = testConnection
        self.chatGPT = chatGPT
        self.chatGPTTransport = chatGPTTransport
        self.profiles = saved.profiles
        consents = saved.consents
        // A choice of a removed profile, or of a profile that can't answer yet, falls back to the bundled model.
        let canAnswer = saved.profiles.first { $0.id == saved.selectedID }.map { Self.canAnswer($0.kind, adapterKinds: adapterKinds) }
        self.selectedID = canAnswer == true ? saved.selectedID : BundledAnswerProvider.providerID
    }

    /// The profile of the "Answer with" choice. Nil for the bundled model.
    public var selected: ProviderProfile? { profiles.first { $0.id == selectedID } }

    /// The profiles of one picker group, in saved order.
    public func profiles(of kind: AnswerProviderKind) -> [ProviderProfile] { profiles.filter { $0.kind == kind } }

    /// The "Answer with" items of one group. A ChatGPT plan shows only after the learner chose a model (#157).
    public func answerProfiles(of kind: AnswerProviderKind) -> [ProviderProfile] {
        profiles(of: kind).filter { !$0.isChatGPTPlan || $0.modelProblem == nil || $0.id == selectedID }
    }

    /// False for a subscription until its Q&A adapter ships (#157). "Answer with" does not list such a profile.
    public func canAnswer(_ kind: AnswerProviderKind) -> Bool { Self.canAnswer(kind, adapterKinds: adapterKinds) }

    private static func canAnswer(_ kind: AnswerProviderKind, adapterKinds: Set<AnswerProviderKind>) -> Bool {
        kind != .subscription || adapterKinds.contains(.subscription)
    }

    /// The row caption. A ChatGPT plan shows "<email> · Subscription", and "· Q&A not available yet" until #157 ships.
    public func caption(for profile: ProviderProfile) -> String {
        guard profile.isChatGPTPlan else { return profile.caption }
        let account = accounts[profile.id]?.displayName ?? ChatGPTAccount(email: nil, planType: nil).displayName
        let caption = "\(account) · \(profile.kind.title)"
        return canAnswer(profile.kind) ? caption : caption + " · " + Self.qaNotAvailableText
    }

    public static let qaNotAvailableText = "Q&A not available yet"
    /// The red caption of a ChatGPT plan session that can't refresh (#156).
    public static let signInAgainText = "Sign in again."

    /// True for a ChatGPT plan with no credential problem and a session that can't refresh (#156). The row shows "Sign In…".
    public func needsSignIn(_ profile: ProviderProfile) -> Bool {
        problems[profile.id] == nil && profile.isChatGPTPlan && expiredSessions.contains(profile.id)
    }

    /// True for a ChatGPT plan that can answer but has no model, from before #157 or a failed model load (#232).
    /// "Answer with" hides it, so the row shows `chooseModelText` and "Choose Model…".
    public func needsModel(_ profile: ProviderProfile) -> Bool {
        problems[profile.id] == nil && profile.isChatGPTPlan && !needsSignIn(profile) && canAnswer(profile.kind)
            && profile.modelProblem != nil
    }

    /// The red caption of a ChatGPT plan with no model (#232).
    public static let chooseModelText = "Choose a model to use this plan for Q&A."

    /// The red caption of a row, first match wins: the credential problem, then "Sign in again.", then no model (#232).
    public func redCaption(for profile: ProviderProfile) -> String? {
        if let problem = problems[profile.id] { return problem.message }
        if needsSignIn(profile) { return Self.signInAgainText }
        if needsModel(profile) { return Self.chooseModelText }
        return nil
    }

    /// The provider that answers the next question: the bundled model, or the provider of the chosen profile.
    /// A profile with no shipped adapter gets a provider that can't answer.
    public func activeProvider(bundled: any AnswerProvider) -> any AnswerProvider {
        guard let profile = selected else { return bundled }
        if let cached = providers[profile.id], cached.profile == profile { return cached.provider }
        let provider = (profile.isChatGPTPlan && canAnswer(profile.kind) ? chatGPTProvider(profile) : makeProvider(profile, credentials))
            ?? UnavailableAnswerProvider(profile: profile)
        providers[profile.id] = (profile, provider)
        return provider
    }

    /// The ChatGPT plan adapter (#157). It gets the session from `chatGPTSession(for:)` before each request.
    private func chatGPTProvider(_ profile: ProviderProfile) -> any AnswerProvider {
        let id = profile.id
        return ChatGPTAnswerProvider(profile: profile, transport: answerTransport(),
                                     session: { [weak self] () async throws(ChatGPTAuthError) -> ChatGPTSession in
                                         guard let self else { throw .canceled }
                                         return try await self.chatGPTSession(for: id)
                                     },
                                     revoke: { [weak self] in self?.endChatGPTSession(id) })
    }

    private func answerTransport() -> any LlamaTransport {
        if let chatGPTTransport { return chatGPTTransport }
        let transport = LoopbackTransport(usesSystemProxy: true)
        chatGPTTransport = transport
        return transport
    }

    /// The models of the account of a ChatGPT plan profile (#157), in server order. The failure is the design-note text.
    /// A revoked grant ends the session, so the row shows "Sign in again.".
    public func chatGPTModels(for id: String) async -> Result<[ChatGPTModel], ChatGPTModelsFailure> {
        let session: ChatGPTSession
        do { session = try await chatGPTSession(for: id) } catch {
            return .failure(ChatGPTModelsFailure(reason: ChatGPTErrors.reason(error)))
        }
        switch await ChatGPTAnswerProvider.fetchModels(accessToken: session.accessToken, transport: answerTransport()) {
        case .models(let models):
            return .success(models)
        case .failed(let reason, let revoked):
            if revoked { endChatGPTSession(id) }
            return .failure(ChatGPTModelsFailure(reason: reason))
        }
    }

    /// Saves the model of a ChatGPT plan profile (#157). A new model needs a new course consent.
    public func saveChatGPTModel(_ modelID: String, for id: String) throws(Problem) {
        guard var profile = profiles.first(where: { $0.id == id && $0.isChatGPTPlan }) else { return }
        profile.modelID = modelID
        try save(profile, secret: nil)
    }

    /// OpenAI says that the grant of a ChatGPT plan ended (#157). The tokens go, the issued client ID stays, and the row
    /// shows "Sign in again.".
    func endChatGPTSession(_ id: String) {
        guard let profile = profiles.first(where: { $0.id == id && $0.isChatGPTPlan }) else { return }
        if let session = savedChatGPTSession(for: id) {
            try? credentials.save(session.discardingTokens().keychainText, account: profile.keychainAccount)
        }
        expiredSessions.insert(id)
    }

    /// The source text of a saved turn: "via OpenAI API · gpt-5". Nil for the bundled model and for removed profiles.
    public func sourceText(for origin: AnswerOrigin) -> String? {
        guard origin.providerID != BundledAnswerProvider.providerID,
              let profile = profiles.first(where: { $0.id == origin.providerID }) else { return nil }
        return "via \(profile.name) · \(origin.modelID ?? profile.modelID)"
    }

    /// The "Answer with" choice. Each change is saved at once.
    /// A subscription profile is refused until its Q&A adapter ships (#157).
    public func select(_ id: String) {
        guard id == BundledAnswerProvider.providerID || profiles.contains(where: { $0.id == id && canAnswer($0.kind) }),
              id != selectedID else { return }
        let previous = selectedID
        selectedID = id
        if !persist() { selectedID = previous }
    }

    /// Saves a new or changed profile. A non-empty `secret` goes into the Keychain only.
    /// A new kind, host or model removes the course consents of the profile, so each course asks again.
    public func save(_ profile: ProviderProfile, secret: String?) throws(Problem) {
        var profile = profile
        let saved = profiles.first { $0.id == profile.id }
        // An edit with no new key keeps the saved key.
        if profile.credentialReference == nil {
            profile.credentialReference = saved?.credentialReference
        }
        // The key of a compatible endpoint stays bound to its host (#155). A new host with no new key drops the old key,
        // so the old key never goes to the new host.
        var dropsKey: String?
        if let secret = secret?.trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty {
            do { try credentials.save(secret, account: profile.keychainAccount) } catch { throw .credential(error) }
            profile.credentialReference = profile.keychainAccount
        } else if !hasSecret(profile), profile.credentialReference != nil {
            dropsKey = profile.keychainAccount
            profile.credentialReference = nil
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
        // The profile no longer names the item, so a failed delete leaves an item that no request reads.
        if let dropsKey { try? credentials.delete(account: dropsKey) }
    }

    /// True when "Save" of a compatible endpoint (#155) changes the host or the upstream list of a saved profile.
    /// The sheet then asks "Change the destination?", because each course must allow the new destination again.
    public func changesDestination(_ profile: ProviderProfile) -> Bool {
        guard profile.endpoint != nil, let saved = profiles.first(where: { $0.id == profile.id }) else { return false }
        return saved.host != profile.host || saved.routing?.upstreams != profile.routing?.upstreams
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
        accounts[id] = nil
        expiredSessions.remove(id)
        refreshes[id]?.cancel()
        refreshes[id] = nil
    }

    /// Saves a ChatGPT plan sign-in (#156): the session into the Keychain, then the profile into `Providers.json`.
    /// A sign-in again replaces the session of the same profile.
    public func saveChatGPT(_ session: ChatGPTSession, profile: ProviderProfile) throws(ChatGPTAuthError) {
        do { try save(profile, secret: session.keychainText) } catch {
            switch error {
            case .credential(let error): throw .credential(error)
            case .saveFailed: throw .saveFailed
            }
        }
        accounts[profile.id] = session.account
        expiredSessions.remove(profile.id)
    }

    /// A valid session of a ChatGPT plan profile (#156). An access token near its end refreshes first, and the new tokens
    /// go into the Keychain. A session that can't refresh marks the profile "Sign in again.".
    /// The Q&A adapter (#157) uses it before each request.
    public func chatGPTSession(for id: String, now: Date = Date()) async throws(ChatGPTAuthError) -> ChatGPTSession {
        guard let profile = profiles.first(where: { $0.id == id && $0.isChatGPTPlan }), profile.credentialReference != nil else {
            throw .refused("invalid_grant")
        }
        if let running = refreshes[id] { return try await running.value.get() }
        let text: String?
        do { text = try credentials.secret(account: profile.keychainAccount) } catch {
            problems[id] = .credential(error)
            throw .credential(error)
        }
        guard let session = text.flatMap(ChatGPTSession.init(keychainText:)) else {
            expiredSessions.insert(id)
            throw .refused("invalid_grant")
        }
        accounts[id] = session.account
        guard session.needsRefresh(at: now) else { return session }
        guard session.canRefresh(at: now) else {
            expiredSessions.insert(id)
            throw .refused("invalid_grant")
        }
        guard let chatGPT else { throw .network }
        let task = Task { @MainActor () -> Result<ChatGPTSession, ChatGPTAuthError> in
            do throws(ChatGPTAuthError) { return .success(try await chatGPT.refresh(session)) } catch { return .failure(error) }
        }
        refreshes[id] = task
        let result = await task.value
        refreshes[id] = nil
        switch result {
        case .success(let fresh):
            // A Disconnect during the refresh wins. The new tokens are not saved.
            guard profiles.contains(where: { $0.id == id }) else { throw .canceled }
            do { try credentials.save(fresh.keychainText, account: profile.keychainAccount) } catch {
                problems[id] = .credential(error)
                throw .credential(error)
            }
            accounts[id] = fresh.account
            expiredSessions.remove(id)
            return fresh
        case .failure(let error):
            guard error.needsSignIn, profiles.contains(where: { $0.id == id }) else { throw error }
            expiredSessions.insert(id)
            // A refused refresh token is dead. The tokens go, and the issued client ID stays for the next sign-in.
            if case .refused(let code) = error, ChatGPTAuthError.revokedRefreshCodes.contains(code) {
                try? credentials.save(session.discardingTokens().keychainText, account: profile.keychainAccount)
            }
            throw error
        }
    }

    /// The saved session of a ChatGPT plan profile, also an expired one (#156). A later sign-in reuses its issued client ID.
    /// Nil when the profile has no session or the Keychain refuses the read.
    public func savedChatGPTSession(for id: String) -> ChatGPTSession? {
        guard let profile = profiles.first(where: { $0.id == id && $0.isChatGPTPlan }), profile.credentialReference != nil,
              let text = try? credentials.secret(account: profile.keychainAccount) else { return nil }
        return ChatGPTSession(keychainText: text)
    }

    /// Refreshes each ChatGPT plan session near its end, so an expired session shows "Sign in again." when Settings opens.
    /// A network failure changes nothing: the next open tries again.
    public func refreshChatGPTSessions(now: Date = Date()) async {
        for profile in profiles where profile.isChatGPTPlan && profile.credentialReference != nil && problems[profile.id] == nil {
            _ = try? await chatGPTSession(for: profile.id, now: now)
        }
    }

    /// Reads the secret of each profile, so the rows show a Keychain problem. "Try Again" reads one profile again.
    /// A ChatGPT plan profile also gets its account, or "Sign in again." when the Keychain has no session (#156).
    public func checkCredentials(_ id: String? = nil) {
        for profile in profiles where id == nil || profile.id == id {
            guard profile.credentialReference != nil else {
                problems[profile.id] = nil
                if profile.isChatGPTPlan { expiredSessions.insert(profile.id) }
                continue
            }
            do {
                let secret = try credentials.secret(account: profile.keychainAccount)
                problems[profile.id] = nil
                guard profile.isChatGPTPlan else { continue }
                if let session = secret.flatMap(ChatGPTSession.init(keychainText:)) {
                    accounts[profile.id] = session.account
                    if !session.canRefresh(at: Date()) { expiredSessions.insert(profile.id) }
                } else {
                    expiredSessions.insert(profile.id)
                }
            } catch {
                problems[profile.id] = .credential(error)
            }
        }
    }

    /// True when a saved secret exists for the profile. The key of a compatible endpoint (#155) is bound to the saved host,
    /// so an edit to another host has no saved key.
    public func hasSecret(_ profile: ProviderProfile) -> Bool {
        guard profile.credentialReference != nil else { return false }
        guard profile.endpoint != nil, let saved = profiles.first(where: { $0.id == profile.id }) else { return true }
        return saved.credentialReference != nil && saved.host == profile.host
    }

    /// True when the provider sheet of `kind` shows "Test Connection" (#152).
    public func canTest(_ kind: AnswerProviderKind) -> Bool { testConnection != nil && adapterKinds.contains(kind) }

    /// "Test Connection" (#152): one synthetic message with the key of the sheet, else the saved key of the profile.
    /// Nil when the kind has no test.
    public func test(_ profile: ProviderProfile, secret: String?) async -> ConnectionTestResult? {
        guard canTest(profile.kind), let testConnection else { return nil }
        var key = secret?.trimmingCharacters(in: .whitespacesAndNewlines)
        if key?.isEmpty != false {
            key = nil
            // The saved key goes only to its saved host (#155).
            if let saved = profiles.first(where: { $0.id == profile.id }), saved.credentialReference != nil,
               profile.endpoint == nil || saved.host == profile.host {
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

/// Why the account model list of a ChatGPT plan did not load (#157). `reason` is the design-note text.
public struct ChatGPTModelsFailure: Error, Equatable, Sendable {
    public let reason: String
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
