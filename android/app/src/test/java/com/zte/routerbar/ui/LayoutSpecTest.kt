package com.zte.routerbar.ui

import java.time.ZoneOffset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LayoutSpecTest {
    @Test
    fun breakpointsAdaptBetweenCompactPhonesAndWideScreens() {
        assertEquals(2, LayoutSpec.summaryGridColumns(360))
        assertEquals(2, LayoutSpec.summaryGridColumns(599))
        assertEquals(4, LayoutSpec.summaryGridColumns(600))
        assertEquals(4, LayoutSpec.summaryGridColumns(840))

        assertEquals(1, LayoutSpec.cellGridColumns(412))
        assertEquals(2, LayoutSpec.cellGridColumns(600))
        assertEquals(1, LayoutSpec.detailPairsPerRow(390))
        assertEquals(2, LayoutSpec.detailPairsPerRow(700))
    }

    @Test
    fun monotoneCubicSplineNeverOvershootsStepExtremaAndHandlesEdgeSizes() {
        assertTrue(LayoutSpec.computeMonotoneCubicSegments(emptyList()).isEmpty())
        assertTrue(LayoutSpec.computeMonotoneCubicSegments(listOf(0f to 10f)).isEmpty())

        val twoPt = LayoutSpec.computeMonotoneCubicSegments(listOf(0f to 10f, 30f to 40f))
        assertEquals(1, twoPt.size)
        assertEquals(0f, twoPt[0].x0, 0.001f)
        assertEquals(30f, twoPt[0].x1, 0.001f)

        val stepPoints = listOf(
            0f to 10f,
            10f to 10f,
            20f to 50f,
            30f to 50f
        )
        val segments = LayoutSpec.computeMonotoneCubicSegments(stepPoints)
        assertEquals(3, segments.size)
        for (seg in segments) {
            assertTrue(seg.cy1 in 10f..50f)
            assertTrue(seg.cy2 in 10f..50f)
        }
    }

    @Test
    fun chartDomainAndNumericFormattersMatchBaseline() {
        val (rsrpMin, rsrpMax) = LayoutSpec.chartYDomain(SignalChartMetric.RSRP, listOf(-88.0, -76.0))
        assertTrue(rsrpMin <= -120.0)
        assertTrue(rsrpMax >= -65.0)

        val (scoreMin, scoreMax) = LayoutSpec.chartYDomain(SignalChartMetric.SCORE, listOf(45.0, 90.0))
        assertEquals(0.0, scoreMin, 0.001)
        assertEquals(100.0, scoreMax, 0.001)

        assertEquals("05:43:33", Formatters.duration(20_613))
        assertEquals("1.50 GB", Formatters.byteCount(1_610_612_736L))
        assertEquals("22:13:20", Formatters.timeOfDay(1_700_000_000_000L, ZoneOffset.UTC))
        assertEquals(MetricTone.EXCELLENT, Formatters.rsrpTone("-76"))
        assertEquals(MetricTone.POOR, Formatters.rsrpTone("-115"))
    }
}
