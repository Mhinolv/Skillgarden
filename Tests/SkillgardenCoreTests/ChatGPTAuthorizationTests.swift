import Foundation
import Security
import Testing
@testable import SkillgardenCore

// Sign in with ChatGPT (#156). Every test runs offline: a fake transport, a fixed clock and fixture ID tokens that a test
// RSA key signs. The fake transport serves the public key as the OpenAI JWKS.

/// The RSA key of the fixture ID tokens.
nonisolated(unsafe) private let signingKey: SecKey = {
    let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
    return SecKeyCreateRandomKey(attributes as CFDictionary, nil)!
}()

/// The JWKS of `signingKey`, with the key ID `test-key`.
private let jwksJSON: String = {
    // PKCS #1 RSAPublicKey: SEQUENCE { INTEGER modulus, INTEGER exponent }.
    let der = [UInt8](SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(signingKey)!, nil)! as Data)
    var index = 0
    func length() -> Int {
        let first = der[index]
        index += 1
        guard first & 0x80 != 0 else { return Int(first) }
        var count = 0
        for _ in 0..<Int(first & 0x7F) {
            count = count << 8 | Int(der[index])
            index += 1
        }
        return count
    }
    func integer() -> Data {
        index += 1
        let count = length()
        defer { index += count }
        return Data(der[index..<index + count].drop { $0 == 0 })
    }
    index += 1
    _ = length()
    let modulus = integer()
    let exponent = integer()
    let key: [String: Any] = ["kty": "RSA", "kid": "test-key", "alg": "RS256", "use": "sig", "n": PKCE.base64URL(modulus),
                              "e": PKCE.base64URL(exponent)]
    return String(decoding: try! JSONSerialization.data(withJSONObject: ["keys": [key]]), as: UTF8.self)
}()

/// Answers each request with the next scripted status and JSON body, or with the reply of `respond`, and records the requests.
/// A GET of the JWKS gets `jwks` and is counted in `keyFetches`, not in `requests`. With no reply left, the request fails as offline.
private final class FakeAuthTransport: LlamaTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [(Int, String)]
    private let respond: (@Sendable (URLRequest) -> (Int, String))?
    private var sent: [URLRequest] = []
    private var fetches = 0
    /// Nil makes the JWKS offline.
    var jwks: String? = jwksJSON

    init(_ replies: [(Int, String)]) {
        self.replies = replies
        respond = nil
    }

    init(respond: @escaping @Sendable (URLRequest) -> (Int, String)) {
        replies = []
        self.respond = respond
    }

    var requests: [URLRequest] { lock.withLock { sent } }
    var keyFetches: Int { lock.withLock { fetches } }

    func send(_ request: URLRequest) -> AsyncThrowingStream<LlamaTransportEvent, any Error> {
        let reply: (Int, String)?
        if request.url == ChatGPTAuthConfiguration.openAI.keysEndpoint {
            reply = lock.withLock {
                fetches += 1
                return jwks.map { (200, $0) }
            }
        } else {
            reply = lock.withLock {
                sent.append(request)
                return replies.isEmpty ? nil : replies.removeFirst()
            } ?? respond?(request)
        }
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
/// The issued client ID of the first sign-in callback.
private let clientID = "oaiapp_test123"
private let hostID = "urn:uuid:3f2504e0-4f89-11d3-9a0c-0305e82c3301"
private let state = "state-abc"
private let nonce = "nonce-xyz"
private let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
private let grantedScope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"

private func base64URL(_ object: [String: Any]) -> String {
    PKCE.base64URL(try! JSONSerialization.data(withJSONObject: object, options: .sortedKeys))
}

/// A fixture ID token that `key` signs. Each argument overrides one claim or header value. `nil` leaves it out.
private func idToken(issuer: String = "https://auth.openai.com", audience: Any = clientID, azp: String? = nil,
                     subject: String = "user-1", expires: Date = now.addingTimeInterval(3600), issued: Date = now,
                     nonce tokenNonce: String? = nonce, email: String? = "learner@example.com", plan: String? = "plus",
                     algorithm: String = "RS256", keyID: String? = "test-key", key: SecKey = signingKey) -> String {
    var claims: [String: Any] = ["iss": issuer, "aud": audience, "sub": subject, "exp": expires.timeIntervalSince1970,
                                 "iat": issued.timeIntervalSince1970]
    if let azp { claims["azp"] = azp }
    if let tokenNonce { claims["nonce"] = tokenNonce }
    if let email { claims["email"] = email }
    if let plan { claims[ChatGPTIDToken.authClaim] = ["chatgpt_plan_type": plan] }
    var header: [String: Any] = ["alg": algorithm, "typ": "JWT"]
    if let keyID { header["kid"] = keyID }
    let input = base64URL(header) + "." + base64URL(claims)
    let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, nil)! as Data
    return input + "." + PKCE.base64URL(signature)
}

