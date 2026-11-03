package com.shca.shca

import android.app.AlarmManager
import android.app.ActivityOptions
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import org.json.JSONObject

object MedicationAlarmScheduler {
    const val ACTION_MEDICATION_ALARM = "com.shca.shca.action.MEDICATION_ALARM"
    const val EXTRA_PAYLOAD = "medication_alarm_payload"
    const val EXTRA_ALARM_ID = "medication_alarm_id"

    private const val PREFS = "native_medication_alarms_v1"

    fun schedule(
        context: Context,
        id: Int,
        triggerAtMillis: Long,
        payload: String,
        remember: Boolean = true,
    ): Boolean {
        if (triggerAtMillis <= System.currentTimeMillis()) return false
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            !alarmManager.canScheduleExactAlarms()
        ) {
            return false
        }

        val operation = alarmIntent(context, id, payload)
        val showIntent = activityPendingIntent(
            context,
            id xor 0x40000000,
            Intent(context, MainActivity::class.java).apply {
                data = Uri.parse("shca://medication-schedule/$id")
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            },
        )
        alarmManager.setAlarmClock(
            AlarmManager.AlarmClockInfo(triggerAtMillis, showIntent),
            operation,
        )
        if (remember) {
            val value = JSONObject()
                .put("triggerAtMillis", triggerAtMillis)
                .put("payload", payload)
                .toString()
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putString(id.toString(), value)
                .apply()
        }
        return true
    }

    fun cancel(context: Context, id: Int) {
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarmManager.cancel(alarmIntent(context, id, ""))
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .remove(id.toString())
            .apply()
    }

    fun consume(context: Context, id: Int) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .remove(id.toString())
            .apply()
    }

    fun restore(context: Context) {
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val now = System.currentTimeMillis()
        val expired = mutableListOf<String>()
        for ((key, stored) in preferences.all) {
            val id = key.toIntOrNull() ?: continue
            val value = stored as? String ?: continue
            try {
                val json = JSONObject(value)
                val triggerAtMillis = json.getLong("triggerAtMillis")
                val payload = json.getString("payload")
                if (triggerAtMillis > now) {
                    schedule(
                        context,
                        id,
                        triggerAtMillis,
                        payload,
                        remember = false,
                    )
                } else {
                    expired.add(key)
                }
            } catch (_: Exception) {
                expired.add(key)
            }
        }
        if (expired.isNotEmpty()) {
            val editor = preferences.edit()
            expired.forEach(editor::remove)
            editor.apply()
        }
    }

    private fun alarmIntent(context: Context, id: Int, payload: String): PendingIntent =
        activityPendingIntent(
            context,
            id,
            Intent(context, MainActivity::class.java).apply {
                action = ACTION_MEDICATION_ALARM
                data = Uri.parse("shca://medication-alarm/$id")
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra(EXTRA_ALARM_ID, id)
                if (payload.isNotEmpty()) putExtra(EXTRA_PAYLOAD, payload)
            },
        )

    private fun activityPendingIntent(
        context: Context,
        requestCode: Int,
        intent: Intent,
    ): PendingIntent {
        val options = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ActivityOptions.makeBasic()
                .setPendingIntentCreatorBackgroundActivityStartMode(
                    ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED,
                )
                .toBundle()
        } else {
            null
        }
        return PendingIntent.getActivity(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            options,
        )
    }
}

class MedicationAlarmBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED ||
            intent.action == Intent.ACTION_MY_PACKAGE_REPLACED ||
            intent.action == "android.intent.action.QUICKBOOT_POWERON" ||
            intent.action == "com.htc.intent.action.QUICKBOOT_POWERON"
        ) {
            MedicationAlarmScheduler.restore(context)
        }
    }
}
