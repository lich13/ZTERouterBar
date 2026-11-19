package com.zte.routerbar.ui

import com.zte.routerbar.core.RouterStatusSnapshot
import com.zte.routerbar.core.SignalQualityGrade
import java.util.Locale

object Formatters {
    fun byteCount(bytes: Long): String {
        val safe = bytes.coerceAtLeast(0L)
        val kb = 1024.0
        val mb = kb * 1024.0
        val gb = mb * 1024.0
        val tb = gb * 1024.0
        return when {
            safe >= tb -> String.format(Locale.US, "%.2f TB", safe / tb)
            safe >= gb -> String.format(Locale.US, "%.2f GB", safe / gb)
            safe >= mb -> String.format(Locale.US, "%.1f MB", safe / mb)
            safe >= kb -> String.format(Locale.US, "%.0f KB", safe / kb)
            else -> "$safe B"
        }
    }

    fun duration(totalSeconds: Int): String {
        val safe = totalSeconds.coerceAtLeast(0)
        val hours = safe / 3600
        val minutes = (safe % 3600) / 60
        val seconds = safe % 60
        return String.format(Locale.US, "%02d:%02d:%02d", hours, minutes, seconds)
    }

    fun rsrpTone(raw: String): MetricTone {
        val value = raw.toDoubleOrNull() ?: return MetricTone.NEUTRAL
        return when {
            value >= -85.0 -> MetricTone.EXCELLENT
            value >= -100.0 -> MetricTone.GOOD
            value >= -110.0 -> MetricTone.FAIR
            else -> MetricTone.POOR
        }
    }

    fun sinrTone(raw: String): MetricTone {
        val value = raw.toDoubleOrNull() ?: return MetricTone.NEUTRAL
        return when {
            value >= 20.0 -> MetricTone.EXCELLENT
            value >= 13.0 -> MetricTone.GOOD
            value >= 0.0 -> MetricTone.FAIR
            else -> MetricTone.POOR
        }
    }

    fun gradeTone(grade: SignalQualityGrade): MetricTone = when (grade) {
        SignalQualityGrade.EXCELLENT -> MetricTone.EXCELLENT
        SignalQualityGrade.GOOD -> MetricTone.GOOD
        SignalQualityGrade.FAIR -> MetricTone.FAIR
        SignalQualityGrade.POOR, SignalQualityGrade.VERY_POOR -> MetricTone.POOR
        SignalQualityGrade.UNKNOWN -> MetricTone.NEUTRAL
    }

    fun dnsSummary(snap: RouterStatusSnapshot): String {
        if (snap.dnsMode == "manual") {
            val list = listOf(snap.preferDNSManual, snap.standbyDNSManual).filter { it.isNotEmpty() }
            return if (list.isEmpty()) "手动" else "手动 (${list.joinToString(", ")})"
        }
        return snap.dnsMode.ifEmpty { "-" }
    }

    fun metricChartValue(metric: SignalChartMetric, value: Double): String = when (metric) {
        SignalChartMetric.RSRP -> String.format(Locale.US, "%.0f dBm", value)
        SignalChartMetric.SINR -> String.format(Locale.US, "%.1f dB", value)
        SignalChartMetric.SCORE -> String.format(Locale.US, "%.0f 分", value)
    }
}
