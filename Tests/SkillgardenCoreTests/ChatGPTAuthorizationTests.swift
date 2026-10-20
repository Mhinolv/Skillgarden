import Foundation
import Testing
@testable import SkillgardenCore

// Sign in with ChatGPT (#156). Every test runs offline: a fake transport, a fixed clock and fixture ID tokens.

/// Answers each request with the next scripted status and JSON body, or with the reply of `respond`, and records the requests.
/// With no reply left, the request fails as offline.
private final class FakeAuthTransport: LlamaTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [(Int, String)]
    private let respond: (@Sendable (URLRequest) -> (Int, String))?
    private var sent: [URLRequest] = []

    init(_ replies: [(Int, String)]) {
        self.replies = replies
        respond = nil
    }

    init(respond: @escaping @Sendable (URLRequest) -> (Int, String)) {
        replies = []
        self.respond = respond
    }

    var requests: [URLRequest] { lock.withLock { sent } }

    func send(_ request: URLRequest) -> AsyncThrowingStream<LlamaTransportEvent, any Error> {
        let reply: (Int, String)? = lock.withLock {
            sent.append(request)
            return replies.isEmpty ? nil : replies.removeFirst()
        } ?? respond?(request)
        return AsyncThrowingStream { continuation in
            guard let (status, body) = reply else { continuation.finish(throwing: URLError(.notConnectedToInternet)); return }
            continuation.yield(.response(status: status))
            continuation.yield(.data(Data(body.utf8)))
            continuation.finish()
        }
    }
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let redirect = URL(string: "http://127.0.0.1:53682/auth/callback")!
private let clientID = "client-123"
private let state = "state-abc"
private let nonce = "nonce-xyz"
private let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

private func base64URL(_ object: [String: Any]) -> String {
    PKCE.base64URL(try! JSONSerialization.data(withJSONObject: object, options: .sortedKeys))
}

/// A fixture ID token. Each argument overrides one claim. `nil` in `drop` leaves claims out.
private func idToken(issuer: String = "https://auth.openai.com", audience: Any = clientID, azp: String? = nil,
                     subject: String = "user-1", expires: Date = now.addingTimeInterval(3600), issued: Date = now,
                     nonce tokenNonce: String? = nonce, email: String? = "learner@example.com", plan: String? = "plus",
                     algorithm: String = "RS256") -> String {
    var claims: [String: Any] = ["iss": issuer, "aud": audience, "sub": subject, "exp": expires.timeIntervalSince1970,
                                 "iat": issued.timeIntervalSince1970]
    if let azp { claims["azp"] = azp }
    if let tokenNonce { claims["nonce"] = tokenNonce }
    if let email { claims["email"] = email }
    if let plan { claims[ChatGPTIDToken.authClaim] = ["chatgpt_plan_type": plan] }
    return base64URL(["alg": algorithm, "typ": "JWT"]) + "." + base64URL(claims) + ".c2ln"
}

