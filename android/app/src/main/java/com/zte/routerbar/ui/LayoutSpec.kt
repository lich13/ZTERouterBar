package com.zte.routerbar.ui

import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.hypot
import kotlin.math.min

enum class SignalChartMetric(val label: String) {
    RSRP("RSRP (dBm)"),
    SINR("SINR (dB)"),
    SCORE("综合评分")
}

data class ChartThreshold(
    val label: String,
    val value: Double,
    val tone: MetricTone
)

enum class MetricTone {
    EXCELLENT,
    GOOD,
    FAIR,
    POOR,
    NEUTRAL
}

data class CubicBezierSegment(
    val x0: Float,
    val y0: Float,
    val cx1: Float,
    val cy1: Float,
    val cx2: Float,
    val cy2: Float,
    val x1: Float,
    val y1: Float
)

/**
 * Single source of truth for responsive breakpoints, fixed label/slot widths,
 * touch targets, polling limits, and monotone cubic chart geometry.
 */
object LayoutSpec {
    const val COMPACT_MAX_WIDTH_DP = 600
    const val DETAIL_LABEL_WIDTH_DP = 88
    const val CELL_METRIC_LABEL_WIDTH_DP = 58
    const val TOOLBAR_CONTROL_HEIGHT_DP = 36
    const val MIN_TOUCH_TARGET_DP = 48
    const val CHART_HEIGHT_DP = 172
    const val SIGNAL_HISTORY_LIMIT = 120
    const val STATION_FETCH_INTERVAL_MS = 10_000L

    fun summaryGridColumns(screenWidthDp: Int): Int =
        if (screenWidthDp < COMPACT_MAX_WIDTH_DP) 2 else 4

    fun cellGridColumns(screenWidthDp: Int): Int =
        if (screenWidthDp < COMPACT_MAX_WIDTH_DP) 1 else 2

    fun detailPairsPerRow(screenWidthDp: Int): Int =
        if (screenWidthDp < COMPACT_MAX_WIDTH_DP) 1 else 2

    fun chartYDomain(metric: SignalChartMetric, values: List<Double>): Pair<Double, Double> {
        val minV = values.minOrNull() ?: 0.0
        val maxV = values.maxOrNull() ?: 0.0
        return when (metric) {
            SignalChartMetric.RSRP -> {
                val lo = minOf(-120.0, floor((minV - 4.0) / 5.0) * 5.0)
                val hi = maxOf(-65.0, ceil((maxV + 4.0) / 5.0) * 5.0)
                lo to hi
            }
            SignalChartMetric.SINR -> {
                val lo = minOf(-5.0, floor((minV - 2.0) / 5.0) * 5.0)
                val hi = maxOf(32.0, ceil((maxV + 2.0) / 5.0) * 5.0)
                lo to hi
            }
            SignalChartMetric.SCORE -> 0.0 to 100.0
        }
    }

    fun chartThresholds(metric: SignalChartMetric): List<ChartThreshold> = when (metric) {
        SignalChartMetric.RSRP -> listOf(
            ChartThreshold("极佳 -85", -85.0, MetricTone.EXCELLENT),
            ChartThreshold("良好 -100", -100.0, MetricTone.FAIR)
        )
        SignalChartMetric.SINR -> listOf(
            ChartThreshold("优秀 20", 20.0, MetricTone.EXCELLENT),
            ChartThreshold("良好 13", 13.0, MetricTone.GOOD)
        )
        SignalChartMetric.SCORE -> listOf(
            ChartThreshold("极佳 85", 85.0, MetricTone.EXCELLENT),
            ChartThreshold("良好 68", 68.0, MetricTone.GOOD)
        )
    }

    /**
     * Computes Fritsch-Carlson monotone cubic Hermite spline Bezier segments so the signal
     * trend curve matches SwiftUI `.interpolationMethod(.monotone)` without overshooting extrema.
     */
    fun computeMonotoneCubicSegments(points: List<Pair<Float, Float>>): List<CubicBezierSegment> {
        val n = points.size
        if (n < 2) return emptyList()
        if (n == 2) {
            val (x0, y0) = points[0]
            val (x1, y1) = points[1]
            val dx = (x1 - x0) / 3f
            val dy = (y1 - y0) / 3f
            return listOf(
                CubicBezierSegment(
                    x0 = x0, y0 = y0,
                    cx1 = x0 + dx, cy1 = y0 + dy,
                    cx2 = x1 - dx, cy2 = y1 - dy,
                    x1 = x1, y1 = y1
                )
            )
        }

        val dx = FloatArray(n - 1)
        val slopes = FloatArray(n - 1)
        for (i in 0 until n - 1) {
            val h = (points[i + 1].first - points[i].first).coerceAtLeast(0.0001f)
            dx[i] = h
            slopes[i] = (points[i + 1].second - points[i].second) / h
        }

        val tangents = FloatArray(n)
        tangents[0] = slopes[0]
        tangents[n - 1] = slopes[n - 2]
        for (i in 1 until n - 1) {
            val s0 = slopes[i - 1]
            val s1 = slopes[i]
            tangents[i] = if (s0 * s1 <= 0f) 0f else (s0 + s1) * 0.5f
        }

        for (i in 0 until n - 1) {
            val s = slopes[i]
            if (abs(s) < 1e-6f) {
                tangents[i] = 0f
                tangents[i + 1] = 0f
            } else {
                val a = tangents[i] / s
                val b = tangents[i + 1] / s
                val norm = hypot(a.toDouble(), b.toDouble()).toFloat()
                if (norm > 3f) {
                    val scale = 3f / norm
                    tangents[i] = scale * a * s
                    tangents[i + 1] = scale * b * s
                }
            }
        }

        val segments = ArrayList<CubicBezierSegment>(n - 1)
        for (i in 0 until n - 1) {
            val (x0, y0) = points[i]
            val (x1, y1) = points[i + 1]
            val h = min(x1 - x0, dx[i])
            val third = h / 3f
            segments.add(
                CubicBezierSegment(
                    x0 = x0,
                    y0 = y0,
                    cx1 = x0 + third,
                    cy1 = y0 + tangents[i] * third,
                    cx2 = x1 - third,
                    cy2 = y1 - tangents[i + 1] * third,
                    x1 = x1,
                    y1 = y1
                )
            )
        }
        return segments
    }
}
