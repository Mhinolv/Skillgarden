import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SkillgardenCore

/// The Settings "Local AI" section: `Use local AI` (#123), the chosen GGUF model and `Choose Model…` (#122),
/// and the status of the owned server (#123).
struct LocalAISection: View {
    let settings: ModelSettings
    let localAI: RuntimeSupervisor

    var body: some View {
        Section {
            // Each change is saved at once, as `autoPlays` (#99).
            Toggle("Use local AI", isOn: Binding(get: { localAI.isEnabled }, set: { localAI.setEnabled($0) }))
            LabeledContent("Model") {
                HStack(spacing: 12) {
                    modelText
                    if settings.isChecking {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Choose Model…") { ModelChooser.start(settings) }
                    }
                }
            }
            LabeledContent("Status") { LocalAIStatusView(localAI: localAI) }
        } header: {
            Text("Local AI")
        } footer: {
            Text("Skillgarden reads the model where it is. It does not copy or download models.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var modelText: some View {
        switch settings.state {
        case .none:
            Text("None").foregroundStyle(.secondary)
        case .ready(let model):
            VStack(alignment: .trailing, spacing: 2) {
                // `LabeledContent` makes its content secondary. The file name stays primary.
                Text(model.name).foregroundStyle(.primary)
                Text(model.detailText())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .truncationMode(.middle)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Model, \(model.name), \(model.sizeText)")
        case .problem(let problem):
            VStack(alignment: .trailing, spacing: 2) {
                Text(problem.name).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                Text(problem.message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// The status row of the owned server: an indicator, the fixed text, and `Try Again` in the Error state.
struct LocalAIStatusView: View {
    let localAI: RuntimeSupervisor

    var body: some View {
        let status = localAI.status
        HStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                indicator(status)
                VStack(alignment: .trailing, spacing: 2) {
                    // `LabeledContent` makes its content secondary. The status text stays primary.
                    Text(status.text).foregroundStyle(.primary)
                    if let reason = status.reason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status.accessibilityLabel)
            if case .failed = status {
                Button("Try Again") { localAI.retry() }
            }
        }
        // Ready and Error post an announcement. Status changes show no alert.
        .onChange(of: status) { _, status in
            guard let announcement = status.announcement else { return }
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: announcement, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    @ViewBuilder private func indicator(_ status: LocalAIStatus) -> some View {
        switch status {
        case .off, .noModel: Image(systemName: "circle").foregroundStyle(.secondary)
        case .starting, .stopping: ProgressView().controlSize(.small)
        case .ready: Image(systemName: "circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        }
    }
}

/// The `Choose Model…` open panel and the alert for an invalid choice. The alert matches `Import Course…` (#111).
@MainActor
enum ModelChooser {
    static func start(_ settings: ModelSettings) {
        let panel = NSOpenPanel()
        panel.title = "Choose Model"
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        let models = ModelBookmarkStore.suggestedModelsDirectory
        try? FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        panel.directoryURL = models
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if let problem = await settings.choose(url) { showProblem(problem) }
        }
    }

    private static func showProblem(_ problem: ModelProblem) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Can't use this model."
        alert.informativeText = problem.message
        alert.runModal()
    }
}

/// The Settings "Q&A" section (#151): the app-wide "Answer with" choice, one row for each provider profile, and the footer.
/// "Add Provider" lists only kinds with a shipped adapter: LM Studio and Ollama (#152), then the OpenAI API (#153).
struct QAProvidersSection: View {
    let providers: ProviderSettings
    @State private var editing: ProviderProfile?
    @State private var disconnecting: ProviderProfile?

    var body: some View {
        Section {
            Picker("Answer with", selection: Binding(get: { providers.selectedID }, set: { providers.select($0) })) {
                Section(AnswerProviderKind.local.title) {
                    Text(ProviderSettings.bundledTitle).tag(BundledAnswerProvider.providerID)
                }
                ForEach([AnswerProviderKind.externalLocal, .api, .subscription], id: \.self) { kind in
                    let profiles = providers.profiles(of: kind)
                    if !profiles.isEmpty {
                        Section(kind.title) {
                            ForEach(profiles) { Text($0.title).tag($0.id) }
                        }
                    }
                }
            }
            .pickerStyle(.menu)
            ForEach(providers.profiles) { row($0) }
            if !providers.adapterKinds.isDisjoint(with: [.externalLocal, .api]) {
                Menu("Add Provider") {
                    if providers.adapterKinds.contains(.externalLocal) {
                        ForEach(ExternalLocalServer.allCases) { server in
                            Button(server.menuTitle) { editing = .preset(server) }
                        }
                    }
                    if providers.adapterKinds.isSuperset(of: [.externalLocal, .api]) { Divider() }
                    if providers.adapterKinds.contains(.api) {
                        ForEach(RemoteAPIService.allCases) { service in
                            Button(service.menuTitle) { editing = .preset(service) }
                        }
                    }
                }
                .fixedSize()
            }
        } header: {
            Text("Q&A")
        } footer: {
            Text(ProviderSettings.footerText).foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { ProviderSheet(providers: providers, profile: $0) }
        .confirmationDialog(disconnecting.map { "Disconnect \($0.name)?" } ?? "",
                            isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }),
                            presenting: disconnecting) { profile in
            // A refused Keychain keeps the profile. Its row then shows the problem.
            Button("Disconnect", role: .destructive) { try? providers.disconnect(profile.id) }
        } message: { _ in
            Text("Skillgarden deletes the key from the Keychain and removes the course permissions.")
        }
    }

    private func row(_ profile: ProviderProfile) -> some View {
        let problem = providers.problems[profile.id]
        return LabeledContent {
            HStack(spacing: 8) {
                if problem != nil {
                    Button("Try Again") { providers.checkCredentials(profile.id) }
                }
                Button("Edit…") { editing = profile }
                Button("Disconnect") { disconnecting = profile }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                Text(profile.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let problem {
                    Text(problem.message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([profile.accessibilityLabel, problem?.message].compactMap { $0 }.joined(separator: ", "))
        }
    }
}

/// The provider sheet (#151): the fields of the kind, "Test Connection", "Cancel" and "Save".
/// The key goes into the Keychain only. The field stays empty for a saved key.
/// An external local server (#152) has the fields Name, Base URL, Model ID and an optional token, with a red caption
/// under an invalid field and the footer of its preset.
/// A remote API preset (#153) has the fixed host, the API key, Model ID and Output limit. A saved key is never shown.
struct ProviderSheet: View {
    let providers: ProviderSettings
    @State private var profile: ProviderProfile
    @State private var testResult: ConnectionTestResult?
    @State private var secret: String
    /// The text of the "Output limit" field (#153): digits only.
    @State private var answerTokensText: String
    /// True after "Replace Key…": the sheet shows the key field in place of "Saved in the Keychain".
    @State private var replacesKey = false
    @State private var isTesting = false
    @State private var saveProblem: String?
    @Environment(\.dismiss) private var dismiss

    /// The snapshot harness injects a test result and a key. The app starts with none.
    init(providers: ProviderSettings, profile: ProviderProfile, testResult: ConnectionTestResult? = nil, secret: String = "") {
        self.providers = providers
        _profile = State(initialValue: profile)
        _testResult = State(initialValue: testResult)
        _secret = State(initialValue: secret)
        _answerTokensText = State(initialValue: String(profile.answerTokens ?? OpenAIAnswerProvider.defaultAnswerTokens))
    }

    private var hasTypedKey: Bool { !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var isValid: Bool {
        if profile.apiService != nil, ProviderProfile.answerTokensProblem(answerTokensText) != nil { return false }
        return profile.isValid(hasSecret: providers.hasSecret(profile) || hasTypedKey)
    }

    private var canTest: Bool { providers.canTest(profile.kind) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if profile.kind == .externalLocal {
                        externalLocalFields
                    } else if let service = profile.apiService {
                        apiFields(service)
                    } else {
                        TextField("Name", text: $profile.name)
                        TextField("Company", text: $profile.vendor)
                        TextField("Base URL", text: $profile.origin, prompt: Text("https://api.example.com"))
                        TextField("Model", text: $profile.modelID)
                        if profile.kind.usesAPIKey {
                            SecureField("API Key", text: $secret, prompt: Text(keyPrompt))
                        }
                    }
                } header: {
                    Text(profile.kind.title)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let saveProblem {
                            Text(saveProblem).foregroundStyle(.red)
                        } else if canTest {
                            testFooter
                        }
                        if let server = profile.externalServer {
                            Text(server.footer).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                if canTest {
                    Button("Test Connection", action: test).disabled(!isValid || isTesting)
                    if isTesting { ProgressView().controlSize(.small) }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The fields of an external local server (#152). The red caption is also the accessibility hint of its field.
    @ViewBuilder private var externalLocalFields: some View {
        TextField("Name", text: $profile.name)
        validated(TextField("Base URL", text: $profile.origin, prompt: Text((profile.externalServer ?? .lmStudio).defaultBaseURL)),
                  problem: profile.originProblem)
        validated(TextField("Model ID", text: $profile.modelID, prompt: Text("Model ID from the server")),
                  problem: profile.modelProblem)
        SecureField("Token", text: $secret, prompt: Text(providers.hasSecret(profile) ? "Saved in the Keychain" : "Bearer token (optional)"))
    }

    /// The fields of a remote API preset (#153). The host is fixed. The saved key shows only as "Saved in the Keychain".
    @ViewBuilder private func apiFields(_ service: RemoteAPIService) -> some View {
        LabeledContent("Host", value: profile.host)
        if providers.hasSecret(profile) && !replacesKey {
            LabeledContent("API key") {
                HStack(spacing: 8) {
                    Text("Saved in the Keychain")
                    Button("Replace Key…") { replacesKey = true }
                }
            }
        } else {
            validated(SecureField("API key", text: $secret, prompt: Text(service.keyPrompt)),
                      problem: providers.hasSecret(profile) || hasTypedKey ? nil : ProviderProfile.noKeyText)
        }
        validated(TextField("Model ID", text: $profile.modelID, prompt: Text("Model ID, for example gpt-5")),
                  problem: profile.modelProblem)
        validated(HStack(spacing: 6) {
                      TextField("Output limit", text: $answerTokensText)
                      Text("tokens").foregroundStyle(.secondary).accessibilityHidden(true)
                  }
                  .onChange(of: answerTokensText) { _, text in
                      // Numbers only. Seven digits keep the value far from an overflow.
                      let digits = String(text.filter(\.isASCII).filter(\.isNumber).prefix(7))
                      if digits != text { answerTokensText = digits }
                      profile.answerTokens = Int(digits)
                  },
                  problem: ProviderProfile.answerTokensProblem(answerTokensText))
    }

    private func validated(_ field: some View, problem: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            field.accessibilityHint(problem ?? "")
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
    }

    private var keyPrompt: String {
        if providers.hasSecret(profile) { return "Saved in the Keychain" }
        return profile.kind.needsAPIKey ? "Required" : "Optional"
    }

    @ViewBuilder private var testFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch testResult {
            case .connected:
                Label(ConnectionTestResult.connectedText, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
            case nil:
                EmptyView()
            }
            Text("Sends one short test message. No lecture text.").foregroundStyle(.secondary)
        }
    }

    private func test() {
        isTesting = true
        testResult = nil
        Task {
            testResult = await providers.test(profile, secret: secret)
            isTesting = false
        }
    }

    private func save() {
        do {
            try providers.save(profile, secret: secret)
            dismiss()
        } catch {
            saveProblem = error.message
        }
    }
}
