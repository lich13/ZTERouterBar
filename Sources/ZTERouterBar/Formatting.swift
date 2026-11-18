import Foundation
import SwiftUI
import ZTERouterCore

enum Formatters {
    static func speedBits(_ bytesPerSecond: Double) -> String {
        let bits = max(0, bytesPerSecond) * 8.0
        if bits < 1_000 {
            return String(format: "%.0f b/s", bits)
        } else if bits < 1_000_000 {
            return String(format: "%.1f Kb/s", bits / 1_000.0)
        } else {
            return String(format: "%.2f Mb/s", bits / 1_000_000.0)
        }
    }

    static func compactSpeed(_ bytesPerSecond: Double) -> String {
        let bits = max(0, bytesPerSecond) * 8.0
        if bits < 1_000 {
            return "0K"
        } else if bits < 1_000_000 {
            return String(format: "%.0fK", bits / 1_000.0)
        } else {
            return String(format: "%.1fM", bits / 1_000_000.0)
        }
    }

    static func byteCount(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }

    static func duration(_ totalSeconds: Int) -> String {
        let safe = max(0, totalSeconds)
        let hours = safe / 3600
        let minutes = (safe % 3600) / 60
        let seconds = safe % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    static func rsrpColor(_ raw: String) -> Color {
        guard let val = Double(raw) else { return .secondary }
        if val >= -85 { return .green }
        if val >= -100 { return .blue }
        if val >= -110 { return .orange }
        return .red
    }

    static func sinrColor(_ raw: String) -> Color {
        guard let val = Double(raw) else { return .secondary }
        if val >= 20 { return .green }
        if val >= 13 { return .blue }
        if val >= 0 { return .orange }
        return .red
    }

    static func signalGradeColor(_ grade: SignalQualityGrade) -> Color {
        switch grade {
        case .excellent: .green
        case .good: .blue
        case .fair: .orange
        case .poor: Color(red: 0.92, green: 0.35, blue: 0.2)
        case .veryPoor: .red
        case .unknown: .secondary
        }
    }
}
