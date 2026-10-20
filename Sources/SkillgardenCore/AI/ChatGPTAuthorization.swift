import CryptoKit
import Foundation
import Security

/// The OpenAI endpoints of Sign in with ChatGPT for a local app (#156): dynamic registration, PKCE and a loopback callback.
/// No client secret and no partner key. See `docs/research/v4-model-providers.md` for the SIWC terms.
public struct ChatGPTAuthConfiguration: Equatable, Sendable {
    /// The `iss` value of the ID token and of the callback.
    public var issuer: String
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var registrationEndpoint: URL
    /// The scopes that Skillgarden asks for. A sign-in fails when OpenAI grants fewer.
    public var scopes: [String]
    /// The name of the registered client. SIWC requires the real name of the app.
    public var clientName: String

    public init(issuer: String, authorizationEndpoint: URL, tokenEndpoint: URL, registrationEndpoint: URL, scopes: [String],
                clientName: String) {
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.registrationEndpoint = registrationEndpoint
        self.scopes = scopes
        self.clientName = clientName
    }

    public static let openAI = ChatGPTAuthConfiguration(
        issuer: "https://auth.openai.com",
        authorizationEndpoint: URL(string: "https://auth.openai.com/oauth/authorize")!,
        tokenEndpoint: URL(string: "https://auth.openai.com/oauth/token")!,
        registrationEndpoint: URL(string: "https://auth.openai.com/oauth/register")!,
        scopes: ["openid", "profile", "email", "offline_access"],
        clientName: "Skillgarden")
}

/// Why a ChatGPT sign-in or refresh failed (#156). No case holds a token.
public enum ChatGPTAuthError: Error, Equatable, Sendable {
    /// The learner closed the system sign-in sheet.
    case canceled
    /// The callback has no state or another state.
    case stateMismatch
    /// The callback came after its sign-in already finished.
    case replayed
    /// The callback is not the loopback redirect URI of the sign-in.
    case wrongRedirect
    case nonceMismatch
    case wrongIssuer
    case wrongAudience
    case missingScopes
    /// The ID token is expired, or its issue time is in the future.
    case expiredToken
    /// A refresh gave the ID token of another account.
    case wrongSubject
    /// A response that Skillgarden can't read.
    case malformedResponse
    /// OpenAI refused, with the OAuth `error` code, for example `access_denied` or `invalid_grant`.
    case refused(String)
    /// The service sent another HTTP status.
    case httpStatus(Int)
    /// The request did not reach OpenAI.
    case network
    /// The loopback listener can't start.
    case listenerFailed
    case credential(CredentialError)
    case saveFailed

    /// True when OpenAI sent something that does not pass the checks.
    public var isValidationFailure: Bool {
        switch self {
        case .stateMismatch, .replayed, .wrongRedirect, .nonceMismatch, .wrongIssuer, .wrongAudience, .missingScopes, .expiredToken,
             .wrongSubject, .malformedResponse: true
        default: false
        }
    }

    /// True when the saved session can't refresh, so the learner must sign in again.
    public var needsSignIn: Bool {
        switch self {
        case .refused, .httpStatus(400), .httpStatus(401): true
        default: isValidationFailure
        }
    }

    /// The reason of the Failed sheet. It never shows token text.
    public var message: String {
        switch self {
        case .credential(let error): error.message
        case .saveFailed: ProviderSettings.Problem.saveFailed.message
        default: isValidationFailure ? Self.unverifiedText : Self.notFinishedText
        }
    }

    public static let notFinishedText = "Sign-in did not finish. Try again."
    public static let unverifiedText = "OpenAI sent a response that Skillgarden can't verify."
}

/// One started sign-in (#156): the page to open and the values that the callback and the ID token must match.
public struct ChatGPTAuthorizationRequest: Equatable, Sendable {
    public let url: URL
    public let redirectURI: URL
    public let clientID: String
    let state: String
    let nonce: String
    let codeVerifier: String
}

