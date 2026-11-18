import Foundation

public enum SignalQualityGrade: String, CaseIterable, Equatable, Sendable {
    case excellent = "极佳"
    case good = "良好"
    case fair = "一般"
    case poor = "较差"
    case veryPoor = "极弱"
    case unknown = "未知"
}

public struct SignalRatingAssessment: Equatable, Sendable {
    public let score: Int
    public let grade: SignalQualityGrade
    public let primaryTechLabel: String
    public let rsrp: Double?
    public let sinr: Double?
    public let rsrq: Double?
    public let adviceText: String

    public init(
        score: Int,
        grade: SignalQualityGrade,
        primaryTechLabel: String,
        rsrp: Double? = nil,
        sinr: Double? = nil,
        rsrq: Double? = nil,
        adviceText: String = ""
    ) {
        self.score = score
        self.grade = grade
        self.primaryTechLabel = primaryTechLabel
        self.rsrp = rsrp
        self.sinr = sinr
        self.rsrq = rsrq
        self.adviceText = adviceText
    }
}

public struct SignalSample: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let rsrp: Double?
    public let sinr: Double?
    public let lteRsrp: Double?
    public let score: Int
    public let grade: SignalQualityGrade
    public let bandLabel: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        rsrp: Double?,
        sinr: Double?,
        lteRsrp: Double? = nil,
        score: Int,
        grade: SignalQualityGrade,
        bandLabel: String = ""
    ) {
        self.id = id
        self.timestamp = timestamp
        self.rsrp = rsrp
        self.sinr = sinr
        self.lteRsrp = lteRsrp
        self.score = score
        self.grade = grade
        self.bandLabel = bandLabel
    }
}

public enum SignalEvaluator {
    public static func assess(snapshot: RouterStatusSnapshot) -> SignalRatingAssessment {
        let rsrp: Double?
        let sinr: Double?
        let rsrq: Double?
        let techLabel: String

        if let nr = snapshot.nrCells.first {
            rsrp = Double(nr.rsrp1) ?? Double(nr.rsrp2)
            sinr = Double(nr.sinr)
            rsrq = Double(nr.rsrq)
            let mode = snapshot.is5GSA ? "5G SA" : (snapshot.is5GNSA ? "5G NSA" : "5G")
            techLabel = nr.band.isEmpty ? mode : "\(mode) \(nr.band)"
        } else if let lte = snapshot.lteCells.first {
            rsrp = lte.rsrpList.first.flatMap(Double.init)
            sinr = lte.sinrList.first.flatMap(Double.init)
            rsrq = Double(lte.rsrq)
            techLabel = lte.band.isEmpty ? "4G LTE" : "LTE \(lte.band)"
        } else if let umts = snapshot.umtsInfo {
            rsrp = umts.rscp.first.flatMap(Double.init)
            sinr = nil
            rsrq = umts.ecio.first.flatMap { Double($0).map { -$0 } }
            techLabel = umts.band.isEmpty ? "3G" : "3G \(umts.band)"
        } else {
            rsrp = nil
            sinr = nil
            rsrq = nil
            techLabel = snapshot.networkType.isEmpty ? "未知" : snapshot.networkType
        }

        let (score, grade) = evaluate(rsrp: rsrp, sinr: sinr, rsrq: rsrq, fallbackBars: snapshot.signalBars)
        let advice = buildAdvice(grade: grade, rsrp: rsrp, sinr: sinr)

        return SignalRatingAssessment(
            score: score,
            grade: grade,
            primaryTechLabel: techLabel,
            rsrp: rsrp,
            sinr: sinr,
            rsrq: rsrq,
            adviceText: advice
        )
    }

    public static func sample(from snapshot: RouterStatusSnapshot) -> SignalSample? {
        guard !snapshot.isUnauthenticatedEmptySnapshot else { return nil }
        let assessment = assess(snapshot: snapshot)
        if assessment.grade == .unknown && assessment.rsrp == nil && assessment.sinr == nil {
            return nil
        }
        let lteAnchorRSRP: Double? = {
            guard !snapshot.nrCells.isEmpty, let lte = snapshot.lteCells.first else { return nil }
            return lte.rsrpList.first.flatMap(Double.init)
        }()
        return SignalSample(
            timestamp: snapshot.fetchedAt,
            rsrp: assessment.rsrp,
            sinr: assessment.sinr,
            lteRsrp: lteAnchorRSRP,
            score: assessment.score,
            grade: assessment.grade,
            bandLabel: snapshot.bandSummary.isEmpty ? assessment.primaryTechLabel : snapshot.bandSummary
        )
    }

    public static func evaluate(
        rsrp: Double?,
        sinr: Double?,
        rsrq: Double? = nil,
        fallbackBars: Int? = nil
    ) -> (score: Int, grade: SignalQualityGrade) {
        var weightedSum = 0.0
        var totalWeight = 0.0

        if let rsrp {
            let s = interpolate(rsrp, points: [
                (-125, 0),
                (-115, 18),
                (-110, 32),
                (-100, 56),
                (-90, 78),
                (-80, 92),
                (-68, 100)
            ])
            weightedSum += s * 0.60
            totalWeight += 0.60
        }

        if let sinr {
            let s = interpolate(sinr, points: [
                (-10, 0),
                (0, 30),
                (10, 60),
                (15, 76),
                (20, 88),
                (30, 100)
            ])
            weightedSum += s * 0.30
            totalWeight += 0.30
        }

        if let rsrq {
            let s = interpolate(rsrq, points: [
                (-22, 0),
                (-16, 42),
                (-12, 68),
                (-9, 86),
                (-5, 100)
            ])
            weightedSum += s * 0.10
            totalWeight += 0.10
        }

        guard totalWeight > 0 else {
            if let bars = fallbackBars, (0...5).contains(bars) {
                let score = bars * 20
                return (score, gradeForScore(score))
            }
            return (0, .unknown)
        }

        var score = Int((weightedSum / totalWeight).rounded())
        if let rsrp, rsrp < -112 {
            score = min(score, 45)
        }
        if let sinr, sinr < 0 {
            score = min(score, 64)
        }
        score = min(max(score, 0), 100)
        return (score, gradeForScore(score))
    }

