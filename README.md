# LFNetwork

A lightweight, `async`/`await` HTTP client for Swift, built on `URLSession`.

Describe each endpoint as a small `HTTPRequest` type, and `HTTPService` handles the rest: it builds the URL, encodes a JSON body, adds a bearer token, checks the status code, decodes the JSON response and retries temporary failures with exponential back-off.

- **Typed requests**: each endpoint declares its method, path, query, body and response type
- **Swift concurrency**: `async throws` APIs, `Sendable` throughout, and cancelling a task cancels its request
- **Automatic retries** for network failures and `408`/`429`/`5xx` responses, honouring `Retry-After`
- **Background uploads** that finish even if the app is suspended or quits, using a background `URLSession`
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

### Background uploads

`HTTPService` sends requests from your app's process, so a request stops if the system suspends the app. For a request that should finish anyway, such as a slow request started from a background task, use `BackgroundHTTPService`. It hands the upload to the system, which finishes it even if the app is suspended or quits. When the response arrives, the system relaunches the app in the background if needed.

Create one `BackgroundHTTPService` per session identifier, early in your app's launch, and keep it for the life of the app. The system delivers finished uploads to the service that owns the session, including after a relaunch:

```swift
let uploads = BackgroundHTTPService(
    sessionIdentifier: "com.example.app.uploads",
    scheme: .https,
    domain: "api.example.com",
    authorizationToken: token
) { upload in
    // upload.identifier: the identifier you gave the upload
    // upload.requestBody: the JSON body that was sent
    // upload.result: the response body, or the error
    if let data = try? upload.result.get() {
        // save the response
    }
}
```

Start an upload with any request whose `RequestBody` is `Encodable`. The identifier tells you which upload a result belongs to, so make it something you can act on later, such as a record's ID:

```swift
try uploads.upload(CreateUser(body: NewUser(name: "Ada")), identifier: "new-user-ada")
```

`upload(_:identifier:)` returns once the upload has started; the result arrives in the completion handler. When the system relaunches your app for a session, wait for the results before telling it you're done. In SwiftUI:

```swift
.backgroundTask(.urlSession("com.example.app.uploads")) {
    await uploads.handleEventsForBackgroundURLSession()
}
```

How background uploads differ from `HTTPService`:
- The body is written to a file in the app's Caches folder while it's uploading, and removed when the upload finishes.
- The system waits for a connection and retries network failures itself; the service's `RetryPolicy` isn't used.
- Any `2xx` status is a success. A `401` fails with `HTTPServiceError.notAuthorized` and any other status with `.invalidStatusCode(statusCode:)`. A request's `acceptableStatusCodes` is ignored, because the result can arrive in a new launch of the app.
- The response body is delivered as raw `Data`, for you to decode.
- Results are handled one at a time, in the order the uploads finish.

To test code that starts uploads, depend on the `BackgroundHTTPServicing` protocol and substitute a mock, then call your completion handling directly with a `BackgroundUploadResult`.

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
