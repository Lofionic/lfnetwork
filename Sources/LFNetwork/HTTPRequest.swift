import Foundation

public enum HTTPRequestMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

/// Use as `Response` for requests whose success response has no body (e.g. `204 No Content`).
public struct EmptyResponse: Decodable, Equatable, Sendable {
    public init() {}
}

public protocol HTTPRequest: Sendable {
    associatedtype RequestBody
    associatedtype Response: Sendable
    
    var path: String { get }
    
    var method: HTTPRequestMethod { get }
    var queryItems: [String: String] { get }
    var body: RequestBody? { get }
    var timeout: TimeInterval? { get }
    var acceptableStatusCodes: Range<Int> { get }
    /// Overrides the service's retry policy for this request.
    var retryPolicy: RetryPolicy? { get }
}

public extension HTTPRequest {
    var method: HTTPRequestMethod { .get }
    var queryItems: [String: String] { [:] }
    var body: RequestBody? { nil }
    var timeout: TimeInterval? { nil }
    var acceptableStatusCodes: Range<Int> { 200..<300 }
    var retryPolicy: RetryPolicy? { nil }
}
