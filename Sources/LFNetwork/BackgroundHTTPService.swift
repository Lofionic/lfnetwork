import Foundation

public struct BackgroundUploadResult: Sendable {
    public let identifier: String
    public let requestBody: Data
    public let result: Result<Data, any Error>

    public init(identifier: String, requestBody: Data, result: Result<Data, any Error>) {
        self.identifier = identifier
        self.requestBody = requestBody
        self.result = result
    }
}

public protocol BackgroundHTTPServicing: AnyObject, Sendable {
    func upload<R: HTTPRequest>(_ request: R, identifier: String) throws where R.RequestBody: Encodable
}

public final class BackgroundHTTPService: BackgroundHTTPServicing {
    public let sessionIdentifier: String

    private let builder: HTTPRequestBuilder
    private let delegate: Delegate
    private let session: URLSession

    public init(
        sessionIdentifier: String,
        scheme: HTTPServiceScheme,
        domain: String,
        port: Int? = nil,
        authorizationToken: String? = nil,
        onCompletion: @escaping @Sendable (BackgroundUploadResult) async -> Void
    ) {
        self.sessionIdentifier = sessionIdentifier
        builder = HTTPRequestBuilder(scheme: scheme, domain: domain, port: port, authorizationToken: authorizationToken)
        delegate = Delegate(directory: Self.directory(for: sessionIdentifier), onCompletion: onCompletion)

        let configuration = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    public func upload<R: HTTPRequest>(_ request: R, identifier: String) throws where R.RequestBody: Encodable {
        var urlRequest = try builder.makeURLRequest(request)
        let body = urlRequest.httpBody ?? Data()
        urlRequest.httpBody = nil

        let file = delegate.file(for: identifier)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: file)

        let task = session.uploadTask(with: urlRequest, fromFile: file)
        task.taskDescription = identifier
        task.resume()
    }

    public func handleEventsForBackgroundURLSession() async {
        await delegate.finishEvents()
    }

    private static func directory(for sessionIdentifier: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LFNetwork", isDirectory: true)
            .appendingPathComponent(sessionIdentifier, isDirectory: true)
    }
}

extension BackgroundHTTPService {
    static func result(data: Data, response: URLResponse?, error: (any Error)?) -> Result<Data, any Error> {
        if let error {
            return .failure(error)
        }
        do {
            try HTTPRequestBuilder.validate(response: response, acceptableStatusCodes: 200..<300)
            return .success(data)
        } catch {
            return .failure(error)
        }
    }
}

private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct State {
        var responses: [Int: Data] = [:]
        var completions: [UUID: Task<Void, Never>] = [:]
        var hasFinishedEvents = false
        var eventsFinished: CheckedContinuation<Void, Never>?
    }

    private let directory: URL
    private let onCompletion: @Sendable (BackgroundUploadResult) async -> Void
    private let lock = NSLock()
    private var state = State()

    init(directory: URL, onCompletion: @escaping @Sendable (BackgroundUploadResult) async -> Void) {
        self.directory = directory
        self.onCompletion = onCompletion
    }

    func file(for identifier: String) -> URL {
        let name = identifier.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? identifier
        return directory.appendingPathComponent(name).appendingPathExtension("body")
    }

    func finishEvents() async {
        await withCheckedContinuation { continuation in
            let hasFinished = withState { state in
                if state.hasFinishedEvents {
                    state.hasFinishedEvents = false
                    return true
                }
                state.eventsFinished = continuation
                return false
            }
            if hasFinished {
                continuation.resume()
            }
        }
        let completions = withState { state in
            Array(state.completions.values)
        }
        for completion in completions {
            await completion.value
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        withState { $0.responses[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let identifier = task.taskDescription else { return }

        let data = withState { $0.responses.removeValue(forKey: task.taskIdentifier) ?? Data() }
        let file = file(for: identifier)
        let requestBody = (try? Data(contentsOf: file)) ?? Data()
        try? FileManager.default.removeItem(at: file)

        let upload = BackgroundUploadResult(
            identifier: identifier,
            requestBody: requestBody,
            result: BackgroundHTTPService.result(data: data, response: task.response, error: error)
        )
        let id = UUID()
        let onCompletion = onCompletion
        withState { state in
            state.completions[id] = Task {
                await onCompletion(upload)
                self.withState { $0.completions[id] = nil }
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let continuation = withState { state in
            defer { state.eventsFinished = nil }
            if state.eventsFinished == nil {
                state.hasFinishedEvents = true
            }
            return state.eventsFinished
        }
        continuation?.resume()
    }

    private func withState<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}
