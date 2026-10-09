# LFNetwork

A lightweight, `async`/`await` HTTP client for Swift, built on `URLSession`.

Describe each endpoint as a small `HTTPRequest` type, and `HTTPService` handles the rest: it builds the URL, encodes a JSON body, adds a bearer token, checks the status code, decodes the JSON response and retries temporary failures with exponential back-off.

- **Typed requests**: each endpoint declares its method, path, query, body and response type
- **Swift concurrency**: `async throws` APIs, `Sendable` throughout, and cancelling a task cancels its request
- **Automatic retries** for network failures and `408`/`429`/`5xx` responses, honouring `Retry-After`
- **No dependencies**

## Requirements

- iOS 15+ / macOS 13+
- Swift 6.4+

## Installation

Add the package with Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/<owner>/LFNetwork.git", branch: "main"),
],
targets: [
    .target(name: "MyApp", dependencies: ["LFNetwork"]),
]
```

## Usage

### Create a service

```swift
import LFNetwork

let service = HTTPService(
    scheme: .https,
    domain: "api.example.com",
    authorizationToken: token  // optional; sent as `Authorization: Bearer <token>`
)
```

### Define requests

A request declares its `Response` type and the request details. Everything except `path` has a default, so a request only spells out what differs.

```swift
struct User: Decodable, Sendable {
    let id: Int
    let name: String
}

struct GetUser: HTTPRequest {
    typealias RequestBody = Never
    typealias Response = User

    let id: Int
    var path: String { "/users/\(id)" }
}

struct SearchUsers: HTTPRequest {
    typealias RequestBody = Never
    typealias Response = [User]

    let query: String
    var path: String { "/users" }
    var queryItems: [String: String] { ["q": query] }
}
```

Requests with a body set `RequestBody` to an `Encodable` type. It's sent as JSON:

```swift
struct NewUser: Encodable, Sendable {
    let name: String
}

struct CreateUser: HTTPRequest {
    typealias Response = User

    let body: NewUser?
    var path: String { "/users" }
    var method: HTTPRequestMethod { .post }
}
```

Requests without a body set `RequestBody` to `Never`.

### Send requests

```swift
let user = try await service.doRequest(GetUser(id: 42))
let results = try await service.doRequest(SearchUsers(query: "ada"))
let created = try await service.doRequest(CreateUser(body: NewUser(name: "Ada")))
```

- **Raw bytes:** use `Response = Data` to get the response body undecoded, for example for images or files.
- **No body:** use `Response = EmptyResponse` for endpoints that return nothing, such as `204 No Content`.

### Customising a request

Override any of these properties on a request:

| Property | Default | |
|---|---|---|
| `method` | `.get` | |
| `queryItems` | `[:]` | Percent-encoded and sorted by name |
| `timeout` | `nil` | `nil` uses the service default of 45 seconds |
| `acceptableStatusCodes` | `200..<300` | Any other status throws |
| `retryPolicy` | `nil` | `nil` uses the service's policy |

### Errors

Failures throw `HTTPServiceError`:

| Case | Meaning |
|---|---|
| `.notAuthorized` | The server responded `401` |
| `.invalidStatusCode(statusCode:)` | Any other status outside `acceptableStatusCodes` |
| `.error(underlyingError:data:)` | The response couldn't be decoded; `data` holds the raw body |
| `.cannotFormURL` | The request's path or query couldn't form a valid URL (paths must start with `/`) |
| `.invalidResponse` | The response wasn't an HTTP response |

Network errors are rethrown as `URLError`. Cancelling the calling task throws `CancellationError` or `URLError(.cancelled)`.

```swift
do {
    let user = try await service.doRequest(GetUser(id: 42))
} catch HTTPServiceError.notAuthorized {
    // refresh credentials
} catch {
    // handle other failures
}
```

### Retries

By default, `HTTPService` makes up to 3 attempts at GET, PUT and DELETE requests that fail with:
- a network error such as a timeout or lost connection;
- a `408`, `429`, `500`, `502`, `503` or `504` response.

The waits between attempts double each time (0.5s, then 1s, up to 10s) and are randomised a little. If the server sends a `Retry-After` header, that wait is used instead.

POST and PATCH aren't retried by default, because the server may already have applied them.

```swift
// Configure retries for the whole service
let service = HTTPService(
    scheme: .https,
    domain: "api.example.com",
    retryPolicy: RetryPolicy(maxAttempts: 5, baseDelay: 1, maxDelay: 30)
)

// Disable retries for every request
let service = HTTPService(scheme: .https, domain: "api.example.com", retryPolicy: .none)

// Or for a single request
struct Ping: HTTPRequest {
    typealias RequestBody = Never
    typealias Response = EmptyResponse

    var path: String { "/ping" }
    var retryPolicy: RetryPolicy? { RetryPolicy.none }
}
```

### Testing

Your code can depend on the `HTTPServicing` protocol instead of `HTTPService`, so tests can substitute a mock. To test against `HTTPService` itself, pass it a `URLSession` configured with a custom `URLProtocol`:

```swift
let configuration = URLSessionConfiguration.ephemeral
configuration.protocolClasses = [MockURLProtocol.self]

let service = HTTPService(
    urlSession: URLSession(configuration: configuration),
    scheme: .https,
    domain: "api.example.com",
    retryPolicy: .none
)
```

See `Tests/LFNetworkTests` for a complete example.
