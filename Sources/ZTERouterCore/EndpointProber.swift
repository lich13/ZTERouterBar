import Foundation

public protocol EndpointProbing: Sendable {
    func check(_ endpoint: WatchdogEndpoint) async -> EndpointProbeOutcome
}

public final class URLEndpointProber: EndpointProbing, @unchecked Sendable {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 35
        config.timeoutIntervalForResource = 35
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.httpMaximumConnectionsPerHost = 4
        self.session = URLSession(configuration: config, delegate: RedirectBlockerDelegate(), delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func check(_ endpoint: WatchdogEndpoint) async -> EndpointProbeOutcome {
        let trimmedURL = endpoint.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard endpoint.isValidHTTPURL, let url = URL(string: trimmedURL) else {
            return makeOutcome(endpoint, urlString: endpoint.urlString, reachable: false, errorMessage: "URL 格式无效（需 http/https）")
        }

        let timeoutSec = min(max(endpoint.timeoutSec, 1), 30)
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: TimeInterval(timeoutSec)
        )
        request.httpMethod = "GET"
        request.setValue("ZTERouterBar-Watchdog/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("close", forHTTPHeaderField: "Connection")

        let clock = ContinuousClock()
        let start = clock.now

        do {
            let response = try await fetchResponseWithHardTimeout(request: request, timeoutSec: timeoutSec)
            let elapsedMs = durationMillis(start.duration(to: clock.now))
            guard let http = response as? HTTPURLResponse else {
                return makeOutcome(endpoint, urlString: trimmedURL, reachable: false, elapsedMs: elapsedMs, errorMessage: "非 HTTP 响应")
            }
            if let gatewayError = Self.failureMessage(forStatusCode: http.statusCode) {
                return makeOutcome(endpoint, urlString: trimmedURL, reachable: false, statusCode: http.statusCode, elapsedMs: elapsedMs, errorMessage: gatewayError)
            }
            return makeOutcome(endpoint, urlString: trimmedURL, reachable: true, statusCode: http.statusCode, elapsedMs: elapsedMs)
        } catch is ProbeTimeoutError {
            let elapsedMs = durationMillis(start.duration(to: clock.now))
            return makeOutcome(endpoint, urlString: trimmedURL, reachable: false, elapsedMs: elapsedMs, errorMessage: "请求超时 (\(timeoutSec)s)")
        } catch {
            let elapsedMs = durationMillis(start.duration(to: clock.now))
            return makeOutcome(endpoint, urlString: trimmedURL, reachable: false, elapsedMs: elapsedMs, errorMessage: error.localizedDescription)
        }
    }

    /// Enforces a hard wall-clock ceiling so DNS or TLS stalls never exceed `endpoint.timeoutSec`.
    private func fetchResponseWithHardTimeout(request: URLRequest, timeoutSec: Int) async throws -> URLResponse {
        let session = self.session
        return try await withThrowingTaskGroup(of: URLResponse.self) { group in
            group.addTask {
                let (_, response) = try await session.data(for: request)
                return response
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSec))
                throw ProbeTimeoutError()
            }
            guard let first = try await group.next() else {
                throw ProbeTimeoutError()
            }
            group.cancelAll()
            return first
        }
    }

    private func makeOutcome(
        _ endpoint: WatchdogEndpoint,
        urlString: String,
        reachable: Bool,
        statusCode: Int? = nil,
        elapsedMs: Int = 0,
        errorMessage: String? = nil
    ) -> EndpointProbeOutcome {
        EndpointProbeOutcome(
            id: endpoint.id,
            name: endpoint.displayTitle,
            urlString: urlString,
            weight: endpoint.weight,
            reachable: reachable,
            statusCode: statusCode,
            elapsedMs: elapsedMs,
            errorMessage: errorMessage
        )
    }

    /// Interprets HTTP proxy/gateway failure codes (e.g. local gateway returning 502/504 when tunnel fails) as unreachable.
    public static func failureMessage(forStatusCode statusCode: Int) -> String? {
        switch statusCode {
        case 407:
            return "代理需要认证 (407)"
        case 502, 503, 504:
            return "网关/代理不可达 (HTTP \(statusCode))"
        default:
            return nil
        }
    }

    private func durationMillis(_ duration: Duration) -> Int {
        let comps = duration.components
        return Int(comps.seconds * 1000) + Int(comps.attoseconds / 1_000_000_000_000_000)
    }
}

private struct ProbeTimeoutError: Error {}

private final class RedirectBlockerDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Treat the immediate HTTP response (e.g. 301/302/204/200) as connectivity proof without chasing redirects.
        completionHandler(nil)
    }
}
