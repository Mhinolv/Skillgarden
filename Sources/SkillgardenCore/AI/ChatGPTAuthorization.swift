import CryptoKit
import Foundation
import Security

/// The OpenAI values of Sign in with ChatGPT for an open-source local app (#156): registration through the authorize request,
/// PKCE and a loopback callback. No client secret, no partner key and no registration endpoint.
/// See `docs/research/v4-model-providers.md` for the SIWC terms.
public struct ChatGPTAuthConfiguration: Equatable, Sendable {
    /// The `iss` value of the ID token and of the callback.
    public var issuer: String
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    /// The RS256 keys of the ID token.
    public var keysEndpoint: URL
    /// The `resource` of the authorize, code and refresh requests.
    public var resource: String
    /// The scopes that Skillgarden asks for.
    public var scopes: [String]
    /// The granted scopes that a sign-in must have. A sign-in fails when OpenAI grants fewer.
    public var requiredScopes: [String]
    /// The `client_id` of the first sign-in. The callback gives the issued client ID.
    public var registrationClientID: String
    /// The `agent_name_hint` of the first sign-in. SIWC requires the real name of the app.
    public var agentName: String

    public init(issuer: String, authorizationEndpoint: URL, tokenEndpoint: URL, keysEndpoint: URL, resource: String,
                scopes: [String], requiredScopes: [String], registrationClientID: String, agentName: String) {
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.keysEndpoint = keysEndpoint
        self.resource = resource
        self.scopes = scopes
        self.requiredScopes = requiredScopes
        self.registrationClientID = registrationClientID
        self.agentName = agentName
    }

    public static let openAI = ChatGPTAuthConfiguration(
        issuer: "https://auth.openai.com",
        authorizationEndpoint: URL(string: "https://auth.openai.com/api/accounts/authorize")!,
        tokenEndpoint: URL(string: "https://auth.openai.com/api/accounts/oauth/token")!,
        keysEndpoint: URL(string: "https://auth.openai.com/.well-known/jwks.json")!,
        resource: "https://api.openai.com/v1",
        scopes: ["openid", "profile", "email", "offline_access", "resource.invoke", "chatgpt.tokens.use.direct"],
        requiredScopes: ["chatgpt.tokens.use.direct"],
        registrationClientID: "dynamic_agent_client",
        agentName: "Skillgarden")
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
    /// The callback of a later sign-in names another client than the saved issued client ID.
    case wrongClient
    case nonceMismatch
    case wrongIssuer
    case wrongAudience
    case missingScopes
    /// The ID token is expired, or its issue time is in the future.
    case expiredToken
    /// The ID token signature does not match an OpenAI key.
    case badSignature
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
        case .stateMismatch, .replayed, .wrongRedirect, .wrongClient, .nonceMismatch, .wrongIssuer, .wrongAudience, .missingScopes,
             .expiredToken, .badSignature, .wrongSubject, .malformedResponse: true
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

    /// The case name for the sign-in log, for example `missingScopes` or `refused(access_denied)`. It holds no token,
    /// code, state, nonce or URL. The OAuth error code keeps only letters, digits and `_`.
    public var logName: String {
        switch self {
        case .refused(let code):
            "refused(\(String(code.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "_" }.prefix(40))))"
        case .httpStatus(let status): "httpStatus(\(status))"
        case .credential(.denied): "credential(denied)"
        case .credential(.failed(let status)): "credential(failed(\(status)))"
        default: "\(self)"
        }
    }

    public static let notFinishedText = "Sign-in did not finish. Try again."
    /// The OAuth codes of a refresh that mean a revoked grant (#157). The tokens then go, and the client ID stays.
    static let revokedRefreshCodes: Set<String> = ["invalid_grant", "invalid_refresh_token", "token_expired",
                                                   "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"]
    public static let unverifiedText = "OpenAI sent a response that Skillgarden can't verify."
}

/// One started sign-in (#156): the page to open and the values that the callback and the ID token must match.
public struct ChatGPTAuthorizationRequest: Equatable, Sendable {
    public let url: URL
    public let redirectURI: URL
    /// The `client_id` of the authorize request: `dynamic_agent_client` on the first sign-in, else the issued client ID.
    public let clientID: String
    /// The saved issued client ID of a later sign-in. Nil on the first sign-in.
    public let issuedClientID: String?
    /// The `ext_agent_host_id` of this Mac.
    public let hostID: String
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
    let keyID: String?
    /// The signed text: the header and the payload with their dot.
    let signingInput: Data
    let signature: Data
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

