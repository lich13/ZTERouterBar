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
        let total = outcomes.reduce(0) { $0 + $1.weight }
        let reachable = outcomes.filter(\.reachable).reduce(0) { $0 + $1.weight }
        return (reachable, total)
    }

    public static func isHealthy(outcomes: [EndpointProbeOutcome], policy: WatchdogTriggerPolicy) -> Bool {
        guard !outcomes.isEmpty else { return false }
        switch policy {
        case .weighted:
            let tally = weightTally(outcomes: outcomes)
            return tally.reachable * 2 > tally.total
        case .allUnreachable:
            return outcomes.contains(where: \.reachable)
        case .anyUnreachable:
            return outcomes.allSatisfy(\.reachable)
        }
    }

    public static func formatProbeSummary(_ outcome: EndpointProbeOutcome) -> String {
        let weightTag = outcome.weight > 1 ? " (权重\(outcome.weight))" : ""
        if outcome.reachable {
            let codeText = outcome.statusCode.map { "HTTP \($0)" } ?? "OK"
            return "可达  \(outcome.name)\(weightTag)  \(outcome.elapsedMs)ms  \(codeText)"
        } else {
            let errText = outcome.errorMessage.map { " [\($0)]" } ?? ""
            let codeText = outcome.statusCode.map { " HTTP \($0)" } ?? ""
            return "不可达  \(outcome.name)\(weightTag)  \(outcome.elapsedMs)ms\(codeText)\(errText)"
        }
    }
}

extension WatchdogEvaluator {
    /// Per-endpoint lines for the endpoints probed this round, followed by the verdict over `snapshot`.
    public static func roundLogEntries(
        probed: [EndpointProbeOutcome],
        snapshot: [EndpointProbeOutcome],
        policy: WatchdogTriggerPolicy,
        healthy: Bool,
        verdictLabel: String
    ) -> [WatchdogLogEntry] {
        var entries = probed.map {
            WatchdogLogEntry(level: $0.reachable ? .info : .warning, message: "  \(formatProbeSummary($0))")
        }
        let verdict: String
        if policy == .weighted {
            let tally = weightTally(outcomes: snapshot)
            verdict = (healthy ? "网络正常" : "未达到权重阈值") + "（可达权重 \(tally.reachable)/\(tally.total)）"
        } else {
            verdict = healthy ? "网络正常" : "未达到可达条件"
        }
        entries.append(WatchdogLogEntry(level: healthy ? .success : .warning, message: "==> \(verdictLabel)：\(verdict)"))
        return entries
    }
}