private func tokenJSON(idToken: String? = idToken(), scope: String? = grantedScope,
                       access: String = "access-secret-1", refresh: String? = "refresh-secret-1") -> String {
    var object: [String: Any] = ["access_token": access, "token_type": "Bearer", "expires_in": 3600]
    if let idToken { object["id_token"] = idToken }
    if let scope { object["scope"] = scope }
    if let refresh { object["refresh_token"] = refresh }
    return String(decoding: try! JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
}

/// A success callback of SIWC: `code`, `scope`, `state` and the issued `client_id`. `nil` leaves a parameter out.
private func callback(code: String? = "code-1", state callbackState: String? = state, client: String? = clientID,
                      scope: String? = grantedScope, extra: [URLQueryItem] = [], base: URL = redirect) -> URL {
    var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
    components.queryItems = [code.map { URLQueryItem(name: "code", value: $0) },
                             scope.map { URLQueryItem(name: "scope", value: $0) },
                             callbackState.map { URLQueryItem(name: "state", value: $0) },
                             client.map { URLQueryItem(name: "client_id", value: $0) }].compactMap { $0 } + extra
    return components.url!
}

@MainActor
private func makeAuthorizer(_ transport: FakeAuthTransport,
                            hostIDs: any CredentialStore = MemoryCredentialStore()) -> ChatGPTAuthorizer {
    ChatGPTAuthorizer(transport: transport, hostIDs: hostIDs, now: { now })
}

/// An authorizer that waits for the callback of a first sign-in, or of a later sign-in of `issuedClientID`.
@MainActor
private func authorizer(_ replies: [(Int, String)], issuedClientID: String? = nil) -> (ChatGPTAuthorizer, FakeAuthTransport) {
    let transport = FakeAuthTransport(replies)
    let authorizer = makeAuthorizer(transport)
    authorizer.expect(authorizer.makeRequest(redirectURI: redirect, hostID: hostID, issuedClientID: issuedClientID, state: state,
                                             nonce: nonce, codeVerifier: verifier))
    return (authorizer, transport)
}

@MainActor
private func expectFailure(_ expected: ChatGPTAuthError, token: String? = nil, scope: String? = grantedScope,
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

private func query(_ url: URL) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
        .map { ($0.name, $0.value ?? "") })
}

// MARK: Request

@Test func pkceUsesS256WithTheRFC7636Vector() {
    #expect(PKCE.challenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    let random = PKCE.randomText(bytes: 64)
    #expect(random.count == 86 && !random.contains("=") && !random.contains("+") && !random.contains("/"))
    #expect(PKCE.randomText(bytes: 32) != PKCE.randomText(bytes: 32))
}

@Test func theConfigurationUsesTheSIWCEndpoints() {
    let openAI = ChatGPTAuthConfiguration.openAI
    #expect(openAI.authorizationEndpoint.absoluteString == "https://auth.openai.com/api/accounts/authorize")
    #expect(openAI.tokenEndpoint.absoluteString == "https://auth.openai.com/api/accounts/oauth/token")
    #expect(openAI.keysEndpoint.absoluteString == "https://auth.openai.com/.well-known/jwks.json")
    #expect(openAI.issuer == "https://auth.openai.com" && openAI.resource == "https://api.openai.com/v1")
    #expect(openAI.scopes.joined(separator: " ") == grantedScope)
    #expect(openAI.requiredScopes == ["chatgpt.tokens.use.direct"])
}

