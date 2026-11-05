package com.shca.shca

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlin.math.roundToInt

/** Plain location details: Malaysian carriers block SMS containing hyperlinks. */
internal object EmergencySmsMessage {
    fun format(manualSos: Boolean, location: Map<String, Any>?, timeZone: TimeZone = TimeZone.getDefault()): String {
        val introduction = if (manualSos) "SHCA SOS: Help requested. Call and check now."
            else "SHCA FALL: Possible fall. Call and check now."
        if (location == null) return "$introduction\nLocation unavailable. Open SHCA for details."
        val source = if (location["source"] == "watch") "watch" else "phone"
        val label = if (location["kind"] == "last_known") "Last known $source" else source.replaceFirstChar { it.uppercaseChar() }
        val time = SimpleDateFormat("dd MMM HH:mm Z", Locale.US).apply { this.timeZone = timeZone }
            .format(Date((location.getValue("recordedAt") as Number).toLong()))
        val accuracy = (location.getValue("accuracyMeters") as Number).toDouble().roundToInt()
        val coordinates = String.format(Locale.US, "%.6f, %.6f",
            (location.getValue("latitude") as Number).toDouble(),
            (location.getValue("longitude") as Number).toDouble())
        // ASCII, no URL, no callback number; even the longest valid fix fits one SMS.
        return "$introduction\n$label $time +/-${accuracy}m\nLocation: $coordinates\nOpen SHCA for map."
    }
}