/// PKCE with S256 (RFC 7636).
enum PKCE {
    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// `count` random bytes as base64url text. 32 bytes give 43 characters.
    static func randomText(bytes count: Int) -> String {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        precondition(status == errSecSuccess, "No random bytes")
        return base64URL(data)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func data(base64URL text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

/// The claims of an OpenAI ID token that Skillgarden checks (#156).
struct ChatGPTIDToken: Equatable {
    let issuer: String
    let audiences: [String]
    let authorizedParty: String?
    let subject: String
    let expiresAt: Date
    let issuedAt: Date?
    let nonce: String?
    let email: String?
    let planType: String?

    /// The claim of the OpenAI account data.
    static let authClaim = "https://api.openai.com/auth"

    /// Reads the payload of a JWT. The token comes straight from the token endpoint over TLS, so the TLS server check
    /// stands for the signature check (OpenID Connect Core 3.1.3.7). A token with `alg: none` is refused.
    init(jwt: String) throws(ChatGPTAuthError) {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let headerData = PKCE.data(base64URL: String(parts[0])),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let algorithm = header["alg"] as? String, algorithm.lowercased() != "none",
              let payloadData = PKCE.data(base64URL: String(parts[1])),
              let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let issuer = claims["iss"] as? String, let subject = claims["sub"] as? String, !subject.isEmpty,
              let expiry = (claims["exp"] as? NSNumber)?.doubleValue else { throw .malformedResponse }
        self.issuer = issuer
        switch claims["aud"] {
        case let audience as String: audiences = [audience]
        case let audience as [String]: audiences = audience
        default: throw .malformedResponse
        }
        authorizedParty = claims["azp"] as? String
        self.subject = subject
        expiresAt = Date(timeIntervalSince1970: expiry)
        issuedAt = (claims["iat"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        nonce = claims["nonce"] as? String
        email = claims["email"] as? String
        planType = (claims[Self.authClaim] as? [String: Any])?["chatgpt_plan_type"] as? String
    }

    /// Checks the issuer, the audience, the times and the nonce. `nonce` nil skips the nonce: a refresh has none.
    func validate(issuer expected: String, clientID: String, nonce expectedNonce: String?, now: Date,
                  leeway: TimeInterval = 60) throws(ChatGPTAuthError) {
        guard issuer == expected else { throw .wrongIssuer }
        guard audiences.contains(clientID) else { throw .wrongAudience }
        // Two or more audiences need an authorized party of this client.
        if audiences.count > 1 || authorizedParty != nil, authorizedParty != clientID { throw .wrongAudience }
        guard expiresAt.timeIntervalSince(now) > -leeway else { throw .expiredToken }
        if let issuedAt, issuedAt.timeIntervalSince(now) > leeway { throw .expiredToken }
        if let expectedNonce, nonce != expectedNonce { throw .nonceMismatch }
    }
}

/// The OAuth part of Sign in with ChatGPT (#156): dynamic registration, the authorization URL, the callback checks, the code
/// exchange and the refresh. Each sign-in accepts one callback only. A second callback, or a callback of an earlier sign-in,
/// fails as a replay. The transport and the clock are injected, so the tests run offline.
@MainActor
public final class ChatGPTAuthorizer {
    public let configuration: ChatGPTAuthConfiguration
    private let transport: any LlamaTransport
    private let now: @Sendable () -> Date
    private var pending: ChatGPTAuthorizationRequest?
    /// The states of finished or failed sign-ins.
    private var usedStates: Set<String> = []

    public init(configuration: ChatGPTAuthConfiguration = .openAI,
                transport: any LlamaTransport = LoopbackTransport(usesSystemProxy: true),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration
        self.transport = transport
        self.now = now
    }

    /// Registers a client for the loopback redirect URI and makes a new request with a new state, nonce and PKCE verifier.
    /// A new request replaces an unfinished one.
    public func begin(redirectURI: URL) async throws(ChatGPTAuthError) -> ChatGPTAuthorizationRequest {
        let clientID = try await register(redirectURI: redirectURI)
        let request = makeRequest(clientID: clientID, redirectURI: redirectURI)
        if let pending { usedStates.insert(pending.state) }
        pending = request
        return request
    }

    /// The request of a known client, with new random values.
    func makeRequest(clientID: String, redirectURI: URL, state: String = PKCE.randomText(bytes: 32),
                     nonce: String = PKCE.randomText(bytes: 32),
                     codeVerifier: String = PKCE.randomText(bytes: 64)) -> ChatGPTAuthorizationRequest {
        var components = URLComponents(url: configuration.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: codeVerifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return ChatGPTAuthorizationRequest(url: components.url!, redirectURI: redirectURI, clientID: clientID, state: state,
                                           nonce: nonce, codeVerifier: codeVerifier)
    }

    /// Starts `request` as the one sign-in that waits for a callback. Tests use it after `makeRequest`.
    func expect(_ request: ChatGPTAuthorizationRequest) {
        if let pending { usedStates.insert(pending.state) }
        pending = request
    }

    /// Ends the waiting sign-in. A later callback of it fails as a replay.
    public func cancel() {
        if let pending { usedStates.insert(pending.state) }
        pending = nil
    }

    /// Checks the loopback callback, exchanges the code and checks the ID token and the scopes.
    /// The sign-in completes only when every check passes. The request is used up before the exchange.
    public func complete(callback: URL) async throws(ChatGPTAuthError) -> ChatGPTSession {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let state = value("state")
        guard let request = pending else {
            throw state.map(usedStates.contains) == true ? .replayed : .stateMismatch
        }
        guard Self.sameEndpoint(callback, request.redirectURI) else { throw .wrongRedirect }
        guard let state else { throw .stateMismatch }
        guard state == request.state else {
            if usedStates.contains(state) { throw .replayed }
            throw .stateMismatch
        }
        pending = nil
        usedStates.insert(state)
        // RFC 9207: an `iss` parameter must name the issuer.
        if let issuer = value("iss"), issuer != configuration.issuer { throw .wrongIssuer }
        if let error = value("error") { throw .refused(error) }
        guard let code = value("code"), !code.isEmpty else { throw .malformedResponse }
        let response = try await tokenRequest([
            "grant_type": "authorization_code", "code": code, "redirect_uri": request.redirectURI.absoluteString,
            "client_id": request.clientID, "code_verifier": request.codeVerifier,
        ])
        return try session(from: response, clientID: request.clientID, nonce: request.nonce, previous: nil)
    }

    /// A new access token for `session`. OpenAI can send a new refresh token. The ID token must name the same account.
    public func refresh(_ session: ChatGPTSession) async throws(ChatGPTAuthError) -> ChatGPTSession {
        guard let refreshToken = session.refreshToken else { throw .refused("invalid_grant") }
        let response = try await tokenRequest([
            "grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": session.clientID,
        ])
        return try self.session(from: response, clientID: session.clientID, nonce: nil, previous: session)
    }

    /// The same scheme, host, port and path. The loopback listener gives the callback with its own host and port.
    static func sameEndpoint(_ callback: URL, _ redirect: URL) -> Bool {
        callback.scheme?.lowercased() == redirect.scheme?.lowercased() && callback.host == redirect.host
            && callback.port == redirect.port && callback.path == redirect.path
    }

    // MARK: Requests

    /// RFC 7591 registration of a public native client.
    private func register(redirectURI: URL) async throws(ChatGPTAuthError) -> String {
        let body: [String: Any] = [
            "client_name": configuration.clientName,
            "redirect_uris": [redirectURI.absoluteString],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
            "application_type": "native",
            "scope": configuration.scopes.joined(separator: " "),
        ]
        var request = URLRequest(url: configuration.registrationEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
        let json = try await send(request)
        guard let clientID = json["client_id"] as? String, !clientID.isEmpty else { throw .malformedResponse }
        return clientID
    }

    private func tokenRequest(_ fields: [String: String]) async throws(ChatGPTAuthError) -> [String: Any] {
        var request = URLRequest(url: configuration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.formBody(fields).utf8)
        return try await send(request)
    }

    static func formBody(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }

    /// Sends one request and reads a JSON object. An OAuth error body gives `.refused`. The body is read up to 1 MB.
    private func send(_ request: URLRequest) async throws(ChatGPTAuthError) -> [String: Any] {
        var status = 0
        var body = Data()
        do {
            for try await event in transport.send(request) {
                switch event {
                case .response(let code): status = code
                case .data(let data):
                    body.append(data)
                    if body.count > 1_000_000 { throw ChatGPTAuthError.malformedResponse }
                }
            }
        } catch let error as ChatGPTAuthError {
            throw error
        } catch {
            throw .network
        }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        guard (200..<300).contains(status) else {
            if let code = json?["error"] as? String, !code.isEmpty { throw .refused(code) }
            throw .httpStatus(status)
        }
        guard let json else { throw .malformedResponse }
        return json
    }

    /// The session of a token response, after the checks of the ID token and the scopes.
    private func session(from json: [String: Any], clientID: String, nonce: String?,
                         previous: ChatGPTSession?) throws(ChatGPTAuthError) -> ChatGPTSession {
        guard let accessToken = json["access_token"] as? String, !accessToken.isEmpty,
              (json["token_type"] as? String)?.lowercased() == "bearer" else { throw .malformedResponse }
        let date = now()
        // A refresh can leave out the ID token. Then the saved one stays.
        guard let idToken = json["id_token"] as? String ?? previous?.idToken else { throw .malformedResponse }
        let token = try ChatGPTIDToken(jwt: idToken)
        if json["id_token"] != nil {
            try token.validate(issuer: configuration.issuer, clientID: clientID, nonce: nonce, now: date)
        }
        if let previous, token.subject != previous.subject { throw .wrongSubject }
        // RFC 6749 5.1: no `scope` means the requested scopes. A refresh keeps the saved scopes.
        let scopes = (json["scope"] as? String).map { $0.split(separator: " ").map(String.init) }
            ?? previous?.scopes ?? configuration.scopes
        guard Set(configuration.scopes).isSubset(of: scopes) else { throw .missingScopes }
        let lifetime = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return ChatGPTSession(clientID: clientID, accessToken: accessToken,
                              refreshToken: json["refresh_token"] as? String ?? previous?.refreshToken, idToken: idToken,
                              expiresAt: date.addingTimeInterval(lifetime), scopes: scopes, subject: token.subject,
                              email: token.email ?? previous?.email, planType: token.planType ?? previous?.planType)
    }
}
