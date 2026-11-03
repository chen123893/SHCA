package com.shca.shca

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import com.google.android.gms.wearable.*
import com.google.firebase.Timestamp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.SetOptions
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.util.Date

object WatchPaths {
    const val STATUS = "/shca/watch/status"
    const val EMERGENCY = "/shca/watch/emergency"
    const val ACK = "/shca/watch/emergency/ack"
    const val PHONE_STATE = "/shca/phone/state"
    const val MEDICATION = "/shca/medication/today"
    const val MEDICATION_ACTION = "/shca/medication/action"
    const val MEDICATION_ACK = "/shca/medication/action/ack"
    const val ACKNOWLEDGE_FALL = "/shca/watch/acknowledge-fall"
}

object WearableEventBus {
    var sink: EventChannel.EventSink? = null
    fun emit(context: Context, event: Map<String, Any?>, persist: Boolean = false) {
        Handler(Looper.getMainLooper()).post { sink?.success(event) }
    }
}

object WatchBridge {
    private const val PREFS = "shca_wearable_bridge"
    private const val SHCA_WATCH_CAPABILITY = "shca_watch_app"
    fun getStatus(context: Context, result: MethodChannel.Result) {
        Wearable.getCapabilityClient(context)
            .getCapability(SHCA_WATCH_CAPABILITY, CapabilityClient.FILTER_REACHABLE)
            .addOnSuccessListener { capability ->
                result.success(statusMap(context, capability.nodes.isNotEmpty()))
            }
            .addOnFailureListener { result.success(statusMap(context, false)) }
    }
    fun refreshConnection(context: Context) {
        Wearable.getCapabilityClient(context)
            .getCapability(SHCA_WATCH_CAPABILITY, CapabilityClient.FILTER_REACHABLE)
            .addOnSuccessListener { capability ->
                WearableEventBus.emit(context, statusMap(context, capability.nodes.isNotEmpty()))
            }
            .addOnFailureListener {
                WearableEventBus.emit(context, statusMap(context, false))
            }
    }
    fun emitConnection(context: Context, connected: Boolean) {
        WearableEventBus.emit(context, statusMap(context, connected))
    }
    private fun statusMap(context: Context, connected: Boolean): Map<String, Any?> {
        val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return mapOf("type" to "status", "connected" to connected,
            "label" to p.getString("label", ""), "confidence" to p.getFloat("confidence", 0f).toDouble(),
            "fallProbability" to p.getFloat("fallProbability", 0f).toDouble(),
            "possibleFall" to p.getBoolean("possibleFall", false), "updatedAt" to p.getLong("updatedAt", 0))
    }
    fun setPhoneState(context: Context, values: Map<String, Any?>, result: MethodChannel.Result) {
        val request = PutDataMapRequest.create(WatchPaths.PHONE_STATE).apply {
            dataMap.putString("userId", values["userId"] as? String ?: "")
            dataMap.putString("role", values["role"] as? String ?: "")
            dataMap.putBoolean("ready", values["role"] == "elderly")
            dataMap.putLong("updatedAt", System.currentTimeMillis())
        }.asPutDataRequest().setUrgent()
        Wearable.getDataClient(context).putDataItem(request)
            .addOnSuccessListener { result.success(true) }
            .addOnFailureListener { result.error("phone-state", "Could not sync phone account.", null) }
    }
    fun syncMedication(context: Context, values: Map<String, Any?>, result: MethodChannel.Result) {
        val request = PutDataMapRequest.create(WatchPaths.MEDICATION).apply {
            dataMap.putString("scheduleJson", values["scheduleJson"] as? String ?: "[]")
            dataMap.putString("userId", values["userId"] as? String ?: "")
            dataMap.putLong("updatedAt", System.currentTimeMillis())
        }.asPutDataRequest().setUrgent()
        Wearable.getDataClient(context).putDataItem(request)
            .addOnSuccessListener { result.success(true) }
            .addOnFailureListener { result.error("watch-sync", "Could not sync today's medicines.", null) }
    }
    fun acknowledgeFall(context: Context, result: MethodChannel.Result) {
        Wearable.getNodeClient(context).connectedNodes.addOnSuccessListener { nodes ->
            nodes.forEach { Wearable.getMessageClient(context).sendMessage(it.id, WatchPaths.ACKNOWLEDGE_FALL, byteArrayOf()) }
            result.success(nodes.isNotEmpty())
        }.addOnFailureListener { result.success(false) }
    }
    fun takePendingEvents(context: Context): List<Map<String, Any?>> = emptyList()
    fun clearPendingEvents(context: Context) { /* Native workers own durable delivery. */ }
    fun saveStatus(context: Context, map: DataMap) {
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        preferences.edit()
            .putString("label", map.getString("label")).putFloat("confidence", map.getFloat("confidence"))
            .putFloat("fallProbability", map.getFloat("fallProbability"))
            .putBoolean("possibleFall", map.getBoolean("possibleFall")).putLong("updatedAt", map.getLong("updatedAt")).apply()
        val user = FirebaseAuth.getInstance().currentUser ?: return
        val keyId = map.getString("watchKeyId") ?: ""
        val publicKey = map.getString("watchPublicKey") ?: ""
        if (keyId.matches(Regex("[a-f0-9]{40}")) && publicKey.length in 300..1000) {
            FirebaseFirestore.getInstance().collection("watch_credentials").document(keyId)
                .set(mapOf(
                    "keyId" to keyId,
                    "elderlyId" to user.uid,
                    "algorithm" to "RS256",
                    "publicKey" to publicKey,
                    "active" to true,
                    "updatedAt" to FieldValue.serverTimestamp(),
                ), SetOptions.merge())
        }

        // Publish from the native listener so caregiver live status continues
        // even while the elderly phone is locked, charging, or Flutter is closed.
        val now = System.currentTimeMillis()
        val label = map.getString("label") ?: ""
        val signature = "$label:${map.getBoolean("possibleFall")}" 
        val lastAt = preferences.getLong("cloudStatusAt", 0)
        if (signature == preferences.getString("cloudStatusSignature", "") && now - lastAt < 20_000) return
        preferences.edit().putString("cloudStatusSignature", signature).putLong("cloudStatusAt", now).apply()
        val measuredAt = map.getLong("updatedAt").takeIf { it > 0 } ?: now
        FirebaseFirestore.getInstance().collection("activity_status").document(user.uid)
            .set(mapOf(
                "elderlyId" to user.uid,
                "watch" to mapOf(
                    "label" to label,
                    "confidence" to map.getFloat("confidence").toDouble().coerceIn(0.0, 1.0),
                    "fallProbability" to map.getFloat("fallProbability").toDouble().coerceIn(0.0, 1.0),
                    "possibleFall" to map.getBoolean("possibleFall"),
                    "active" to label.isNotBlank(),
                    "measuredAt" to Timestamp(Date(measuredAt)),
                    "publishedAt" to FieldValue.serverTimestamp(),
                ),
                "updatedAt" to FieldValue.serverTimestamp(),
            ), SetOptions.merge())
    }
    fun acknowledge(context: Context, node: String, id: String, status: String, message: String, medicine: Boolean = false) {
        val path = if (medicine) WatchPaths.MEDICATION_ACK else WatchPaths.ACK
        val json = JSONObject(mapOf("eventId" to id, "status" to status, "message" to message))
        val request = PutDataMapRequest.create("$path/$id").apply {
            dataMap.putString("json", json.toString())
            dataMap.putLong("updatedAt", System.currentTimeMillis())
        }.asPutDataRequest().setUrgent()
        Wearable.getDataClient(context).putDataItem(request)
        if (node.isNotEmpty()) Wearable.getMessageClient(context).sendMessage(node, path, json.toString().toByteArray())
    }
    fun showEmergencyNotification(context: Context, message: String, phone: String = "") {
        val manager = context.getSystemService(NotificationManager::class.java)
        val channel = "shca_watch_emergency_v2"
        manager.createNotificationChannel(NotificationChannel(channel, "Watch emergencies", NotificationManager.IMPORTANCE_HIGH).apply {
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 500, 200, 500, 200, 500)
        })
        val open = PendingIntent.getActivity(context, 9201,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = android.app.Notification.Builder(context, channel)
            .setSmallIcon(R.mipmap.ic_launcher).setContentTitle("SHCA Watch: help requested")
            .setContentText(message).setStyle(android.app.Notification.BigTextStyle().bigText(message))
            .setCategory(android.app.Notification.CATEGORY_ALARM).setAutoCancel(true).setContentIntent(open)
        if (phone.isNotBlank()) {
            val dial = PendingIntent.getActivity(context, 9202,
                Intent(Intent.ACTION_DIAL, Uri.fromParts("tel", phone, null)),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            notification.addAction(android.app.Notification.Action.Builder(null, "Call emergency contact", dial).build())
        }
        try { manager.notify(9201, notification.build()) } catch (_: SecurityException) { }
    }
}

class WatchDataLayerService : WearableListenerService() {
    override fun onConnectedNodes(connectedNodes: List<Node>) {
        WatchBridge.refreshConnection(this)
    }
    override fun onPeerConnected(peer: Node) {
        WatchBridge.refreshConnection(this)
    }
    override fun onPeerDisconnected(peer: Node) {
        WatchBridge.refreshConnection(this)
    }
    override fun onCapabilityChanged(capabilityInfo: CapabilityInfo) {
        if (capabilityInfo.name == "shca_watch_app") {
            WatchBridge.emitConnection(this, capabilityInfo.nodes.isNotEmpty())
        }
    }
    override fun onDataChanged(events: DataEventBuffer) {
        events.forEach { event ->
            if (event.type != DataEvent.TYPE_CHANGED) return@forEach
            val map = DataMapItem.fromDataItem(event.dataItem).dataMap
            val path = event.dataItem.uri.path ?: ""
            when {
                path == WatchPaths.STATUS -> {
                    WatchBridge.saveStatus(this, map)
                    WearableEventBus.emit(this, mapOf("type" to "status", "connected" to true,
                        "label" to map.getString("label"), "confidence" to map.getFloat("confidence").toDouble(),
                        "fallProbability" to map.getFloat("fallProbability").toDouble(),
                        "possibleFall" to map.getBoolean("possibleFall"), "updatedAt" to map.getLong("updatedAt")))
                }
                path == WatchPaths.EMERGENCY || path.startsWith(WatchPaths.EMERGENCY + "/") ->
                    accept(map, event.dataItem.uri.host ?: "", false)
                path == WatchPaths.MEDICATION_ACTION || path.startsWith(WatchPaths.MEDICATION_ACTION + "/") ->
                    accept(map, event.dataItem.uri.host ?: "", true)
            }
        }
    }
    override fun onMessageReceived(event: MessageEvent) {
        if (WatchSignInBridge.receive(event)) return
        if (event.path != WatchPaths.EMERGENCY && event.path != WatchPaths.MEDICATION_ACTION) return
        try {
            val json = JSONObject(String(event.data))
            val map = DataMap()
            json.keys().forEach { key ->
                when (val value = json.get(key)) {
                    is String -> map.putString(key, value)
                    is Number -> if (key == "fallProbability") map.putFloat(key, value.toFloat()) else map.putLong(key, value.toLong())
                }
            }
            accept(map, event.sourceNodeId, event.path == WatchPaths.MEDICATION_ACTION)
        } catch (_: Exception) { /* Legacy wake-only messages contain no payload. */ }
    }
    private fun accept(map: DataMap, node: String, medicine: Boolean) {
        val id = map.getString("eventId") ?: return
        if (!id.matches(Regex("[A-Za-z0-9_-]{1,100}"))) return
        val payload = JSONObject(mapOf("eventId" to id, "elderlyId" to (map.getString("elderlyId") ?: ""),
            "source" to (map.getString("source") ?: "wearable_sos"),
            "fallProbability" to map.getFloat("fallProbability").toDouble(),
            "createdAt" to map.getLong("createdAt"), "medicationId" to (map.getString("medicationId") ?: ""),
            "occurrenceId" to (map.getString("occurrenceId") ?: ""),
            "scheduledAt" to map.getLong("scheduledAt"), "remindAt" to map.getLong("remindAt"),
            "action" to (map.getString("action") ?: "")))
        WatchActionWorker.enqueue(this, payload.toString(), node, medicine)
        WatchBridge.acknowledge(this, node, id, "received", "Phone received the request. Processing…", medicine)
    }
}
