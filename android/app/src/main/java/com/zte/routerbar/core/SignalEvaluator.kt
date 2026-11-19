package com.zte.routerbar.core

import java.util.Locale
import java.util.UUID
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

enum class SignalQualityGrade(val label: String) {
    EXCELLENT("极佳"),
    GOOD("良好"),
    FAIR("一般"),
    POOR("较差"),
    VERY_POOR("极弱"),
    UNKNOWN("未知")
}

data class SignalRatingAssessment(
    val score: Int,
    val grade: SignalQualityGrade,
    val primaryTechLabel: String,
    val rsrp: Double? = null,
    val sinr: Double? = null,
    val rsrq: Double? = null,
    val adviceText: String = ""
)

data class SignalSample(
    val id: String = UUID.randomUUID().toString(),
    val timestampMs: Long,
    val rsrp: Double?,
    val sinr: Double?,
    val score: Int
)

object SignalEvaluator {
    private val RSRP_POINTS = listOf(
        -125.0 to 0.0,
        -115.0 to 18.0,
        -110.0 to 32.0,
        -100.0 to 56.0,
        -90.0 to 78.0,
        -80.0 to 92.0,
        -68.0 to 100.0
    )

    private val SINR_POINTS = listOf(
        -10.0 to 0.0,
        0.0 to 30.0,
        10.0 to 60.0,
        15.0 to 76.0,
        20.0 to 88.0,
        30.0 to 100.0
    )

    private val RSRQ_POINTS = listOf(
        -22.0 to 0.0,
        -16.0 to 42.0,
        -12.0 to 68.0,
        -9.0 to 86.0,
        -5.0 to 100.0
    )

    fun assess(snapshot: RouterStatusSnapshot): SignalRatingAssessment {
        val rsrp: Double?
        val sinr: Double?
        val rsrq: Double?
        val techLabel: String

        val nr = snapshot.nrCells.firstOrNull()
        val lte = snapshot.lteCells.firstOrNull()
        val umts = snapshot.umtsInfo

        when {
            nr != null -> {
                rsrp = nr.rsrp1.toDoubleOrNull() ?: nr.rsrp2.toDoubleOrNull()
                sinr = nr.sinr.toDoubleOrNull()
                rsrq = nr.rsrq.toDoubleOrNull()
                val mode = when {
                    snapshot.is5GSA -> "5G SA"
                    snapshot.is5GNSA -> "5G NSA"
                    else -> "5G"
                }
                techLabel = if (nr.band.isEmpty()) mode else "$mode ${nr.band}"
            }
            lte != null -> {
                rsrp = lte.rsrpList.firstOrNull()?.toDoubleOrNull()
                sinr = lte.sinrList.firstOrNull()?.toDoubleOrNull()
                rsrq = lte.rsrq.toDoubleOrNull()
                techLabel = if (lte.band.isEmpty()) "4G LTE" else "LTE ${lte.band}"
            }
            umts != null -> {
                rsrp = umts.rscp.firstOrNull()?.toDoubleOrNull()
                sinr = null
                rsrq = umts.ecio.firstOrNull()?.toDoubleOrNull()?.let { -it }
                techLabel = if (umts.band.isEmpty()) "3G" else "3G ${umts.band}"
            }
            else -> {
                rsrp = null
                sinr = null
                rsrq = null
                techLabel = snapshot.networkType.ifEmpty { "未知" }
            }
        }

        val (score, grade) = evaluate(rsrp = rsrp, sinr = sinr, rsrq = rsrq, fallbackBars = snapshot.signalBars)
        val advice = buildAdvice(grade = grade, rsrp = rsrp, sinr = sinr)
        return SignalRatingAssessment(
            score = score,
            grade = grade,
            primaryTechLabel = techLabel,
            rsrp = rsrp,
            sinr = sinr,
            rsrq = rsrq,
            adviceText = advice
        )
    }

    fun sample(from: RouterStatusSnapshot): SignalSample? {
        if (from.isUnauthenticatedEmptySnapshot) return null
        val assessment = assess(from)
        if (assessment.grade == SignalQualityGrade.UNKNOWN && assessment.rsrp == null && assessment.sinr == null) {
            return null
        }
        return SignalSample(
            timestampMs = from.fetchedAtMs,
            rsrp = assessment.rsrp,
            sinr = assessment.sinr,
            score = assessment.score
        )
    }

