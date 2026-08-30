import Foundation

public struct FeedbackSubmission: Codable, Equatable, Sendable {
    public static let maximumMessageLength = 10_000
    public static let maximumConversationIDLength = 512
    public var message: String; public var submissionID: UUID; public var conversationID: String?
    public init(message: String, submissionID: UUID = UUID(), conversationID: String? = nil) throws {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, message.count <= Self.maximumMessageLength else { throw FeedbackError.invalid }
        let conversation = conversationID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard conversation == nil || conversation!.isEmpty || conversation!.count <= Self.maximumConversationIDLength else { throw FeedbackError.invalid }
        self.message = message; self.submissionID = submissionID; self.conversationID = conversation?.isEmpty == false ? conversation : nil
    }
    private enum CodingKeys: String, CodingKey { case message, submissionID, conversationID }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(message: c.decode(String.self, forKey: .message), submissionID: c.decode(UUID.self, forKey: .submissionID), conversationID: c.decodeIfPresent(String.self, forKey: .conversationID))
    }
}
public struct FeedbackHTTPResponse: Equatable, Sendable { public var statusCode: Int; public var body: Data; public init(statusCode: Int, body: Data = Data()) { self.statusCode = statusCode; self.body = body } }
public protocol FeedbackTransport: Sendable { func send(_ submission: FeedbackSubmission) async throws -> FeedbackHTTPResponse }
public enum FeedbackError: Error, Equatable, Sendable { case invalid, deadlineExceeded, badRequest, authenticationRequired, paymentRequired, forbidden, rateLimited, server(status: Int), transport }

public actor FeedbackClient {
    private let transport: any FeedbackTransport
    private var completed = Set<UUID>()
    private var inFlight: [UUID: Task<Void, Error>] = [:]
    public init(transport: any FeedbackTransport) { self.transport = transport }
    public func submit(_ submission: FeedbackSubmission, deadline: Duration = .seconds(15)) async throws {
        if completed.contains(submission.submissionID) { return }
        if let task = inFlight[submission.submissionID] { return try await task.value }
        let transport = self.transport
        let task = Task {
            let response: FeedbackHTTPResponse
            do {
                response = try await raceFeedbackRequest(transport: transport, submission: submission, deadline: deadline)
            } catch let e as FeedbackError { throw e } catch { throw FeedbackError.transport }
            switch response.statusCode {
            case 200..<300: return
            case 400: throw FeedbackError.badRequest
            case 401: throw FeedbackError.authenticationRequired
            case 402: throw FeedbackError.paymentRequired
            case 403: throw FeedbackError.forbidden
            case 429: throw FeedbackError.rateLimited
            default: throw FeedbackError.server(status: response.statusCode)
            }
        }
        inFlight[submission.submissionID] = task
        defer { inFlight[submission.submissionID] = nil }
        try await task.value; completed.insert(submission.submissionID)
    }
}

private func raceFeedbackRequest(
    transport: any FeedbackTransport,
    submission: FeedbackSubmission,
    deadline: Duration
) async throws -> FeedbackHTTPResponse {
    let race = FeedbackRequestRace()
    return try await withCheckedThrowingContinuation { continuation in
        race.install(continuation)
        let request = Task {
            do { race.resolve(.success(try await transport.send(submission))) }
            catch { race.resolve(.failure(error)) }
        }
        let timeout = Task {
            do {
                try await Task.sleep(for: deadline)
                race.resolve(.failure(FeedbackError.deadlineExceeded))
            } catch { /* The request completed and cancelled the timer. */ }
        }
        race.installTasks(request: request, timeout: timeout)
    }
}

private final class FeedbackRequestRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<FeedbackHTTPResponse, Error>?
    private var tasks: (Task<Void, Never>, Task<Void, Never>)?
    private var result: Result<FeedbackHTTPResponse, Error>?

    func install(_ continuation: CheckedContinuation<FeedbackHTTPResponse, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func installTasks(request: Task<Void, Never>, timeout: Task<Void, Never>) {
        lock.lock()
        if result != nil {
            lock.unlock(); request.cancel(); timeout.cancel()
        } else {
            tasks = (request, timeout)
            lock.unlock()
        }
    }

    func resolve(_ result: Result<FeedbackHTTPResponse, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        let tasks = self.tasks
        self.continuation = nil
        self.tasks = nil
        lock.unlock()
        tasks?.0.cancel(); tasks?.1.cancel()
        continuation?.resume(with: result)
    }
}
