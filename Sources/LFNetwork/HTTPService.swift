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
    
    let jsonEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()
    private let jsonDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()
    
    let defaultTimeout: TimeInterval = 45.0
    
    var queryItems: [String: String] { [:] }
    
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
    }
    
    //MARK: - Private/Internal
    
    private func getURLForRequest<R: HTTPRequest>(_ request: R) -> URL? {
        let queryItems = self.queryItems.urlQueryItems
        let requestQueryItems = request.queryItems.urlQueryItems
        
        var urlComponents = URLComponents()
        urlComponents.scheme = scheme.rawValue
        urlComponents.host = domain
        urlComponents.port = port
        urlComponents.path = request.path
        urlComponents.percentEncodedQueryItems = queryItems + requestQueryItems
        if urlComponents.percentEncodedQueryItems?.count == 0 {
            urlComponents.percentEncodedQueryItems = nil
        }
        return urlComponents.url
    }
    
    func makeURLRequest<R: HTTPRequest>(_ request: R) throws -> URLRequest {
        guard let url = getURLForRequest(request) else {
            throw HTTPServiceError.cannotFormURL
        }
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        if let body = request.body as? Encodable {
            urlRequest.httpBody = try jsonEncoder.encode(body)
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        
        urlRequest.timeoutInterval = request.timeout ?? defaultTimeout
        
        if let authorizationToken {
            urlRequest.setValue("Bearer \(authorizationToken)", forHTTPHeaderField: "Authorization")
        }
        return urlRequest
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
                try validate(response: response, acceptableStatusCodes: request.acceptableStatusCodes)
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
    
    private func validate(response: URLResponse, acceptableStatusCodes: Range<Int>) throws {
        guard let httpURLResponse = response as? HTTPURLResponse else {
            throw HTTPServiceError.invalidResponse
        }
        
        guard acceptableStatusCodes.contains(httpURLResponse.statusCode) else {
            if httpURLResponse.statusCode == 401 {
                throw HTTPServiceError.notAuthorized
            } else {
                throw HTTPServiceError.invalidStatusCode(statusCode: httpURLResponse.statusCode)
            }
        }
    }
}

private extension Dictionary where Key == String, Value == String {
    /// Sorted by name so the resulting URL is deterministic (stable for caching, signing and tests).
    var urlQueryItems: [URLQueryItem] {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))
        return sorted { $0.key < $1.key }.map { name, value in
            URLQueryItem(
                name: name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name,
                value: value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            )
        }
    }
}
