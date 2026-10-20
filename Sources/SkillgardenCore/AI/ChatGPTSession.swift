import Foundation

/// The account of a ChatGPT plan sign-in (#156). Settings shows it on this Mac only. It never goes into `Providers.json`.
public struct ChatGPTAccount: Equatable, Sendable {
    public let email: String?
    /// The plan type of the ID token, for example `plus`. Nil when OpenAI does not send it.
    public let planType: String?

    public init(email: String?, planType: String?) {
        self.email = email
        self.planType = planType
    }

    /// The account text of the row caption and the sheet: the email, else "ChatGPT account".
    public var displayName: String { email ?? "ChatGPT account" }

    /// The plan line of the Signed in sheet: "ChatGPT Plus". Nil when the plan is not known.
    public var planName: String? {
        guard let planType = planType?.trimmingCharacters(in: .whitespacesAndNewlines), !planType.isEmpty else { return nil }
        return "ChatGPT " + planType.prefix(1).uppercased() + planType.dropFirst()
    }
}

/// The tokens of a ChatGPT plan sign-in (#156). They are in the Keychain only, as one JSON item of the profile.
/// No log, URL, alert or `Providers.json` holds them.
public struct ChatGPTSession: Codable, Equatable, Sendable {
    /// The client ID of the dynamic registration. The refresh uses the same client.
    public var clientID: String
    public var accessToken: String
    public var refreshToken: String?
    public var idToken: String
    /// The end of the access token.
    public var expiresAt: Date
    /// The scopes that OpenAI granted.
    public var scopes: [String]
    /// The `sub` claim of the ID token. A refresh must give the same subject.
    public var subject: String
    public var email: String?
    public var planType: String?

    public init(clientID: String, accessToken: String, refreshToken: String?, idToken: String, expiresAt: Date, scopes: [String],
                subject: String, email: String?, planType: String?) {
        self.clientID = clientID
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.subject = subject
        self.email = email
        self.planType = planType
    }

    public var account: ChatGPTAccount { ChatGPTAccount(email: email, planType: planType) }

    /// True when the access token ends in `leeway` seconds or less, so a request must refresh it first.
    public func needsRefresh(at now: Date, leeway: TimeInterval = 60) -> Bool {
        expiresAt.timeIntervalSince(now) <= leeway
    }

    /// False when the access token needs a refresh and no refresh token exists, so only a new sign-in helps.
    public func canRefresh(at now: Date) -> Bool { refreshToken != nil || !needsRefresh(at: now) }

    /// The Keychain text of the session.
    var keychainText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .secondsSince1970
        return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self)
    }

    /// The session of a Keychain text. Nil when the text is not a session.
    init?(keychainText: String) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let session = try? decoder.decode(Self.self, from: Data(keychainText.utf8)) else { return nil }
        self = session
    }
}

extension ProviderProfile {
    /// The name of the ChatGPT plan profile (#156).
    public static let chatGPTPlanName = "ChatGPT Plan"

    /// A new ChatGPT plan profile (#156). The model ID is empty until the Q&A adapter ships (#157).
    public static func chatGPTPlan() -> ProviderProfile {
        ProviderProfile(kind: .subscription, name: chatGPTPlanName, vendor: "OpenAI", origin: "https://api.openai.com", modelID: "")
    }

    /// True for the ChatGPT plan profile (#156).
    public var isChatGPTPlan: Bool { kind == .subscription && vendor == "OpenAI" }
}
