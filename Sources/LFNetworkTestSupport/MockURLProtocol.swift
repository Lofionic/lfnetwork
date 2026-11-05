import Foundation

/// A `URLSession` whose requests are answered by `requestHandler` instead of the network.
///
/// Each `MockURLSession` has its own handler, so tests that use separate sessions can run in parallel:
///
/// ```swift
/// let mock = MockURLSession { request in
///     let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
///     return (response, Data())
/// }
/// let service = HTTPService(urlSession: mock.urlSession, scheme: .https, domain: "api.example.com")
/// ```
///
/// Keep a reference to the `MockURLSession` for as long as you use its `urlSession`. Once it's released, requests
/// fail with `URLError(.resourceUnavailable)`.
public final class MockURLSession: @unchecked Sendable {
    /// Returns the response and body for a request. Throw a `URLError` to make the request fail with it, for example
    /// `URLError(.timedOut)`.
    ///
    /// Called on a background thread. The request's body arrives as `httpBodyStream`, not `httpBody`.
    public typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    /// The session to inject into the code under test.
    public let urlSession: URLSession

    /// Answers this session's requests. Can be replaced at any time; `nil` makes requests fail.
    public var requestHandler: Handler? {
        get { lock.withLock { _requestHandler } }
        set { lock.withLock { _requestHandler = newValue } }
    }

    let id = UUID().uuidString
    private let lock = NSLock()
    private var _requestHandler: Handler?

    /// - Parameters:
    ///   - configuration: The configuration to build the session from. Its `protocolClasses` are replaced.
    ///   - requestHandler: Answers the session's requests.
    public init(configuration: URLSessionConfiguration = .ephemeral, requestHandler: Handler? = nil) {
        _requestHandler = requestHandler
        configuration.protocolClasses = [MockURLProtocol.self]
        var headers = configuration.httpAdditionalHeaders ?? [:]
        headers[MockURLProtocol.sessionHeader] = id
        configuration.httpAdditionalHeaders = headers
        urlSession = URLSession(configuration: configuration)
        MockURLProtocol.registry.register(self)
    }

    deinit {
        MockURLProtocol.registry.remove(id)
    }
}

/// The `URLProtocol` behind `MockURLSession`. Use `MockURLSession` rather than registering this directly.
public final class MockURLProtocol: URLProtocol {
    /// The error a request fails with when it has no handler: `URLError(.resourceUnavailable)`, with a description
    /// explaining why. A `URLError` because URLSession converts other error types to a plain `NSError`.
    public static func missingHandlerError(for request: URLRequest) -> URLError {
        let description = "MockURLProtocol has no handler for \(request). Set MockURLSession.requestHandler, and keep a reference to the MockURLSession while it's in use."
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: description]
        userInfo[NSURLErrorFailingURLErrorKey] = request.url
        return URLError(.resourceUnavailable, userInfo: userInfo)
    }

    /// Answers requests from sessions that weren't made by `MockURLSession`. Shared by all of them, so tests that
    /// set it can't run in parallel.
    @available(*, deprecated, message: "Use MockURLSession, which has a handler per session.")
    nonisolated(unsafe)
    public static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { sharedHandler }
        set { sharedHandler = newValue }
    }

    nonisolated(unsafe)
    private static var sharedHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static let sessionHeader = "X-MockURLSession-ID"
    static let registry = Registry()

    /// Maps session IDs to their `MockURLSession`, without keeping them alive.
    final class Registry: @unchecked Sendable {
        private struct WeakSession { weak var session: MockURLSession? }
        private let lock = NSLock()
        private var sessions: [String: WeakSession] = [:]

        func register(_ session: MockURLSession) {
            lock.withLock { sessions[session.id] = WeakSession(session: session) }
        }

        func remove(_ id: String) {
            lock.withLock { sessions[id] = nil }
        }

        func session(for id: String) -> MockURLSession? {
            lock.withLock { sessions[id]?.session }
        }
    }

    public override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    public override func startLoading() {
        var request = self.request
        let handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
        if let id = request.value(forHTTPHeaderField: Self.sessionHeader) {
            request.setValue(nil, forHTTPHeaderField: Self.sessionHeader)
            handler = Self.registry.session(for: id)?.requestHandler
        } else {
            handler = Self.sharedHandler
        }

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: Self.missingHandlerError(for: request))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    public override func stopLoading() {}
}
