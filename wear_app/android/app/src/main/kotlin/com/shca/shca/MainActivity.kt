package com.shca.shca

import android.Manifest
import android.content.pm.PackageManager
import android.content.Intent
import android.os.*
import com.google.android.gms.wearable.*
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private val setupScreenHandler = Handler(Looper.getMainLooper())
    private val releaseSetupScreen = Runnable {
        window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }
    private var locationChannel: EmergencyLocationChannel? = null
    private var credentialResult: MethodChannel.Result? = null
    private var pendingLaunchEvent: Map<String, Any?>? = null
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingLaunchEvent = launchEvent(intent)
        // Also register at runtime so a freshly updated app is discoverable immediately.
        Wearable.getCapabilityClient(this).addLocalCapability("shca_watch_app")
        requestNotifications()
        if (WatchSession.isSignedIn(this)) WatchMonitoringService.start(this)
        MedicationScheduler.restore(this)
        handleFallPreview(intent)
    }
    override fun onDestroy() {
        setupScreenHandler.removeCallbacks(releaseSetupScreen)
        credentialResult?.success(null)
        credentialResult = null
        super.onDestroy()
    }
    override fun onResume() {
        super.onResume()
        WatchMonitoringService.setFlutterVisible(true)
        MedicationScheduler.restore(this)
        WatchCloud.refreshIfNeeded(this)
    }
    override fun onPause() {
        WatchMonitoringService.setFlutterVisible(false)
        super.onPause()
    }
    private fun requestNotifications() {
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 9301)
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent); setIntent(intent)
        launchEvent(intent)?.let { if (WatchEventBus.sink == null) pendingLaunchEvent = it else WatchEventBus.emit(it) }
        handleFallPreview(intent)
    }
    private fun handleFallPreview(intent: Intent?) {
        if (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE == 0) return
        if (intent?.action != "com.shca.shca.PREVIEW_FALL_CONFIRMATION") return
        Handler(Looper.getMainLooper()).postDelayed({
            WatchFallConfirmation.begin(this, preview = true)
        }, 3000)
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        locationChannel?.permissionResult(requestCode)
    }

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        val messenger = engine.dartExecutor.binaryMessenger
        locationChannel = EmergencyLocationChannel(this, messenger) { WatchSession.userId(this) }
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { WatchEventBus.sink = events }
            override fun onCancel(arguments: Any?) { WatchEventBus.sink = null }
        })
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            val values = call.arguments.asStringMap()
            when (call.method) {
                "getInitialState" -> getInitialState(result)
                "setMonitoringEnabled" -> {
                    try {
                        WatchMonitoringService.setEnabled(this, values["enabled"] == true)
                        result.success(WatchMonitoringService.isEnabled(this))
                    } catch (error: Exception) {
                        result.error("monitoring-unavailable", error.message, null)
                    }
                }
                "signIn" -> signIn(values, result)
                "startPhoneSignIn" -> {
                    val request = WatchPhoneSignIn.start(this, values["renew"] == true)
                    if (request["code"] != null) {
                        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        setupScreenHandler.removeCallbacks(releaseSetupScreen)
                        val remaining = ((request["expiresAt"] as? Long ?: 0) - System.currentTimeMillis()).coerceAtLeast(1)
                        setupScreenHandler.postDelayed(releaseSetupScreen, remaining)
                    }
                    result.success(request)
                }
                "cancelPhoneSignIn" -> {
                    WatchPhoneSignIn.cancel(this)
                    setupScreenHandler.removeCallbacks(releaseSetupScreen)
                    releaseSetupScreen.run()
                    result.success(true)
                }
                "editCredential" -> editCredential(values, result)
                "signOut" -> { WatchCloud.signOut(this); result.success(true) }
                "publishStatus" -> publishStatus(values, result)
                "sendEmergency" -> sendAction(values, false, result)
                "sendMedicationAction" -> sendAction(values, true, result)
                "dismissMedicationAlarm" -> { MedicationAlarmReceiver.cancel(this); result.success(true) }
                "confirmPossibleFall" -> result.success(WatchFallConfirmation.begin(this,
                    (values["probability"] as? Number)?.toDouble() ?: .95))
                "requestFallScreenPermission" -> {
                    try {
                        startActivity(Intent(android.provider.Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                            android.net.Uri.parse("package:$packageName")))
                        result.success(true)
                    } catch (_: Exception) {
                        result.error("settings-unavailable", "Allow SHCA to appear on top in watch app settings.", null)
                    }
                }
                "startFallVibration" -> { WatchAlertVibration.startFallCountdown(this); result.success(true) }
                "stopVibration" -> {
                    // Flutter can be disposed when the native confirmation opens.
                    // Keep the native fall vibration until its own response/deadline.
                    if (WatchFallConfirmation.current(this)?.status != "pending") WatchAlertVibration.stop(this)
                    result.success(true)
                }
                "testVibration" -> { MedicationAlarmReceiver.vibrate(this); result.success(true) }
                "requestAlarmPermission" -> { MedicationScheduler.requestExact(this); result.success(true) }
                "requestNotifications" -> { requestNotifications(); result.success(true) }
                else -> result.notImplemented()
            }
        }
    }
    private fun getInitialState(result: MethodChannel.Result) {
        WatchCloud.refreshIfNeeded(this)
        // Read already-synced data too: an app installed after the last phone
        // change otherwise never sees the existing account or medicine list.
        Wearable.getDataClient(this).dataItems.addOnCompleteListener { task ->
            if (task.isSuccessful) task.result.use { items ->
                val rows = items.toList()
                rows.filter { it.uri.path == Paths.PHONE_STATE }.forEach { WatchDataStore.receive(this, it) }
                rows.filter { it.uri.path != Paths.PHONE_STATE }.forEach { WatchDataStore.receive(this, it) }
            }
            Wearable.getNodeClient(this).connectedNodes.addOnCompleteListener { nodeTask ->
                val p = getSharedPreferences("shca_watch_bridge_v2", MODE_PRIVATE)
                val connected = nodeTask.isSuccessful && nodeTask.result.isNotEmpty()
                result.success(mapOf("connected" to connected, "phoneReady" to p.getBoolean("ready", false),
                    "userId" to p.getString("userId", ""), "role" to p.getString("role", ""),
                    "medications" to MedicationStore.all(this).map { it.toMap() },
                    "medication" to MedicationStore.active(this)?.toMap(),
                    "exactAlarms" to MedicationScheduler.exactAllowed(this),
                    "monitoringEnabled" to WatchMonitoringService.isEnabled(this),
                    "fallScreenAllowed" to android.provider.Settings.canDrawOverlays(this),
                    "notificationsAllowed" to (Build.VERSION.SDK_INT < 33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED),
                    "emergencyAck" to WatchDataStore.ackMap(this),
                    "launchEvent" to pendingLaunchEvent) + WatchSession.state(this))
                pendingLaunchEvent = null
            }
        }
    }
    private fun publishStatus(v: Map<String, Any?>, result: MethodChannel.Result) {
        WatchCloud.publishActivity(this, v)
        val identity = WatchDeviceIdentity.getOrCreate(this)
        val request = PutDataMapRequest.create(Paths.STATUS).apply {
            dataMap.putString("label", v["label"] as? String ?: "")
            dataMap.putFloat("confidence", (v["confidence"] as? Number)?.toFloat() ?: 0f)
            dataMap.putFloat("fallProbability", (v["fallProbability"] as? Number)?.toFloat() ?: 0f)
            dataMap.putBoolean("possibleFall", v["possibleFall"] == true)
            dataMap.putLong("updatedAt", (v["updatedAt"] as? Number)?.toLong() ?: System.currentTimeMillis())
            dataMap.putString("watchKeyId", identity.keyId)
            dataMap.putString("watchPublicKey", identity.publicKey)
        }.asPutDataRequest().setUrgent()
        Wearable.getDataClient(this).putDataItem(request).addOnSuccessListener { result.success(true) }.addOnFailureListener { result.success(false) }
    }
    private fun sendAction(v: Map<String, Any?>, medicine: Boolean, result: MethodChannel.Result) {
        val p = getSharedPreferences("shca_watch_bridge_v2", MODE_PRIVATE)
        val standalone = WatchSession.isSignedIn(this)
        val uid = if (standalone) WatchSession.userId(this) else p.getString("userId", "") ?: ""
        if ((!standalone && !p.getBoolean("ready", false)) || uid.isBlank()) {
            result.error("watch-account", "Sign in on this watch first.", null); return
        }
        val id = v["eventId"] as? String ?: ""
        if (!id.matches(Regex("[A-Za-z0-9_-]{1,100}"))) { result.error("event-id", "Invalid request.", null); return }
        val json = JSONObject(v).put("elderlyId", uid).put("createdAt", v["createdAt"] ?: System.currentTimeMillis())
        val occurrence = v["occurrenceId"] as? String ?: ""
        if (medicine) {
            if (v["action"] !in listOf("taken", "snoozed")) { result.error("medicine-action", "Invalid response.", null); return }
            if (MedicationStore.userId(this) != uid) { result.error("stale-medicine", "Wait for today's medicine sync.", null); return }
            val m = MedicationStore.find(this, occurrence)
            if (m == null || m.status == "taken") { result.error("stale-medicine", "This dose is no longer pending.", null); return }
            json.put("medicationId", m.id).put("scheduledAt", m.scheduledAt)
            json.put("remindAt", if (v["action"] == "snoozed") System.currentTimeMillis() + 600000 else m.remindAt)
        }
        val path = if (medicine) Paths.MEDICATION_ACTION else Paths.EMERGENCY
        if (!medicine) DirectEmergencySender.send(this, json)
        if (medicine) {
            MedicationStore.action(this, occurrence, v["action"] as? String ?: "taken", json.optLong("remindAt"))
            p.edit().putString("medicine-action:$id", occurrence).apply()
            if (standalone) WatchCloud.queueMedicationAction(this, json)
        }
        val request = PutDataMapRequest.create("$path/$id").apply {
            json.keys().forEach { key ->
                when(val value = json.get(key)) {
                    is String -> dataMap.putString(key, value)
                    is Number -> if (key == "fallProbability") dataMap.putFloat(key, value.toFloat()) else dataMap.putLong(key, value.toLong())
                }
            }
            dataMap.putLong("retryAt", System.currentTimeMillis())
        }.asPutDataRequest().setUrgent()
        Wearable.getDataClient(this).putDataItem(request).addOnSuccessListener {
            if (medicine) {
                // An immediate phone reply may beat the local DataItem callback.
                val ack = try { JSONObject(p.getString("ack:$id", "{}")) } catch (_: Exception) { JSONObject() }
                if (ack.optString("status") == "completed") MedicationStore.confirmAction(this, occurrence)
            }
            result.success(mapOf("eventId" to id, "status" to "queued",
                "message" to if (medicine && standalone) "Saving directly from your watch…"
                    else if (medicine) "Waiting for the phone to confirm…"
                    else "Direct caregiver delivery is in progress…"))
        }.addOnFailureListener {
            if (medicine && standalone) result.success(mapOf("eventId" to id, "status" to "queued",
                "message" to "Saved on this watch. Cloud sync will retry automatically."))
            else if (medicine) result.error("watch-send", "Could not save the request. Try again.", null)
            else result.success(mapOf("eventId" to id, "status" to "queued",
                "message" to "Direct caregiver delivery is in progress…"))
        }
        Wearable.getNodeClient(this).connectedNodes.addOnSuccessListener { nodes ->
            nodes.forEach { Wearable.getMessageClient(this).sendMessage(it.id, path, json.toString().toByteArray()) }
        }
    }
    private fun editCredential(v: Map<String, Any?>, result: MethodChannel.Result) {
        if (credentialResult != null) { result.error("input-busy", "Finish the current field first.", null); return }
        val field = v["field"] as? String
        if (field != "email" && field != "password") { result.error("input-field", "Invalid sign-in field.", null); return }
        credentialResult = result
        try {
            startActivityForResult(Intent(this, WatchCredentialActivity::class.java)
                .putExtra("field", field).putExtra("value", v["value"] as? String ?: ""), 9402)
        } catch (_: Exception) {
            credentialResult = null
            result.error("input-unavailable", "Could not open the watch keyboard. Use Connect with phone instead.", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 9402) {
            val pending = credentialResult
            credentialResult = null
            pending?.success(if (resultCode == RESULT_OK) data?.getStringExtra("value") else null)
        }
    }

    private fun signIn(v: Map<String, Any?>, result: MethodChannel.Result) {
        val email = v["email"] as? String ?: ""
        val password = v["password"] as? String ?: ""
        if (!android.util.Patterns.EMAIL_ADDRESS.matcher(email.trim()).matches() || password.length < 6) {
            result.error("invalid-login", "Enter the elderly account email and password.", null)
            return
        }
        WatchCloud.signIn(this, email, password) { response -> result.success(response) }
    }
    private fun launchEvent(intent: Intent?): Map<String, Any?>? =
        if (intent?.action == ACTION_SHOW_MEDICATION) {
            val medication = MedicationStore.find(this, intent.getStringExtra("occurrenceId") ?: "") ?: MedicationStore.active(this)
            if (medication != null && medication.status != "taken") mapOf("type" to "show_medication", "medication" to medication.toMap()) else null
        } else null
    private fun Any?.asStringMap(): Map<String, Any?> {
        @Suppress("UNCHECKED_CAST")
        return this as? Map<String, Any?> ?: emptyMap()
    }
    companion object {
        const val METHOD_CHANNEL = "com.shca.shca/watch_bridge"
        const val EVENT_CHANNEL = "com.shca.shca/watch_events"
        const val ACTION_SHOW_MEDICATION = "com.shca.shca.SHOW_WATCH_MEDICATION"
    }
}
object Paths {
    const val STATUS = "/shca/watch/status"
    const val EMERGENCY = "/shca/watch/emergency"
    const val ACK = "/shca/watch/emergency/ack"
    const val PHONE_STATE = "/shca/phone/state"
    const val MEDICATION = "/shca/medication/today"
    const val MEDICATION_ACTION = "/shca/medication/action"
    const val MEDICATION_ACK = "/shca/medication/action/ack"
    const val ACKNOWLEDGE_FALL = "/shca/watch/acknowledge-fall"
}
object WatchEventBus {
    var sink: EventChannel.EventSink? = null
    fun emit(event: Map<String, Any?>) { Handler(Looper.getMainLooper()).post { sink?.success(event) } }
}
