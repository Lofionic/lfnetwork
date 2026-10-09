import Foundation

/// Exponential back-off for transient failures.
///
/// The delay before retry `n` is `baseDelay * multiplier^(n - 1)`, capped at `maxDelay`. With `jitter`,
/// each delay is randomised within its upper half so clients that failed together don't retry in lockstep.
/// A `Retry-After` header (in seconds) on a retryable response takes precedence, still capped at `maxDelay`.
public struct RetryPolicy: Sendable {
    /// Total attempts, including the first. `1` disables retries.
    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public var multiplier: Double
    public var maxDelay: TimeInterval
    public var jitter: Bool
    /// Non-idempotent methods (POST, PATCH) are excluded by default: the server may already have applied them.
    public var retryableMethods: Set<HTTPRequestMethod>
    public var retryableStatusCodes: Set<Int>

    public init(
        maxAttempts: Int = 3,
        baseDelay: TimeInterval = 0.5,
        multiplier: Double = 2,
        maxDelay: TimeInterval = 10,
        jitter: Bool = true,
        retryableMethods: Set<HTTPRequestMethod> = [.get, .put, .delete],
        retryableStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504])
    {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.multiplier = multiplier
        self.maxDelay = maxDelay
        self.jitter = jitter
        self.retryableMethods = retryableMethods
        self.retryableStatusCodes = retryableStatusCodes
    }

    public static let `default` = RetryPolicy()
    public static let none = RetryPolicy(maxAttempts: 1)

    /// The delay before the next attempt, or `nil` if the failure shouldn't be retried.
    func delay(
        afterAttempt attempt: Int,
        method: HTTPRequestMethod,
        error: Error,
        response: HTTPURLResponse?) -> TimeInterval?
    {
        guard attempt < maxAttempts,
              retryableMethods.contains(method),
              isRetryable(error)
        else {
            return nil
        }

        if let retryAfter = response?.retryAfter {
            return min(retryAfter, maxDelay)
        }

        let exponential = baseDelay * pow(multiplier, Double(attempt - 1))
        let capped = max(0, min(exponential, maxDelay))
        return jitter ? Double.random(in: (capped / 2)...capped) : capped
    }

    private func isRetryable(_ error: Error) -> Bool {
        switch error {
        case HTTPServiceError.invalidStatusCode(let statusCode):
            retryableStatusCodes.contains(statusCode)
        case let urlError as URLError:
            Self.retryableURLErrorCodes.contains(urlError.code)
        default:
            false
        }
    }

    private static let retryableURLErrorCodes: Set<URLError.Code> = [
        .timedOut,
        .networkConnectionLost,
        .notConnectedToInternet,
        .cannotConnectToHost,
        .cannotFindHost,
        .dnsLookupFailed,
    ]
}

private extension HTTPURLResponse {
    var retryAfter: TimeInterval? {
        guard let value = value(forHTTPHeaderField: "Retry-After"),
              let seconds = Double(value.trimmingCharacters(in: .whitespaces)),
              seconds >= 0
        else {
            return nil
        }
        return seconds
    }
}
