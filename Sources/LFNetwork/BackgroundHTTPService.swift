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

final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let directory: URL
    private let onCompletion: @Sendable (BackgroundUploadResult) async -> Void
    private let eventsFinished = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let lock = NSLock()
    private var responses: [Int: Data] = [:]
    private var lastCompletion: Task<Void, Never>?

    init(directory: URL, onCompletion: @escaping @Sendable (BackgroundUploadResult) async -> Void) {
        self.directory = directory
        self.onCompletion = onCompletion
    }

    func file(for identifier: String) -> URL {
        let name = identifier.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? identifier
        return directory.appendingPathComponent(name).appendingPathExtension("body")
    }

    func finishEvents() async {
        var events = eventsFinished.stream.makeAsyncIterator()
        await events.next()
        await locked { lastCompletion }?.value
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        locked { responses[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let identifier = task.taskDescription else { return }

        let data = locked { responses.removeValue(forKey: task.taskIdentifier) ?? Data() }
        let file = file(for: identifier)
        let requestBody = (try? Data(contentsOf: file)) ?? Data()
        try? FileManager.default.removeItem(at: file)

        let upload = BackgroundUploadResult(
            identifier: identifier,
            requestBody: requestBody,
            result: BackgroundHTTPService.result(data: data, response: task.response, error: error)
        )
        let onCompletion = onCompletion
        locked {
            let previous = lastCompletion
            lastCompletion = Task {
                await previous?.value
                await onCompletion(upload)
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        eventsFinished.continuation.yield()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
