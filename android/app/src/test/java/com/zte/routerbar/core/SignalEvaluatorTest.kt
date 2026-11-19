package com.zte.routerbar.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SignalEvaluatorTest {
    @Test
    fun signalRatingAssessmentAndWanIpBannerFormattingMatchBaseline() {
        val (strongScore, strongGrade) = SignalEvaluator.evaluate(rsrp = -78.0, sinr = 24.0, rsrq = -8.0)
        assertEquals(SignalQualityGrade.EXCELLENT, strongGrade)
        assertTrue(strongScore >= 85)

        val (weakScore, weakGrade) = SignalEvaluator.evaluate(rsrp = -115.0, sinr = 12.0, rsrq = -16.0)
        assertTrue(weakScore <= 45)
        assertTrue(weakGrade == SignalQualityGrade.POOR || weakGrade == SignalQualityGrade.VERY_POOR)

        val snap1 = RouterStatusParser.parseJsonTexts(
            listOf(
                """{"ppp_status":"ipv4_ipv6_connected","network_type":"SA","nr5g_action_band":"n41","5g_rx0_rsrp":"-84","Z5g_SINR":"21.0","Z5g_rsrq":"-9","wan_ipaddr":"10.10.0.1","ipv6_wan_ipaddr":"2001:db8::1"}"""
            )
        )
        val sample = SignalEvaluator.sample(snap1)
        assertNotNull(sample)
        assertEquals(-84.0, sample!!.rsrp!!, 0.001)
        assertEquals(21.0, sample.sinr!!, 0.001)

        val strongSnap = RouterStatusParser.parseJsonTexts(
            listOf(
                """{"ppp_status":"ipv4_ipv6_connected","network_type":"SA","nr5g_action_band":"n41","5g_rx0_rsrp":"-69","Z5g_SINR":"23.5","Z5g_rsrq":"-12"}"""
            )
        )
        assertEquals("-69dBm 极佳", SignalEvaluator.headerSignalText(strongSnap))

        val offlineSnap = RouterStatusParser.parseJsonTexts(
            listOf(
                """{"ppp_status":"ppp_disconnected","network_type":"SA","5g_rx0_rsrp":"-69"}"""
            )
        )
        assertEquals("断网", SignalEvaluator.headerSignalText(offlineSnap))

        val beforeIp = WANIPSnapshot.fromSnapshot(snap1)
        val afterIp = WANIPSnapshot(ipv4 = "10.10.0.2", ipv6 = "2001:db8::2")
        val (changedTitle, changedDetail) = WANIPChangeFormatter.formatBannerSummary(
            state = WANConnectionState.Connected("ipv4_ipv6_connected"),
            before = beforeIp,
            after = afterIp
        )
        assertTrue(changedTitle.contains("IP 已变更"))
        assertTrue(changedDetail.contains("10.10.0.1 → 10.10.0.2"))
        assertTrue(changedDetail.contains("2001:db8::1 → 2001:db8::2"))

        val (sameTitle, sameDetail) = WANIPChangeFormatter.formatBannerSummary(
            state = WANConnectionState.Connected("ipv4_ipv6_connected"),
            before = beforeIp,
            after = beforeIp
        )
        assertTrue(sameTitle.contains("未变化"))
        assertTrue(sameDetail.contains("10.10.0.1（未变化）"))
    }
}