    public static func gradeForScore(_ score: Int) -> SignalQualityGrade {
        switch score {
        case 85...100: .excellent
        case 68..<85: .good
        case 48..<68: .fair
        case 25..<48: .poor
        default: .veryPoor
        }
    }

    private static func buildAdvice(grade: SignalQualityGrade, rsrp: Double?, sinr: Double?) -> String {
        switch grade {
        case .unknown:
            return "暂无有效无线信号指标"
        case .excellent:
            return "信号覆盖与信噪比俱佳，适合高速率与低延迟传输"
        case .good:
            return "信号质量良好，日常负载稳定"
        case .fair, .poor, .veryPoor:
            if let rsrp, rsrp < -105, let sinr, sinr < 5 {
                return "电平较弱且干扰偏高，建议移近窗口或调整摆位"
            }
            if let rsrp, rsrp < -105 {
                return "信号接收功率偏弱（RSRP \(Int(rsrp)) dBm），可尝试换位或锁定高频段"
            }
            if let sinr, sinr < 5 {
                return "信噪比偏低（SINR \(String(format: "%.1f", sinr)) dB），同频/邻区干扰较明显"
            }
            return "信号处于中等波动区间"
        }
    }

    private static func interpolate(_ value: Double, points: [(Double, Double)]) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if value <= first.0 { return first.1 }
        if value >= last.0 { return last.1 }

        for idx in 0..<(points.count - 1) {
            let (x0, y0) = points[idx]
            let (x1, y1) = points[idx + 1]
            if value >= x0 && value <= x1 {
                let ratio = (value - x0) / max(0.0001, x1 - x0)
                return y0 + ratio * (y1 - y0)
            }
        }
        return last.1
    }
}

public struct WANIPSnapshot: Equatable, Sendable {
    public let ipv4: String
    public let ipv6: String

    public init(ipv4: String = "", ipv6: String = "") {
        self.ipv4 = ipv4.trimmingCharacters(in: .whitespacesAndNewlines)
        self.ipv6 = ipv6.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init(snapshot: RouterStatusSnapshot?) {
        self.init(
            ipv4: snapshot?.wanIPv4 ?? "",
            ipv6: snapshot?.wanIPv6 ?? ""
        )
    }

    public var isEmpty: Bool {
        ipv4.isEmpty && ipv6.isEmpty
    }

    public func hasChanged(from previous: WANIPSnapshot) -> Bool {
        if !ipv4.isEmpty && !previous.ipv4.isEmpty && ipv4 != previous.ipv4 {
            return true
        }
        if !ipv6.isEmpty && !previous.ipv6.isEmpty && ipv6 != previous.ipv6 {
            return true
        }
        if ipv4 != previous.ipv4 && (!ipv4.isEmpty || !previous.ipv4.isEmpty) {
            return true
        }
        return false
    }
}

public enum WANIPChangeFormatter {
    public static func formatNotificationMessage(
        isAutomatic: Bool,
        profileName: String,
        state: WANConnectionState,
        before: WANIPSnapshot,
        after: WANIPSnapshot
    ) -> (title: String, body: String) {
        let modeText = isAutomatic ? "自动重连" : "手动重连"
        let changed = after.hasChanged(from: before)

        let title: String
        if !state.isConnected {
            title = "\(modeText)已完成（\(state.localizedLabel)）"
        } else if changed {
            title = "\(modeText)完成 · 外网 IP 已变更"
        } else {
            title = "\(modeText)完成 · 外网 IP 未变化"
        }

        var lines: [String] = ["路由器：\(profileName)"]
        let v4Text = formatDeltaLine(label: "IPv4", before: before.ipv4, after: after.ipv4)
        if let v4Text {
            lines.append(v4Text)
        }
        if !before.ipv6.isEmpty || !after.ipv6.isEmpty {
            if let v6Text = formatDeltaLine(label: "IPv6", before: before.ipv6, after: after.ipv6) {
                lines.append(v6Text)
            }
        }
        if before.isEmpty && after.isEmpty {
            lines.append("暂未读取到重连前后 WAN IP（当前状态：\(state.localizedLabel)）")
        }

        return (title, lines.joined(separator: "\n"))
    }

    public static func formatLogSummary(before: WANIPSnapshot, after: WANIPSnapshot) -> String {
        var parts: [String] = []
        if let v4 = formatDeltaLine(label: "IPv4", before: before.ipv4, after: after.ipv4) {
            parts.append(v4)
        }
        if !before.ipv6.isEmpty || !after.ipv6.isEmpty,
           let v6 = formatDeltaLine(label: "IPv6", before: before.ipv6, after: after.ipv6) {
            parts.append(v6)
        }
        return parts.isEmpty ? "WAN IP 暂无变化记录" : parts.joined(separator: " | ")
    }

    private static func formatDeltaLine(label: String, before: String, after: String) -> String? {
        if before.isEmpty && after.isEmpty { return nil }
        let beforeText = before.isEmpty ? "未知" : before
        let afterText = after.isEmpty ? "未获取" : after
        if !before.isEmpty && !after.isEmpty && before == after {
            return "\(label)：\(afterText)（未变化）"
        }
        return "\(label)：\(beforeText) → \(afterText)"
    }
}