public struct WatchdogRunner: Sendable {
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    public func probeAll(
        endpoints: [WatchdogEndpoint],
        prober: any EndpointProbing
    ) async -> [EndpointProbeOutcome] {
        await withTaskGroup(of: (Int, EndpointProbeOutcome).self) { group in
            for (idx, endpoint) in endpoints.enumerated() {
                group.addTask {
                    let result = await prober.check(endpoint)
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

    /// Monitoring -> confirming (sustained failure window) -> reconnecting -> settling (grace) -> monitoring.
    /// A reconnect needs `failureWindowSec` of uninterrupted failure, and every reconnect is followed by a
    /// quiet period, so back-to-back redials are impossible by construction.
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

        let summaryDesc = endpoints.map { "\($0.displayTitle)(\($0.intervalSec)s/\($0.timeoutSec)s)" }.joined(separator: "、")
        await onEvent(.log(WatchdogLogEntry(
            level: .info,
            message: config.autoReconnectEnabled
                ? "保活守护启动：\(summaryDesc)，持续异常 \(config.failureWindowSec)s 才重连（确认期每 \(config.recheckIntervalSec)s 复检），重连后保护 \(config.postReconnectGraceSec)s"
                : "保活守护启动：\(summaryDesc)，自动重连未开启，连续 2 次探测不通仅通知"
        )))
        await onEvent(.phaseChanged(.monitoring))

        let minIntervalSec = endpoints.map(\.intervalSec).min() ?? 15
        var consecutiveReconnects = 0
        var notifiedThisOutage = false
        var latestByID: [UUID: EndpointProbeOutcome] = [:]
        var nextDueSec: [UUID: Int] = Dictionary(uniqueKeysWithValues: endpoints.map { ($0.id, 0) })
        var timelineSec = 0

        do {
            while true {
                try Task.checkCancellation()

                // Monitoring: probe whichever endpoints are due on their own interval.
                let dueEndpoints = endpoints.filter { (nextDueSec[$0.id] ?? 0) <= timelineSec }
                guard !dueEndpoints.isEmpty else {
                    try await sleepUntilNextDue(endpoints: endpoints, nextDueSec: nextDueSec, timelineSec: &timelineSec)
                    continue
                }
                let batch = await probeAll(endpoints: dueEndpoints, prober: prober)
                for outcome in batch { latestByID[outcome.id] = outcome }
                for ep in dueEndpoints { nextDueSec[ep.id] = timelineSec + ep.intervalSec }

                let latest = endpoints.compactMap { latestByID[$0.id] }
                let healthy = WatchdogEvaluator.isHealthy(outcomes: latest, policy: config.triggerPolicy)
                await logRound(snapshotOutcomes: latest, probedOutcomes: batch, policy: config.triggerPolicy, healthy: healthy, onEvent: onEvent)
                if healthy {
                    consecutiveReconnects = 0
                    notifiedThisOutage = false
                    await onEvent(.phaseChanged(.monitoring))
                    continue
                }

                // Confirming: every round re-probes all endpoints; one healthy round cancels the reconnect.
                await onEvent(.log(WatchdogLogEntry(
                    level: .warning,
                    message: "探测异常，进入确认期：每 \(config.recheckIntervalSec)s 复检，"
                        + (config.autoReconnectEnabled ? "持续异常满 \(config.failureWindowSec)s 才重连" : "自动重连未开启，仅通知")
                )))
                var failingSec = 0
                var recovered = false
                while failingSec < config.failureWindowSec {
                    await onEvent(.phaseChanged(.confirming(elapsedSec: failingSec, windowSec: config.failureWindowSec)))
                    try await sleep(.seconds(config.recheckIntervalSec))
                    timelineSec += config.recheckIntervalSec

                    let recheck = await probeAll(endpoints: endpoints, prober: prober)
                    for outcome in recheck { latestByID[outcome.id] = outcome }
                    for ep in endpoints { nextDueSec[ep.id] = timelineSec + ep.intervalSec }

                    recovered = WatchdogEvaluator.isHealthy(outcomes: recheck, policy: config.triggerPolicy)
                    await logRound(snapshotOutcomes: recheck, probedOutcomes: recheck, policy: config.triggerPolicy, healthy: recovered, onEvent: onEvent)
                    if recovered { break }
                    if !notifiedThisOutage {
                        notifiedThisOutage = true
                        await onEvent(.probeFailureDetected(reason: "连续 2 次探测不通"))
                    }
                    // A round lasts its recheck pause plus its slowest probe (probes run in parallel).
                    failingSec += config.recheckIntervalSec + (recheck.map(\.elapsedMs).max() ?? 0) / 1000
                }
                if recovered {
                    consecutiveReconnects = 0
                    notifiedThisOutage = false
                    await onEvent(.log(WatchdogLogEntry(level: .success, message: "确认期内恢复通畅，判定为瞬时抖动，不重连")))
                    await onEvent(.phaseChanged(.monitoring))
                    continue
                }

                guard config.autoReconnectEnabled else {
                    await onEvent(.phaseChanged(.paused(reason: "外网持续异常，自动重连未开启")))
                    await onEvent(.log(WatchdogLogEntry(level: .warning, message: "持续 \(failingSec)s 检测不可达；自动重连未开启，仅通知，继续监测")))
                    try await pause(seconds: minIntervalSec, endpoints: endpoints, nextDueSec: &nextDueSec, timelineSec: &timelineSec)
                    continue
                }

                // Reconnecting.
                if let pauseReason = await canReconnect?() {
                    await onEvent(.phaseChanged(.paused(reason: pauseReason)))
                    await onEvent(.log(WatchdogLogEntry(level: .warning, message: "暂停重连：\(pauseReason)")))
                    try await pause(seconds: minIntervalSec, endpoints: endpoints, nextDueSec: &nextDueSec, timelineSec: &timelineSec)
                    continue
                }

                let triggerReason = "持续 \(failingSec)s 检测不可达"
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
                        // Retrying cannot help until the user fixes the session or credentials.
                        let reason = routerError.localizedDescription
                        await onEvent(.phaseChanged(.paused(reason: reason)))
                        await onEvent(.log(WatchdogLogEntry(level: .error, message: "无法执行重连：\(reason)")))
                        try await pause(seconds: max(minIntervalSec, 20), endpoints: endpoints, nextDueSec: &nextDueSec, timelineSec: &timelineSec)
                        continue
                    default:
                        await onEvent(.log(WatchdogLogEntry(level: .error, message: "路由器重连异常：\(routerError.localizedDescription)")))
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    await onEvent(.log(WatchdogLogEntry(level: .error, message: "重连异常：\(error.localizedDescription)")))
                }

                // Settling: stay silent while the new link (and anything riding on it) comes back up.
                consecutiveReconnects += 1
                if consecutiveReconnects >= config.maxConsecutiveReconnects {
                    let cooldownSec = max(config.cooldownSec, config.postReconnectGraceSec)
                    await onEvent(.phaseChanged(.coolingDown(seconds: cooldownSec)))
                    await onEvent(.log(WatchdogLogEntry(
                        level: .error,
                        message: "已连续重连 \(consecutiveReconnects) 次且期间未见恢复，冷却 \(cooldownSec)s 后再继续监测"
                    )))
                    consecutiveReconnects = 0
                    try await pause(seconds: cooldownSec, endpoints: endpoints, nextDueSec: &nextDueSec, timelineSec: &timelineSec)
                } else {
                    await onEvent(.phaseChanged(.settling(seconds: config.postReconnectGraceSec)))
                    await onEvent(.log(WatchdogLogEntry(
                        level: .info,
                        message: "重连完成，进入 \(config.postReconnectGraceSec)s 保护期（期间不探测、不重连）"
                    )))
                    try await pause(seconds: config.postReconnectGraceSec, endpoints: endpoints, nextDueSec: &nextDueSec, timelineSec: &timelineSec)
                }
                latestByID.removeAll()
                await onEvent(.phaseChanged(.monitoring))
            }
        } catch {
            // Cancellation (or a failing injected sleep) ends the watchdog.
        }

        await onEvent(.phaseChanged(.idle))
        await onEvent(.log(WatchdogLogEntry(level: .info, message: "保活守护已停止")))
    }

    /// Sleeps, then makes every endpoint due so the next monitoring round is a full fresh probe.
    private func pause(
        seconds: Int,
        endpoints: [WatchdogEndpoint],
        nextDueSec: inout [UUID: Int],
        timelineSec: inout Int
    ) async throws {
        if seconds > 0 {
            try await sleep(.seconds(seconds))
        }
        timelineSec += seconds
        for ep in endpoints { nextDueSec[ep.id] = timelineSec }
    }

    private func sleepUntilNextDue(
        endpoints: [WatchdogEndpoint],
        nextDueSec: [UUID: Int],
        timelineSec: inout Int
    ) async throws {
        let earliest = endpoints.compactMap { nextDueSec[$0.id] }.min() ?? (timelineSec + 5)
        let delta = max(1, earliest - timelineSec)
        try await sleep(.seconds(delta))
        timelineSec = max(earliest, timelineSec + delta)
    }

    private func logRound(
        snapshotOutcomes: [EndpointProbeOutcome],
        probedOutcomes: [EndpointProbeOutcome],
        policy: WatchdogTriggerPolicy,
        healthy: Bool,
        onEvent: @escaping @Sendable (WatchdogEvent) async -> Void
    ) async {
        await onEvent(.probeRoundCompleted(snapshotOutcomes, overallHealthy: healthy))
        for entry in WatchdogEvaluator.roundLogEntries(
            probed: probedOutcomes, snapshot: snapshotOutcomes, policy: policy, healthy: healthy, verdictLabel: "本轮判定"
        ) {
            await onEvent(.log(entry))
        }
    }
}
