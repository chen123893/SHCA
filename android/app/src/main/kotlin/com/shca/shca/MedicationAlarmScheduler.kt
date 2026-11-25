package com.shca.shca

import android.app.ActivityOptions
import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import com.google.firebase.auth.FirebaseAuth
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

object MedicationAlarmScheduler {
    const val ACTION_MEDICATION_ALARM = "com.shca.shca.action.MEDICATION_ALARM"
    const val EXTRA_PAYLOAD = "medication_alarm_payload"
    const val EXTRA_ALARM_ID = "medication_alarm_id"
    private const val PREFS = "native_medication_alarms_v1"
    private const val RESPONSES = "native_medication_responses_v1"

    // Read the private registry of scheduled medicine alarms.
    private fun preferences(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    // Find the account and dose key carried by the alarm payload.
    private fun responseKey(payload: JSONObject): String {
        val uid = payload.optString("elderlyId")
        var occurrence = payload.optString("occurrenceId")
        if (occurrence.isEmpty()) {
            val multiple = (payload.optJSONObject("medicationSnapshot")
                ?.optJSONArray("reminderMinutes")?.length() ?: 1) > 1
            val format = if (multiple) "yyyy-MM-dd_HHmm" else "yyyy-MM-dd"
            occurrence = SimpleDateFormat(format, Locale.US)
                .format(Date(payload.optLong("scheduledAt"))) + "_" + payload.optString("medicationId")
        }
        return "$uid:$occurrence"
    }

    // Check the signed-in account and saved dose response before allowing the alarm.
    fun payloadAllowed(context: Context, payload: String): Boolean = try {
        val json = JSONObject(payload)
        val uid = FirebaseAuth.getInstance().currentUser?.uid
        if (uid == null || uid != json.optString("elderlyId")) false
        else {
            val stored = context.getSharedPreferences(RESPONSES, Context.MODE_PRIVATE)
                .getString(responseKey(json), null)
            val response = stored?.let { JSONObject(it) }
            MedicationAlarmPolicy.allows(response?.optString("status"),
                response?.optLong("remindAt") ?: 0, json.optLong("reminderAt"))
        }
    } catch (_: Exception) { false }

    // Persist the dose response and cancel alarms that are no longer allowed.
    @Synchronized
    fun updateRecord(context: Context, response: JSONObject) {
        val uid = FirebaseAuth.getInstance().currentUser?.uid
        if (uid == null || uid != response.optString("elderlyId")) return
        val key = responseKey(response)
        val responses = context.getSharedPreferences(RESPONSES, Context.MODE_PRIVATE)
        val previous = responses.getString(key, null)?.let { JSONObject(it) }
        if (previous == null && response.optString("status") == "pending") return
        val resetOldSnooze = previous?.optString("status") == "snoozed" &&
            response.optString("status") == "pending" &&
            previous.optLong("remindAt") < response.optLong("scheduledAt")
        if (!resetOldSnooze && !MedicationAlarmPolicy.acceptsUpdate(previous?.optString("status"),
                previous?.optLong("actionAt") ?: 0, response.optString("status"),
                response.optLong("actionAt"))) return
        if (previous?.optString("status") == response.optString("status") &&
            previous.optLong("actionAt") == response.optLong("actionAt") &&
            previous.optLong("remindAt") == response.optLong("remindAt")) return
        // Commit the response before cancelling. A broadcast already queued by
        // Android will check this persisted guard before it starts ringing.
        responses.edit().putString(key, response.toString()).commit()
        var snoozePayload: JSONObject? = null
        for ((id, stored) in preferences(context).all) {
            val value = runCatching { JSONObject(stored as String) }.getOrNull() ?: continue
            val payload = value.optString("payload")
            val json = runCatching { JSONObject(payload) }.getOrNull() ?: continue
            if (responseKey(json) == key) {
                snoozePayload = json
                if (!payloadAllowed(context, payload)) id.toIntOrNull()?.let { cancel(context, it) }
            }
        }
        // The paired watch can snooze while Flutter is closed.
        val remindAt = response.optLong("remindAt")
        if (response.optString("status") == "snoozed" &&
            remindAt > System.currentTimeMillis() && snoozePayload != null) {
            val payload = snoozePayload.put("reminderAt", remindAt).toString()
            val input = "$uid:${response.optString("medicationId")}_${response.optLong("scheduledAt")}_snooze"
            val hash = java.security.MessageDigest.getInstance("SHA-256").digest(input.toByteArray())
            val id = java.nio.ByteBuffer.wrap(hash).int and 0x7fffffff
            schedule(context, id, remindAt, payload)
        }
    }

    // Register the medicine alarm with Android after checking its saved dose response.
    @Synchronized
    fun schedule(context: Context, id: Int, triggerAtMillis: Long, payload: String,
                 remember: Boolean = true): Boolean {
        if (!payloadAllowed(context, payload)) return true
        if (triggerAtMillis <= System.currentTimeMillis()) return false
        val manager = context.getSystemService(AlarmManager::class.java)
        if (Build.VERSION.SDK_INT >= 31 && !manager.canScheduleExactAlarms()) return false

        // Remove the old activity-based alarm when upgrading this installation.
        manager.cancel(activityIntent(context, id, payload))
        val operation = broadcastIntent(context, id)
        val show = activityIntent(context, id xor 0x40000000, payload)
        if (remember) {
            val value = JSONObject().put("triggerAtMillis", triggerAtMillis)
                .put("payload", payload).put("delivered", false)
            preferences(context).edit().putString(id.toString(), value.toString()).commit()
        }
        return try {
            manager.setAlarmClock(AlarmManager.AlarmClockInfo(triggerAtMillis, show), operation)
            true
        } catch (error: SecurityException) {
            preferences(context).edit().remove(id.toString()).commit()
            android.util.Log.w("MedicationAlarm", "Exact alarm permission unavailable", error)
            false
        }
    }

    // Cancel this alarm's pending intents, notification and saved registry entry.
    @Synchronized
    fun cancel(context: Context, id: Int) {
        preferences(context).edit().remove(id.toString()).commit()
        val manager = context.getSystemService(AlarmManager::class.java)
        manager.cancel(broadcastIntent(context, id))
        manager.cancel(activityIntent(context, id, ""))
        MedicationRingingService.dismiss(context, id)
    }

    // Mark an alarm as delivered once before starting its reminder.
    @Synchronized
    fun takeForDelivery(context: Context, id: Int): String? {
        val value = preferences(context).getString(id.toString(), null)?.let { JSONObject(it) }
            ?: return null
        val payload = value.getString("payload")
        if (value.optBoolean("delivered") || !payloadAllowed(context, payload)) return null
        value.put("delivered", true)
        preferences(context).edit().putString(id.toString(), value.toString()).commit()
        return payload
    }

    // Check that this payload still matches an allowed registered alarm.
    @Synchronized
    fun isActive(context: Context, id: Int, payload: String): Boolean {
        val value = preferences(context).getString(id.toString(), null)?.let { JSONObject(it) }
        return value?.optString("payload") == payload && payloadAllowed(context, payload)
    }

    // Remove every saved medicine alarm belonging to the given account.
    fun cancelOwner(context: Context, uid: String) {
        for ((key, stored) in preferences(context).all) {
            val value = runCatching { JSONObject(stored as String) }.getOrNull() ?: continue
            val payload = runCatching { JSONObject(value.optString("payload")) }.getOrNull() ?: continue
            if (payload.optString("elderlyId") == uid) key.toIntOrNull()?.let { cancel(context, it) }
        }
    }

    // Restore future medicine alarms after a supported system event.
    fun restore(context: Context) {
        for ((key, stored) in preferences(context).all) {
            val id = key.toIntOrNull() ?: continue
            try {
                val value = JSONObject(stored as String)
                val trigger = value.getLong("triggerAtMillis")
                if (trigger > System.currentTimeMillis() && !value.optBoolean("delivered")) {
                    schedule(context, id, trigger, value.getString("payload"), remember = false)
                } else cancel(context, id)
            } catch (_: Exception) { cancel(context, id) }
        }
    }

    // Build the broadcast intent that Android delivers when this alarm is due.
    private fun broadcastIntent(context: Context, id: Int): PendingIntent =
        PendingIntent.getBroadcast(context, id,
            Intent(context, MedicationAlarmReceiver::class.java)
                .setData(Uri.parse("shca://medication-alarm/$id"))
                .putExtra(EXTRA_ALARM_ID, id),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    // Build the legacy activity pending intent so it can also be cancelled.
    fun activityIntent(context: Context, id: Int, payload: String): PendingIntent {
        val options = if (Build.VERSION.SDK_INT >= 34) ActivityOptions.makeBasic().apply {
            setPendingIntentCreatorBackgroundActivityStartMode(ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED)
        }.toBundle() else null
        return PendingIntent.getActivity(context, id,
            launchIntent(context, id, payload),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE, options)
    }

    // Build the app intent containing this medicine alarm's payload.
    fun launchIntent(context: Context, id: Int, payload: String) =
        Intent(context, MainActivity::class.java).apply {
            action = ACTION_MEDICATION_ALARM
            data = Uri.parse("shca://medication-alarm/$id")
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(EXTRA_ALARM_ID, id)
            if (payload.isNotEmpty()) putExtra(EXTRA_PAYLOAD, payload)
        }
}

class MedicationAlarmReceiver : BroadcastReceiver() {
    // Handle the medicine alarm or the system event that restores its schedule.
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getIntExtra(MedicationAlarmScheduler.EXTRA_ALARM_ID, -1)
        val payload = MedicationAlarmScheduler.takeForDelivery(context, id) ?: return
        val service = Intent(context, MedicationRingingService::class.java)
            .putExtra(MedicationAlarmScheduler.EXTRA_ALARM_ID, id)
            .putExtra(MedicationAlarmScheduler.EXTRA_PAYLOAD, payload)
        if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(service)
        else context.startService(service)
    }
}

class MedicationAlarmBootReceiver : BroadcastReceiver() {
    // Handle the medicine alarm or the system event that restores its schedule.
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action in setOf(Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED,
                AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED,
                Intent.ACTION_TIME_CHANGED, Intent.ACTION_TIMEZONE_CHANGED,
                "android.intent.action.QUICKBOOT_POWERON", "com.htc.intent.action.QUICKBOOT_POWERON")) {
            MedicationAlarmScheduler.restore(context)
        }
    }
}
