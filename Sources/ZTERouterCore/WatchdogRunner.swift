import Foundation

public protocol RouterReconnecting: Sendable {
    func reconnectInternet() async throws -> WANConnectionState
}

extension ZTERouterClient: RouterReconnecting {
    public func reconnectInternet() async throws -> WANConnectionState {
        try await reconnectInternet(pauseBetweenDisconnectAndConnect: .milliseconds(300))
    }
}

public enum WatchdogEvaluator {
    public static func weightTally(outcomes: [EndpointProbeOutcome]) -> (reachable: Int, total: Int) {
        let total = outcomes.reduce(0) { $0 + max(1, $1.weight) }
        let reachable = outcomes.filter(\.reachable).reduce(0) { $0 + max(1, $1.weight) }
        return (reachable, total)
    }

    public static func isHealthy(outcomes: [EndpointProbeOutcome], policy: WatchdogTriggerPolicy) -> Bool {
        guard !outcomes.isEmpty else { return false }
        switch policy {
        case .weighted:
            let tally = weightTally(outcomes: outcomes)
            return tally.reachable * 2 > tally.total
        case .allUnreachable:
            // Healthy if at least one enabled endpoint is reachable.
            return outcomes.contains(where: \.reachable)
        case .anyUnreachable:
            // Healthy only if all enabled endpoints are reachable.
            return outcomes.allSatisfy(\.reachable)
        }
    }

    public static func formatProbeSummary(_ outcome: EndpointProbeOutcome) -> String {
        let weightTag = outcome.weight > 1 ? " · 权重\(outcome.weight)" : ""
        if outcome.reachable {
            let codeText = outcome.statusCode.map { "HTTP \($0)" } ?? "OK"
            return "可达  \(outcome.name) (\(outcome.proxyMode.shortName)\(weightTag))  \(outcome.elapsedMs)ms  \(codeText)"
        } else {
            let errText = outcome.errorMessage.map { " [\($0)]" } ?? ""
            let codeText = outcome.statusCode.map { " HTTP \($0)" } ?? ""
            return "不可达  \(outcome.name) (\(outcome.proxyMode.shortName)\(weightTag))  \(outcome.elapsedMs)ms\(codeText)\(errText)"
        }
    }
}

public struct WatchdogRunner: Sendable {
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    public func probeAll(
        endpoints: [WatchdogEndpoint],
        timeoutMs: Int,
        prober: any EndpointProbing
    ) async -> [EndpointProbeOutcome] {
        await withTaskGroup(of: (Int, EndpointProbeOutcome).self) { group in
            for (idx, endpoint) in endpoints.enumerated() {
                group.addTask {
                    let result = await prober.check(endpoint, timeoutMs: timeoutMs)
                    return (idx, result)
                }
            }
            var indexed: [(Int, EndpointProbeOutcome)] = []
            for await item in group {
                indexed.append(item)
            }
            return indexed.sorted(by: { $0.0 < $1.0 }).map(\.1)
        }
    }