@MainActor @Test func aFirstSignInRegistersThroughTheAuthorizeRequestAndSendsNoRequest() throws {
    let transport = FakeAuthTransport([(201, #"{"client_id":"from-a-register-endpoint"}"#)])
    let hostIDs = MemoryCredentialStore()
    let request = try makeAuthorizer(transport, hostIDs: hostIDs).begin(redirectURI: redirect)
    // No registration POST and no other request: SIWC has no registration endpoint.
    #expect(transport.requests.isEmpty && transport.keyFetches == 0)
    #expect(request.url.host == "auth.openai.com" && request.url.path == "/api/accounts/authorize")
    let items = query(request.url)
    #expect(items["client_id"] == "dynamic_agent_client" && request.clientID == "dynamic_agent_client")
    #expect(request.issuedClientID == nil)
    #expect(items["agent_name_hint"] == "Skillgarden")
    let host = try #require(items["ext_agent_host_id"])
    #expect(host.hasPrefix("urn:uuid:") && UUID(uuidString: String(host.dropFirst(9))) != nil)
    #expect(try hostIDs.secret(account: ChatGPTAuthorizer.hostIDAccount) == host)
    #expect(items["response_type"] == "code" && items["redirect_uri"] == redirect.absoluteString)
    #expect(items["scope"] == grantedScope)
    #expect(items["resource"] == "https://api.openai.com/v1")
    #expect(items["code_challenge_method"] == "S256")
    #expect(items["code_challenge"] == PKCE.challenge(for: request.codeVerifier))
    #expect(items["state"] == request.state && items["nonce"] == request.nonce)
    #expect(items["id_token_hint"] == nil && items["client_secret"] == nil)
    #expect(request.state.count >= 43 && request.nonce.count >= 43 && request.codeVerifier.count >= 43)
    // Each value is percent-encoded.
    let raw = try #require(request.url.query)
    #expect(raw.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A53682%2Fauth%2Fcallback"))
    #expect(raw.contains("resource=https%3A%2F%2Fapi.openai.com%2Fv1") && raw.contains("scope=openid%20profile"))
}

@MainActor @Test func theHostIDStaysTheSameAcrossSignIns() throws {
    let hostIDs = MemoryCredentialStore()
    let first = try makeAuthorizer(FakeAuthTransport([]), hostIDs: hostIDs).begin(redirectURI: redirect)
    let second = try makeAuthorizer(FakeAuthTransport([]), hostIDs: hostIDs).begin(redirectURI: redirect,
                                                                                  previous: signedInSession())
    #expect(first.hostID == second.hostID && query(second.url)["ext_agent_host_id"] == first.hostID)
    #expect(first.state != second.state)
    // Another Mac gets another host ID.
    let other = try makeAuthorizer(FakeAuthTransport([])).begin(redirectURI: redirect)
    #expect(other.hostID != first.hostID)
    // A refused Keychain stops the sign-in before the browser opens.
    let denied = makeAuthorizer(FakeAuthTransport([]),
                                hostIDs: MemoryCredentialStore(deniedAccounts: [ChatGPTAuthorizer.hostIDAccount]))
    #expect(throws: ChatGPTAuthError.credential(.denied)) { try denied.begin(redirectURI: redirect) }
}

@MainActor @Test func aLaterSignInUsesTheSavedIssuedClientID() throws {
    let request = try makeAuthorizer(FakeAuthTransport([])).begin(redirectURI: redirect, previous: signedInSession())
    let items = query(request.url)
    #expect(items["client_id"] == clientID && request.issuedClientID == clientID)
    #expect(items["agent_name_hint"] == nil && items["resource"] == "https://api.openai.com/v1")
}

// MARK: Complete

@MainActor @Test func signInCompletesWhenEveryCheckPasses() async throws {
    let (authorizer, transport) = authorizer([(200, tokenJSON())])
    let session = try await authorizer.complete(callback: callback(extra: [URLQueryItem(name: "iss", value: "https://auth.openai.com")]))
    #expect(session.clientID == clientID && session.accessToken == "access-secret-1" && session.refreshToken == "refresh-secret-1")
    #expect(session.email == "learner@example.com" && session.subject == "user-1")
    #expect(session.account.planName == "ChatGPT Plus")
    #expect(session.expiresAt == now.addingTimeInterval(3600) && session.scopes.contains("chatgpt.tokens.use.direct"))
    #expect(transport.requests.count == 1 && transport.keyFetches == 1)
    let exchange = try #require(transport.requests.first)
    #expect(exchange.url?.absoluteString == "https://auth.openai.com/api/accounts/oauth/token" && exchange.httpMethod == "POST")
    #expect(exchange.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    #expect(form(exchange) == ["grant_type": "authorization_code", "code": "code-1", "redirect_uri": redirect.absoluteString,
                               "client_id": clientID, "code_verifier": verifier, "resource": "https://api.openai.com/v1"])
}

@MainActor @Test func aCallbackWithNoIssuerPasses() async throws {
    let (authorizer, _) = authorizer([(200, tokenJSON())])
    let session = try await authorizer.complete(callback: callback())
    #expect(session.clientID == clientID)
}

@MainActor @Test func theFirstSignInSavesTheIssuedClientIDFromTheCallback() async throws {
    let (issued, transport) = authorizer([(200, tokenJSON(idToken: idToken(audience: "oaiapp_new")))])
    let session = try await issued.complete(callback: callback(client: "oaiapp_new"))
    let exchange = try #require(transport.requests.first)
    #expect(session.clientID == "oaiapp_new" && form(exchange)["client_id"] == "oaiapp_new")
    // A callback with no issued client ID, or with the registration client ID, does not finish and sends nothing.
    await expectFailure(.malformedResponse, callbackURL: callback(client: nil))
    let (registration, registrationTransport) = authorizer([(200, tokenJSON())])
    await #expect(throws: ChatGPTAuthError.malformedResponse) {
        try await registration.complete(callback: callback(client: "dynamic_agent_client"))
    }
    #expect(registrationTransport.requests.isEmpty)
}

