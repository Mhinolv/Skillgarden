import AppKit
import SwiftUI
import WebKit
import SkillgardenCore

enum InteractiveStyle {
    static let maxWidth: CGFloat = 960
    static let frameHeight: CGFloat = 560
}

/// The interactive lecture body: the sandboxed module frame, the controls row and the latest score.
struct InteractiveLectureView: View {
    let lecture: Lecture
    let module: InteractiveModule?
    let result: InteractiveResult?
    let receive: (InteractiveBridgeMessage) -> Void
    /// Nil until the file check ends. False if the snapshot has no `index.html` or the web view cannot start.
    @State private var available: Bool?
    @State private var isLoading = true
    @State private var blockedLink = false
    /// A new value makes a new web view, so the module starts again.
    @State private var session = 0
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: CourseStyle.spacing) {
            Label("Interactive", systemImage: LectureType.interactive.symbolName)
                .gardenText(.meta)
            frame
            if blockedLink {
                Text("Skillgarden blocked a link outside this course.")
                    .gardenText(.meta)
            }
            HStack {
                Spacer()
                Button("Restart Module", systemImage: "arrow.clockwise") {
                    isLoading = true
                    blockedLink = false
                    session += 1
                }
                .buttonStyle(.garden(.soft, .small))
                .disabled(available != true)
            }
            if let result { InteractiveResultView(result: result).padding(.top, CourseStyle.spacing) }
        }
        .task(id: module) {
            available = nil
            guard let module else { available = false; return }
            available = await Task.detached { module.entryExists() }.value
        }
    }

    private var frame: some View {
        ZStack {
            switch (available, module) {
            case let (true?, module?):
                InteractiveWebView(module: module, title: lecture.title,
                                   loaded: { isLoading = false }, failed: { available = false },
                                   blocked: { blockedLink = true }, receive: receive)
                    .id(session)
                if isLoading { ProgressView().controlSize(.small) }
            case (false?, _), (true?, nil):
                ContentUnavailableView("Module unavailable", systemImage: "exclamationmark.triangle",
                                       description: Text("Publish the course again to restore this module."))
            case (nil, _):
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: InteractiveStyle.frameHeight)
        .background(palette.card, in: .garden(24))
        .clipShape(.garden(24))
        .overlay(RoundedRectangle.garden(24).strokeBorder(palette.line, lineWidth: 1.5))
    }
}

/// The latest score of the module in a card, with the skills to review when the score is weak.
struct InteractiveResultView: View {
    let result: InteractiveResult
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        GardenCard {
            VStack(alignment: .leading, spacing: GardenSpacing.s) {
                Text("Score: \(result.score)%").gardenText(.cardTitle).monospacedDigit()
                if result.weakSkills.isEmpty {
                    Label {
                        Text("You met the objective.").font(GardenFont.body.weight(.bold)).foregroundStyle(palette.ink)
                    } icon: {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(palette.accent)
                    }
                } else {
                    SkillsToReviewList(skills: result.weakSkills)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A WKWebView that shows only the files of one bundle. It has no network access and no persistent website data.
struct InteractiveWebView: NSViewRepresentable {
    let module: InteractiveModule
    let title: String
    let loaded: () -> Void
    let failed: () -> Void
    let blocked: () -> Void
    let receive: (InteractiveBridgeMessage) -> Void

    private static let ruleListIdentifier = "SkillgardenInteractiveNetworkBlock"
    /// The compiled rules are a cache, so they live in the temporary folder.
    @MainActor private static let ruleStore = WKContentRuleListStore(
        url: FileManager.default.temporaryDirectory.appending(path: "SkillgardenContentRules", directoryHint: .isDirectory))

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> ModuleWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let content = configuration.userContentController
        content.addUserScript(WKUserScript(source: InteractiveBridgeMessage.bridgeScript, injectionTime: .atDocumentStart,
                                           forMainFrameOnly: false))
        content.add(context.coordinator, name: InteractiveBridgeMessage.handlerName)
        let webView = ModuleWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.setAccessibilityLabel("Interactive module: \(title)")
        let module = module, failed = failed
        // The page loads only after the network block is in place. If the rules do not compile, nothing loads.
        Task { @MainActor [weak webView] in
            let list: WKContentRuleList?
            do {
                list = try await Self.ruleStore?.compileContentRuleList(
                    forIdentifier: Self.ruleListIdentifier, encodedContentRuleList: InteractiveNavigationPolicy.contentRules)
            } catch {
                FileHandle.standardError.write(Data("interactive: cannot compile the network block: \(error)\n".utf8))
                list = nil
            }
            guard let webView else { return }
            guard let list else { failed(); return }
            webView.configuration.userContentController.add(list)
            webView.loadFileURL(module.entryURL, allowingReadAccessTo: module.folder)
        }
        return webView
    }

    func updateNSView(_ webView: ModuleWebView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleNSView(_ webView: ModuleWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: InteractiveBridgeMessage.handlerName)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: InteractiveWebView

        init(parent: InteractiveWebView) {
            self.parent = parent
        }

        private func allows(_ url: URL?) -> Bool {
            url.map { InteractiveNavigationPolicy.allows($0, bundle: parent.module.folder) } ?? false
        }

        /// A blocked link keeps the current page.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if allows(navigationAction.request.url) {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                parent.blocked()
            }
        }

        /// New windows never open. A bundle link with a `_blank` target opens in the module frame.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if allows(navigationAction.request.url) { webView.load(navigationAction.request) } else { parent.blocked() }
            return nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loaded()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            parent.loaded()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            parent.loaded()
        }

        /// Only frames inside the bundle can call the bridge.
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard allows(message.frameInfo.request.url), let value = InteractiveBridgeMessage(body: message.body) else { return }
            parent.receive(value)
        }
    }
}

/// Removes "Reload" and "Inspect Element" from the context menu.
final class ModuleWebView: WKWebView {
    private static let hiddenItems: Set<String> = ["WKMenuItemIdentifierReload", "WKMenuItemIdentifierInspectElement"]

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        for item in menu.items where item.identifier.map({ Self.hiddenItems.contains($0.rawValue) }) == true {
            menu.removeItem(item)
        }
        super.willOpenMenu(menu, with: event)
    }
}

struct InteractiveViews_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            InteractiveResultView(result: InteractiveResult(score: 80, objective: "Order the steps of a course plan"))
            InteractiveResultView(result: InteractiveResult(score: 100, objective: "Order the steps of a course plan"))
            InteractiveLectureView(lecture: Lecture(id: "m", title: "Order the steps", type: .interactive, order: 0),
                                   module: nil, result: nil) { _ in }
        }
        .padding()
        .frame(width: 720)
    }
}
