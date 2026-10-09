import XCTest
@testable import LFNetwork

final class LFNetworkTests: XCTestCase {
    lazy var urlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]

        let session = URLSession(configuration: configuration)
        return session
    }()

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    // MARK: - URL request construction

    func testGetRequestBuildsURLMethodAndHeaders() async throws {
        let recorder = stub(statusCode: 200, data: Item.json)
        let service = makeService(port: 8080, authorizationToken: "secret")

        let _: Item = try await service.doRequest(GetRequest<Item>(path: "/items/1"))

        let request = try XCTUnwrap(recorder.request)
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com:8080/items/1")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertNil(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(recorder.body?.isEmpty ?? true)
    }

    func testNoAuthorizationHeaderWithoutToken() async throws {
        let recorder = stub(statusCode: 200, data: Item.json)

        let _: Item = try await makeService().doRequest(GetRequest<Item>(path: "/items/1"))

        XCTAssertNil(try XCTUnwrap(recorder.request).value(forHTTPHeaderField: "Authorization"))
    }

    func testQueryItemsAreSortedAndPercentEncoded() throws {
        let request = GetRequest<Item>(
            path: "/search",
            queryItems: ["q": "a b+c&d=e", "b": "2", "a": "1"]
        )

        let urlRequest = try makeService().makeURLRequest(request)

        XCTAssertEqual(
            urlRequest.url?.absoluteString,
            "https://api.example.com/search?a=1&b=2&q=a%20b%2Bc%26d%3De"
        )
    }

    func testNoQueryStringWhenNoQueryItems() throws {
        let urlRequest = try makeService().makeURLRequest(GetRequest<Item>(path: "/items"))

        XCTAssertEqual(urlRequest.url?.absoluteString, "https://api.example.com/items")
    }

    func testTimeoutDefaultsAndOverrides() throws {
        let service = makeService()

        XCTAssertEqual(try service.makeURLRequest(GetRequest<Item>(path: "/items")).timeoutInterval, 45)
        XCTAssertEqual(try service.makeURLRequest(GetRequest<Item>(path: "/items", timeout: 5)).timeoutInterval, 5)
    }

    func testPathWithoutLeadingSlashThrowsCannotFormURL() async {
        let error = await capturedError {
            let _: Item = try await self.makeService().doRequest(GetRequest<Item>(path: "items"))
        }

        guard case HTTPServiceError.cannotFormURL = error ?? NoError() else {
            return XCTFail("Unexpected error: \(String(describing: error))")
        }
    }

    func testPostRequestEncodesJSONBody() async throws {
        let recorder = stub(statusCode: 201, data: Item.json)
        let request = TestRequest<Item, Item>(path: "/items", method: .post, body: Item(id: 1, name: "Widget"))

        let _: Item = try await makeService().doRequest(request)

        let urlRequest = try XCTUnwrap(recorder.request)
        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Content-Type"), "application/json")
        // Keys are sorted by the service's encoder.
        XCTAssertEqual(recorder.body.map { String(decoding: $0, as: UTF8.self) }, #"{"id":1,"name":"Widget"}"#)
    }

    // MARK: - Responses

    func testDecodesSuccessfulResponse() async throws {
        stub(statusCode: 200, data: Item.json)

        let item: Item = try await makeService().doRequest(GetRequest<Item>(path: "/items/1"))

        XCTAssertEqual(item, Item(id: 1, name: "Widget"))
    }

    func testDataRequestReturnsRawBytes() async throws {
        let bytes = Data([0x00, 0xFF, 0x10, 0x80])
        stub(statusCode: 200, data: bytes)

        let data = try await makeService().doRequest(GetRequest<Data>(path: "/file"))

        XCTAssertEqual(data, bytes)
    }

    func testAnySuccessStatusIsAcceptedByDefault() async throws {
        for statusCode in [200, 201, 202, 299] {
            stub(statusCode: statusCode, data: Item.json)

            let item: Item = try await makeService().doRequest(GetRequest<Item>(path: "/items/1"))

            XCTAssertEqual(item.id, 1, "status \(statusCode)")
        }
    }

    func testNoContentReturnsEmptyResponse() async throws {
        stub(statusCode: 204, data: Data())

        let response = try await makeService().doRequest(TestRequest<Never, EmptyResponse>(path: "/items/1", method: .delete))

        XCTAssertEqual(response, EmptyResponse())
    }

    func testUnauthorizedThrowsNotAuthorized() async {
        stub(statusCode: 401, data: Data())

        let error = await capturedError {
            let _: Item = try await self.makeService().doRequest(GetRequest<Item>(path: "/items/1"))
        }

        guard case HTTPServiceError.notAuthorized = error ?? NoError() else {
            return XCTFail("Unexpected error: \(String(describing: error))")
        }
    }

    func testUnacceptableStatusThrowsInvalidStatusCode() async {
        stub(statusCode: 500, data: Data())

        let error = await capturedError {
            let _: Item = try await self.makeService().doRequest(GetRequest<Item>(path: "/items/1"))
        }

        guard case HTTPServiceError.invalidStatusCode(500) = error ?? NoError() else {
            return XCTFail("Unexpected error: \(String(describing: error))")
        }
    }

    func testUnacceptableStatusThrowsForDataRequests() async {
        stub(statusCode: 404, data: Data())

        let error = await capturedError {
            _ = try await self.makeService().doRequest(GetRequest<Data>(path: "/file"))
        }

        guard case HTTPServiceError.invalidStatusCode(404) = error ?? NoError() else {
            return XCTFail("Unexpected error: \(String(describing: error))")
        }
    }

    func testCustomAcceptableStatusCodesNarrowSuccess() async {
        stub(statusCode: 201, data: Item.json)

        let error = await capturedError {
            let _: Item = try await self.makeService().doRequest(
                GetRequest<Item>(path: "/items/1", acceptableStatusCodes: 200..<201)
            )
        }

        guard case HTTPServiceError.invalidStatusCode(201) = error ?? NoError() else {
            return XCTFail("Unexpected error: \(String(describing: error))")
        }
    }

    func testDecodingFailureIsWrappedWithResponseData() async {
        let invalidJSON = Data(#"{"unexpected":true}"#.utf8)
        stub(statusCode: 200, data: invalidJSON)

        let error = await capturedError {
            let _: Item = try await self.makeService().doRequest(GetRequest<Item>(path: "/items/1"))
        }

        guard case HTTPServiceError.error(let underlyingError, let data) = error ?? NoError() else {
            return XCTFail("Unexpected error: \(String(describing: error))")
        }
        XCTAssertTrue(underlyingError is DecodingError)
        XCTAssertEqual(data, invalidJSON)
    }

    // MARK: - Retries
    
    func testRetriesTransientFailureThenSucceeds() async throws {
        let recorder = stub(statusCodes: [503, 502, 200], data: Item.json)
        
        let item: Item = try await makeService(retryPolicy: .fast).doRequest(GetRequest<Item>(path: "/items/1"))
        
        XCTAssertEqual(item.id, 1)
        XCTAssertEqual(recorder.count, 3)
    }
    
    func testStopsRetryingAfterMaxAttempts() async {
        let recorder = stub(statusCodes: [500], data: Data())
        
        let error = await capturedError {
            let _: Item = try await self.makeService(retryPolicy: .fast).doRequest(GetRequest<Item>(path: "/items/1"))
        }
        
        guard case HTTPServiceError.invalidStatusCode(500) = error ?? NoError() else {
            return XCTFail("Unexpected error: \(String(describing: error))")
        }
        XCTAssertEqual(recorder.count, RetryPolicy.fast.maxAttempts)
    }
    
    func testDoesNotRetryNonRetryableStatus() async {
        let recorder = stub(statusCodes: [404], data: Data())
        
        _ = await capturedError {
            let _: Item = try await self.makeService(retryPolicy: .fast).doRequest(GetRequest<Item>(path: "/items/1"))
        }
        
        XCTAssertEqual(recorder.count, 1)
    }
    
    func testDoesNotRetryNonIdempotentMethods() async {
        let recorder = stub(statusCodes: [503], data: Data())
        let request = TestRequest<Item, Item>(path: "/items", method: .post, body: Item(id: 1, name: "Widget"))
        
        _ = await capturedError {
            let _: Item = try await self.makeService(retryPolicy: .fast).doRequest(request)
        }
        
        XCTAssertEqual(recorder.count, 1)
    }
    
    func testRequestRetryPolicyOverridesService() async {
        let recorder = stub(statusCodes: [503], data: Data())
        
        _ = await capturedError {
            let _: Item = try await self.makeService(retryPolicy: .fast).doRequest(
                GetRequest<Item>(path: "/items/1", retryPolicy: RetryPolicy.none)
            )
        }
        
        XCTAssertEqual(recorder.count, 1)
    }
    
    func testCancellationDuringBackOffStopsRetrying() async {
        let recorder = stub(statusCodes: [503], data: Data())
        let service = makeService(retryPolicy: RetryPolicy(baseDelay: 30, jitter: false))
        
        let task = Task {
            let _: Item = try await service.doRequest(GetRequest<Item>(path: "/items/1"))
        }
        while recorder.count == 0 {
            await Task.yield()
        }
        // The mock records the request before URLSession delivers the 503; give it time to reach the back-off sleep.
        try? await Task.sleep(nanoseconds: 200_000_000)
        let start = Date()
        task.cancel()
        let result = await task.result
        
        guard case .failure(let error) = result, error is CancellationError else {
            return XCTFail("Expected CancellationError, got \(result)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "Back-off wasn't interrupted")
        XCTAssertEqual(recorder.count, 1)
    }
    
    // MARK: - RetryPolicy
    
    func testBackOffIsExponentialAndCapped() {
        let policy = RetryPolicy(maxAttempts: 10, baseDelay: 1, multiplier: 2, maxDelay: 5, jitter: false)
        let delays = (1...4).map { policy.delay(afterAttempt: $0, method: .get, error: URLError(.timedOut), response: nil) }
        
        XCTAssertEqual(delays, [1, 2, 4, 5])
    }
    
    func testJitterStaysWithinUpperHalfOfDelay() throws {
        let policy = RetryPolicy(maxAttempts: 10, baseDelay: 1, multiplier: 2, maxDelay: 60)
        
        for _ in 0..<100 {
            let delay = try XCTUnwrap(policy.delay(afterAttempt: 3, method: .get, error: URLError(.timedOut), response: nil))
            XCTAssertTrue((2...4).contains(delay), "\(delay)")
        }
    }
    
    func testRetryAfterHeaderTakesPrecedenceAndIsCapped() {
        let policy = RetryPolicy(baseDelay: 1, maxDelay: 10, jitter: false)
        let error = HTTPServiceError.invalidStatusCode(statusCode: 429)
        
        XCTAssertEqual(policy.delay(afterAttempt: 1, method: .get, error: error, response: response(retryAfter: "3")), 3)
        XCTAssertEqual(policy.delay(afterAttempt: 1, method: .get, error: error, response: response(retryAfter: "120")), 10)
        XCTAssertEqual(policy.delay(afterAttempt: 1, method: .get, error: error, response: response(retryAfter: "soon")), 1)
    }
    
    func testRetryableErrors() {
        let policy = RetryPolicy(jitter: false)
        func retries(_ error: Error) -> Bool {
            policy.delay(afterAttempt: 1, method: .get, error: error, response: nil) != nil
        }
        
        XCTAssertTrue(retries(URLError(.timedOut)))
        XCTAssertTrue(retries(URLError(.networkConnectionLost)))
        XCTAssertTrue(retries(HTTPServiceError.invalidStatusCode(statusCode: 503)))
        XCTAssertFalse(retries(URLError(.cancelled)))
        XCTAssertFalse(retries(URLError(.badURL)))
        XCTAssertFalse(retries(HTTPServiceError.invalidStatusCode(statusCode: 400)))
        XCTAssertFalse(retries(HTTPServiceError.notAuthorized))
        XCTAssertFalse(retries(CancellationError()))
    }
    
    // MARK: - Helpers

    /// Retries are disabled unless a test opts in, so failure tests don't wait on back-off.
    private func makeService(
        port: Int? = nil,
        authorizationToken: String? = nil,
        retryPolicy: RetryPolicy = .none) -> HTTPService
    {
        HTTPService(
            urlSession: urlSession,
            scheme: .https,
            domain: "api.example.com",
            port: port,
            authorizationToken: authorizationToken,
            retryPolicy: retryPolicy
        )
    }

    /// Responds to every request with `statusCode` and `data`, recording the last request and its body.
    @discardableResult
    private func stub(statusCode: Int, data: Data) -> RequestRecorder {
        stub(statusCodes: [statusCode], data: data)
    }
    
    /// Responds to successive requests with `statusCodes` in order, repeating the last one once exhausted.
    @discardableResult
    private func stub(statusCodes: [Int], data: Data, headerFields: [String: String]? = nil) -> RequestRecorder {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            let count = recorder.record(request)
            let statusCode = statusCodes[min(count, statusCodes.count) - 1]
            let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: headerFields)!
            return (response, data)
        }
        return recorder
    }

    private func capturedError(_ operation: () async throws -> Void) async -> Error? {
        do {
            try await operation()
            return nil
        } catch {
            return error
        }
    }
}

// MARK: - Fixtures

private struct Item: Codable, Equatable, Sendable {
    let id: Int
    let name: String

    static let json = Data(#"{"id":1,"name":"Widget"}"#.utf8)
}

private struct NoError: Error {}

private extension RetryPolicy {
    static let fast = RetryPolicy(maxAttempts: 3, baseDelay: 0.001, jitter: false)
}

private func response(retryAfter: String) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "https://api.example.com")!,
        statusCode: 429,
        httpVersion: nil,
        headerFields: ["Retry-After": retryAfter]
    )!
}

private struct TestRequest<RequestBody: Encodable & Sendable, Response: Sendable>: HTTPRequest {
    var path: String
    var method: HTTPRequestMethod = .get
    var queryItems: [String: String] = [:]
    var body: RequestBody?
    var timeout: TimeInterval?
    var acceptableStatusCodes: Range<Int> = 200..<300
    var retryPolicy: RetryPolicy?
}

private typealias GetRequest<Response: Sendable> = TestRequest<Never, Response>

/// Captures the request seen by `MockURLProtocol`. URLSession delivers the body as a stream, so it's read eagerly.
private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _request: URLRequest?
    private var _body: Data?
    private var _count = 0

    var request: URLRequest? { lock.withLock { _request } }
    var body: Data? { lock.withLock { _body } }
    var count: Int { lock.withLock { _count } }

    /// Returns the number of requests recorded so far, including this one.
    @discardableResult
    func record(_ request: URLRequest) -> Int {
        let body = request.httpBody ?? request.httpBodyStream.map(Data.init(reading:))
        return lock.withLock {
            _request = request
            _body = body
            _count += 1
            return _count
        }
    }
}

private extension Data {
    init(reading stream: InputStream) {
        self.init()
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            append(buffer, count: count)
        }
    }
}