@MainActor @Test func aLaterSignInRejectsAnotherClientID() async throws {
    let (later, transport) = authorizer([(200, tokenJSON())], issuedClientID: clientID)
    await #expect(throws: ChatGPTAuthError.wrongClient) { try await later.complete(callback: callback(client: "oaiapp_other")) }
    #expect(transport.requests.isEmpty)
    #expect(ChatGPTAuthError.wrongClient.message == ChatGPTAuthError.unverifiedText)
    let (same, _) = authorizer([(200, tokenJSON())], issuedClientID: clientID)
    let session = try await same.complete(callback: callback(client: clientID))
    #expect(session.clientID == clientID)
}

@MainActor @Test func aCallbackWithAWrongOrMissingStateIsRejectedBeforeAnyRequest() async {
    let (authorizer, transport) = authorizer([(200, tokenJSON())])
    await #expect(throws: ChatGPTAuthError.stateMismatch) { try await authorizer.complete(callback: callback(state: "other")) }
    await #expect(throws: ChatGPTAuthError.stateMismatch) { try await authorizer.complete(callback: callback(state: nil)) }
    // The state check comes before the `error` check.
    await #expect(throws: ChatGPTAuthError.stateMismatch) {
        try await authorizer.complete(callback: callback(code: nil, state: "other", client: nil, scope: nil,
                                                         extra: [URLQueryItem(name: "error", value: "access_denied")]))
    }
    #expect(transport.requests.isEmpty)
}

