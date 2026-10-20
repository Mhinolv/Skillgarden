import Foundation
import Observation

/// Opens the OpenAI sign-in page and gives the loopback callback (#156). The app uses `ASWebAuthenticationSession` with a
/// `LoopbackCallbackListener`, and no web view. Tests use a fake.
@MainActor
public protocol ChatGPTBrowser: AnyObject {
    /// Starts the loopback listener and gives its redirect URI.
    func listen() async throws(ChatGPTAuthError) -> URL
    /// Shows the system sign-in sheet and gives the first callback URL. It throws `.canceled` when the learner closes the sheet.
    func signIn(at url: URL) async throws(ChatGPTAuthError) -> URL
    /// Closes the sheet and stops the listener.
    func stop()
}

/// The ChatGPT plan sheet (#156): Signed out, Waiting, Signed in and Failed. A sign-in saves the session in the Keychain
/// and the profile in `Providers.json` only after every callback and token check passes.
@MainActor @Observable
public final class ChatGPTSignIn {
    public enum State: Equatable, Sendable {
        case signedOut
        case waiting
        case signedIn(ChatGPTAccount)
        case failed(String)

        /// The VoiceOver announcement of the state. Nil for no announcement.
        public var announcement: String? {
            switch self {
            case .waiting: "Waiting for sign-in"
            case .signedIn: "Signed in"
            default: nil
            }
        }
    }

    public static let signedOutText = "Sign in with your ChatGPT account. OpenAI shows its sign-in page."
    public static let waitingText = "Waiting for sign-in…"

    public private(set) var state: State
    /// The profile that the sign-in saves: the existing ChatGPT plan profile, else a new one.
    public let profile: ProviderProfile
    @ObservationIgnored private let providers: ProviderSettings
    @ObservationIgnored private let browser: (any ChatGPTBrowser)?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// The snapshot harness injects `state` and no browser. The app starts Signed out.
    public init(providers: ProviderSettings, browser: (any ChatGPTBrowser)?, state: State = .signedOut) {
        self.providers = providers
        self.browser = browser
        self.state = state
        profile = providers.profiles.first(where: \.isChatGPTPlan) ?? .chatGPTPlan()
    }

    /// "Continue with ChatGPT", "Try Again" and "Sign In…". A profile with a saved session signs in again with its issued
    /// client ID.
    public func start() {
        guard state != .waiting else { return }
        guard let browser, let authorizer = providers.chatGPT else { state = .failed(ChatGPTAuthError.notFinishedText); return }
        state = .waiting
        let previous = providers.savedChatGPTSession(for: profile.id)
        task = Task { [weak self] in
            do throws(ChatGPTAuthError) {
                let redirectURI = try await browser.listen()
                let request = try authorizer.begin(redirectURI: redirectURI, previous: previous)
                let callback = try await browser.signIn(at: request.url)
                browser.stop()
                let session = try await authorizer.complete(callback: callback)
                guard let self, !Task.isCancelled else { return }
                try self.providers.saveChatGPT(session, profile: self.profile)
                self.state = .signedIn(session.account)
            } catch {
                browser.stop()
                authorizer.cancel()
                guard let self, !Task.isCancelled else { return }
                // Cancel in the system sheet shows no error.
                self.state = error == .canceled ? .signedOut : .failed(error.message)
            }
        }
    }

    /// "Cancel" while the sheet waits, and the close of the sheet. Nothing is saved.
    public func cancel() {
        task?.cancel()
        task = nil
        browser?.stop()
        providers.chatGPT?.cancel()
        if state == .waiting { state = .signedOut }
    }
}
