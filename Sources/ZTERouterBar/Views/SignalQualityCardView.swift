import Charts
import SwiftUI
import ZTERouterCore

enum SignalChartMetric: String, CaseIterable, Identifiable {
    case rsrp = "RSRP (dBm)"
    case sinr = "SINR (dB)"
    case score = "综合评分"

    var id: String { rawValue }
}

struct SignalQualityDashboardCard: View {
    let assessment: SignalRatingAssessment
    let samples: [SignalSample]
    let signalBars: Int?

    @State private var selectedMetric: SignalChartMetric = .rsrp

    var body: some View {
        let gradeColor = Formatters.signalGradeColor(assessment.grade)
        let points = plottedPoints

        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("信号强度评级")
                                .font(.headline)
                            Text(assessment.grade.rawValue)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(gradeColor, in: Capsule())
                            Text("\(assessment.score) / 100")
                                .font(.subheadline.monospacedDigit().weight(.semibold))
                                .foregroundStyle(gradeColor)
                            if let bars = signalBars {
                                Text("格数 \(bars)/5")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Text("\(assessment.primaryTechLabel) · \(assessment.adviceText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Picker("", selection: $selectedMetric) {
                        ForEach(SignalChartMetric.allCases) { metric in
                            Text(metric.rawValue).tag(metric)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                }

                if points.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在等待该指标的轮询采样数据…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 150, alignment: .center)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    chartBody(points: points, lineColor: gradeColor)
                        .frame(height: 165)

                    HStack(spacing: 16) {
                        let vals = points.map(\.value)
                        if let minV = vals.min(), let maxV = vals.max(), let lastV = vals.last {
                            let avgV = vals.reduce(0, +) / Double(vals.count)
                            statItem("最新", formatValue(lastV))
                            statItem("平均", formatValue(avgV))
                            statItem("最低", formatValue(minV))
                            statItem("最高", formatValue(maxV))
                        }
                        Spacer()
                        Text("最近 \(points.count) 次采样")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(6)
        }
    }

    private struct ChartPoint: Identifiable {
        let id: UUID
        let timestamp: Date
        let value: Double
    }

    private var plottedPoints: [ChartPoint] {
        samples.compactMap { sample in
            let val: Double?
            switch selectedMetric {
            case .rsrp:
                val = sample.rsrp
            case .sinr:
                val = sample.sinr
            case .score:
                val = Double(sample.score)
            }
            guard let val else { return nil }
            return ChartPoint(id: sample.id, timestamp: sample.timestamp, value: val)
        }
    }

    @ViewBuilder
    private func chartBody(points: [ChartPoint], lineColor: Color) -> some View {
        let domain = yDomain(for: points.map(\.value))
        Chart {
            ForEach(referenceThresholds, id: \.value) { threshold in
                RuleMark(y: .value("基准", threshold.value))
                    .foregroundStyle(threshold.color.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text(threshold.label)
                            .font(.system(size: 9))
                            .foregroundStyle(threshold.color.opacity(0.85))
                    }
            }

            ForEach(points) { pt in
                AreaMark(
                    x: .value("时间", pt.timestamp),
                    yStart: .value("底线", domain.lowerBound),
                    yEnd: .value(selectedMetric.rawValue, pt.value)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    LinearGradient(
                        colors: [lineColor.opacity(0.28), lineColor.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("时间", pt.timestamp),
                    y: .value(selectedMetric.rawValue, pt.value)
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .foregroundStyle(lineColor)

                if points.count <= 2 || pt.id == points.last?.id {
                    PointMark(
                        x: .value("时间", pt.timestamp),
                        y: .value(selectedMetric.rawValue, pt.value)
                    )
                    .symbolSize(pt.id == points.last?.id ? 40 : 22)
                    .foregroundStyle(lineColor)
                }
            }
        }
        .chartYScale(domain: domain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute().second())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4))
        }
    }

    private var referenceThresholds: [(label: String, value: Double, color: Color)] {
        switch selectedMetric {
        case .rsrp:
            return [("极佳 -85", -85, .green), ("良好 -100", -100, .orange)]
        case .sinr:
            return [("优秀 20", 20, .green), ("良好 13", 13, .blue)]
        case .score:
            return [("极佳 85", 85, .green), ("良好 68", 68, .blue)]
        }
    }

    private func yDomain(for values: [Double]) -> ClosedRange<Double> {
        let minV = values.min() ?? 0
        let maxV = values.max() ?? 0
        switch selectedMetric {
        case .rsrp:
            let lo = min(-120, floor((minV - 4) / 5) * 5)
            let hi = max(-65, ceil((maxV + 4) / 5) * 5)
            return lo...hi
        case .sinr:
            let lo = min(-5, floor((minV - 2) / 5) * 5)
            let hi = max(32, ceil((maxV + 2) / 5) * 5)
            return lo...hi
        case .score:
            return 0...100
        }
    }

    private func formatValue(_ val: Double) -> String {
        switch selectedMetric {
        case .rsrp:
            return String(format: "%.0f dBm", val)
        case .sinr:
            return String(format: "%.1f dB", val)
        case .score:
            return String(format: "%.0f 分", val)
        }
    }

    private func statItem(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(title + ":")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2.monospacedDigit().weight(.medium))
        }
    }
}

struct SignalSparklineView: View {
    let samples: [SignalSample]
    let lineColor: Color

    var body: some View {
        let points = samples.suffix(40)
        if points.count >= 2 {
            let values = points.map { $0.rsrp ?? Double($0.score) }
            let useRSRP = points.allSatisfy { $0.rsrp != nil }
            let lo = useRSRP ? min(-120.0, (values.min() ?? -120) - 3) : 0.0
            let hi = useRSRP ? max(-65.0, (values.max() ?? -65) + 3) : 100.0

            Chart(Array(points)) { sample in
                let y = useRSRP ? (sample.rsrp ?? -100) : Double(sample.score)
                AreaMark(
                    x: .value("T", sample.timestamp),
                    yStart: .value("Min", lo),
                    yEnd: .value("Val", y)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    LinearGradient(
                        colors: [lineColor.opacity(0.25), lineColor.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("T", sample.timestamp),
                    y: .value("Val", y)
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .foregroundStyle(lineColor)
            }
            .chartYScale(domain: lo...hi)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 32)
        } else {
            Text("信号趋势采样中…")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 18)
        }
    }
}
