package com.shca.shca

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.util.Log
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import com.google.android.gms.wearable.PutDataMapRequest
import com.google.android.gms.wearable.Wearable
import kotlin.math.sqrt

class WatchMonitoringService : Service(), SensorEventListener {
    private var wakeLock: PowerManager.WakeLock? = null
    private lateinit var sensorManager: SensorManager
    private val handler = Handler(Looper.getMainLooper())
    private var identity: WatchIdentity? = null
    private var latestGyroscope = 0.0
    private var freeFallAt = 0L
    private var impactAt = 0L
    private var stillSamples = 0
    private var accelerationSum = 0.0
    private var accelerationSquaredSum = 0.0
    private var gyroscopeSum = 0.0
    private var lastAlertAt = 0L
    private val heartbeat = object : Runnable {
        override fun run() {
            if (!flutterVisible) publishBackgroundHeartbeat()
            handler.postDelayed(this, HEARTBEAT_INTERVAL_MS)
        }
    }

    override fun onCreate() {
        super.onCreate()
        if (!isEnabled(this) || !WatchSession.isSignedIn(this)) { stopSelf(); return }
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Fall monitoring",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "Keeps wrist fall detection active when the watch screen is off."
                    setShowBadge(false)
                },
            )
        }
        val openApp = PendingIntent.getActivity(
            this,
            9401,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("SHCA fall monitoring")
            .setContentText("Wrist sensors are monitoring for falls")
            .setCategory(Notification.CATEGORY_SERVICE)
            .setOngoing(true)
            .setContentIntent(openApp)
            .build()
        startForeground(NOTIFICATION_ID, notification)
        wakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:fall-monitoring")
            .apply {
                setReferenceCounted(false)
                acquire()
            }
        identity = WatchDeviceIdentity.getOrCreate(this)
        sensorManager = getSystemService(Context.SENSOR_SERVICE) as SensorManager
        sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)?.let {
            sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME)
        }
        sensorManager.getDefaultSensor(Sensor.TYPE_GYROSCOPE)?.let {
            sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME)
        }
        handler.post(heartbeat)
        WatchFallConfirmation.restore(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!isEnabled(this) || !WatchSession.isSignedIn(this)) {
            stopSelf(); return START_NOT_STICKY
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    override fun onSensorChanged(event: SensorEvent) {
        val magnitude = sqrt(
            event.values[0].toDouble() * event.values[0] +
                event.values[1].toDouble() * event.values[1] +
                event.values[2].toDouble() * event.values[2],
        )
        if (!isEnabled(this)) return
        if (event.sensor.type == Sensor.TYPE_GYROSCOPE) {
            latestGyroscope = magnitude
            return
        }
        if (event.sensor.type != Sensor.TYPE_ACCELEROMETER || flutterVisible) return
        evaluateBackgroundFall(magnitude, SystemClock.elapsedRealtime())
    }

    private fun evaluateBackgroundFall(acceleration: Double, now: Long) {
        if (impactAt == 0L) {
            if (acceleration < FREE_FALL_THRESHOLD) {
                if (freeFallAt == 0L) diagnostic("Free-fall candidate: acceleration=$acceleration")
                freeFallAt = now
            }
            if (freeFallAt > 0L && now - freeFallAt <= FREE_FALL_TO_IMPACT_MS &&
                acceleration > IMPACT_THRESHOLD
            ) {
                diagnostic("Impact observed: acceleration=$acceleration; checking post-impact stillness")
                impactAt = now
                stillSamples = 0
                accelerationSum = 0.0
                accelerationSquaredSum = 0.0
                gyroscopeSum = 0.0
            } else if (freeFallAt > 0L && now - freeFallAt > FREE_FALL_TO_IMPACT_MS) {
                diagnostic("Candidate rejected: no qualifying impact after free fall")
                freeFallAt = 0L
            }
            return
        }

        val elapsed = now - impactAt
        if (elapsed >= STILLNESS_START_MS) {
            stillSamples++
            accelerationSum += acceleration
            accelerationSquaredSum += acceleration * acceleration
            gyroscopeSum += latestGyroscope
        }
        if (elapsed < CONFIRMATION_WINDOW_MS) return

        if (stillSamples >= MINIMUM_STILL_SAMPLES) {
            val mean = accelerationSum / stillSamples
            val variance = (accelerationSquaredSum / stillSamples - mean * mean)
                .coerceAtLeast(0.0)
            val deviation = sqrt(variance)
            val meanGyroscope = gyroscopeSum / stillSamples
            val eligible = mean in STILL_ACCELERATION_MIN..STILL_ACCELERATION_MAX &&
                deviation <= STILL_ACCELERATION_DEVIATION &&
                meanGyroscope <= STILL_GYROSCOPE_MAX &&
                now - lastAlertAt >= ALERT_COOLDOWN_MS
            diagnostic("Post-impact check: samples=$stillSamples meanAcceleration=$mean " +
                "deviation=$deviation meanGyroscope=$meanGyroscope eligible=$eligible")
            if (eligible) {
                lastAlertAt = now
                sendBackgroundFall()
            }
        } else {
            diagnostic("Candidate rejected: insufficient post-impact samples ($stillSamples)")
        }
        freeFallAt = 0L
        impactAt = 0L
    }

    private fun diagnostic(message: String) {
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) {
            Log.d("WatchFallDetector", message)
        }
    }

    private fun publishBackgroundHeartbeat() {
        val now = System.currentTimeMillis()
        val watchIdentity = identity ?: WatchDeviceIdentity.getOrCreate(this).also { identity = it }
        val request = PutDataMapRequest.create(Paths.STATUS).apply {
            dataMap.putString("label", "Wrist monitoring")
            dataMap.putFloat("confidence", 1f)
            dataMap.putFloat("fallProbability", 0f)
            dataMap.putBoolean("possibleFall", false)
            dataMap.putLong("updatedAt", now)
            dataMap.putString("watchKeyId", watchIdentity.keyId)
            dataMap.putString("watchPublicKey", watchIdentity.publicKey)
        }.asPutDataRequest().setUrgent()
        Wearable.getDataClient(this).putDataItem(request)
        WatchCloud.publishActivity(this, mapOf(
            "label" to "Wrist monitoring",
            "confidence" to 1.0,
            "fallProbability" to 0.0,
            "possibleFall" to false,
            "updatedAt" to now,
        ))
        WatchCloud.refreshIfNeeded(this)
    }

    private fun sendBackgroundFall() {
        WatchFallConfirmation.begin(this)
    }

    override fun onDestroy() {
        handler.removeCallbacks(heartbeat)
        if (::sensorManager.isInitialized) sensorManager.unregisterListener(this)
        wakeLock?.takeIf { it.isHeld }?.release()
        wakeLock = null
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "shca_watch_monitoring"
        private const val NOTIFICATION_ID = 9401
        private const val HEARTBEAT_INTERVAL_MS = 5_000L
        private const val FREE_FALL_THRESHOLD = 4.5
        private const val IMPACT_THRESHOLD = 22.0
        private const val FREE_FALL_TO_IMPACT_MS = 1_200L
        private const val STILLNESS_START_MS = 400L
        private const val CONFIRMATION_WINDOW_MS = 2_400L
        private const val MINIMUM_STILL_SAMPLES = 30
        private const val STILL_ACCELERATION_MIN = 7.0
        private const val STILL_ACCELERATION_MAX = 13.0
        private const val STILL_ACCELERATION_DEVIATION = 1.8
        private const val STILL_GYROSCOPE_MAX = 1.2
        private const val ALERT_COOLDOWN_MS = 60_000L

        @Volatile
        private var flutterVisible = false

        fun setFlutterVisible(visible: Boolean) {
            flutterVisible = visible
        }

        fun isEnabled(context: Context): Boolean = context
            .getSharedPreferences("shca_watch_monitoring", Context.MODE_PRIVATE)
            .getBoolean("enabled:${WatchSession.userId(context)}", true)

        fun setEnabled(context: Context, enabled: Boolean) {
            check(WatchSession.isSignedIn(context)) { "Sign in before changing fall detection." }
            check(context.getSharedPreferences("shca_watch_monitoring", Context.MODE_PRIVATE)
                .edit().putBoolean("enabled:${WatchSession.userId(context)}", enabled).commit())
            if (enabled) {
                start(context)
            } else {
                context.stopService(Intent(context, WatchMonitoringService::class.java))
                WatchFallConfirmation.cancelAll(context)
                val now = System.currentTimeMillis()
                val identity = WatchDeviceIdentity.getOrCreate(context)
                val request = PutDataMapRequest.create(Paths.STATUS).apply {
                    dataMap.putString("label", "Fall detection off")
                    dataMap.putFloat("confidence", 0f)
                    dataMap.putFloat("fallProbability", 0f)
                    dataMap.putBoolean("possibleFall", false)
                    dataMap.putLong("updatedAt", now)
                    dataMap.putString("watchKeyId", identity.keyId)
                    dataMap.putString("watchPublicKey", identity.publicKey)
                }.asPutDataRequest().setUrgent()
                Wearable.getDataClient(context).putDataItem(request)
                WatchCloud.publishActivity(context, mapOf("label" to "Fall detection off",
                    "confidence" to 0.0, "fallProbability" to 0.0, "possibleFall" to false,
                    "updatedAt" to now))
            }
        }

        fun start(context: Context) {
            if (!WatchSession.isSignedIn(context) || !isEnabled(context)) return
            val intent = Intent(context, WatchMonitoringService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }
}
