package com.shca.shca

import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.util.Locale
import java.util.TimeZone

class EmergencySmsMessageTest {
    private val zone = TimeZone.getTimeZone("Asia/Kuala_Lumpur")
    private val timestamp = Instant.parse("2026-11-04T06:01:00Z").toEpochMilli()
    private fun fix(latitude: Double = 3.139, longitude: Double = 101.6869,
        source: String = "phone", kind: String = "current", accuracy: Double = 7.0) = mapOf<String, Any>(
        "latitude" to latitude, "longitude" to longitude, "recordedAt" to timestamp,
        "source" to source, "kind" to kind, "accuracyMeters" to accuracy)

    @Test fun allValidLocationExtremesFitOneGsmSmsWithoutLinks() {
        for (sos in listOf(false, true)) for (latitude in listOf(-90.0, 90.0))
        for (longitude in listOf(-180.0, 180.0)) for (source in listOf("phone", "watch"))
        for (kind in listOf("current", "last_known")) for (accuracy in listOf(0.0, 100000.0)) {
            val text = EmergencySmsMessage.format(sos, fix(latitude, longitude, source, kind, accuracy), zone)
            assertTrue("Must fit one SMS: ${text.length}", text.length <= 160)
            // These are all single-septet GSM characters; no Unicode or escape-table symbols.
            assertTrue(text.all { it == '\n' || it in 'A'..'Z' || it in 'a'..'z' ||
                it in '0'..'9' || it in " :.,+/-" })
            assertFalse(text.contains(Regex("https?://|www\\.|maps\\.")))
        }
    }
    @Test fun smsPreservesLocationSourceAgeTimeAndAccuracy() {
        val text = EmergencySmsMessage.format(false, fix(source = "watch", kind = "last_known"), zone)
        assertTrue(text.startsWith("SHCA FALL: Possible fall."))
        assertTrue(text.contains("Last known watch 04 Nov 14:01 +0800 +/-7m"))
        assertTrue(text.contains("Location: 3.139000, 101.686900"))
        assertTrue(text.endsWith("Open SHCA for map."))
    }
    @Test fun sosAndUnavailableLocationRemainClear() {
        val text = EmergencySmsMessage.format(true, null, zone)
        assertTrue(text.startsWith("SHCA SOS: Help requested."))
        assertTrue(text.contains("Location unavailable."))
        assertTrue(text.length <= 160)
    }
    @Test fun nonEnglishPhoneLocaleCannotIntroduceUnicodeOrDecimalCommas() {
        val previous = Locale.getDefault()
        try {
            Locale.setDefault(Locale.GERMANY)
            val text = EmergencySmsMessage.format(true, fix(latitude = -3.1234567, longitude = -100.7654321), zone)
            assertTrue(text.contains("Location: -3.123457, -100.765432"))
            assertTrue(text.contains("04 Nov 14:01 +0800"))
        } finally { Locale.setDefault(previous) }
    }
}
