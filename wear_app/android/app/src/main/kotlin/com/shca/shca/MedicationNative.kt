package com.shca.shca

import android.app.*
import android.content.*
import android.net.Uri
import android.os.*
import android.provider.Settings
import android.media.AudioAttributes
import org.json.JSONArray
import org.json.JSONObject

data class NativeMedication(
    val id: String = "", val occurrenceId: String = "", val name: String = "Medicine",
    val dose: String = "", val instruction: String = "", val scheduledAt: Long = 0,
    val remindAt: Long = scheduledAt, val status: String = "pending",
) {
    val isAvailable get() = id.isNotBlank() && occurrenceId.isNotBlank()
    fun toMap(): Map<String, Any?> = mapOf("id" to id, "occurrenceId" to occurrenceId, "name" to name,
        "dose" to dose, "instruction" to instruction, "scheduledAt" to scheduledAt, "remindAt" to remindAt, "status" to status)
    companion object {
        fun fromJson(json: JSONObject) = NativeMedication(json.optString("id"), json.optString("occurrenceId"),
            json.optString("name", "Medicine"), json.optString("dose"), json.optString("instruction"),
            json.optLong("scheduledAt"), json.optLong("remindAt", json.optLong("scheduledAt")), json.optString("status", "pending"))
    }
}

object MedicationStore {
    private const val PREFS = "shca_watch_medication_v3"
    private fun prefs(c: Context) = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    fun userId(c: Context) = prefs(c).getString("userId", "") ?: ""
    fun all(c: Context): List<NativeMedication> {
        val rows = try { JSONArray(prefs(c).getString("rows", "[]")) } catch (_: Exception) { JSONArray() }
        return (0 until rows.length()).mapNotNull { rows.optJSONObject(it)?.let(NativeMedication::fromJson) }
    }
    fun find(c: Context, occurrenceId: String) = all(c).find { it.occurrenceId == occurrenceId }
    fun receive(c: Context, uid: String, json: String) {
        val old = all(c)
        old.forEach { MedicationScheduler.cancel(c, it) }
        if (userId(c) != uid) { MedicationAlarmReceiver.cancel(c); prefs(c).edit().clear().apply() }
        val rows = try { JSONArray(json) } catch (_: Exception) { JSONArray() }
        val overrides = try { JSONObject(prefs(c).getString("overrides", "{}")) } catch (_: Exception) { JSONObject() }
        val merged = JSONArray()
        for (i in 0 until rows.length()) {
            val row = rows.optJSONObject(i) ?: continue
            val original = NativeMedication.fromJson(row)
            val local = overrides.optJSONObject(original.occurrenceId)?.let(NativeMedication::fromJson)
            val item = if (local != null && local.scheduledAt == original.scheduledAt) {
                // Preserve a local Taken/Snooze until the phone confirms it.
                original.copy(status = local.status, remindAt = local.remindAt)
            } else original
            if (item.isAvailable) merged.put(JSONObject(item.toMap()))
        }
        prefs(c).edit().putString("rows", merged.toString()).putString("userId", uid).putLong("syncedAt", System.currentTimeMillis()).apply()
        val pendingIds = all(c).filter { it.status != "taken" }.map { it.occurrenceId }.toSet()
        old.filter { it.occurrenceId !in pendingIds }.forEach { MedicationAlarmReceiver.cancel(c, it.occurrenceId) }
        val current = active(c)
        if (current == null || merged.toString().isEmpty() || find(c, current.occurrenceId) == null) {
            MedicationAlarmReceiver.cancel(c)
            prefs(c).edit().remove("activeDoses").apply()
        }
        all(c).filter { it.status != "taken" }.forEach { MedicationScheduler.schedule(c, it) }
        WatchEventBus.emit(mapOf("type" to "medication_updated"))
    }
    fun setActive(c: Context, m: NativeMedication) {
        val pending = (prefs(c).getStringSet("activeDoses", emptySet()) ?: emptySet()).toMutableSet()
        pending.add(m.occurrenceId)
        prefs(c).edit().putStringSet("activeDoses", pending).apply()
    }
    fun active(c: Context): NativeMedication? {
        val ids = prefs(c).getStringSet("activeDoses", emptySet()) ?: emptySet()
        return all(c).filter { it.occurrenceId in ids && it.status != "taken" }.minByOrNull { it.remindAt }
    }
    fun wasDelivered(c: Context, m: NativeMedication) = prefs(c).getBoolean("delivered:${m.occurrenceId}:${m.remindAt}", false)
    fun delivered(c: Context, m: NativeMedication) { prefs(c).edit().putBoolean("delivered:${m.occurrenceId}:${m.remindAt}", true).apply() }
    fun action(c: Context, occurrenceId: String, action: String, remindAt: Long): NativeMedication? {
        val original = find(c, occurrenceId) ?: return null
        val updated = if (action == "snoozed") original.copy(status = "snoozed", remindAt = remindAt)
            else original.copy(status = "taken")
        MedicationScheduler.cancel(c, original)
        val overrides = try { JSONObject(prefs(c).getString("overrides", "{}")) } catch (_: Exception) { JSONObject() }
        overrides.put(occurrenceId, JSONObject(updated.toMap()))
        prefs(c).edit().putString("overrides", overrides.toString())
            .putString("rows", JSONArray(all(c).map { JSONObject((if (it.occurrenceId == occurrenceId) updated else it).toMap()) }).toString())
            .putStringSet("activeDoses", (prefs(c).getStringSet("activeDoses", emptySet()) ?: emptySet()).filter { it != occurrenceId }.toSet()).apply()
        MedicationAlarmReceiver.cancel(c, occurrenceId)
        if (action == "snoozed") MedicationScheduler.schedule(c, updated)
        return updated
    }
    fun confirmAction(c: Context, occurrenceId: String) {
        val overrides = try { JSONObject(prefs(c).getString("overrides", "{}")) } catch (_: Exception) { JSONObject() }
        overrides.remove(occurrenceId)
        prefs(c).edit().putString("overrides", overrides.toString()).apply()
    }
}

