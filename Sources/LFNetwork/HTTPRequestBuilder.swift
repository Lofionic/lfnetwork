import Foundation

struct HTTPRequestBuilder: Sendable {
    static let defaultTimeout: TimeInterval = 45

    let scheme: HTTPServiceScheme
    let domain: String
    let port: Int?
    let authorizationToken: String?

    static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    func url<R: HTTPRequest>(for request: R) -> URL? {
        var urlComponents = URLComponents()
        urlComponents.scheme = scheme.rawValue
        urlComponents.host = domain
        urlComponents.port = port
        urlComponents.path = request.path
        let queryItems = request.queryItems.urlQueryItems
        urlComponents.percentEncodedQueryItems = queryItems.isEmpty ? nil : queryItems
        return urlComponents.url
    }

    func makeURLRequest<R: HTTPRequest>(_ request: R) throws -> URLRequest {
        guard let url = url(for: request) else {
            throw HTTPServiceError.cannotFormURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        if let body = request.body as? Encodable {
            urlRequest.httpBody = try Self.makeJSONEncoder().encode(body)
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        urlRequest.timeoutInterval = request.timeout ?? Self.defaultTimeout
        if let authorizationToken {
            urlRequest.setValue("Bearer \(authorizationToken)", forHTTPHeaderField: "Authorization")
        }
        return urlRequest
    }

    static func validate(response: URLResponse?, acceptableStatusCodes: Range<Int>) throws {
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
