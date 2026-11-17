import Foundation

public enum ZTERouterError: LocalizedError, Sendable, Equatable {
    case invalidBaseURL(String)
    case missingPassword
    case wrongPassword
    case loginRateLimited
    case duplicateUser
    case loginFailed(code: String)
    case commandFailed(goformId: String, result: String)
    case invalidResponse(String)
    case httpError(Int)
    case transportError(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidBaseURL(url):
            "无效的路由器地址：\(url)"
        case .missingPassword:
            "尚未设置路由器管理密码，请在设置中输入密码。"
        case .wrongPassword:
            "路由器管理密码错误，请检查配置中的密码。"
        case .loginRateLimited:
            "路由器登录尝试过于频繁，请稍后再试。"
        case .duplicateUser:
            "路由器管理会话已被其他页面占用（duplicateUser），请稍后重试。"
        case let .loginFailed(code):
            "登录失败（返回码：\(code)）。"
        case let .commandFailed(goformId, result):
            "指令 \(goformId) 执行失败（返回：\(result)）。"
        case let .invalidResponse(detail):
            "路由器返回数据无法解析：\(detail)"
        case let .httpError(status):
            "路由器 HTTP 错误：\(status)"
        case let .transportError(message):
            "无法连接路由器：\(message)"
        }
    }
}

public struct RouterEndpointConfig: Sendable, Equatable {
    public let baseURL: URL
    public let hashPreference: AuthHashPreference

