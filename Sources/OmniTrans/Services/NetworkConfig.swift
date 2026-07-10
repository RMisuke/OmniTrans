import Foundation
import OSLog

// MARK: - Unified Network Configuration (L1)

/// Single source of truth for all networking timeout constants, session
/// configuration knobs, and connection tuning parameters.
/// Every `req.timeoutInterval = …` in the codebase should reference these values,
/// making it trivial to adjust timeouts globally.
enum NetworkConfig {
    // MARK: Session-level (sharedURLSession)
    static let requestTimeout: TimeInterval = 30
    static let resourceTimeout: TimeInterval = 60
    static let maxConnectionsPerHost = 10
    /// Whether to wait for connectivity instead of failing immediately (P1)
    static let waitsForConnectivity = true
    /// Timeout for the initial TCP/TLS connection phase
    static let connectTimeout: TimeInterval = 8

    // MARK: Per-operation timeouts
    /// AI streaming (SSE) — OpenAI / Anthropic / Gemini
    static let streamingTimeout: TimeInterval = 30
    /// Non-streaming AI fallback — OpenAI / Anthropic / Gemini
    static let nonStreamingTimeout: TimeInterval = 20
    /// Traditional MT — Google / Bing / Alibaba / Volcengine
    static let mtTimeout: TimeInterval = 20
    /// Model list fetching — OpenAI / Gemini models endpoint
    static let modelFetchTimeout: TimeInterval = 15
    /// Lightweight connectivity probes (HEAD) — M2
    static let probeTimeout: TimeInterval = 5
    /// Ollama heartbeat — localhost, should be near-instant
    static let ollamaProbeTimeout: TimeInterval = 2
    /// Pre-warm connection probe (best-effort, fire-and-forget)
    static let warmupTimeout: TimeInterval = 3

    // MARK: Throttle intervals (L2)
    /// ThrottledStream fast path — normal streaming (35ms ≈ 28fps)
    static let throttleFastNs: UInt64 = 35_000_000
    /// ThrottledStream slow path — during window drag (120ms)
    static let throttleSlowNs: UInt64 = 120_000_000

    // MARK: Probe cache (P5)
    /// How long a successful probe result is considered valid (seconds)
    static let probeCacheTTL: TimeInterval = 30
    /// How long a local Ollama probe is cached (seconds)
    static let ollamaProbeCacheTTL: TimeInterval = 10
}

// MARK: - Structured Network Logger (L3)

/// Runtime-level logging for all network I/O.
/// Uses `OSLog` so Debug-level messages are captured during development
/// (visible via Console.app or `log stream`) while Error-level messages
/// are always persisted — even in Release builds.
///
/// To view Debug logs in real time:
///   $ log stream --predicate 'subsystem == "com.omnitrans.omnitrans"'
enum NetworkLogger {
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.omnitrans.omnitrans",
        category: "network"
    )

    /// Logs an outgoing HTTP request with method, URL, and body preview.
    static func logRequest(_ request: URLRequest, body: Data? = nil, label: String = "") {
        let method = request.httpMethod ?? "GET"
        let url = request.url?.absoluteString ?? "?"
        let tag = label.isEmpty ? "" : "[\(label)] "
        os_log(.debug, log: log, "%{public}@──→ %{public}@ %{public}@", tag, method, url)
        if let body = body, let str = String(data: body, encoding: .utf8), !str.isEmpty {
            os_log(.debug, log: log, "%{public}@  body: %{public}@", tag, String(str.prefix(500)))
        }
    }

    /// Logs an incoming HTTP response with status code and body preview.
    static func logResponse(_ response: HTTPURLResponse, data: Data? = nil, label: String = "") {
        let tag = label.isEmpty ? "" : "[\(label)] "
        os_log(.debug, log: log, "%{public}@←── HTTP %d", tag, response.statusCode)
        if let data = data, let str = String(data: data, encoding: .utf8), !str.isEmpty {
            os_log(.debug, log: log, "%{public}@  body: %{public}@", tag, String(str.prefix(500)))
        }
    }

    /// Logs an error with context label and duration (if available).
    /// Uses `.error` level so it's captured in both Debug and Release builds.
    static func logError(_ label: String, _ error: Error, duration: TimeInterval? = nil) {
        let dur = duration.map { String(format: " (%.1fms)", $0 * 1000) } ?? ""
        os_log(.error, log: log, "❌ [%{public}@]%{public}@ %{public}@", label, dur, String(error.localizedDescription.prefix(200)))
    }

    /// Logs a debug message with label.
    static func log(_ label: String, _ message: String) {
        os_log(.debug, log: log, "🔍 [%{public}@] %{public}@", label, message)
    }
}

// MARK: - Exponential Backoff Retry (L7)

/// Utility for retrying network operations with exponential backoff + jitter.
///
/// Usage:
/// ```swift
/// let result = try await RetryUtility.retryWithBackoff(maxRetries: 3) {
///     try await someNetworkCall()
/// }
/// ```
enum RetryUtility {
    /// Retries `operation` up to `maxRetries` times.
    /// - Parameters:
    ///   - maxRetries: Maximum number of attempts (default 3, includes the first try).
    ///   - baseDelay: Initial delay in seconds (doubles each retry, default 0.5).
    ///   - maxDelay: Cap on delay in seconds (default 10).
    ///   - isRetryable: Optional predicate to skip retry on certain errors (e.g. auth errors).
    ///   - operation: The async throwing operation to retry.
    /// - Returns: The result of `operation` on success.
    /// - Throws: The last error if all retries are exhausted.
    static func retryWithBackoff<T>(
        maxRetries: Int = 3,
        baseDelay: TimeInterval = 0.5,
        maxDelay: TimeInterval = 10,
        isRetryable: @Sendable (Error) -> Bool = { _ in true },
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        var lastError: Error = CancellationError()

        for attempt in 0..<maxRetries {
            do {
                return try await operation()
            } catch {
                lastError = error
                guard isRetryable(error) else { throw error }
                guard attempt < maxRetries - 1 else { break }

                let rawDelay = baseDelay * pow(2.0, Double(attempt))
                let clampedDelay = min(rawDelay, maxDelay)
                // Add ±25% jitter to avoid thundering herd
                let jitter = Double.random(in: -clampedDelay * 0.25 ... clampedDelay * 0.25)
                let actualDelay = max(clampedDelay + jitter, 0.05)

                NetworkLogger.log("Retry", "attempt \(attempt + 1)/\(maxRetries - 1) failed, retrying in \(String(format: "%.0f", actualDelay * 1000))ms")
                try await Task.sleep(nanoseconds: UInt64(actualDelay * 1_000_000_000))
            }
        }

        throw lastError
    }
}
