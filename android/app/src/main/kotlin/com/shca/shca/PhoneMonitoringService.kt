package com.shca.shca

import android.app.*
import android.content.*
import android.os.*
import com.google.firebase.auth.FirebaseAuth
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/** Owns the sensor/inference engine even after the phone UI is closed. */
class PhoneMonitoringService : Service() {
    private var engine: FlutterEngine? = null
    private var worker: MethodChannel? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var ready = false
    private var onStopped: (() -> Unit)? = null
    private var queuedAction: Map<String, Any?>? = null
    private val handler = Handler(Looper.getMainLooper())
    private val authListener = FirebaseAuth.AuthStateListener {
        if (!ownsSession(this)) disable(this)
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        if (!ownsSession(this)) { stopSelf(); return }
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "Fall detection status",
            NotificationManager.IMPORTANCE_LOW).apply { setShowBadge(false) })
        manager.createNotificationChannel(NotificationChannel(FALL_CHANNEL, "Possible fall confirmation",
            NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Respond before SHCA automatically notifies your caregiver"
            setSound(null, null); enableVibration(false)
        })
        }
        latest = startingState()
        startForeground(STATUS_ID, statusNotification("Starting phone sensors…"))
        wakeLock = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:phone-fall-monitoring")
            .apply { setReferenceCounted(false); acquire() }
        FirebaseAuth.getInstance().addAuthStateListener(authListener)
        try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(applicationContext)
            loader.ensureInitializationComplete(applicationContext, null)
            val backgroundEngine = FlutterEngine(applicationContext)
            engine = backgroundEngine
            worker = MethodChannel(backgroundEngine.dartExecutor.binaryMessenger, WORKER_CHANNEL).also { channel ->
                channel.setMethodCallHandler { call, result ->
                    if (!ownsSession(this)) { result.error("signed-out", "Monitoring stopped.", null); return@setMethodCallHandler }
                    when (call.method) {
                        "ready" -> {
                            ready = true
                            result.success(mapOf("userId" to prefs(this).getString("userId", ""),
                                "pending" to pending(this), "action" to queuedAction))
                            queuedAction = null
                        }
                        "snapshot" -> {
                            @Suppress("UNCHECKED_CAST")
                            latest = latest.filterKeys { it.startsWith("delivery") } +
                                (call.arguments as? Map<String, Any?> ?: emptyMap()) + ("enabled" to true)
                            emit()
                            val text = when (latest["state"]) {
                                "active" -> "Fall detection is on • ${latest["label"]}"
                                "unavailable" -> "Fall detection needs attention. Open SHCA."
                                else -> "Fall detection is starting…"
                            }
                            manager.notify(STATUS_ID, statusNotification(text))
                            result.success(null)
                        }
                        "savePendingFall" -> {
                            val saved = prefs(this).edit().putString("pending", JSONObject(call.arguments as Map<*, *>).toString()).commit()
                            if (saved) {
                                if (pending(this)?.get("status") != "pending") PhoneFallAlarm.dismiss()
                                result.success(null)
                            }
                            else result.error("storage", "Could not save fall confirmation.", null)
                        }
                        "queueFallSms" -> {
                            val fall = pending(this)
                            if (fall?.get("status") == "confirmed") {
                                val id = fall["eventId"] as? String
                                val detectedAt = (fall["detectedAt"] as? Number)?.toLong()
                                val uid = FirebaseAuth.getInstance().currentUser?.uid
                                if (uid != null && id != null && detectedAt != null) {
                                    FallSmsWorker.enqueue(this, uid, id, detectedAt)
                                }
                            }
                            result.success(null)
                        }
                        "clearPendingFall" -> { prefs(this).edit().remove("pending").commit(); result.success(null) }
                        "showFallWarning" -> { showFallWarning(); result.success(null) }
                        "hideFallWarning" -> { hideFallWarning(); result.success(null) }
                        "deliveryStatus" -> {
                            latest = latest + mapOf("deliveryEventId" to call.argument<String>("eventId"),
                                "deliveryTitle" to call.argument<String>("title"), "deliveryMessage" to call.argument<String>("message"))
                            emit()
                            manager.notify(RESULT_ID, notificationBuilder(FALL_CHANNEL)
                                .setSmallIcon(R.drawable.ic_fall_monitoring)
                                .setContentTitle("SHCA fall alert")
                                .setContentText(call.argument<String>("message"))
                                .setContentIntent(openApp()).setAutoCancel(true).build())
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                }
            }
            backgroundEngine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "phoneMonitoringMain"))
        } catch (error: Exception) {
            android.util.Log.e("PhoneMonitoring", "Background monitoring could not start", error)
            disable(this)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!ownsSession(this)) { stopSelf(); return START_NOT_STICKY }
        if (intent?.action == ACTION_RESPOND) {
            val id = intent.getStringExtra("eventId")
            if (id != null) respond(mapOf("eventId" to id, "send" to intent.getBooleanExtra("send", false)))
        }
        return START_STICKY
    }

    fun respond(action: Map<String, Any?>, result: MethodChannel.Result? = null) {
        if (!ownsSession(this)) { result?.success(null); return }
        if (ready) worker?.invokeMethod("respond", action, result)
        else { queuedAction = action; result?.success(null) }
    }

    @Suppress("DEPRECATION")
    private fun notificationBuilder(channel: String): Notification.Builder =
        if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, channel) else Notification.Builder(this)

    private fun statusNotification(text: String): Notification = notificationBuilder(CHANNEL)
        .setSmallIcon(R.drawable.ic_fall_monitoring)
        .setContentTitle("SHCA fall detection")
        .setContentText(text).setCategory(Notification.CATEGORY_SERVICE)
        .setOngoing(true).setOnlyAlertOnce(true).setShowWhen(false)
        .setContentIntent(openApp()).build()

    private fun openApp() = PendingIntent.getActivity(this, STATUS_ID,
        Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    private fun showFallWarning() {
        val value = pending(this) ?: return
        val id = value["eventId"] as? String ?: return
        val remaining = ((value["deadline"] as? Number)?.toLong() ?: 0L) - System.currentTimeMillis()
        if (remaining <= 0) return
        FallAlertFeedback.start(this, remaining)
        fun action(send: Boolean) = PendingIntent.getBroadcast(this, if (send) 9453 else 9452,
            Intent(this, PhoneFallResponseReceiver::class.java).putExtra("eventId", id).putExtra("send", send),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val state = PhoneFallAlarmState(id, (value["deadline"] as Number).toLong())
        val alarmScreen = PhoneFallAlarm.activityPendingIntent(this, state)
        getSystemService(NotificationManager::class.java).notify(FALL_ID,
            notificationBuilder(FALL_CHANNEL).setSmallIcon(R.drawable.ic_fall_monitoring)
                .setContentTitle("Possible fall — are you safe?")
                .setContentText("Respond within 30 seconds to cancel the automatic caregiver alert.")
                .setCategory(Notification.CATEGORY_ALARM).setOngoing(true)
                .setContentIntent(alarmScreen).setFullScreenIntent(alarmScreen, true)
                .setPriority(Notification.PRIORITY_MAX)
                .setUsesChronometer(true).setChronometerCountDown(true)
                .setWhen(System.currentTimeMillis() + remaining)
                .addAction(Notification.Action.Builder(null, "I'm safe", action(false)).build())
                .addAction(Notification.Action.Builder(null, "Send alert now", action(true)).build()).build())
        PhoneFallAlarm.present(this, state)
    }

    private fun hideFallWarning() {
        PhoneFallAlarm.dismiss()
        FallAlertFeedback.stop()
        getSystemService(NotificationManager::class.java).cancel(FALL_ID)
    }

    private fun shutdown() {
        hideFallWarning()
        val finish = Runnable { stopSelf() }
        handler.postDelayed(finish, 2_000)
        if (ready) worker?.invokeMethod("shutdown", null, object : MethodChannel.Result {
            override fun success(result: Any?) { handler.removeCallbacks(finish); stopSelf() }
            override fun error(code: String, message: String?, details: Any?) { stopSelf() }
            override fun notImplemented() { stopSelf() }
        }) else stopSelf()
    }

    override fun onDestroy() {
        FirebaseAuth.getInstance().removeAuthStateListener(authListener)
        handler.removeCallbacksAndMessages(null)
        hideFallWarning()
        worker?.setMethodCallHandler(null)
        engine?.destroy(); engine = null; worker = null
        wakeLock?.takeIf { it.isHeld }?.release(); wakeLock = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        if (instance === this) instance = null
        super.onDestroy()
        onStopped?.invoke(); onStopped = null
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        const val METHOD_CHANNEL = "com.shca.shca/phone_monitoring"
        const val EVENT_CHANNEL = "com.shca.shca/phone_monitoring_events"
        private const val WORKER_CHANNEL = "com.shca.shca/phone_monitoring_worker"
        private const val CHANNEL = "shca_phone_monitoring"
        private const val FALL_CHANNEL = "shca_phone_fall_confirmation"
        private const val STATUS_ID = 9450
        private const val FALL_ID = 9451
        private const val RESULT_ID = 9454
        const val ACTION_RESPOND = "com.shca.shca.PHONE_FALL_RESPONSE"
        private var instance: PhoneMonitoringService? = null
        var sink: EventChannel.EventSink? = null
        private var latest: Map<String, Any?> = stoppedState()
        private fun prefs(c: Context) = c.getSharedPreferences("shca_phone_monitoring", Context.MODE_PRIVATE)
        private fun ownsSession(c: Context): Boolean = prefs(c).getBoolean("enabled", false) &&
            FirebaseAuth.getInstance().currentUser?.uid?.let { it == prefs(c).getString("userId", "") } == true
        private fun pending(c: Context): Map<String, Any?>? = try {
            val value = JSONObject(prefs(c).getString("pending", "") ?: "")
            value.keys().asSequence().associateWith { value.get(it) }
        } catch (_: Exception) { null }

        fun currentFallAlarm(c: Context): PhoneFallAlarmState? {
            if (!ownsSession(c)) return null
            val value = pending(c) ?: return null
            if (value["status"] != "pending" || value["userId"] != prefs(c).getString("userId", "")) return null
            val id = value["eventId"] as? String ?: return null
            val deadline = (value["deadline"] as? Number)?.toLong() ?: return null
            return PhoneFallAlarmState(id, deadline)
        }

        private fun stoppedState() = mapOf("enabled" to false, "state" to "stopped",
            "label" to "Fall detection off", "message" to "Turn on fall detection to monitor in the background.", "possibleFall" to false)
        private fun startingState() = mapOf("enabled" to true, "state" to "starting",
            "label" to "Preparing sensors", "message" to "Starting background fall detection…", "possibleFall" to false)
        fun state(c: Context): Map<String, Any?> = if (ownsSession(c)) latest else stoppedState()
        private fun emit() { sink?.success(latest) }

        private fun startServiceCompat(c: Context, intent: Intent) {
            if (Build.VERSION.SDK_INT >= 26) c.startForegroundService(intent) else c.startService(intent)
        }

        fun enable(c: Context) {
            val user = FirebaseAuth.getInstance().currentUser ?: error("Sign in before starting fall detection.")
            if (prefs(c).getString("userId", "") != user.uid) prefs(c).edit().remove("pending").commit()
            check(prefs(c).edit().putString("userId", user.uid).putBoolean("enabled", true).commit())
            try {
                if (instance == null) {
                    latest = startingState()
                    startServiceCompat(c, Intent(c, PhoneMonitoringService::class.java))
                }
                emit()
            } catch (error: Exception) {
                prefs(c).edit().putBoolean("enabled", false).commit()
                latest = stoppedState(); emit(); throw error
            }
        }

        fun attach(c: Context) {
            if (ownsSession(c)) enable(c)
            else if (prefs(c).getBoolean("enabled", false)) disable(c)
        }

        fun disable(c: Context, completion: (() -> Unit)? = null) {
            prefs(c).edit().putBoolean("enabled", false).remove("pending").commit()
            latest = stoppedState(); emit()
            val service = instance
            if (service != null) { service.onStopped = completion; service.shutdown() } else completion?.invoke()
            c.getSystemService(NotificationManager::class.java).cancel(FALL_ID)
        }

        fun respond(c: Context, values: Map<String, Any?>, result: MethodChannel.Result? = null) {
            if (!ownsSession(c)) { result?.success(null); return }
            val service = instance
            if (service != null) service.respond(values, result)
            else {
                startServiceCompat(c, Intent(c, PhoneMonitoringService::class.java).setAction(ACTION_RESPOND)
                    .putExtra("eventId", values["eventId"] as? String).putExtra("send", values["send"] == true))
                result?.success(null)
            }
        }
    }
}

class PhoneFallResponseReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra("eventId") ?: return
        PhoneMonitoringService.respond(context, mapOf("eventId" to id, "send" to intent.getBooleanExtra("send", false)))
    }
}