    public init(baseURLString: String, hashPreference: AuthHashPreference = .auto) throws {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let parsed = URL(string: normalized),
              let scheme = parsed.scheme,
              let host = parsed.host,
              !scheme.isEmpty,
              !host.isEmpty else {
            throw ZTERouterError.invalidBaseURL(baseURLString)
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = parsed.port
        guard let cleanURL = components.url else {
            throw ZTERouterError.invalidBaseURL(baseURLString)
        }
        self.baseURL = cleanURL
        self.hashPreference = hashPreference
    }
}

public actor ZTERouterClient {
    private var config: RouterEndpointConfig
    private var password: String
    private let transport: any HTTPTransport

    private var cachedWaInnerVersion: String = ""
    private var cachedCrVersion: String = ""
    private var lastKeepAliveAt: Date?

    public init(
        config: RouterEndpointConfig,
        password: String = "",
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.config = config
        self.password = password
        self.transport = transport
    }

    public func updateCredentials(config: RouterEndpointConfig, password: String) {
        if self.config.baseURL != config.baseURL {
            self.cachedWaInnerVersion = ""
            self.cachedCrVersion = ""
            self.lastKeepAliveAt = nil
        }
        self.config = config
        self.password = password
    }

    // MARK: - Auth & Session

    public func checkLoggedIn() async throws -> Bool {
        let dict = try await getRawFields(["loginfo"])
        let state = (dict["loginfo"] ?? "").lowercased()
        return state == "ok"
    }

    public func login() async throws {
        guard !password.isEmpty else {
            throw ZTERouterError.missingPassword
        }

        let meta = try await getRawFields(["wa_inner_version", "cr_version", "RD", "LD"])
        let wa = meta["wa_inner_version"] ?? ""
        let cr = meta["cr_version"] ?? ""
        let ld = meta["LD"] ?? ""
        let rd = meta["RD"] ?? ""

        if !wa.isEmpty {
            self.cachedWaInnerVersion = wa
            self.cachedCrVersion = cr
        }

        let algo = ResolvedHashAlgorithm.resolve(
            waInnerVersion: wa.isEmpty ? cachedWaInnerVersion : wa,
            preference: config.hashPreference
        )
        let challengePassword = RouterCrypto.computeLoginPassword(plainPassword: password, ld: ld)

        var params: [(String, String)] = [
            ("isTest", "false"),
            ("goformId", "LOGIN"),
            ("password", challengePassword)
        ]

        if !rd.isEmpty {
            let ad = RouterCrypto.computeAD(
                waInnerVersion: wa,
                crVersion: cr,
                rd: rd,
                algorithm: algo
            )
            params.append(("AD", ad))
        }

        let result = try await postGoformRaw(params)
        switch result {
        case "0", "4", "success":
            self.lastKeepAliveAt = Date()
            return
        case "1":
            throw ZTERouterError.loginRateLimited
        case "2":
            throw ZTERouterError.duplicateUser
        case "3":
            throw ZTERouterError.wrongPassword
        default:
            throw ZTERouterError.loginFailed(code: result)
        }
    }

    public func ensureAuthenticated() async throws {
        if try await checkLoggedIn() {
            return
        }
        try await login()
    }

    public func keepAliveIfNeeded(interval: TimeInterval = 55) async {
        let now = Date()
        if let last = lastKeepAliveAt, now.timeIntervalSince(last) < interval {
            return
        }
        let url = config.baseURL.appendingPathComponent("tmpl/network/apn_setting.html")
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "v", value: String(Int(now.timeIntervalSince1970)))]
        guard let requestURL = comps?.url else { return }
        var request = makeBaseRequest(url: requestURL, method: "GET")
        request.setValue("text/html, */*; q=0.01", forHTTPHeaderField: "Accept")
        _ = try? await transport.send(request)
        lastKeepAliveAt = now
    }

    // MARK: - Status & Station List

    public func fetchStatus() async throws -> RouterStatusSnapshot {
        try await ensureAuthenticated()
        await keepAliveIfNeeded()

        let data1 = try await getRawData(RouterStatusParser.primarySignalCmds)
        let data2 = try await getRawData(RouterStatusParser.secondaryDashboardCmds)
        // ZTE firmware returns array JSON for `station_list` and `lan_station_list` only when queried individually without `multi_data=1`.
        let wifiStationsData = try? await getRawData(["station_list"])
        let lanStationsData = try? await getRawData(["lan_station_list"])

        var payloads = [data1, data2]
        if let wifiStationsData { payloads.append(wifiStationsData) }
        if let lanStationsData { payloads.append(lanStationsData) }

        let snapshot = try RouterStatusParser.parse(jsonDataList: payloads)
        if !snapshot.versionInfo.waInnerVersion.isEmpty {
            cachedWaInnerVersion = snapshot.versionInfo.waInnerVersion
            cachedCrVersion = snapshot.versionInfo.crVersion
        }
        return snapshot
    }

    // MARK: - One-Click WAN Reconnect

    @discardableResult
    public func reconnectInternet(
        pauseBetweenDisconnectAndConnect: Duration = .milliseconds(300)
    ) async throws -> WANConnectionState {
        try await ensureAuthenticated()
        let currentDict = try await getRawFields(["ppp_status"])
        let currentState = WANConnectionState(pppStatus: currentDict["ppp_status"] ?? "")

        if !currentState.isDisconnected {
            _ = try await setInternetConnected(false, waitUntilSettled: true)
            try await Task.sleep(for: pauseBetweenDisconnectAndConnect)
        }
        return try await setInternetConnected(true, waitUntilSettled: true)
    }

    @discardableResult
    public func setInternetConnected(_ connect: Bool, waitUntilSettled: Bool = true) async throws -> WANConnectionState {
        try await ensureAuthenticated()
        let goformId = connect ? "CONNECT_NETWORK" : "DISCONNECT_NETWORK"
        try await sendAuthenticatedSetCommand(
            goformId: goformId,
            extraParams: [("notCallback", "true")]
        )

        guard waitUntilSettled else {
            let stateDict = try await getRawFields(["ppp_status"])
            return WANConnectionState(pppStatus: stateDict["ppp_status"] ?? "")
        }

        let deadline = Date().addingTimeInterval(connect ? 18 : 10)
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(300))
            let stateDict = try await getRawFields(["ppp_status"])
            let state = WANConnectionState(pppStatus: stateDict["ppp_status"] ?? "")
            if connect && state.isConnected {
                return state
            }
            if !connect && state.isDisconnected {
                return state
            }
        }
        let finalDict = try await getRawFields(["ppp_status"])
        return WANConnectionState(pppStatus: finalDict["ppp_status"] ?? "")
    }

    // MARK: - Low-level GoForm Plumbing

    private func sendAuthenticatedSetCommand(
        goformId: String,
        extraParams: [(String, String)]
    ) async throws {
        let ad = try await fetchFreshADToken()
        var params: [(String, String)] = [
            ("isTest", "false"),
            ("goformId", goformId)
        ]
        params.append(contentsOf: extraParams)
        params.append(("AD", ad))

        let result = try await postGoformRaw(params)
        if result == "success" || result == "0" {
            return
        }
        throw ZTERouterError.commandFailed(goformId: goformId, result: result)
    }

    private func fetchFreshADToken() async throws -> String {
        let cmds = cachedWaInnerVersion.isEmpty ? ["wa_inner_version", "cr_version", "RD"] : ["RD"]
        let dict = try await getRawFields(cmds)
        if let wa = dict["wa_inner_version"], !wa.isEmpty {
            cachedWaInnerVersion = wa
            cachedCrVersion = dict["cr_version"] ?? ""
        }
        let rd = dict["RD"] ?? ""
        let algo = ResolvedHashAlgorithm.resolve(
            waInnerVersion: cachedWaInnerVersion,
            preference: config.hashPreference
        )
        return RouterCrypto.computeAD(
            waInnerVersion: cachedWaInnerVersion,
            crVersion: cachedCrVersion,
            rd: rd,
            algorithm: algo
        )
    }

    private func getRawFields(_ cmds: [String]) async throws -> [String: String] {
        let data = try await getRawData(cmds)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ZTERouterError.invalidResponse("非 JSON 对象")
        }
        var result: [String: String] = [:]
        for (k, v) in object {
            if let s = v as? String {
                result[k] = s
            } else if let n = v as? NSNumber {
                result[k] = n.stringValue
            }
        }
        return result
    }

    private func getRawData(_ cmds: [String]) async throws -> Data {
        let endpoint = config.baseURL.appendingPathComponent("goform/goform_get_cmd_process")
        var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var items: [URLQueryItem] = [
            URLQueryItem(name: "isTest", value: "false"),
            URLQueryItem(name: "cmd", value: cmds.joined(separator: ","))
        ]
        if cmds.count > 1 {
            items.append(URLQueryItem(name: "multi_data", value: "1"))
        }
        items.append(URLQueryItem(name: "_", value: String(Int(Date().timeIntervalSince1970 * 1000))))
        comps?.queryItems = items

        guard let requestURL = comps?.url else {
            throw ZTERouterError.invalidBaseURL(config.baseURL.absoluteString)
        }

        var request = makeBaseRequest(url: requestURL, method: "GET")
        request.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
        return try await execute(request)
    }

    private func postGoformRaw(_ params: [(String, String)]) async throws -> String {
        let endpoint = config.baseURL.appendingPathComponent("goform/goform_set_cmd_process")
        var request = makeBaseRequest(url: endpoint, method: "POST")
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")

        let encodedBody = params.map { key, value in
            "\(formEncode(key))=\(formEncode(value))"
        }.joined(separator: "&")
        request.httpBody = Data(encodedBody.utf8)

        let data = try await execute(request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(data: data, encoding: .utf8) ?? "<binary>"
            throw ZTERouterError.invalidResponse(text)
        }
        if let result = object["result"] as? String {
            return result
        }
        if let resultNum = object["result"] as? NSNumber {
            return resultNum.stringValue
        }
        throw ZTERouterError.invalidResponse(String(data: data, encoding: .utf8) ?? "")
    }

    private func execute(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw ZTERouterError.transportError(error.localizedDescription)
        }
        guard (200...299).contains(response.statusCode) else {
            throw ZTERouterError.httpError(response.statusCode)
        }
        return data
    }

    private func makeBaseRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        // ZTE router firmware validates Referer on protected endpoints.
        let referer = config.baseURL.appendingPathComponent("index.html").absoluteString
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue(config.baseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        return request
    }

    private func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        return value
            .addingPercentEncoding(withAllowedCharacters: allowed)?
            .replacingOccurrences(of: "%20", with: "+") ?? value
    }
}
