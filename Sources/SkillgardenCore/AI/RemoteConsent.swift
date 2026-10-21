import Foundation

/// The place that lecture text goes to (#151). A consent names one exact destination.
/// A change of kind, host or model gives another destination, so the course asks again.
public struct RemoteDestination: Codable, Hashable, Sendable {
    public let profileID: String
    public let kind: AnswerProviderKind
    public let host: String
    public let modelID: String

    public init(profileID: String, kind: AnswerProviderKind, host: String, modelID: String) {
        self.profileID = profileID
        self.kind = kind
        self.host = host
        self.modelID = modelID
    }
}

/// The learner allowed one course to send lecture text to one destination (#151). `Providers.json` saves it.
public struct RemoteConsent: Codable, Hashable, Sendable {
    public let courseID: String
    public let destination: RemoteDestination
    public let allowedAt: Date

    public init(courseID: String, destination: RemoteDestination, allowedAt: Date) {
        self.courseID = courseID
        self.destination = destination
        self.allowedAt = allowedAt
    }
}

/// The consent sheet of a question (#151): what the app sends, and the exact text of the request.
public struct RemoteConsentRequest: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let courseID: String
    public let question: String
    public let destination: RemoteDestination
    /// The company name, for example "OpenAI".
    public let vendor: String
    /// The provider row, for example "OpenAI API".
    public let providerName: String
    public let passageCount: Int
    /// The course title, then the lecture title.
    public let titles: [String]
    /// The earlier messages of the thread in the request: questions and answers.
    public let earlierMessageCount: Int
    /// The messages that the app sends when the learner allows.
    public let messages: [ChatMessage]

    public init(courseID: String, question: String, providerName: String, destination: RemoteDestination,
                vendor: String, context: LectureContext, prompt: LecturePrompt) {
        self.courseID = courseID
        self.question = question
        self.destination = destination
        self.vendor = vendor
        self.providerName = providerName
        passageCount = prompt.passages.count
        titles = [context.courseTitle, context.lectureTitle]
        earlierMessageCount = prompt.messages.filter { $0.role != .system }.count - 1
        messages = prompt.messages
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    /// The sheet title: "Send this question to OpenAI?"
    public var title: String { "Send this question to \(vendor)?" }

    /// The extra line of an external local server (#152). A loopback address does not prove that the server keeps the text
    /// on this Mac. A subscription (#157) says that the answer uses the plan. Nil for the other kinds.
    public var cloudNote: String? {
        switch destination.kind {
        case .externalLocal: "Skillgarden can't check if this server uses the cloud."
        case .subscription: "Use of your plan counts toward its limits."
        case .local, .api: nil
        }
    }

    /// The list of the sheet: what leaves the Mac.
    public var items: [String] {
        let passages = passageCount == 1 ? "1 lecture passage" : "\(passageCount) lecture passages"
        let earlier = earlierMessageCount == 1 ? "1 earlier message" : "\(earlierMessageCount) earlier messages"
        return [passages, "Titles: " + titles.map { "\"\($0)\"" }.joined(separator: ", "), "Your question", earlier]
    }

    /// The exact text of the request: each message with its role, in the order that the app sends them.
    public var exactText: String {
        messages.map { "[\($0.role.rawValue)]\n\($0.content)" }.joined(separator: "\n\n")
    }
}
