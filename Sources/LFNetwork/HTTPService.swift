import Foundation
import OSLog

public enum HTTPServiceScheme: String, Sendable {
    case http
    case https
}

public enum HTTPServiceError: Swift.Error {
    case cannotFormURL
    case invalidResponse
    case notAuthorized
    case invalidStatusCode(statusCode: Int)
    case error(underlyingError: Error, data: Data?)
    case unknown
}

extension HTTPServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cannotFormURL: return "Cannot form URL"
        case .invalidResponse: return "Invalid response"
        case .notAuthorized: return "Not Authorized"
        case .invalidStatusCode(let statusCode): return "Invalid status code (\(statusCode))"
        case .error(let error, _): return "Underlying error: \(error.localizedDescription)"
        case .unknown: return "Unknown"
        }
    }
}

public protocol HTTPServicing: AnyObject, Sendable {
    var authorizationToken: String? { get }
    func doRequest<R: HTTPRequest, T>(_ request: R) async throws -> T where R.Response == T, T: Decodable
    func doRequest<R: HTTPRequest>(_ request: R) async throws -> Data where R.Response == Data
}

extension HTTPService: HTTPServicing {
    public func doRequest<R: HTTPRequest>(_ request: R) async throws -> Data where R.Response == Data {
        try await performRequest(request)
    }

    public func doRequest<R: HTTPRequest, T>(_ request: R) async throws -> T where R.Response == T, T: Decodable {
        let data = try await performRequest(request)
        if data.isEmpty, let empty = EmptyResponse() as? T {
            return empty
        }
        do {
            return try jsonDecoder.decode(T.self, from: data)
        } catch {
            throw HTTPServiceError.error(underlyingError: error, data: data)
        }
    }
}

nonisolated
public final class HTTPService: Sendable {
    public let scheme: HTTPServiceScheme
    public let domain: String
    public let port: Int?
    
    public let authorizationToken: String?
    public let retryPolicy: RetryPolicy
    
    private let urlSession: URLSession
    private let builder: HTTPRequestBuilder
    
    private let jsonDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()
    
    @usableFromInline
    static let urlSessionConfiguration: URLSessionConfiguration = {
        let configuration = URLSessionConfiguration.default
        configuration.allowsCellularAccess = true
        return configuration
    }()
    
    public init(
        urlSession: URLSession = URLSession(configuration: urlSessionConfiguration),
        scheme: HTTPServiceScheme,
        domain: String,
        port: Int? = nil,
        authorizationToken: String? = nil,
        retryPolicy: RetryPolicy = .default)
    {
        self.urlSession = urlSession
        self.scheme = scheme
        self.domain = domain
        self.port = port
        self.authorizationToken = authorizationToken
        self.retryPolicy = retryPolicy
        self.builder = HTTPRequestBuilder(scheme: scheme, domain: domain, port: port, authorizationToken: authorizationToken)
    }
    
    //MARK: - Private/Internal
    
    func makeURLRequest<R: HTTPRequest>(_ request: R) throws -> URLRequest {
        try builder.makeURLRequest(request)
    }
    
    private func performRequest<R: HTTPRequest>(_ request: R) async throws -> Data {
        let urlRequest = try makeURLRequest(request)
        let retryPolicy = request.retryPolicy ?? self.retryPolicy
        var attempt = 1
        
        while true {
            var httpURLResponse: HTTPURLResponse?
            do {
                let (data, response) = try await urlSession.data(for: urlRequest)
                httpURLResponse = response as? HTTPURLResponse
                try HTTPRequestBuilder.validate(response: response, acceptableStatusCodes: request.acceptableStatusCodes)
                return data
            } catch {
                guard let delay = retryPolicy.delay(
                    afterAttempt: attempt,
                    method: request.method,
                    error: error,
                    response: httpURLResponse)
                else {
                    throw error
                }
                // Throws CancellationError if the calling task is cancelled during back-off.
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                attempt += 1
            }
        }
    }
}
