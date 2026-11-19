package com.zte.routerbar.core

import com.zte.routerbar.data.AndroidProfileStore
import com.zte.routerbar.data.StoredAppSettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RouterStatusParserTest {
    @Test
    fun parsesRadioCountsStationListsAndHidesBogusWifi5Label() {
        val mu5120Json1 = """
            {
              "wa_inner_version": "BD_FLYMODEMMU5120V1.0.1B12",
              "cr_version": "",
              "ppp_status": "ipv4_ipv6_connected",
              "wan_connect_status": "pdp_connected",
              "network_type": "SA",
              "network_provider": "CMCC",
              "mdm_mcc": "460",
              "mdm_mnc": "02",
              "wan_apn": "CMIOT5G",
              "wan_ipaddr": "10.0.0.2",
              "ipv6_wan_ipaddr": "2001:db8::2",
              "bandwidth": "100MHz",
              "Z5g_rsrp": "-76",
              "Z5g_rsrq": "-11",
              "Z5g_SINR": "22.0",
              "nr5g_cell_id": "151918002",
              "nr5g_pci": "297",
              "nr5g_action_channel": "504990",
              "nr5g_action_band": "n41",
              "pm_sensor_mdm": "41",
              "pm_sensor_pa1": "39",
              "wifi_chip_temp": "47"
            }
        """.trimIndent()

        val mu5120Json2 = """
            {
              "net_select": "Only_5G",
              "realtime_time": "20613",
              "battery_value": "100",
              "battery_charging": "2",
              "wifi_access_sta_num": "6",
              "wifi_chip1_ssid1_access_sta_num": "1",
              "wifi_chip2_ssid1_access_sta_num": "5"
            }
        """.trimIndent()

        val stationListJson = """
            {
              "station_list": [
                {"interfacetype": "WIFI5", "ip_addr": "192.168.8.47", "connect_time": "120", "ssid_index": "2", "mac_addr": "00:00:5E:00:53:01", "hostname": "device-1"},
                {"interfacetype": "WIFI5", "ip_addr": "192.168.8.48", "connect_time": "60", "ssid_index": "1", "mac_addr": "00:00:5E:00:53:02", "hostname": "device-2"}
              ]
            }
        """.trimIndent()

        val lanStationListJson = """
            {
              "lan_station_list": [
                {"interfacetype": "", "ip_addr": "192.168.8.50", "connect_time": "300", "ssid_index": "", "mac_addr": "00:00:5E:00:53:03", "hostname": "wired-1"}
              ]
            }
        """.trimIndent()

        val snap = RouterStatusParser.parseJsonTexts(
            listOf(mu5120Json1, mu5120Json2, stationListJson, lanStationListJson),
            fetchedAtMs = 1_700_000_000_000L
        )

        assertTrue(snap.connectionState.isConnected)
        assertTrue(snap.is5GSA)
        assertEquals("n41(100MHz)", snap.bandSummary)
        assertEquals(1, snap.nrCells.size)
        assertEquals("297", snap.nrCells[0].pci)
        assertEquals("n41", snap.nrCells[0].band)
        assertEquals(6, snap.wifiAccessStationCount)
        assertEquals(1, snap.wifi24GCount)
        assertEquals(5, snap.wifi5GCount)
        assertEquals(6, snap.wirelessDeviceCount)
        assertEquals(1, snap.wiredDeviceCount)
        assertEquals(7, snap.totalConnectedDevices)
        assertEquals(2, snap.wifiStations.size)
        assertEquals(ConnectedDeviceKind.WIRELESS, snap.wifiStations[0].deviceKind)
        assertEquals("无线 Wi-Fi", snap.wifiStations[0].displayConnectionType)
        assertEquals(1, snap.lanStations.size)
        assertEquals(ConnectedDeviceKind.WIRED, snap.lanStations[0].deviceKind)
        assertEquals("有线 / USB", snap.lanStations[0].displayConnectionType)
    }

    @Test
    fun parsesLteCaPlusNsaCellsFiltersInvalidSensorsAndRejectsJsonNullLiteral() {
        val lteJson = """
            {
              "wa_inner_version": "BD_MC888V1.0",
              "network_type": "ENDC",
              "wan_lte_ca": "ca_activated",
              "lte_pci": "1A",
              "lte_ca_pcell_band": "3",
              "lte_ca_pcell_freq": "1525",
              "lte_ca_pcell_bandwidth": "20MHz",
              "lte_rsrp_1": "-85",
              "lte_snr_1": "15.0",
              "lte_rsrq": "-9",
              "lte_multi_ca_scell_info": "1,2B,2,1,300,15.0;",
              "lte_multi_ca_scell_sig_info": "-90.0,-8.0,12.5,0,2;",
              "nr5g_pci": "64",
              "nr5g_action_channel": "639936",
              "nr5g_action_nsa_band": "78",
              "5g_rx0_rsrp": "-82",
              "Z5g_SINR": "18.5",
              "pm_sensor_ambient": "-273",
              "wan_ipaddr": null,
              "ipv6_wan_ipaddr": null
            }
        """.trimIndent()

        val snap = RouterStatusParser.parseJsonTexts(listOf(lteJson))
        assertTrue(snap.isLTE)
        assertTrue(snap.is5GNSA)
        assertTrue(snap.isLTECarrierAggregationActive)
        assertEquals(2, snap.lteCells.size)
        assertEquals("26", snap.lteCells[0].pci)
        assertEquals("B3", snap.lteCells[0].band)
        assertEquals("43", snap.lteCells[1].pci)
        assertEquals("B1", snap.lteCells[1].band)
        assertEquals(1, snap.nrCells.size)
        assertEquals("n78", snap.nrCells[0].band)
        assertTrue(snap.temperatures.isEmpty())
        assertEquals("", snap.wanIPv4)
        assertEquals("", snap.wanIPv6)
    }

    @Test
    fun gatewayProfileMatcherAndSettingsJsonRoundTrip() {
        val p1 = RouterProfile(id = "p1", name = "随身路由 A", routerUrlString = "http://192.168.8.1")
        val p2 = RouterProfile(id = "p2", name = "随身路由 B", routerUrlString = "192.168.8.1:80")
        val p3 = RouterProfile(id = "p3", name = "客厅 CPE", routerUrlString = "http://192.168.0.1")
        val profiles = listOf(p1, p2, p3)

        assertEquals("p3", RouterProfileMatcher.matchByGateway("192.168.0.1", profiles, activeProfileId = "p1")?.id)
        // Keeps active profile p2 when gateway 192.168.8.1 already matches p2.
        assertEquals("p2", RouterProfileMatcher.matchByGateway("192.168.8.1", profiles, activeProfileId = "p2")?.id)
        assertNull(RouterProfileMatcher.matchByGateway("10.0.0.1", profiles, activeProfileId = "p1"))

        val stored = StoredAppSettings(
            profiles = profiles,
            activeProfileId = "p2",
            autoMatchByGateway = true,
            pollingIntervalSec = 5
        )
        val encoded = AndroidProfileStore.encodeSettingsJson(stored)
        val decoded = AndroidProfileStore.decodeSettingsJson(encoded)
        assertEquals(stored, decoded)
    }
}