private func tokenJSON(idToken: String? = idToken(), scope: String? = "openid profile email offline_access",
                       access: String = "access-secret-1", refresh: String? = "refresh-secret-1") -> String {
    var object: [String: Any] = ["access_token": access, "token_type": "Bearer", "expires_in": 3600]
    if let idToken { object["id_token"] = idToken }
    if let scope { object["scope"] = scope }
    if let refresh { object["refresh_token"] = refresh }
    return String(decoding: try! JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
}

private func callback(code: String? = "code-1", state callbackState: String? = state, extra: [URLQueryItem] = [],
                      base: URL = redirect) -> URL {
    var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
    components.queryItems = [code.map { URLQueryItem(name: "code", value: $0) },
                             callbackState.map { URLQueryItem(name: "state", value: $0) }].compactMap { $0 } + extra
    return components.url!
}

@MainActor
private func authorizer(_ replies: [(Int, String)]) -> (ChatGPTAuthorizer, FakeAuthTransport) {
    let transport = FakeAuthTransport(replies)
    let authorizer = ChatGPTAuthorizer(transport: transport, now: { now })
    authorizer.expect(authorizer.makeRequest(clientID: clientID, redirectURI: redirect, state: state, nonce: nonce,
                                             codeVerifier: verifier))
    return (authorizer, transport)
}

@MainActor
private func expectFailure(_ expected: ChatGPTAuthError, token: String? = nil, scope: String? = "openid profile email offline_access",
                           callbackURL: URL = callback()) async {
    let (authorizer, _) = authorizer([(200, tokenJSON(idToken: token ?? idToken(), scope: scope))])
    await #expect(throws: expected) { try await authorizer.complete(callback: callbackURL) }
}

private func form(_ request: URLRequest) -> [String: String] {
    let text = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    return Dictionary(uniqueKeysWithValues: text.split(separator: "&").map {
        let pair = $0.split(separator: "=", maxSplits: 1).map(String.init)
        return (pair[0], pair.count > 1 ? pair[1].removingPercentEncoding ?? "" : "")
    })
}

// MARK: Request

@Test func pkceUsesS256WithTheRFC7636Vector() {
    #expect(PKCE.challenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    let random = PKCE.randomText(bytes: 64)
    #expect(random.count == 86 && !random.contains("=") && !random.contains("+") && !random.contains("/"))
    #expect(PKCE.randomText(bytes: 32) != PKCE.randomText(bytes: 32))
}

@MainActor @Test func beginRegistersAPublicLoopbackClientAndBuildsThePKCEURL() async throws {
    let transport = FakeAuthTransport([(201, #"{"client_id":"client-new"}"#)])
    let authorizer = ChatGPTAuthorizer(transport: transport, now: { now })
    let request = try await authorizer.begin(redirectURI: redirect)
    let registration = try #require(transport.requests.first)
    #expect(registration.url?.absoluteString == "https://auth.openai.com/oauth/register")
    let body = try #require(try JSONSerialization.jsonObject(with: registration.httpBody ?? Data()) as? [String: Any])
    #expect(body["redirect_uris"] as? [String] == [redirect.absoluteString])
    #expect(body["token_endpoint_auth_method"] as? String == "none")
    #expect(body["client_name"] as? String == "Skillgarden")
    #expect(body["client_secret"] == nil)
    let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
        .map { ($0.name, $0.value ?? "") })
    #expect(request.url.host == "auth.openai.com" && request.url.path == "/oauth/authorize")
    #expect(items["client_id"] == "client-new" && items["response_type"] == "code")
    #expect(items["redirect_uri"] == redirect.absoluteString)
    #expect(items["scope"] == "openid profile email offline_access")
    #expect(items["code_challenge_method"] == "S256")
    #expect(items["code_challenge"] == PKCE.challenge(for: request.codeVerifier))
    #expect(items["state"] == request.state && items["nonce"] == request.nonce)
    #expect(request.state.count >= 43 && request.nonce.count >= 43 && request.codeVerifier.count >= 43)
}

@MainActor @Test func aFailedRegistrationDoesNotFinish() async {
    let authorizer = ChatGPTAuthorizer(transport: FakeAuthTransport([(400, #"{"error":"invalid_client_metadata"}"#)]), now: { now })
    await #expect(throws: ChatGPTAuthError.refused("invalid_client_metadata")) { try await authorizer.begin(redirectURI: redirect) }
    let offline = ChatGPTAuthorizer(transport: FakeAuthTransport([]), now: { now })
    await #expect(throws: ChatGPTAuthError.network) { try await offline.begin(redirectURI: redirect) }
}

// MARK: Complete

@MainActor @Test func signInCompletesWhenEveryCheckPasses() async throws {
    let (authorizer, transport) = authorizer([(200, tokenJSON())])
    let session = try await authorizer.complete(callback: callback(extra: [URLQueryItem(name: "iss", value: "https://auth.openai.com")]))
    #expect(session.clientID == clientID && session.accessToken == "access-secret-1" && session.refreshToken == "refresh-secret-1")
    #expect(session.email == "learner@example.com" && session.subject == "user-1")
    #expect(session.account.planName == "ChatGPT Plus")
    #expect(session.expiresAt == now.addingTimeInterval(3600))
    let exchange = try #require(transport.requests.first)
    #expect(exchange.url?.absoluteString == "https://auth.openai.com/oauth/token" && exchange.httpMethod == "POST")
    #expect(form(exchange) == ["grant_type": "authorization_code", "code": "code-1", "redirect_uri": redirect.absoluteString,
                               "client_id": clientID, "code_verifier": verifier])
}

@MainActor @Test func aCallbackWithAWrongOrMissingStateIsRejectedBeforeAnyRequest() async {
    let (authorizer, transport) = authorizer([(200, tokenJSON())])
    await #expect(throws: ChatGPTAuthError.stateMismatch) { try await authorizer.complete(callback: callback(state: "other")) }
    await #expect(throws: ChatGPTAuthError.stateMismatch) { try await authorizer.complete(callback: callback(state: nil)) }
    #expect(transport.requests.isEmpty)
}

@MainActor @Test func aWrongNonceIsRejected() async {
    await expectFailure(.nonceMismatch, token: idToken(nonce: "nonce-of-another-sign-in"))
    await expectFailure(.nonceMismatch, token: idToken(nonce: nil))
}

@MainActor @Test func aWrongIssuerIsRejected() async {
    await expectFailure(.wrongIssuer, token: idToken(issuer: "https://evil.example.com"))
    await expectFailure(.wrongIssuer, token: idToken(issuer: "https://auth.openai.com/"))
    await expectFailure(.wrongIssuer, callbackURL: callback(extra: [URLQueryItem(name: "iss", value: "https://evil.example.com")]))
}

@MainActor @Test func aWrongAudienceIsRejected() async {
    await expectFailure(.wrongAudience, token: idToken(audience: "another-client"))
    await expectFailure(.wrongAudience, token: idToken(audience: [clientID, "another-client"]))
    await expectFailure(.wrongAudience, token: idToken(audience: clientID, azp: "another-client"))
    let (authorizer, _) = authorizer([(200, tokenJSON(idToken: idToken(audience: [clientID, "api"], azp: clientID)))])
    await #expect(throws: Never.self) { try await authorizer.complete(callback: callback()) }
}

@MainActor @Test func missingScopesAreRejected() async {
    await expectFailure(.missingScopes, scope: "openid email")
    await expectFailure(.missingScopes, scope: "openid profile email")
    // No `scope` in the response means the requested scopes (RFC 6749 5.1).
    let (authorizer, _) = authorizer([(200, tokenJSON(scope: nil))])
    let session = try? await authorizer.complete(callback: callback())
    #expect(session?.scopes == ChatGPTAuthConfiguration.openAI.scopes)
}

@MainActor @Test func anExpiredOrFutureIDTokenIsRejected() async {
    await expectFailure(.expiredToken, token: idToken(expires: now.addingTimeInterval(-120)))
    await expectFailure(.expiredToken, token: idToken(issued: now.addingTimeInterval(600)))
}

@MainActor @Test func aMalformedTokenResponseIsRejected() async {
    await expectFailure(.malformedResponse, token: idToken(algorithm: "none"))
    await expectFailure(.malformedResponse, token: "not.a-token")
    await expectFailure(.malformedResponse, token: idToken(audience: 7))
    let (noID, _) = authorizer([(200, tokenJSON(idToken: nil))])
    await #expect(throws: ChatGPTAuthError.malformedResponse) { try await noID.complete(callback: callback()) }
    let (noCode, _) = authorizer([(200, tokenJSON())])
    await #expect(throws: ChatGPTAuthError.malformedResponse) { try await noCode.complete(callback: callback(code: nil)) }
}

@MainActor @Test func aReplayedCallbackIsRejected() async throws {
    let (authorizer, transport) = authorizer([(200, tokenJSON()), (200, tokenJSON())])
    _ = try await authorizer.complete(callback: callback())
    await #expect(throws: ChatGPTAuthError.replayed) { try await authorizer.complete(callback: callback()) }
    #expect(transport.requests.count == 1)
    // The callback of a cancelled sign-in is a replay too, also while a new sign-in waits.
    let (second, secondTransport) = ChatGPTAuthorizerPair.make()
    second.expect(second.makeRequest(clientID: clientID, redirectURI: redirect, state: "first", nonce: nonce, codeVerifier: verifier))
    second.cancel()
    await #expect(throws: ChatGPTAuthError.replayed) { try await second.complete(callback: callback(state: "first")) }
    second.expect(second.makeRequest(clientID: clientID, redirectURI: redirect, state: "second", nonce: nonce, codeVerifier: verifier))
    await #expect(throws: ChatGPTAuthError.replayed) { try await second.complete(callback: callback(state: "first")) }
    #expect(secondTransport.requests.isEmpty)
}

@MainActor @Test func aFailedExchangeUsesUpTheCallback() async {
    let (authorizer, transport) = authorizer([(400, #"{"error":"invalid_grant"}"#), (200, tokenJSON())])
    await #expect(throws: ChatGPTAuthError.refused("invalid_grant")) { try await authorizer.complete(callback: callback()) }
    await #expect(throws: ChatGPTAuthError.replayed) { try await authorizer.complete(callback: callback()) }
    #expect(transport.requests.count == 1)
}

@MainActor @Test func aCallbackOnAnotherPortOrPathIsRejected() async {
    await expectFailure(.wrongRedirect, callbackURL: callback(base: URL(string: "http://127.0.0.1:9999/auth/callback")!))
    await expectFailure(.wrongRedirect, callbackURL: callback(base: URL(string: "http://127.0.0.1:53682/other")!))
    await expectFailure(.wrongRedirect, callbackURL: callback(base: URL(string: "http://localhost:53682/auth/callback")!))
}

@MainActor @Test func aRefusedSignInDoesNotFinish() async {
    let (authorizer, transport) = authorizer([])
    await #expect(throws: ChatGPTAuthError.refused("access_denied")) {
        try await authorizer.complete(callback: callback(code: nil, extra: [URLQueryItem(name: "error", value: "access_denied")]))
    }
    #expect(transport.requests.isEmpty)
}

@Test func failureTextsAreTheDesignTextsAndNeverHoldTokens() {
    #expect(ChatGPTAuthError.nonceMismatch.message == "OpenAI sent a response that Skillgarden can't verify.")
    #expect(ChatGPTAuthError.replayed.message == ChatGPTAuthError.unverifiedText)
    #expect(ChatGPTAuthError.refused("access_denied").message == "Sign-in did not finish. Try again.")
    #expect(ChatGPTAuthError.network.message == ChatGPTAuthError.notFinishedText)
    #expect(ChatGPTAuthError.httpStatus(500).message == ChatGPTAuthError.notFinishedText)
    #expect(ChatGPTAuthError.refused("invalid_grant").needsSignIn && !ChatGPTAuthError.network.needsSignIn)
    #expect(!ChatGPTAuthError.httpStatus(503).needsSignIn)
}

// MARK: Refresh

@MainActor @Test func refreshKeepsTheAccountAndSavesRotatedTokens() async throws {
    let (authorizer, transport) = authorizer([(200, tokenJSON()),
                                              (200, tokenJSON(idToken: idToken(nonce: nil), access: "access-2", refresh: "refresh-2")),
                                              (200, tokenJSON(idToken: nil, scope: nil, access: "access-3", refresh: nil))])
    let session = try await authorizer.complete(callback: callback())
    let refreshed = try await authorizer.refresh(session)
    #expect(refreshed.accessToken == "access-2" && refreshed.refreshToken == "refresh-2" && refreshed.subject == "user-1")
    #expect(form(transport.requests[1]) == ["grant_type": "refresh_token", "refresh_token": "refresh-secret-1", "client_id": clientID])
    // No new ID token and no new refresh token: the saved ones stay.
    let again = try await authorizer.refresh(refreshed)
    #expect(again.accessToken == "access-3" && again.refreshToken == "refresh-2" && again.idToken == refreshed.idToken)
    #expect(again.email == "learner@example.com")
}

@MainActor @Test func refreshRejectsAnotherAccountAndAWrongAudience() async throws {
    let (authorizer, _) = authorizer([(200, tokenJSON()), (200, tokenJSON(idToken: idToken(subject: "user-2", nonce: nil))),
                                      (200, tokenJSON(idToken: idToken(audience: "other", nonce: nil)))])
    let session = try await authorizer.complete(callback: callback())
    await #expect(throws: ChatGPTAuthError.wrongSubject) { try await authorizer.refresh(session) }
    await #expect(throws: ChatGPTAuthError.wrongAudience) { try await authorizer.refresh(session) }
    var noRefresh = session
    noRefresh.refreshToken = nil
    await #expect(throws: ChatGPTAuthError.refused("invalid_grant")) { try await authorizer.refresh(noRefresh) }
}

@MainActor
private enum ChatGPTAuthorizerPair {
    static func make(_ replies: [(Int, String)] = []) -> (ChatGPTAuthorizer, FakeAuthTransport) {
        let transport = FakeAuthTransport(replies)
        return (ChatGPTAuthorizer(transport: transport, now: { now }), transport)
    }
}

// MARK: Settings

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "ChatGPTAuthTests-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
private func signedInSession(expires: Date = now.addingTimeInterval(3600)) -> ChatGPTSession {
    ChatGPTSession(clientID: clientID, accessToken: "access-secret-1", refreshToken: "refresh-secret-1", idToken: idToken(nonce: nil),
                   expiresAt: expires, scopes: ChatGPTAuthConfiguration.openAI.scopes, subject: "user-1",
                   email: "learner@example.com", planType: "plus")
}

@MainActor @Test func aSignInSavesTokensInTheKeychainOnly() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ProviderSettingsStore(directory: root)
    let credentials = MemoryCredentialStore()
    let providers = ProviderSettings(store: store, credentials: credentials, adapterKinds: ShippedAdapters.kinds)
    let profile = ProviderProfile.chatGPTPlan()
    try providers.saveChatGPT(signedInSession(), profile: profile)
    let saved = try #require(providers.profiles.first)
    #expect(saved.kind == .subscription && saved.name == "ChatGPT Plan" && saved.credentialReference == profile.id)
    let text = try #require(try credentials.secret(account: profile.id))
    #expect(ChatGPTSession(keychainText: text) == signedInSession())
    let file = try String(contentsOf: store.fileURL, encoding: .utf8)
    for secret in ["access-secret-1", "refresh-secret-1", "learner@example.com", "eyJ"] { #expect(!file.contains(secret)) }
    #expect(providers.caption(for: saved) == "learner@example.com · Subscription · Q&A not available yet")
    // A reload reads the account from the Keychain.
    let reloaded = ProviderSettings(store: store, credentials: credentials, adapterKinds: ShippedAdapters.kinds)
    reloaded.checkCredentials()
    #expect(reloaded.accounts[saved.id] == ChatGPTAccount(email: "learner@example.com", planType: "plus"))
    #expect(reloaded.expiredSessions.isEmpty)
    // A sign-in again keeps one profile.
    try reloaded.saveChatGPT(signedInSession(), profile: ChatGPTSignIn(providers: reloaded, browser: nil).profile)
    #expect(reloaded.profiles.count == 1)
}

@MainActor @Test func disconnectRemovesTheKeychainItemAndTheProfileReference() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ProviderSettingsStore(directory: root)
    let credentials = MemoryCredentialStore()
    let providers = ProviderSettings(store: store, credentials: credentials)
    let profile = ProviderProfile.chatGPTPlan()
    try providers.saveChatGPT(signedInSession(), profile: profile)
    try providers.allow(courseID: "sample-course", destination: profile.destination)
    try providers.disconnect(profile.id)
    #expect(try credentials.secret(account: profile.id) == nil)
    #expect(providers.profiles.isEmpty && providers.consents.isEmpty && providers.accounts.isEmpty)
    #expect(ProviderSettings(store: store, credentials: credentials).profiles.isEmpty)
    // A refused Keychain keeps the profile.
    let denied = ProviderSettings(store: nil, credentials: MemoryCredentialStore(deniedAccounts: ["chatgpt"]),
                                  profiles: [ProviderProfile(id: "chatgpt", kind: .subscription, name: "ChatGPT Plan", vendor: "OpenAI",
                                                             origin: "https://api.openai.com", modelID: "", credentialReference: "chatgpt")])
    #expect(throws: ProviderSettings.Problem.credential(.denied)) { try denied.disconnect("chatgpt") }
    #expect(denied.profiles.count == 1)
}

@MainActor @Test func qaStaysOffForASubscriptionUntilItsAdapterShips() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ProviderSettingsStore(directory: root)
    let profile = ProviderProfile(id: "chatgpt", kind: .subscription, name: "ChatGPT Plan", vendor: "OpenAI",
                                  origin: "https://api.openai.com", modelID: "", credentialReference: "chatgpt")
    try store.save(SavedProviders(selectedID: "chatgpt", profiles: [profile]))
    let providers = ProviderSettings(store: store, credentials: MemoryCredentialStore(), adapterKinds: ShippedAdapters.kinds)
    #expect(!ShippedAdapters.kinds.contains(.subscription))
    #expect(providers.selectedID == BundledAnswerProvider.providerID)
    #expect(!providers.canAnswer(.subscription) && providers.canAnswer(.api))
    providers.select("chatgpt")
    #expect(providers.selectedID == BundledAnswerProvider.providerID && providers.selected == nil)
    #expect(ShippedAdapters.provider(for: profile, credentials: MemoryCredentialStore()) == nil)
    // The paired inference issue (#157) adds the kind. Then the choice works.
    let later = ProviderSettings(store: store, credentials: MemoryCredentialStore(), adapterKinds: [.subscription])
    #expect(later.selectedID == "chatgpt")
    #expect(later.caption(for: profile) == "ChatGPT account · Subscription")
}

@MainActor @Test func providerFilesSavedBeforeChatGPTSignInStillLoad() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ProviderSettingsStore(directory: root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("""
    {"version": 1, "selectedID": "openai",
     "profiles": [{"id": "openai", "kind": "api", "name": "OpenAI API", "vendor": "OpenAI", "origin": "https://api.openai.com",
                   "modelID": "gpt-5", "credentialReference": "openai"},
                  {"id": "sub", "kind": "subscription", "name": "Plan", "origin": "https://example.com", "modelID": "m"}],
     "consents": []}
    """.utf8).write(to: store.fileURL)
    let providers = ProviderSettings(store: store, credentials: MemoryCredentialStore(secrets: ["openai": "sk-1"]),
                                     adapterKinds: ShippedAdapters.kinds)
    #expect(providers.profiles.map(\.id) == ["openai", "sub"] && providers.selectedID == "openai")
    providers.checkCredentials()
    #expect(providers.problems.isEmpty && providers.expiredSessions.isEmpty)
    // A subscription of another vendor is not a ChatGPT plan, so it keeps the plain caption.
    #expect(!providers.profiles[1].isChatGPTPlan)
}

@MainActor @Test func anExpiredSessionRefreshesAndSavesTheNewTokens() async throws {
    let credentials = MemoryCredentialStore()
    let transport = FakeAuthTransport([(200, tokenJSON(idToken: idToken(nonce: nil), access: "access-2", refresh: "refresh-2"))])
    let providers = ProviderSettings(store: nil, credentials: credentials, chatGPT: ChatGPTAuthorizer(transport: transport, now: { now }))
    let profile = ProviderProfile.chatGPTPlan()
    try providers.saveChatGPT(signedInSession(expires: now.addingTimeInterval(30)), profile: profile)
    await providers.refreshChatGPTSessions(now: now)
    let saved = try #require(try credentials.secret(account: profile.id).flatMap(ChatGPTSession.init(keychainText:)))
    #expect(saved.accessToken == "access-2" && saved.refreshToken == "refresh-2")
    #expect(providers.expiredSessions.isEmpty)
    // A valid session sends no request.
    _ = try await providers.chatGPTSession(for: profile.id, now: now)
    #expect(transport.requests.count == 1)
}

@MainActor @Test func aSessionThatCantRefreshShowsSignInAgain() async throws {
    let transport = FakeAuthTransport([(400, #"{"error":"invalid_grant"}"#), (200, tokenJSON(idToken: idToken(nonce: nil)))])
    let providers = ProviderSettings(store: nil, credentials: MemoryCredentialStore(),
                                     chatGPT: ChatGPTAuthorizer(transport: transport, now: { now }))
    let profile = ProviderProfile.chatGPTPlan()
    try providers.saveChatGPT(signedInSession(expires: now.addingTimeInterval(-10)), profile: profile)
    await providers.refreshChatGPTSessions(now: now)
    #expect(providers.expiredSessions == [profile.id])
    // A sign-in again clears it.
    try providers.saveChatGPT(signedInSession(), profile: profile)
    #expect(providers.expiredSessions.isEmpty)
    // A network failure does not ask for a sign-in.
    let offline = ProviderSettings(store: nil, credentials: MemoryCredentialStore(),
                                   chatGPT: ChatGPTAuthorizer(transport: FakeAuthTransport([]), now: { now }))
    try offline.saveChatGPT(signedInSession(expires: now), profile: profile)
    await #expect(throws: ChatGPTAuthError.network) { try await offline.chatGPTSession(for: profile.id, now: now) }
    #expect(offline.expiredSessions.isEmpty)
    // A Keychain item that is not a session asks for a sign-in.
    let broken = ProviderSettings(store: nil, credentials: MemoryCredentialStore(secrets: [profile.id: "not json"]),
                                  profiles: [{ var copy = profile; copy.credentialReference = profile.id; return copy }()])
    broken.checkCredentials()
    #expect(broken.expiredSessions == [profile.id])
}

// MARK: Sheet

@MainActor
private final class FakeBrowser: ChatGPTBrowser {
    var result: Result<URL, ChatGPTAuthError>
    private(set) var opened: [URL] = []
    private(set) var stops = 0

    init(_ result: Result<URL, ChatGPTAuthError>) { self.result = result }

    func listen() async throws(ChatGPTAuthError) -> URL { redirect }

    func signIn(at url: URL) async throws(ChatGPTAuthError) -> URL {
        opened.append(url)
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value
        switch result {
        case .success(let base): return callback(state: state, base: base)
        case .failure(let error): throw error
        }
    }

    func stop() { stops += 1 }
}

@MainActor
private func until(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(2)) }
}

/// A token response whose ID token carries the nonce of the sign-in that the browser opened.
@MainActor
private func signInProviders(browser: FakeBrowser, tokenNonce: @escaping @Sendable (String) -> String?) -> (ProviderSettings, FakeAuthTransport) {
    final class Box: @unchecked Sendable { var browser: FakeBrowser? }
    let box = Box()
    box.browser = browser
    let transport = FakeAuthTransport { request in
        if request.url?.path == "/oauth/register" { return (201, #"{"client_id":"client-123"}"#) }
        let opened = MainActor.assumeIsolated { box.browser?.opened.last }
        let sent = opened.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "nonce" }?.value }
        return (200, tokenJSON(idToken: idToken(nonce: tokenNonce(sent ?? ""))))
    }
    let providers = ProviderSettings(store: nil, credentials: MemoryCredentialStore(),
                                     chatGPT: ChatGPTAuthorizer(transport: transport, now: { now }))
    return (providers, transport)
}

@MainActor @Test func theSheetSignsInAndSavesOnlyAfterTheChecksPass() async throws {
    let browser = FakeBrowser(.success(redirect))
    let (providers, _) = signInProviders(browser: browser) { $0 }
    let signIn = ChatGPTSignIn(providers: providers, browser: browser)
    #expect(signIn.state == .signedOut && signIn.state.announcement == nil)
    signIn.start()
    #expect(signIn.state == .waiting && signIn.state.announcement == "Waiting for sign-in")
    try await until { signIn.state != .waiting }
    #expect(signIn.state == .signedIn(ChatGPTAccount(email: "learner@example.com", planType: "plus")))
    #expect(signIn.state.announcement == "Signed in")
    #expect(providers.profiles.map(\.name) == ["ChatGPT Plan"] && browser.stops >= 1)
}

@MainActor @Test func theSheetShowsTheVerifyFailureAndSavesNothing() async throws {
    let browser = FakeBrowser(.success(redirect))
    let (providers, _) = signInProviders(browser: browser) { _ in "nonce-of-an-attacker" }
    let signIn = ChatGPTSignIn(providers: providers, browser: browser)
    signIn.start()
    try await until { signIn.state != .waiting }
    #expect(signIn.state == .failed("OpenAI sent a response that Skillgarden can't verify."))
    #expect(providers.profiles.isEmpty)
}

@MainActor @Test func cancelInTheSystemSheetReturnsToSignedOutWithNoError() async throws {
    let browser = FakeBrowser(.failure(.canceled))
    let (providers, _) = signInProviders(browser: browser) { $0 }
    let signIn = ChatGPTSignIn(providers: providers, browser: browser)
    signIn.start()
    try await until { signIn.state != .waiting }
    #expect(signIn.state == .signedOut && providers.profiles.isEmpty)
    browser.result = .failure(.network)
    signIn.start()
    try await until { signIn.state != .waiting }
    #expect(signIn.state == .failed("Sign-in did not finish. Try again."))
}

// MARK: Loopback listener

@Test func theListenerAcceptsOnlyAGETOfTheCallbackPath() {
    let listener = LoopbackCallbackListener()
    func head(_ line: String) -> Data { Data("\(line)\r\nHost: 127.0.0.1\r\n\r\n".utf8) }
    #expect(listener.callbackURL(requestHead: head("GET /auth/callback?code=a&state=b HTTP/1.1"), port: 4000)?.absoluteString
        == "http://127.0.0.1:4000/auth/callback?code=a&state=b")
    #expect(listener.callbackURL(requestHead: head("GET /favicon.ico HTTP/1.1"), port: 4000) == nil)
    #expect(listener.callbackURL(requestHead: head("POST /auth/callback?code=a HTTP/1.1"), port: 4000) == nil)
    #expect(listener.callbackURL(requestHead: head("GET http://evil.example.com/auth/callback HTTP/1.1"), port: 4000) == nil)
    #expect(listener.callbackURL(requestHead: head("GET /auth/callback HTTP/1.1"), port: nil) == nil)
}

@Test func theListenerGivesTheCallbackOfALoopbackRequest() async throws {
    let listener = LoopbackCallbackListener()
    defer { listener.stop() }
    let redirectURI = try await listener.start()
    #expect(redirectURI.host == "127.0.0.1" && redirectURI.path == "/auth/callback" && (redirectURI.port ?? 0) > 0)
    let target = URL(string: redirectURI.absoluteString + "?code=c&state=s")!
    let (body, response) = try await URLSession(configuration: .ephemeral).data(from: target)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(String(decoding: body, as: UTF8.self).contains("Sign-in finished."))
    var iterator = listener.callbacks.makeAsyncIterator()
    #expect(await iterator.next() == target)
}
