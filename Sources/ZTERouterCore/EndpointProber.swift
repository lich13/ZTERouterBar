import CFNetwork
import Foundation

public protocol EndpointProbing: Sendable {
    func check(_ endpoint: WatchdogEndpoint, timeoutMs: Int) async -> EndpointProbeOutcome
}

public struct URLEndpointProber: EndpointProbing {
    public init() {}

    public func check(_ endpoint: WatchdogEndpoint, timeoutMs: Int) async -> EndpointProbeOutcome {
        let trimmedURL = endpoint.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard endpoint.isValidHTTPURL, let url = URL(string: trimmedURL) else {
            return EndpointProbeOutcome(
                id: endpoint.id,
                name: endpoint.displayTitle,
                urlString: endpoint.urlString,
                proxyMode: endpoint.proxyMode,
                reachable: false,
                errorMessage: "URL 格式无效（需 http/https）"
            )
        }

        let proxyDict: [AnyHashable: Any]?
        switch endpoint.proxyMode {
        case .system:
            proxyDict = nil
        case .direct:
            proxyDict = [:]
        case .http:
            let host = endpoint.proxyHost.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty, (1...65535).contains(endpoint.proxyPort) else {
                return EndpointProbeOutcome(
                    id: endpoint.id,
                    name: endpoint.displayTitle,
                    urlString: trimmedURL,
                    proxyMode: endpoint.proxyMode,
                    reachable: false,
                    errorMessage: "HTTP 代理地址/端口无效"
                )
            }
            proxyDict = [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: host,
                kCFNetworkProxiesHTTPPort as String: endpoint.proxyPort,
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: host,
                kCFNetworkProxiesHTTPSPort as String: endpoint.proxyPort
            ]
        case .socks5:
            let host = endpoint.proxyHost.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty, (1...65535).contains(endpoint.proxyPort) else {
                return EndpointProbeOutcome(
                    id: endpoint.id,
                    name: endpoint.displayTitle,
                    urlString: trimmedURL,
                    proxyMode: endpoint.proxyMode,
                    reachable: false,
                    errorMessage: "SOCKS5 代理地址/端口无效"
                )
            }
            proxyDict = [
                kCFNetworkProxiesSOCKSEnable as String: 1,
                kCFNetworkProxiesSOCKSProxy as String: host,
                kCFNetworkProxiesSOCKSPort as String: endpoint.proxyPort
            ]
        }

        let config = URLSessionConfiguration.ephemeral
        let timeoutSec = max(0.5, TimeInterval(timeoutMs) / 1000.0)
        config.timeoutIntervalForRequest = timeoutSec
        config.timeoutIntervalForResource = timeoutSec
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.httpShouldSetCookies = false
        if let proxyDict {
            config.connectionProxyDictionary = proxyDict
        }

        let delegate = ProbeSessionDelegate(
            proxyUsername: endpoint.proxyUsername,
            proxyPassword: endpoint.proxyPassword
        )
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeoutSec)
        request.httpMethod = "GET"
        request.setValue("ZTERouterBar-Watchdog/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("close", forHTTPHeaderField: "Connection")

        let clock = ContinuousClock()
        let start = clock.now

        do {
            let (_, response) = try await session.data(for: request)
            let elapsedMs = durationMillis(start.duration(to: clock.now))
            guard let http = response as? HTTPURLResponse else {
                return EndpointProbeOutcome(
                    id: endpoint.id,
                    name: endpoint.displayTitle,
                    urlString: trimmedURL,
                    proxyMode: endpoint.proxyMode,
                    reachable: false,
                    elapsedMs: elapsedMs,
                    errorMessage: "非 HTTP 响应"
                )
            }
            if http.statusCode == 407 {
                return EndpointProbeOutcome(
                    id: endpoint.id,
                    name: endpoint.displayTitle,
                    urlString: trimmedURL,
                    proxyMode: endpoint.proxyMode,
                    reachable: false,
                    statusCode: http.statusCode,
                    elapsedMs: elapsedMs,
                    errorMessage: "代理需要认证 (407)"
                )
            }
            return EndpointProbeOutcome(
                id: endpoint.id,
                name: endpoint.displayTitle,
                urlString: trimmedURL,
                proxyMode: endpoint.proxyMode,
                reachable: true,
                statusCode: http.statusCode,
                elapsedMs: elapsedMs
            )
        } catch {
            let elapsedMs = durationMillis(start.duration(to: clock.now))
            return EndpointProbeOutcome(
                id: endpoint.id,
                name: endpoint.displayTitle,
                urlString: trimmedURL,
                proxyMode: endpoint.proxyMode,
                reachable: false,
                elapsedMs: elapsedMs,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func durationMillis(_ duration: Duration) -> Int {
        let comps = duration.components
        return Int(comps.seconds * 1000) + Int(comps.attoseconds / 1_000_000_000_000_000)
    }
}

private final class ProbeSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let proxyUsername: String
    private let proxyPassword: String

    init(proxyUsername: String, proxyPassword: String) {
        self.proxyUsername = proxyUsername
        self.proxyPassword = proxyPassword
    }

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

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.isProxy(),
           !proxyUsername.isEmpty,
           challenge.previousFailureCount == 0 {
            let cred = URLCredential(user: proxyUsername, password: proxyPassword, persistence: .none)
            completionHandler(.useCredential, cred)
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}