@MainActor @Test func anAccessDeniedCallbackSendsNoTokenRequest() async {
    let (denied, transport) = authorizer([(200, tokenJSON())])
    await #expect(throws: ChatGPTAuthError.refused("access_denied")) {
        try await denied.complete(callback: callback(code: nil, client: nil, scope: nil,
                                                         extra: [URLQueryItem(name: "error", value: "access_denied")]))
    }
    #expect(transport.requests.isEmpty && transport.keyFetches == 0)
    // An `error` with a code sends no request either.
    let (withCode, withCodeTransport) = authorizer([(200, tokenJSON())])
    await #expect(throws: ChatGPTAuthError.refused("access_denied")) {
        try await withCode.complete(callback: callback(extra: [URLQueryItem(name: "error", value: "access_denied")]))
    }
    #expect(withCodeTransport.requests.isEmpty)
    #expect(ChatGPTAuthError.refused("access_denied").message == "Sign-in did not finish. Try again.")
}

@MainActor @Test func aSignInWithoutTheDirectTokenScopeIsRejected() async {
    // The callback scopes: rejected before the code exchange.
    let (callbackCheck, transport) = authorizer([(200, tokenJSON())])
    await #expect(throws: ChatGPTAuthError.missingScopes) {
        try await callbackCheck.complete(callback: callback(scope: "openid profile email offline_access resource.invoke"))
    }
    #expect(transport.requests.isEmpty)
    // The token response scopes.
    await expectFailure(.missingScopes, scope: "openid email")
    await expectFailure(.missingScopes, scope: "openid profile email offline_access resource.invoke")
    // No `scope` in the callback or the response means the requested scopes (RFC 6749 5.1).
    let (noScope, _) = authorizer([(200, tokenJSON(scope: nil))])
    let session = try? await noScope.complete(callback: callback(scope: nil))
    #expect(session?.scopes == ChatGPTAuthConfiguration.openAI.scopes)
    // The callback scopes stand when the response has none.
    await expectFailure(.missingScopes, scope: nil, callbackURL: callback(scope: "openid"))
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
    await expectFailure(.wrongAudience, token: idToken(audience: "dynamic_agent_client"))
    await expectFailure(.wrongAudience, token: idToken(audience: [clientID, "another-client"]))
    await expectFailure(.wrongAudience, token: idToken(audience: clientID, azp: "another-client"))
    let (authorizer, _) = authorizer([(200, tokenJSON(idToken: idToken(audience: [clientID, "api"], azp: clientID)))])
    await #expect(throws: Never.self) { try await authorizer.complete(callback: callback()) }
}

@MainActor @Test func anExpiredOrFutureIDTokenIsRejected() async {
    await expectFailure(.expiredToken, token: idToken(expires: now.addingTimeInterval(-120)))
    await expectFailure(.expiredToken, token: idToken(issued: now.addingTimeInterval(600)))
}

@MainActor @Test func anIDTokenWithABadSignatureIsRejected() async throws {
    // Claims of one token with the signature of another.
    let valid = idToken().split(separator: ".")
    let other = idToken(subject: "user-2").split(separator: ".")
    await expectFailure(.badSignature, token: "\(valid[0]).\(other[1]).\(valid[2])")
    // A key that is not in the JWKS.
    let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
    let stranger = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
    await expectFailure(.badSignature, token: idToken(key: stranger))
    // An unknown key ID loads the keys one more time, then fails.
    let (rotated, transport) = authorizer([(200, tokenJSON(idToken: idToken(keyID: "rotated")))])
    await #expect(throws: ChatGPTAuthError.badSignature) { try await rotated.complete(callback: callback()) }
    #expect(transport.keyFetches == 1)
    // No key ID uses the one key of the JWKS.
    let (noKeyID, _) = authorizer([(200, tokenJSON(idToken: idToken(keyID: nil)))])
    await #expect(throws: Never.self) { try await noKeyID.complete(callback: callback()) }
    // An unreachable JWKS does not finish.
    let (offline, offlineTransport) = authorizer([(200, tokenJSON())])
    offlineTransport.jwks = nil
    await #expect(throws: ChatGPTAuthError.network) { try await offline.complete(callback: callback()) }
}

