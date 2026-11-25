package com.shca.shca

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import org.json.JSONObject

/** The due alarm rings without waiting for Flutter, Firestore or a network. */
class MedicationRingingService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private var alarmId: Int? = null
    private var alarmKey: String? = null
    private val timeout = Runnable { stopSelf() }

    // Return no binder because this alarm service is started by an intent.
    override fun onBind(intent: Intent?): IBinder? = null

    // Show the medicine alarm notification and start its native feedback.
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val id = intent?.getIntExtra(MedicationAlarmScheduler.EXTRA_ALARM_ID, -1) ?: -1
        val payload = intent?.getStringExtra(MedicationAlarmScheduler.EXTRA_PAYLOAD) ?: ""
        val manager = getSystemService(NotificationManager::class.java)
        val attributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build()
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Medication alarms", NotificationManager.IMPORTANCE_HIGH).apply {
                setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM), attributes)
                enableVibration(true)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            })
        val medicine = try { JSONObject(payload).optJSONObject("medicationSnapshot") } catch (_: Exception) { null }
        val open = MedicationAlarmScheduler.activityIntent(this, id, payload)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else Notification.Builder(this)
        val notification = builder.setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Time to take medicine")
            .setContentText(medicine?.optString("name") ?: "Open your medication reminder")
            .setStyle(Notification.BigTextStyle().bigText(listOfNotNull(
                medicine?.optString("name"), medicine?.optString("dose"), medicine?.optString("instruction")
            ).filter { it.isNotBlank() }.joinToString(" • ")))
            .setCategory(Notification.CATEGORY_ALARM).setVisibility(Notification.VISIBILITY_PUBLIC)
            .setPriority(Notification.PRIORITY_MAX).setOngoing(true)
            .setContentIntent(open).setFullScreenIntent(open, true).build()
        startForeground(id, notification)
        if (!MedicationAlarmScheduler.isActive(this, id, payload)) {
            stopSelf()
            return START_NOT_STICKY
        }
        alarmKey?.let { MedicationAlarmFeedback.stop(it) }
        alarmId?.takeIf { it != id }?.let { manager.cancel(it) }
        alarmId = id
        current = this
        alarmKey = "native-medication:$id"
        MedicationAlarmFeedback.start(this, alarmKey!!)
        handler.removeCallbacks(timeout)
        handler.postDelayed(timeout, 5 * 60_000L)
        // A user-granted appear-on-top permission permits presenting the
        // existing reminder controls while another app is visible.
        if (Settings.canDrawOverlays(this)) {
            try {
                startActivity(MedicationAlarmScheduler.launchIntent(this, id, payload))
            } catch (error: Exception) {
                android.util.Log.w("MedicationAlarm", "Reminder controls remain in notification", error)
            }
        }
        return START_NOT_STICKY
    }

    // Stop this service's alarm feedback and release its active reference.
    override fun onDestroy() {
        handler.removeCallbacks(timeout)
        alarmKey?.let { MedicationAlarmFeedback.stop(it) }
        stopForeground(STOP_FOREGROUND_REMOVE)
        if (current === this) current = null
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "shca_medication_alarms_v2"
        private var current: MedicationRingingService? = null

        // Stop the native ringing service when the Flutter alert takes over.
        fun transferToFlutter() {
            current?.stopSelf()
        }

        // Dismiss the matching medicine notification and ringing service.
        fun dismiss(context: Context, id: Int) {
            context.getSystemService(NotificationManager::class.java).cancel(id)
            Handler(Looper.getMainLooper()).post {
                current?.takeIf { it.alarmId == id }?.stopSelf()
            }
        }
    }
}