    /// Reads a JWT. Only RS256 is accepted, so a token with `alg: none` is refused. `verify(with:)` checks the signature.
    init(jwt: String) throws(ChatGPTAuthError) {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let headerData = PKCE.data(base64URL: String(parts[0])),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256",
              let signature = PKCE.data(base64URL: String(parts[2])), !signature.isEmpty,
              let payloadData = PKCE.data(base64URL: String(parts[1])),
              let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let issuer = claims["iss"] as? String, let subject = claims["sub"] as? String, !subject.isEmpty,
              let expiry = (claims["exp"] as? NSNumber)?.doubleValue else { throw .malformedResponse }
        keyID = header["kid"] as? String
        signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        self.signature = signature
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

    /// True when the RS256 signature matches `key`.
    func verify(with key: SecKey) -> Bool {
        SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, signingInput as CFData, signature as CFData, nil)
    }
}

/// The RS256 keys of a JWKS document (RFC 7517), by key ID.
enum ChatGPTSigningKeys {
    /// The RSA signature keys of `json`. A key with no `kid` has the empty key ID.
    static func keys(fromJWKS json: [String: Any]) -> [String: SecKey] {
        var keys: [String: SecKey] = [:]
        for jwk in json["keys"] as? [[String: Any]] ?? [] {
            guard jwk["kty"] as? String == "RSA", (jwk["use"] as? String ?? "sig") == "sig",
                  (jwk["alg"] as? String ?? "RS256") == "RS256",
                  let modulus = (jwk["n"] as? String).flatMap(PKCE.data(base64URL:)),
                  let exponent = (jwk["e"] as? String).flatMap(PKCE.data(base64URL:)),
                  let key = publicKey(modulus: [UInt8](modulus), exponent: [UInt8](exponent)) else { continue }
            keys[jwk["kid"] as? String ?? ""] = key
        }
        return keys
    }

    /// The Security key of an RSA modulus and exponent, through the PKCS #1 `RSAPublicKey` DER form.
    static func publicKey(modulus: [UInt8], exponent: [UInt8]) -> SecKey? {
        let der = sequence(integer(modulus) + integer(exponent))
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        return SecKeyCreateWithData(Data(der) as CFData, attributes as CFDictionary, nil)
    }

    private static func integer(_ bytes: [UInt8]) -> [UInt8] {
        var value = Array(bytes.drop { $0 == 0 })
        if value.isEmpty || value[0] & 0x80 != 0 { value.insert(0, at: 0) }
        return [0x02] + length(value.count) + value
    }

    private static func sequence(_ body: [UInt8]) -> [UInt8] { [0x30] + length(body.count) + body }

    private static func length(_ count: Int) -> [UInt8] {
        guard count >= 0x80 else { return [UInt8(count)] }
        var bytes: [UInt8] = []
        var rest = count
        while rest > 0 {
            bytes.insert(UInt8(rest & 0xFF), at: 0)
            rest >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }
}

/// The OAuth part of Sign in with ChatGPT (#156): the authorization URL, the callback checks, the code exchange and the refresh.
/// The first sign-in registers the client through the authorize request, and the callback gives the issued client ID.
/// Each sign-in accepts one callback only. A second callback, or a callback of an earlier sign-in, fails as a replay.
/// The transport, the host ID store and the clock are injected, so the tests run offline.
@MainActor
public final class ChatGPTAuthorizer {
    /// The Keychain account of the `ext_agent_host_id` of this Mac. It is not a secret, and Disconnect keeps it.
    public static let hostIDAccount = "chatgpt-agent-host-id"

    public let configuration: ChatGPTAuthConfiguration
    private let transport: any LlamaTransport
    private let hostIDs: any CredentialStore
    private let now: @Sendable () -> Date
    private var pending: ChatGPTAuthorizationRequest?
    /// The states of finished or failed sign-ins.
    private var usedStates: Set<String> = []
    /// The OpenAI signature keys, by key ID. A token with an unknown key ID loads the keys again.
    private var signingKeys: [String: SecKey] = [:]

