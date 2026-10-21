import Foundation
import Observation
import os

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

/// The completion handler of the system sign-in sheet (#156). AuthenticationServices calls it on its own XPC queue after
/// the learner closes the sheet or `stop()` cancels it. A handler that main-actor code passes inline to
/// `ASWebAuthenticationSession` is main-actor isolated, and its isolation check traps on that queue. This handler is
/// nonisolated: it only hops to the main actor.
public enum ChatGPTSheetCompletion {
    /// Gives `.canceled` to `finish` on the main actor. `finish` must ignore a second result.
    public nonisolated static func make(
        _ finish: @escaping @MainActor @Sendable (Result<URL, ChatGPTAuthError>) -> Void
    ) -> @Sendable (URL?, (any Error)?) -> Void {
        { _, _ in Task { @MainActor in finish(.failure(.canceled)) } }
    }
}

/// The ChatGPT plan sheet (#156): Signed out, Waiting, Signed in and Failed. A sign-in saves the session in the Keychain
/// and the profile in `Providers.json` only after every callback and token check passes.
/// Signed in shows the model picker of the account model list (#157). "Save" saves the model.
@MainActor @Observable
public final class ChatGPTSignIn {
    /// The model picker of the Signed in sheet (#157).
    public enum Models: Equatable, Sendable {
        /// The sheet did not ask for the list yet.
        case notLoaded
        case loading
        /// The account models in server order. An empty list is the Empty state.
        case loaded([ChatGPTModel])
        /// The design-note reason of the failure.
        case failed(String)
    }

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

    /// Each failed sign-in logs only `ChatGPTAuthError.logName`. It never logs a token, a code, the state, the nonce or a URL.
    nonisolated static let log = Logger(subsystem: "dev.skillgarden.app", category: "chatgpt-sign-in")

    public static let signedOutText = "Sign in with your ChatGPT account. OpenAI shows its sign-in page."
    public static let waitingText = "Waiting for sign-in…"
    public static let loadingModelsText = "Loading models…"
    public static let noModelsText = "This plan has no models for Skillgarden."

    /// The red caption of a saved model that left the account list: "gpt-5 is no longer available. Choose a model."
    public static func modelGoneText(_ modelID: String) -> String { "\(modelID) is no longer available. Choose a model." }

    public private(set) var state: State
    public private(set) var models: Models
    /// The model of the picker. It starts with the saved model of the profile. An empty saved model gets the first model.
    public var modelID: String
    /// The profile that the sign-in saves: the existing ChatGPT plan profile, else a new one.
    public let profile: ProviderProfile
    @ObservationIgnored private let providers: ProviderSettings
    @ObservationIgnored private let browser: (any ChatGPTBrowser)?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// The snapshot harness injects `state`, `models` and no browser. The app starts Signed out, or Signed in for "Edit…".
    public init(providers: ProviderSettings, browser: (any ChatGPTBrowser)?, state: State = .signedOut, models: Models = .notLoaded,
                modelID: String? = nil) {
        self.providers = providers
        self.browser = browser
        self.state = state
        self.models = models
        let profile = providers.profiles.first(where: \.isChatGPTPlan) ?? .chatGPTPlan()
        self.profile = profile
        self.modelID = modelID ?? profile.modelID
    }

    /// Loads the model list once after the sheet shows Signed in.
    public func loadModelsIfNeeded() async {
        guard models == .notLoaded else { return }
        await loadModels()
    }

    /// "Refresh" and "Try Again": loads the account model list again.
    public func loadModels() async {
        guard case .signedIn = state, models != .loading else { return }
        models = .loading
        let result = await providers.chatGPTModels(for: profile.id)
        guard case .signedIn = state else { return }
        switch result {
        case .success(let list):
            models = .loaded(list)
            if modelID.isEmpty, let first = list.first { modelID = first.slug }
        case .failure(let failure):
            models = .failed(failure.reason)
        }
    }

    /// The red caption of a chosen model that is not in the loaded list. Nil in the other cases.
    public var missingModelText: String? {
        guard case .loaded(let list) = models, !modelID.isEmpty, !list.contains(where: { $0.slug == modelID }) else { return nil }
        return Self.modelGoneText(modelID)
    }

    /// True when the picker has a model of the loaded list, so "Save" works.
    public var canSave: Bool {
        guard case .loaded(let list) = models else { return false }
        return list.contains { $0.slug == modelID }
    }

    /// "Save": saves the chosen model in the profile. Nil on success, else the problem text.
    public func save() -> String? {
        guard canSave else { return nil }
        do { try providers.saveChatGPTModel(modelID, for: profile.id) } catch { return error.message }
        return nil
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
                self.models = .notLoaded
                self.state = .signedIn(session.account)
            } catch {
                Self.log.error("ChatGPT sign-in failed: \(error.logName, privacy: .public)")
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