object MedicationScheduler {
    private fun intent(c: Context, m: NativeMedication) = Intent(c, MedicationAlarmReceiver::class.java).apply {
        data = Uri.parse("shca://medicine/" + Uri.encode(m.occurrenceId))
        putExtra("occurrenceId", m.occurrenceId); putExtra("remindAt", m.remindAt)
    }
    private fun pending(c: Context, m: NativeMedication) = PendingIntent.getBroadcast(c, 0, intent(c, m),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    fun cancel(c: Context, m: NativeMedication) { c.getSystemService(AlarmManager::class.java).cancel(pending(c, m)) }
    fun exactAllowed(c: Context): Boolean = Build.VERSION.SDK_INT < 31 || c.getSystemService(AlarmManager::class.java).canScheduleExactAlarms()
    fun schedule(c: Context, m: NativeMedication) {
        if (!m.isAvailable || m.status == "taken" || MedicationStore.wasDelivered(c, m)) return
        val now = System.currentTimeMillis()
        // Don't replay old missed doses on reconnect; retain only recent due ones.
        if (m.remindAt < now - 10 * 60000) return
        val at = maxOf(now + 1000, m.remindAt)
        val alarms = c.getSystemService(AlarmManager::class.java)
        try {
            if (exactAllowed(c)) alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending(c, m))
            else alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending(c, m))
        } catch (_: SecurityException) {
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending(c, m))
        }
    }
    fun restore(c: Context) { MedicationStore.all(c).forEach { schedule(c, it) } }
    fun requestExact(c: Context) {
        if (Build.VERSION.SDK_INT >= 31) c.startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,
            Uri.parse("package:${c.packageName}")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}

class MedicationAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val medication = MedicationStore.find(context, intent?.getStringExtra("occurrenceId") ?: "") ?: return
        if (medication.status == "taken" || medication.remindAt != intent?.getLongExtra("remindAt", 0) ||
            MedicationStore.wasDelivered(context, medication)) return
        MedicationStore.delivered(context, medication)
        MedicationStore.setActive(context, medication)
        vibrate(context)
        WatchEventBus.emit(mapOf("type" to "show_medication", "medication" to medication.toMap()))
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "Medicine vibration reminders", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Vibrates when a scheduled medicine is due"
            enableVibration(true); vibrationPattern = PATTERN
            setSound(null, null)
        })
        val open = Intent(context, MainActivity::class.java).apply {
            action = MainActivity.ACTION_SHOW_MEDICATION
            data = Uri.parse("shca://open-medicine/" + Uri.encode(medication.occurrenceId))
            putExtra("occurrenceId", medication.occurrenceId)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pending = PendingIntent.getActivity(context, 8302, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        try {
        manager.notify(medication.occurrenceId, NOTIFICATION, Notification.Builder(context, CHANNEL)
                .setSmallIcon(R.mipmap.ic_launcher).setContentTitle("Time to take medicine")
                .setContentText("${medication.name} • ${medication.dose}")
                .setCategory(Notification.CATEGORY_ALARM).setOngoing(true).setAutoCancel(false)
                .setContentIntent(pending).setFullScreenIntent(pending, true).build())
        } catch (_: SecurityException) { /* Vibration and foreground screen still work. */ }
    }
    companion object {
        const val CHANNEL = "shca_watch_medicine_vibration_v3"
        const val NOTIFICATION = 8302
        val PATTERN = longArrayOf(0, 600, 350, 600, 350, 600, 700, 600, 350, 600)
        @Suppress("DEPRECATION")
        private fun vibrator(c: Context): Vibrator = if (Build.VERSION.SDK_INT >= 31)
            c.getSystemService(VibratorManager::class.java).defaultVibrator else c.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        fun vibrate(c: Context) {
            vibrator(c).vibrate(VibrationEffect.createWaveform(PATTERN, -1),
                AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build())
        }
        fun stopVibration(c: Context) { vibrator(c).cancel() }
        fun cancel(c: Context, occurrenceId: String? = null) {
            stopVibration(c)
            val manager = c.getSystemService(NotificationManager::class.java)
            if (occurrenceId != null) manager.cancel(occurrenceId, NOTIFICATION)
            else {
                manager.cancel(NOTIFICATION)
                MedicationStore.all(c).forEach { manager.cancel(it.occurrenceId, NOTIFICATION) }
            }
        }
    }
}
class MedicationRestoreReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        MedicationScheduler.restore(context)
        if (WatchSession.isSignedIn(context)) WatchMonitoringService.start(context)
        WatchCloud.refreshIfNeeded(context, force = true)
    }
}
