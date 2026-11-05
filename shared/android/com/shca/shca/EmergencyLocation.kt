package com.shca.shca

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationManager
import android.os.Build
import android.os.CancellationSignal
import android.os.SystemClock
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** A bounded, one-shot location read. Call capture on a worker thread. */
internal object EmergencyLocation {
    private const val PREFS = "shca_emergency_location"
    private const val MAX_AGE_MS = 24 * 60 * 60_000L

    fun hasPermission(context: Context) =
        context.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
            context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED

    fun isEnabled(context: Context, uid: String) = uid.isNotBlank() && hasPermission(context) &&
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(uid, false)

    fun setEnabled(context: Context, uid: String, enabled: Boolean) {
        if (uid.isNotBlank()) context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putBoolean(uid, enabled).apply()
    }

    fun status(context: Context, uid: String) = mapOf(
        "enabled" to isEnabled(context, uid),
        "backgroundAllowed" to (Build.VERSION.SDK_INT < 29 ||
            context.checkSelfPermission(Manifest.permission.ACCESS_BACKGROUND_LOCATION) == PackageManager.PERMISSION_GRANTED),
    )

    fun capture(context: Context, uid: String, source: String): Map<String, Any>? {
        if (!isEnabled(context, uid)) return null
        return try {
            val manager = context.getSystemService(LocationManager::class.java) ?: return null
            if (Build.VERSION.SDK_INT >= 28 && !manager.isLocationEnabled) return null
            val providers = manager.getProviders(true)
            val cached = providers.mapNotNull { provider ->
                try { manager.getLastKnownLocation(provider) } catch (_: SecurityException) { null }
            }.filter { valid(it) }.maxByOrNull { it.elapsedRealtimeNanos }
            if (cached != null && age(cached) <= 120_000) return values(cached, source)
            if (Build.VERSION.SDK_INT < 30) return cached?.let { values(it, source) }
            val provider = listOf("fused", LocationManager.NETWORK_PROVIDER, LocationManager.GPS_PROVIDER)
                .firstOrNull { it in providers } ?: return cached?.let { values(it, source) }
            val signal = CancellationSignal()
            val received = AtomicReference<Location?>()
            val completed = CountDownLatch(1)
            try {
                manager.getCurrentLocation(provider, signal, { command -> command.run() }) {
                    received.set(it)
                    completed.countDown()
                }
                completed.await(6, TimeUnit.SECONDS)
            } finally {
                signal.cancel()
            }
            if (!isEnabled(context, uid)) return null
            val location = received.get()?.takeIf { valid(it) } ?: cached
            location?.let { values(it, source) }
        } catch (_: Exception) {
            null
        }
    }

    private fun age(location: Location) =
        (SystemClock.elapsedRealtimeNanos() - location.elapsedRealtimeNanos) / 1_000_000

    private fun valid(location: Location) =
        location.latitude.isFinite() && location.latitude in -90.0..90.0 &&
            location.longitude.isFinite() && location.longitude in -180.0..180.0 &&
            location.hasAccuracy() && location.accuracy.isFinite() &&
            location.accuracy in 0f..100_000f && age(location) in 0..MAX_AGE_MS

    private fun values(location: Location, source: String): Map<String, Any> = mapOf(
        "latitude" to location.latitude,
        "longitude" to location.longitude,
        "recordedAt" to (System.currentTimeMillis() - age(location)),
        "accuracyMeters" to location.accuracy.toDouble(),
        "source" to source,
        "kind" to if (age(location) <= 120_000) "current" else "last_known",
    )

    fun fromJson(value: String?): Map<String, Any>? = try {
        val json = JSONObject(value ?: "")
        val latitude = json.getDouble("latitude")
        val longitude = json.getDouble("longitude")
        val recordedAt = json.getLong("recordedAt")
        val accuracy = json.getDouble("accuracyMeters")
        val source = json.getString("source")
        val kind = json.getString("kind")
        if (!latitude.isFinite() || latitude !in -90.0..90.0 ||
            !longitude.isFinite() || longitude !in -180.0..180.0 ||
            !accuracy.isFinite() || accuracy !in 0.0..100_000.0 ||
            System.currentTimeMillis() - recordedAt !in -60_000..MAX_AGE_MS ||
            source !in listOf("phone", "watch") || kind !in listOf("current", "last_known")) null
        else mapOf("latitude" to latitude, "longitude" to longitude, "recordedAt" to recordedAt,
            "accuracyMeters" to accuracy, "source" to source, "kind" to kind)
    } catch (_: Exception) { null }
}