    public func run(
        config rawConfig: WatchdogConfig,
        prober: any EndpointProbing,
        router: any RouterReconnecting,
        canReconnect: (@Sendable () async -> String?)? = nil,
        onEvent: @escaping @Sendable (WatchdogEvent) async -> Void
    ) async {
        let config = rawConfig.clamped()
        let endpoints = config.enabledValidEndpoints
        guard !endpoints.isEmpty else {
            await onEvent(.log(WatchdogLogEntry(level: .warning, message: "未配置有效探测端点，守护无法启动")))
            await onEvent(.phaseChanged(.idle))
            return
        }

        await onEvent(.log(WatchdogLogEntry(
            level: .info,
            message: "保活守护启动：\(endpoints.count) 个端点，轮询 \(config.pollIntervalSec)s，连续 \(config.recheckBeforeAct + 1) 次异常重连（复检 \(config.recheckBeforeAct) 次 · 间隔 \(config.recheckIntervalSec)s），单点超时 \(config.checkTimeoutMs)ms"
        )))
        await onEvent(.phaseChanged(.monitoring))

        var consecutiveReconnects = 0

        while !Task.isCancelled {
            do {
                let firstRound = await probeAll(endpoints: endpoints, timeoutMs: config.checkTimeoutMs, prober: prober)
                let firstHealthy = WatchdogEvaluator.isHealthy(outcomes: firstRound, policy: config.triggerPolicy)
                await logRound(firstRound, policy: config.triggerPolicy, healthy: firstHealthy, onEvent: onEvent)

                if firstHealthy {
                    consecutiveReconnects = 0
                    await onEvent(.phaseChanged(.monitoring))
                    try await sleep(.seconds(config.pollIntervalSec))
                    continue
                }

                // Jitter recheck loop before triggering WAN disconnect/reconnect.
                var confirmedDown = true
                if config.recheckBeforeAct > 0 {
                    await onEvent(.log(WatchdogLogEntry(
                        level: .warning,
                        message: "探测异常，开始防抖复检（\(config.recheckBeforeAct) 次，间隔 \(config.recheckIntervalSec)s）…"
                    )))
                    for attempt in 1...config.recheckBeforeAct {
                        await onEvent(.phaseChanged(.rechecking(attempt: attempt, total: config.recheckBeforeAct)))
                        try await sleep(.seconds(config.recheckIntervalSec))

                        let recheck = await probeAll(endpoints: endpoints, timeoutMs: config.checkTimeoutMs, prober: prober)
                        let recovered = WatchdogEvaluator.isHealthy(outcomes: recheck, policy: config.triggerPolicy)
                        await logRound(recheck, policy: config.triggerPolicy, healthy: recovered, onEvent: onEvent)
                        if recovered {
                            confirmedDown = false
                            await onEvent(.log(WatchdogLogEntry(
                                level: .success,
                                message: "复检第 \(attempt) 次恢复通畅，判定为瞬时抖动，不重连"
                            )))
                            break
                        }
                    }
                }

                if !confirmedDown {
                    consecutiveReconnects = 0
                    await onEvent(.phaseChanged(.monitoring))
                    try await sleep(.seconds(config.pollIntervalSec))
                    continue
                }

                // Confirmed unreachable -> check boundary guard & perform reconnect loop.
                reconnectLoop: while !Task.isCancelled {
                    if let pauseReason = await canReconnect?() {
                        await onEvent(.phaseChanged(.paused(reason: pauseReason)))
                        await onEvent(.log(WatchdogLogEntry(level: .warning, message: "暂停重连：\(pauseReason)")))
                        try await sleep(.seconds(config.pollIntervalSec))
                        break reconnectLoop
                    }

                    let triggerReason = "连续 \(config.recheckBeforeAct + 1) 次检测不可达"
                    await onEvent(.phaseChanged(.reconnecting))
                    await onEvent(.autoReconnectTriggered(reason: triggerReason))
                    await onEvent(.log(WatchdogLogEntry(level: .warning, message: "\(triggerReason)，正在触发路由器外网重连…")))

                    do {
                        let newState = try await router.reconnectInternet()
                        await onEvent(.autoReconnectFinished(state: newState))
                        if !newState.isConnected {
                            await onEvent(.log(WatchdogLogEntry(
                                level: .warning,
                                message: "重连指令已执行，但状态尚未确认在线（\(newState.localizedLabel)）"
                            )))
                        }
                    } catch let routerError as ZTERouterError {
                        switch routerError {
                        case .duplicateUser, .wrongPassword, .loginRateLimited, .missingPassword, .sessionExpired:
                            let reason = routerError.localizedDescription
                            await onEvent(.phaseChanged(.paused(reason: reason)))
                            await onEvent(.log(WatchdogLogEntry(level: .error, message: "无法执行重连：\(reason)")))
                            try await sleep(.seconds(max(config.pollIntervalSec, 20)))
                            break reconnectLoop
                        default:
                            await onEvent(.log(WatchdogLogEntry(
                                level: .error,
                                message: "路由器重连异常：\(routerError.localizedDescription)"
                            )))
                            try await sleep(.seconds(config.recheckIntervalSec))
                            continue reconnectLoop
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        await onEvent(.log(WatchdogLogEntry(level: .error, message: "重连异常：\(error.localizedDescription)")))
                        try await sleep(.seconds(config.recheckIntervalSec))
                        continue reconnectLoop
                    }

                    // Wait `recheckIntervalSec`, then run a single post-reconnect verification round.
                    await onEvent(.phaseChanged(.verifyingAfterReconnect))
                    await onEvent(.log(WatchdogLogEntry(
                        level: .info,
                        message: "外网重连完成，等待 \(config.recheckIntervalSec)s 后执行连通性复检…"
                    )))
                    try await sleep(.seconds(config.recheckIntervalSec))

                    let postCheck = await probeAll(endpoints: endpoints, timeoutMs: config.checkTimeoutMs, prober: prober)
                    let postHealthy = WatchdogEvaluator.isHealthy(outcomes: postCheck, policy: config.triggerPolicy)
                    await logRound(postCheck, policy: config.triggerPolicy, healthy: postHealthy, onEvent: onEvent)

                    if postHealthy {
                        consecutiveReconnects = 0
                        await onEvent(.log(WatchdogLogEntry(level: .success, message: "重连后复检通过，外网已恢复畅通")))
                        await onEvent(.phaseChanged(.monitoring))
                        break reconnectLoop
                    }

                    consecutiveReconnects += 1
                    if consecutiveReconnects >= config.maxConsecutiveReconnects {
                        await onEvent(.phaseChanged(.coolingDown(seconds: config.cooldownSec)))
                        await onEvent(.log(WatchdogLogEntry(
                            level: .error,
                            message: "连续 \(consecutiveReconnects) 次重连后仍不可达，进入 \(config.cooldownSec)s 冷却期"
                        )))
                        consecutiveReconnects = 0
                        try await sleep(.seconds(config.cooldownSec))
                        await onEvent(.phaseChanged(.monitoring))
                        break reconnectLoop
                    } else {
                        await onEvent(.log(WatchdogLogEntry(
                            level: .warning,
                            message: "重连后复检仍不可达（第 \(consecutiveReconnects)/\(config.maxConsecutiveReconnects) 次），准备再次重连…"
                        )))
                    }
                }

                if !Task.isCancelled {
                    try await sleep(.seconds(config.pollIntervalSec))
                }
            } catch is CancellationError {
                break
            } catch {
                await onEvent(.log(WatchdogLogEntry(level: .error, message: "守护循环异常：\(error.localizedDescription)")))
                try? await sleep(.seconds(config.pollIntervalSec))
            }
        }

        await onEvent(.phaseChanged(.idle))
        await onEvent(.log(WatchdogLogEntry(level: .info, message: "保活守护已停止")))
    }

    private func logRound(
        _ outcomes: [EndpointProbeOutcome],
        policy: WatchdogTriggerPolicy,
        healthy: Bool,
        onEvent: @escaping @Sendable (WatchdogEvent) async -> Void
    ) async {
        await onEvent(.probeRoundCompleted(outcomes, overallHealthy: healthy))
        for outcome in outcomes {
            await onEvent(.log(WatchdogLogEntry(
                level: outcome.reachable ? .info : .warning,
                message: "  \(WatchdogEvaluator.formatProbeSummary(outcome))"
            )))
        }
        let verdict: String
        if policy == .weighted {
            let tally = WatchdogEvaluator.weightTally(outcomes: outcomes)
            verdict = healthy
                ? "==> 本轮判定：网络正常（可达权重 \(tally.reachable)/\(tally.total)）"
                : "==> 本轮判定：未达到权重阈值（可达权重 \(tally.reachable)/\(tally.total)）"
        } else {
            verdict = healthy ? "==> 本轮判定：网络正常" : "==> 本轮判定：未达到可达条件"
        }
        await onEvent(.log(WatchdogLogEntry(
            level: healthy ? .success : .warning,
            message: verdict
        )))
    }
}