@MainActor @Test func theSigningKeysLoadOnce() async throws {
    let (authorizer, transport) = authorizer([(200, tokenJSON()), (200, tokenJSON(idToken: idToken(nonce: nil)))])
    let session = try await authorizer.complete(callback: callback())
    _ = try await authorizer.refresh(session)
    #expect(transport.keyFetches == 1)
}

@MainActor @Test func aMalformedTokenResponseIsRejected() async {
    await expectFailure(.malformedResponse, token: idToken(algorithm: "none"))
    await expectFailure(.malformedResponse, token: idToken(algorithm: "HS256"))
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
    let secondTransport = FakeAuthTransport([])
    let second = makeAuthorizer(secondTransport)
    second.expect(second.makeRequest(redirectURI: redirect, hostID: hostID, issuedClientID: nil, state: "first", nonce: nonce,
                                     codeVerifier: verifier))
    second.cancel()
    await #expect(throws: ChatGPTAuthError.replayed) { try await second.complete(callback: callback(state: "first")) }
    second.expect(second.makeRequest(redirectURI: redirect, hostID: hostID, issuedClientID: nil, state: "second", nonce: nonce,
                                     codeVerifier: verifier))
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

@Test func failureTextsAreTheDesignTextsAndNeverHoldTokens() {
    #expect(ChatGPTAuthError.nonceMismatch.message == "OpenAI sent a response that Skillgarden can't verify.")
    #expect(ChatGPTAuthError.replayed.message == ChatGPTAuthError.unverifiedText)
    #expect(ChatGPTAuthError.badSignature.message == ChatGPTAuthError.unverifiedText)
    #expect(ChatGPTAuthError.refused("access_denied").message == "Sign-in did not finish. Try again.")
    #expect(ChatGPTAuthError.network.message == ChatGPTAuthError.notFinishedText)
    #expect(ChatGPTAuthError.httpStatus(500).message == ChatGPTAuthError.notFinishedText)
    #expect(ChatGPTAuthError.refused("invalid_grant").needsSignIn && !ChatGPTAuthError.network.needsSignIn)
    #expect(!ChatGPTAuthError.httpStatus(503).needsSignIn)
}

// MARK: Refresh

@MainActor @Test func refreshKeepsTheAccountAndSavesRotatedTokens() async throws {
    let (authorizer, transport) = authorizer([(200, tokenJSON()),
                                              (200, tokenJSON(idToken: idToken(nonce: nil), scope: "openid chatgpt.tokens.use.direct",
                                                              access: "access-2", refresh: "refresh-2")),
                                              (200, tokenJSON(idToken: nil, scope: nil, access: "access-3", refresh: nil)),
                                              (200, tokenJSON(idToken: nil, scope: "openid", access: "access-4"))])
    let session = try await authorizer.complete(callback: callback())
    let refreshed = try await authorizer.refresh(session)
    #expect(refreshed.accessToken == "access-2" && refreshed.refreshToken == "refresh-2" && refreshed.subject == "user-1")
    #expect(refreshed.scopes == ["openid", "chatgpt.tokens.use.direct"] && refreshed.clientID == clientID)
    #expect(transport.requests[1].url == ChatGPTAuthConfiguration.openAI.tokenEndpoint)
    #expect(form(transport.requests[1]) == ["grant_type": "refresh_token", "refresh_token": "refresh-secret-1", "client_id": clientID,
                                            "resource": "https://api.openai.com/v1"])
    // No new ID token and no new refresh token: the saved ones stay.
    let again = try await authorizer.refresh(refreshed)
    #expect(again.accessToken == "access-3" && again.refreshToken == "refresh-2" && again.idToken == refreshed.idToken)
    #expect(again.email == "learner@example.com" && again.scopes == refreshed.scopes)
    // A refresh that drops the direct token scope fails.
    await #expect(throws: ChatGPTAuthError.missingScopes) { try await authorizer.refresh(again) }
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

