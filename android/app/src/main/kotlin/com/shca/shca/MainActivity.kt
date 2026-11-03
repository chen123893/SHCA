package com.shca.shca

import android.app.AlarmManager
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.net.Uri
import android.provider.Settings
import com.google.android.gms.wearable.PutDataMapRequest
import com.google.android.gms.wearable.Wearable
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private data class SosCallRequest(val uid: String, val phone: String, val result: MethodChannel.Result)
    private var sosCallRequest: SosCallRequest? = null
    private var smsPermissionRequest: Pair<String, MethodChannel.Result>? = null
    private var monitoringEventSink: EventChannel.EventSink? = null
    private var monitoringPermissionResult: MethodChannel.Result? = null
    private var alarmEventSink: EventChannel.EventSink? = null
    private var pendingMedicationAlarmPayload: String? = null
    private var overlayPermissionResult: MethodChannel.Result? = null
    private var fullScreenPermissionResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        captureMedicationAlarm(intent)
        super.onCreate(savedInstanceState)
        handleFallAlarmPreview(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureMedicationAlarm(intent)
        handleFallAlarmPreview(intent)
    }

    private fun handleFallAlarmPreview(intent: Intent?) {
        if (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE == 0 ||
            intent?.action != "com.shca.shca.PREVIEW_PHONE_FALL_ALARM") return
        val duration = intent.getLongExtra("previewDurationMillis", 30000)
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
            PhoneFallAlarm.preview(this, duration)
        }, 3000)
    }

    override fun onDestroy() {
        if (PhoneMonitoringService.sink === monitoringEventSink) PhoneMonitoringService.sink = null
        monitoringEventSink = null
        if (!PhoneMonitoringService.state(this).get("enabled").let { it == true } && !PhoneFallAlarm.isShowing()) FallAlertFeedback.stop()
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 9461) {
            val request = sosCallRequest ?: return
            sosCallRequest = null
            val granted = grantResults.firstOrNull() == android.content.pm.PackageManager.PERMISSION_GRANTED
            val stillSignedIn = com.google.firebase.auth.FirebaseAuth.getInstance().currentUser?.uid == request.uid
            request.result.success(granted && stillSignedIn && placeSosCall(request.phone))
            return
        }
        if (requestCode == 9460) {
            val (uid, result) = smsPermissionRequest ?: return
            smsPermissionRequest = null
            val enabled = grantResults.firstOrNull() == android.content.pm.PackageManager.PERMISSION_GRANTED &&
                com.google.firebase.auth.FirebaseAuth.getInstance().currentUser?.uid == uid
            if (enabled) FallSmsWorker.setEnabled(this, uid, true)
            result.success(enabled)
            return
        }
        if (requestCode != 9450) return
        val result = monitoringPermissionResult ?: return
        monitoringPermissionResult = null
        if (grantResults.firstOrNull() == android.content.pm.PackageManager.PERMISSION_GRANTED) {
            try { PhoneMonitoringService.enable(this); result.success(PhoneMonitoringService.state(this)) }
            catch (error: Exception) { result.error("monitoring-unavailable", error.message, null) }
        } else result.error("notifications-disabled", "Allow notifications to show fall detection status while SHCA runs in the background.", null)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == FULL_SCREEN_PERMISSION_REQUEST) {
            fullScreenPermissionResult?.success(Build.VERSION.SDK_INT < 34 ||
                getSystemService(NotificationManager::class.java).canUseFullScreenIntent())
            fullScreenPermissionResult = null
        }
        if (requestCode == OVERLAY_PERMISSION_REQUEST) {
            overlayPermissionResult?.success(Settings.canDrawOverlays(this))
            overlayPermissionResult = null
        }
    }

    private fun placeSosCall(phone: String): Boolean = try {
        startActivity(Intent(Intent.ACTION_CALL, Uri.fromParts("tel", phone, null)))
        true
    } catch (_: SecurityException) {
        false
    } catch (_: android.content.ActivityNotFoundException) {
        false
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "com.shca.shca/sos").setMethodCallHandler { call, result ->
            val uid = com.google.firebase.auth.FirebaseAuth.getInstance().currentUser?.uid
            when (call.method) {
                "queueSms" -> {
                    val eventId = call.argument<String>("eventId")
                    result.success(uid != null && eventId != null &&
                        eventId.matches(Regex("[A-Za-z0-9_-]{1,100}")) &&
                        FallSmsWorker.enqueue(this, uid, eventId, System.currentTimeMillis(), manualSos = true))
                }
                "callContact" -> {
                    val phone = call.argument<String>("phone")?.trim()?.replace(Regex("[ ()-]"), "")
                    when {
                        uid == null || phone == null || !phone.matches(Regex("[+]?[0-9]{7,15}")) ->
                            result.success(false)
                        checkSelfPermission(android.Manifest.permission.CALL_PHONE) ==
                            android.content.pm.PackageManager.PERMISSION_GRANTED ->
                            result.success(placeSosCall(phone))
                        sosCallRequest != null -> result.success(false)
                        else -> {
                            sosCallRequest = SosCallRequest(uid, phone, result)
                            requestPermissions(arrayOf(android.Manifest.permission.CALL_PHONE), 9461)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(messenger, "com.shca.shca/fall_sms").setMethodCallHandler { call, result ->
            val uid = com.google.firebase.auth.FirebaseAuth.getInstance().currentUser?.uid
            when {
                uid == null -> result.success(false)
                call.method == "isEnabled" -> result.success(FallSmsWorker.isEnabled(this, uid))
                call.method != "setEnabled" -> result.notImplemented()
                call.argument<Boolean>("enabled") != true -> {
                    FallSmsWorker.setEnabled(this, uid, false)
                    result.success(false)
                }
                FallSmsWorker.hasPermission(this) -> {
                    FallSmsWorker.setEnabled(this, uid, true)
                    result.success(true)
                }
                smsPermissionRequest != null -> result.error("permission-pending", "SMS permission is already open.", null)
                else -> {
                    smsPermissionRequest = uid to result
                    requestPermissions(arrayOf(android.Manifest.permission.SEND_SMS), 9460)
                }
            }
        }
        EventChannel(messenger, PhoneMonitoringService.EVENT_CHANNEL).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                monitoringEventSink = events
                PhoneMonitoringService.sink = events
                events?.success(PhoneMonitoringService.state(this@MainActivity))
            }
            override fun onCancel(arguments: Any?) {
                if (PhoneMonitoringService.sink === monitoringEventSink) PhoneMonitoringService.sink = null
                monitoringEventSink = null
            }
        })
        MethodChannel(messenger, PhoneMonitoringService.METHOD_CHANNEL).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "getAlarmDisplayAccess" -> result.success(mapOf(
                        "appearOnTop" to Settings.canDrawOverlays(this),
                        "fullScreen" to (Build.VERSION.SDK_INT < 34 ||
                            getSystemService(NotificationManager::class.java).canUseFullScreenIntent())))
                    "attach" -> { PhoneMonitoringService.attach(this); result.success(PhoneMonitoringService.state(this)) }
                    "setEnabled" -> {
                        if (call.argument<Boolean>("enabled") == true) {
                            if (!getSystemService(NotificationManager::class.java).areNotificationsEnabled()) {
                                if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                                    if (monitoringPermissionResult != null) result.error("permission-pending", "Notification permission is already open.", null)
                                    else {
                                        monitoringPermissionResult = result
                                        requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 9450)
                                    }
                                } else result.error("notifications-disabled", "Enable SHCA notifications in phone settings to show fall detection status.", null)
                            } else {
                                PhoneMonitoringService.enable(this)
                                result.success(PhoneMonitoringService.state(this))
                            }
                        } else { PhoneMonitoringService.disable(this) { result.success(PhoneMonitoringService.state(this)) } }
                    }
                    "respondToFall" -> {
                        @Suppress("UNCHECKED_CAST")
                        PhoneMonitoringService.respond(this, call.arguments as? Map<String, Any?> ?: emptyMap(), result)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) { result.error("monitoring-unavailable", error.message, null) }
        }
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                WearableEventBus.sink = events
            }

            override fun onCancel(arguments: Any?) {
                WearableEventBus.sink = null
            }
        })
        EventChannel(messenger, ALARM_EVENT_CHANNEL).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                alarmEventSink = events
                pendingMedicationAlarmPayload?.let { payload ->
                    events?.success(payload)
                    pendingMedicationAlarmPayload = null
                }
            }

            override fun onCancel(arguments: Any?) {
                alarmEventSink = null
            }
        })
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setPhoneState" -> {
                    @Suppress("UNCHECKED_CAST")
                    val values = call.arguments as? Map<String, Any?> ?: emptyMap()
                    WatchBridge.setPhoneState(this, values, result)
                }
                "getStatus" -> WatchBridge.getStatus(this, result)
                "findWatchSignInRequests" -> WatchSignInBridge.find(this, result)
                "approveWatchSignIn" -> WatchSignInBridge.approve(this, call.arguments as? Map<String, Any?> ?: emptyMap(), result)
                "getPendingEvents" -> result.success(WatchBridge.takePendingEvents(this))
                "clearPendingEvents" -> {
                    WatchBridge.clearPendingEvents(this)
                    result.success(true)
                }
                "syncMedication" -> {
                    @Suppress("UNCHECKED_CAST")
                    val medication = call.arguments as? Map<String, Any?>
                    if (medication == null) result.error("invalid-medication", "Medication data is missing.", null)
                    else WatchBridge.syncMedication(this, medication, result)
                }
                "acknowledgeFall" -> WatchBridge.acknowledgeFall(this, result)
                "startFallAlert", "startFallVibration" -> {
                    val duration = call.argument<Number>("durationMillis")?.toLong() ?: 30000L
                    FallAlertFeedback.start(this, duration)
                    result.success(true)
                }
                "stopFallAlert", "stopAlertVibration" -> {
                    FallAlertFeedback.stop()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(messenger, ALARM_PERMISSION_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getStatus" -> {
                    val notifications = getSystemService(NotificationManager::class.java)
                    val alarms = getSystemService(Context.ALARM_SERVICE) as AlarmManager
                    result.success(
                        mapOf(
                            "notifications" to notifications.areNotificationsEnabled(),
                            "appearOnTop" to Settings.canDrawOverlays(this),
                            "exact" to (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarms.canScheduleExactAlarms()),
                            "fullScreen" to (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE || notifications.canUseFullScreenIntent()),
                        ),
                    )
                }
                "requestFullScreenPermission" -> {
                    if (Build.VERSION.SDK_INT < 34 || getSystemService(NotificationManager::class.java).canUseFullScreenIntent()) {
                        result.success(true)
                    } else if (fullScreenPermissionResult != null) {
                        result.error("permission-in-progress", "Alarm settings are already open.", null)
                    } else {
                        fullScreenPermissionResult = result
                        try {
                            startActivityForResult(Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
                                Uri.parse("package:$packageName")), FULL_SCREEN_PERMISSION_REQUEST)
                        } catch (error: Exception) {
                            fullScreenPermissionResult = null
                            result.error("settings-unavailable", "Allow full-screen alarms for SHCA in phone settings.", null)
                        }
                    }
                }
                "requestAppearOnTopPermission" -> {
                    if (Settings.canDrawOverlays(this)) {
                        result.success(true)
                    } else if (overlayPermissionResult != null) {
                        result.error("permission-in-progress", "Alarm settings are already open.", null)
                    } else {
                        overlayPermissionResult = result
                        try {
                            startActivityForResult(
                                Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                    Uri.parse("package:$packageName")),
                                OVERLAY_PERMISSION_REQUEST,
                            )
                        } catch (error: Exception) {
                            overlayPermissionResult = null
                            result.error("settings-unavailable", "Open Settings > Apps > Special access > Appear on top, then enable SHCA.", null)
                        }
                    }
                }
                "startMedicationAlarmFeedback" -> {
                    val key = call.argument<String>("alarmKey")
                    if (key.isNullOrEmpty()) {
                        result.error("invalid-alarm", "Alarm key is missing.", null)
                    } else {
                        try {
                            MedicationAlarmFeedback.start(this, key)
                            result.success(null)
                        } catch (error: Exception) {
                            MedicationAlarmFeedback.stop(key)
                            result.error("alarm-feedback-failed", error.message, null)
                        }
                    }
                }
                "stopMedicationAlarmFeedback" -> {
                    MedicationAlarmFeedback.stop(call.argument<String>("alarmKey"))
                    result.success(null)
                }
                "scheduleMedicationAlarm" -> {
                    val id = (call.argument<Number>("id"))?.toInt()
                    val triggerAtMillis =
                        (call.argument<Number>("triggerAtMillis"))?.toLong()
                    val payload = call.argument<String>("payload")
                    if (id == null || triggerAtMillis == null || payload.isNullOrEmpty()) {
                        result.error("invalid-alarm", "Alarm id, time, or payload is missing.", null)
                    } else {
                        result.success(
                            MedicationAlarmScheduler.schedule(
                                this,
                                id,
                                triggerAtMillis,
                                payload,
                            ),
                        )
                    }
                }
                "cancelMedicationAlarm" -> {
                    val id = (call.argument<Number>("id"))?.toInt()
                    if (id == null) {
                        result.error("invalid-alarm", "Alarm id is missing.", null)
                    } else {
                        MedicationAlarmScheduler.cancel(this, id)
                        result.success(true)
                    }
                }
                "takePendingMedicationAlarm" -> {
                    val payload = pendingMedicationAlarmPayload
                    pendingMedicationAlarmPayload = null
                    result.success(payload)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun captureMedicationAlarm(intent: Intent?) {
        if (intent?.action != MedicationAlarmScheduler.ACTION_MEDICATION_ALARM) return
        val payload = intent.getStringExtra(MedicationAlarmScheduler.EXTRA_PAYLOAD)
        val id = intent.getIntExtra(MedicationAlarmScheduler.EXTRA_ALARM_ID, -1)
        if (id >= 0) MedicationAlarmScheduler.consume(this, id)
        if (payload.isNullOrEmpty()) return
        val sink = alarmEventSink
        if (sink == null) {
            pendingMedicationAlarmPayload = payload
        } else {
            sink.success(payload)
        }
    }

    companion object {
        private const val OVERLAY_PERMISSION_REQUEST = 8402
        private const val FULL_SCREEN_PERMISSION_REQUEST = 8403
        const val METHOD_CHANNEL = "com.shca.shca/wearable"
        const val EVENT_CHANNEL = "com.shca.shca/wearable_events"
        const val ALARM_PERMISSION_CHANNEL = "com.shca.shca/alarm_permissions"
        const val ALARM_EVENT_CHANNEL = "com.shca.shca/alarm_events"
    }
}
