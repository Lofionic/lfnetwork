import Foundation

/// A `URLProtocol` that answers every request with a stubbed response, for testing code that uses `URLSession`.
///
/// Register it on a session configuration, then set `requestHandler`:
///
/// ```swift
/// let configuration = URLSessionConfiguration.ephemeral
/// configuration.protocolClasses = [MockURLProtocol.self]
/// let session = URLSession(configuration: configuration)
///
/// MockURLProtocol.requestHandler = { request in
///     let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
///     return (response, Data())
/// }
/// ```
///
/// The handler is shared by every session using this protocol, so tests that set it shouldn't run in parallel.
public final class MockURLProtocol: URLProtocol {
    /// The error a request fails with when `requestHandler` is `nil`.
    public struct MissingRequestHandlerError: Error, CustomStringConvertible {
        public let request: URLRequest
        public var description: String { "MockURLProtocol.requestHandler isn't set (request: \(request))" }
    }

    /// Returns the response and body for a request. Throw to make the request fail with that error, for example
    /// `URLError(.timedOut)`.
    ///
    /// The request's body arrives as `httpBodyStream`, not `httpBody`.
    nonisolated(unsafe)
    public static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    public override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    public override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: MissingRequestHandlerError(request: request))
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