// MARK: Settings

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "ChatGPTAuthTests-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

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
    let session = signedInSession()
    try providers.saveChatGPT(session, profile: profile)
    let saved = try #require(providers.profiles.first)
    #expect(saved.kind == .subscription && saved.name == "ChatGPT Plan" && saved.credentialReference == profile.id)
    let text = try #require(try credentials.secret(account: profile.id))
    #expect(ChatGPTSession(keychainText: text) == session)
    #expect(providers.savedChatGPTSession(for: profile.id)?.clientID == clientID)
    let file = try String(contentsOf: store.fileURL, encoding: .utf8)
    for secret in ["access-secret-1", "refresh-secret-1", "learner@example.com", "eyJ", clientID] { #expect(!file.contains(secret)) }
    #expect(providers.caption(for: saved) == "learner@example.com · Subscription · Q&A not available yet")
    // A reload reads the account from the Keychain.
    let reloaded = ProviderSettings(store: store, credentials: credentials, adapterKinds: ShippedAdapters.kinds)
    reloaded.checkCredentials()
    #expect(reloaded.accounts[saved.id] == ChatGPTAccount(email: "learner@example.com", planType: "plus"))
    #expect(reloaded.expiredSessions.isEmpty)
    // A sign-in again keeps one profile.
    try reloaded.saveChatGPT(session, profile: ChatGPTSignIn(providers: reloaded, browser: nil).profile)
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
    #expect(providers.savedChatGPTSession(for: profile.id) == nil)
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
    let providers = ProviderSettings(store: nil, credentials: credentials, chatGPT: makeAuthorizer(transport))
    let profile = ProviderProfile.chatGPTPlan()
    try providers.saveChatGPT(signedInSession(expires: now.addingTimeInterval(30)), profile: profile)
    await providers.refreshChatGPTSessions(now: now)
    let saved = try #require(try credentials.secret(account: profile.id).flatMap(ChatGPTSession.init(keychainText:)))
    #expect(saved.accessToken == "access-2" && saved.refreshToken == "refresh-2" && saved.clientID == clientID)
    #expect(providers.expiredSessions.isEmpty)
    // A valid session sends no request.
    _ = try await providers.chatGPTSession(for: profile.id, now: now)
    #expect(transport.requests.count == 1)
}