    public init(configuration: ChatGPTAuthConfiguration = .openAI,
                transport: any LlamaTransport = LoopbackTransport(usesSystemProxy: true),
                hostIDs: any CredentialStore = KeychainCredentialStore(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration
        self.transport = transport
        self.hostIDs = hostIDs
        self.now = now
    }

    /// Makes a new request with a new state, nonce and PKCE verifier. It sends nothing. A new request replaces an unfinished one.
    /// `previous` is the saved session of the profile: a later sign-in uses its issued client ID.
    public func begin(redirectURI: URL, previous: ChatGPTSession? = nil) throws(ChatGPTAuthError) -> ChatGPTAuthorizationRequest {
        let request = makeRequest(redirectURI: redirectURI, hostID: try hostID(), issuedClientID: previous?.clientID)
        expect(request)
        return request
    }

    /// The `ext_agent_host_id` of this Mac: the saved value, else a new `urn:uuid:` value that is saved first.
    func hostID() throws(ChatGPTAuthError) -> String {
        do {
            if let saved = try hostIDs.secret(account: Self.hostIDAccount), saved.hasPrefix("urn:uuid:") { return saved }
            let hostID = "urn:uuid:" + UUID().uuidString.lowercased()
            try hostIDs.save(hostID, account: Self.hostIDAccount)
            return hostID
        } catch {
            throw .credential(error)
        }
    }

    /// The request of one sign-in, with new random values. `issuedClientID` nil makes a first sign-in.
    func makeRequest(redirectURI: URL, hostID: String, issuedClientID: String?, state: String = PKCE.randomText(bytes: 32),
                     nonce: String = PKCE.randomText(bytes: 32),
                     codeVerifier: String = PKCE.randomText(bytes: 64)) -> ChatGPTAuthorizationRequest {
        let clientID = issuedClientID ?? configuration.registrationClientID
        var fields: [(String, String)] = [("client_id", clientID), ("ext_agent_host_id", hostID)]
        if issuedClientID == nil { fields.append(("agent_name_hint", configuration.agentName)) }
        fields += [
            ("response_type", "code"),
            ("redirect_uri", redirectURI.absoluteString),
            ("scope", configuration.scopes.joined(separator: " ")),
            ("resource", configuration.resource),
            ("state", state),
            ("nonce", nonce),
            ("code_challenge", PKCE.challenge(for: codeVerifier)),
            ("code_challenge_method", "S256"),
        ]
        var components = URLComponents(url: configuration.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = fields.map { "\($0)=\(Self.encode($1))" }.joined(separator: "&")
        return ChatGPTAuthorizationRequest(url: components.url!, redirectURI: redirectURI, clientID: clientID,
                                           issuedClientID: issuedClientID, hostID: hostID, state: state, nonce: nonce,
                                           codeVerifier: codeVerifier)
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
    /// An `error` callback, for example `access_denied` for a plan with no plan usage, sends no request.
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
        // RFC 9207: an `iss` parameter must name the issuer. SIWC can leave it out.
        if let issuer = value("iss"), issuer != configuration.issuer { throw .wrongIssuer }
        if let error = value("error") { throw .refused(error) }
        // The first sign-in gets the issued client ID from the callback. A later sign-in must keep the saved one.
        let callbackClientID = value("client_id")
        let clientID: String
        if let saved = request.issuedClientID {
            if let callbackClientID, callbackClientID != saved { throw .wrongClient }
            clientID = saved
        } else {
            guard let callbackClientID, !callbackClientID.isEmpty, callbackClientID != configuration.registrationClientID else {
                throw .malformedResponse
            }
            clientID = callbackClientID
        }
        let grantedScopes = value("scope").map(Self.scopes)
        if let grantedScopes { try requireScopes(grantedScopes) }
        guard let code = value("code"), !code.isEmpty else { throw .malformedResponse }
        let response = try await tokenRequest([
            "grant_type": "authorization_code", "code": code, "redirect_uri": request.redirectURI.absoluteString,
            "client_id": clientID, "code_verifier": request.codeVerifier, "resource": configuration.resource,
        ])
        return try await session(from: response, clientID: clientID, nonce: request.nonce, grantedScopes: grantedScopes,
                                 previous: nil)
    }

    /// A new access token for `session`. OpenAI can send a new refresh token. The ID token must name the same account.
    /// The access token, the end time, the scopes and the refresh token change together.
    public func refresh(_ session: ChatGPTSession) async throws(ChatGPTAuthError) -> ChatGPTSession {
        guard let refreshToken = session.refreshToken else { throw .refused("invalid_grant") }
        let response = try await tokenRequest([
            "grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": session.clientID,
            "resource": configuration.resource,
        ])
        return try await self.session(from: response, clientID: session.clientID, nonce: nil, grantedScopes: nil,
                                      previous: session)
    }

    /// The same scheme, host, port and path. The loopback listener gives the callback with its own host and port.
    static func sameEndpoint(_ callback: URL, _ redirect: URL) -> Bool {
        callback.scheme?.lowercased() == redirect.scheme?.lowercased() && callback.host == redirect.host
            && callback.port == redirect.port && callback.path == redirect.path
    }

    /// The scope names of a callback or token response. The callback is form data, so `+` is a space. A token response
    /// can also give a JSON array of names. JSON `null` is no scope. Another type grants no scope.
    nonisolated static func scopeList(_ value: Any) -> [String]? {
        switch value {
        case is NSNull: nil
        case let text as String: scopes(text)
        case let names as [String]: names.flatMap { scopes($0) }
        default: []
        }
    }

    nonisolated static func scopes(_ text: String) -> [String] {
        text.replacingOccurrences(of: "+", with: " ").split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private func requireScopes(_ granted: [String]) throws(ChatGPTAuthError) {
        guard Set(configuration.requiredScopes).isSubset(of: granted) else { throw .missingScopes }
    }

    // MARK: Requests

    private func tokenRequest(_ fields: [String: String]) async throws(ChatGPTAuthError) -> [String: Any] {
        var request = URLRequest(url: configuration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.formBody(fields).utf8)
        return try await send(request)
    }

    /// Percent-encodes everything except the RFC 3986 unreserved characters.
    static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    static func formBody(_ fields: [String: String]) -> String {
        fields.sorted { $0.key < $1.key }.map { "\($0.key)=\(encode($0.value))" }.joined(separator: "&")
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

    /// Checks the RS256 signature against the OpenAI JWKS. An unknown key ID loads the keys one more time.
    private func verifySignature(_ token: ChatGPTIDToken) async throws(ChatGPTAuthError) {
        func key() -> SecKey? {
            if let keyID = token.keyID { return signingKeys[keyID] }
            return signingKeys.count == 1 ? signingKeys.values.first : nil
        }
        if key() == nil {
            var request = URLRequest(url: configuration.keysEndpoint)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            signingKeys = ChatGPTSigningKeys.keys(fromJWKS: try await send(request))
        }
        guard let key = key(), token.verify(with: key) else { throw .badSignature }
    }

    /// The session of a token response, after the checks of the ID token and the scopes.
    private func session(from json: [String: Any], clientID: String, nonce: String?, grantedScopes: [String]?,
                         previous: ChatGPTSession?) async throws(ChatGPTAuthError) -> ChatGPTSession {
        guard let accessToken = json["access_token"] as? String, !accessToken.isEmpty,
              (json["token_type"] as? String)?.lowercased() == "bearer" else { throw .malformedResponse }
        let date = now()
        // A refresh can leave out the ID token. Then the saved one stays.
        guard let idToken = json["id_token"] as? String ?? previous?.idToken else { throw .malformedResponse }
        let token = try ChatGPTIDToken(jwt: idToken)
        if json["id_token"] != nil {
            try token.validate(issuer: configuration.issuer, clientID: clientID, nonce: nonce, now: date)
            try await verifySignature(token)
        }
        if let previous, token.subject != previous.subject { throw .wrongSubject }
        // RFC 6749 5.1: no `scope` means the requested scopes. A refresh keeps the saved scopes.
        let scopes = json["scope"].flatMap(Self.scopeList) ?? grantedScopes ?? previous?.scopes ?? configuration.scopes
        try requireScopes(scopes)
        let lifetime = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return ChatGPTSession(clientID: clientID, accessToken: accessToken,
                              refreshToken: json["refresh_token"] as? String ?? previous?.refreshToken, idToken: idToken,
                              expiresAt: date.addingTimeInterval(lifetime), scopes: scopes, subject: token.subject,
                              email: token.email ?? previous?.email, planType: token.planType ?? previous?.planType)
    }
}