    fun headerSignalText(snapshot: RouterStatusSnapshot): String {
        if (!snapshot.connectionState.isConnected) return "断网"
        val assessment = assess(snapshot)
        if (assessment.rsrp != null) {
            return "${assessment.rsrp.roundToInt()}dBm ${assessment.grade.label}"
        }
        val bars = snapshot.signalBars
        if (bars != null && assessment.grade != SignalQualityGrade.UNKNOWN) {
            return "${bars}格 ${assessment.grade.label}"
        }
        if (assessment.grade != SignalQualityGrade.UNKNOWN) {
            return assessment.grade.label
        }
        return snapshot.networkType.ifEmpty { "在线" }
    }

    fun evaluate(
        rsrp: Double?,
        sinr: Double?,
        rsrq: Double? = null,
        fallbackBars: Int? = null
    ): Pair<Int, SignalQualityGrade> {
        var weightedSum = 0.0
        var totalWeight = 0.0

        if (rsrp != null) {
            weightedSum += interpolate(rsrp, RSRP_POINTS) * 0.60
            totalWeight += 0.60
        }
        if (sinr != null) {
            weightedSum += interpolate(sinr, SINR_POINTS) * 0.30
            totalWeight += 0.30
        }
        if (rsrq != null) {
            weightedSum += interpolate(rsrq, RSRQ_POINTS) * 0.10
            totalWeight += 0.10
        }

        if (totalWeight <= 0.0) {
            if (fallbackBars != null && fallbackBars in 0..5) {
                val score = fallbackBars * 20
                return score to gradeForScore(score)
            }
            return 0 to SignalQualityGrade.UNKNOWN
        }

        var score = (weightedSum / totalWeight).roundToInt()
        if (rsrp != null && rsrp < -112.0) {
            score = min(score, 45)
        }
        if (sinr != null && sinr < 0.0) {
            score = min(score, 64)
        }
        score = score.coerceIn(0, 100)
        return score to gradeForScore(score)
    }

    fun gradeForScore(score: Int): SignalQualityGrade = when {
        score in 85..100 -> SignalQualityGrade.EXCELLENT
        score in 68 until 85 -> SignalQualityGrade.GOOD
        score in 48 until 68 -> SignalQualityGrade.FAIR
        score in 25 until 48 -> SignalQualityGrade.POOR
        else -> SignalQualityGrade.VERY_POOR
    }

    private fun buildAdvice(grade: SignalQualityGrade, rsrp: Double?, sinr: Double?): String = when (grade) {
        SignalQualityGrade.UNKNOWN -> "暂无有效无线信号指标"
        SignalQualityGrade.EXCELLENT -> "信号覆盖与信噪比俱佳，适合高速率与低延迟传输"
        SignalQualityGrade.GOOD -> "信号质量良好，日常负载稳定"
        SignalQualityGrade.FAIR, SignalQualityGrade.POOR, SignalQualityGrade.VERY_POOR -> when {
            rsrp != null && rsrp < -105.0 && sinr != null && sinr < 5.0 ->
                "电平较弱且干扰偏高，建议移近窗口或调整摆位"
            rsrp != null && rsrp < -105.0 ->
                "信号接收功率偏弱（RSRP ${rsrp.toInt()} dBm），可尝试换位或锁定高频段"
            sinr != null && sinr < 5.0 ->
                "信噪比偏低（SINR ${String.format(Locale.US, "%.1f", sinr)} dB），同频/邻区干扰较明显"
            else -> "信号处于中等波动区间"
        }
    }

    private fun interpolate(value: Double, points: List<Pair<Double, Double>>): Double {
        if (points.isEmpty()) return 0.0
        val first = points.first()
        val last = points.last()
        if (value <= first.first) return first.second
        if (value >= last.first) return last.second

        for (idx in 0 until (points.size - 1)) {
            val (x0, y0) = points[idx]
            val (x1, y1) = points[idx + 1]
            if (value in x0..x1) {
                val ratio = (value - x0) / max(0.0001, x1 - x0)
                return y0 + ratio * (y1 - y0)
            }
        }
        return last.second
    }
}