@MainActor @Test func aSessionThatCantRefreshShowsSignInAgain() async throws {
    let credentials = MemoryCredentialStore()
    let transport = FakeAuthTransport([(400, #"{"error":"invalid_grant"}"#), (200, tokenJSON(idToken: idToken(nonce: nil)))])
    let providers = ProviderSettings(store: nil, credentials: credentials, chatGPT: makeAuthorizer(transport))
    let profile = ProviderProfile.chatGPTPlan()
    try providers.saveChatGPT(signedInSession(expires: now.addingTimeInterval(-10)), profile: profile)
    await providers.refreshChatGPTSessions(now: now)
    #expect(providers.expiredSessions == [profile.id])
    // `invalid_grant` discards the tokens. The issued client ID and the account stay for the next sign-in.
    let discarded = try #require(providers.savedChatGPTSession(for: profile.id))
    #expect(discarded.accessToken.isEmpty && discarded.refreshToken == nil && discarded.clientID == clientID)
    #expect(!discarded.canRefresh(at: now) && discarded.subject == "user-1")
    let text = try #require(try credentials.secret(account: profile.id))
    #expect(!text.contains("access-secret-1") && !text.contains("refresh-secret-1"))
    // A second refresh sends no request.
    await providers.refreshChatGPTSessions(now: now)
    #expect(transport.requests.count == 1)
    // A sign-in again clears it.
    try providers.saveChatGPT(signedInSession(), profile: profile)
    #expect(providers.expiredSessions.isEmpty)
    // A network failure does not ask for a sign-in and keeps the tokens.
    let offlineCredentials = MemoryCredentialStore()
    let offline = ProviderSettings(store: nil, credentials: offlineCredentials, chatGPT: makeAuthorizer(FakeAuthTransport([])))
    try offline.saveChatGPT(signedInSession(expires: now), profile: profile)
    await #expect(throws: ChatGPTAuthError.network) { try await offline.chatGPTSession(for: profile.id, now: now) }
    #expect(offline.expiredSessions.isEmpty && offline.savedChatGPTSession(for: profile.id)?.refreshToken == "refresh-secret-1")
    // A Keychain item that is not a session asks for a sign-in.
    let broken = ProviderSettings(store: nil, credentials: MemoryCredentialStore(secrets: [profile.id: "not json"]),
                                  profiles: [{ var copy = profile; copy.credentialReference = profile.id; return copy }()])
    broken.checkCredentials()
    #expect(broken.expiredSessions == [profile.id] && broken.savedChatGPTSession(for: profile.id) == nil)
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
        switch result {
        case .success(let base): return callback(state: query(url)["state"], base: base)
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
    let transport = FakeAuthTransport { _ in
        let opened = MainActor.assumeIsolated { box.browser?.opened.last }
        let sent = opened.flatMap { query($0)["nonce"] }
        return (200, tokenJSON(idToken: idToken(nonce: tokenNonce(sent ?? ""))))
    }
    let providers = ProviderSettings(store: nil, credentials: MemoryCredentialStore(), chatGPT: makeAuthorizer(transport))
    return (providers, transport)
}

@MainActor @Test func theSheetSignsInAndSavesOnlyAfterTheChecksPass() async throws {
    let browser = FakeBrowser(.success(redirect))
    let (providers, transport) = signInProviders(browser: browser) { $0 }
    let signIn = ChatGPTSignIn(providers: providers, browser: browser)
    #expect(signIn.state == .signedOut && signIn.state.announcement == nil)
    signIn.start()
    #expect(signIn.state == .waiting && signIn.state.announcement == "Waiting for sign-in")
    try await until { signIn.state != .waiting }
    #expect(signIn.state == .signedIn(ChatGPTAccount(email: "learner@example.com", planType: "plus")))
    #expect(signIn.state.announcement == "Signed in")
    #expect(providers.profiles.map(\.name) == ["ChatGPT Plan"] && browser.stops >= 1)
    // The only request is the code exchange: no registration request.
    #expect(transport.requests.map { $0.url } == [ChatGPTAuthConfiguration.openAI.tokenEndpoint])
    let first = try #require(browser.opened.first)
    #expect(query(first)["client_id"] == "dynamic_agent_client" && query(first)["agent_name_hint"] == "Skillgarden")
    #expect(providers.savedChatGPTSession(for: signIn.profile.id)?.clientID == clientID)
    // "Sign In…" again uses the saved issued client ID and the same host ID.
    let again = ChatGPTSignIn(providers: providers, browser: browser)
    again.start()
    try await until { again.state != .waiting }
    #expect(again.state == .signedIn(ChatGPTAccount(email: "learner@example.com", planType: "plus")))
    let second = try #require(browser.opened.last)
    #expect(query(second)["client_id"] == clientID && query(second)["agent_name_hint"] == nil)
    #expect(query(second)["ext_agent_host_id"] == query(first)["ext_agent_host_id"])
    #expect(providers.profiles.count == 1)
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

/// The owner crash of PR #202: AuthenticationServices calls the sheet completion on its XPC queue, not on the main queue.
@MainActor @Test func theSheetCompletionOnABackgroundQueueGivesCanceledOnTheMainActor() async {
    let (result, onMain) = await withCheckedContinuation {
        (continuation: CheckedContinuation<(Result<URL, ChatGPTAuthError>, Bool), Never>) in
        let completion = ChatGPTSheetCompletion.make { continuation.resume(returning: ($0, Thread.isMainThread)) }
        DispatchQueue(label: "com.skillgarden.tests.sheet-completion").async {
            completion(nil, NSError(domain: "com.apple.AuthenticationServices.WebAuthenticationSession", code: 1))
        }
    }
    #expect(result == .failure(.canceled) && onMain)
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
