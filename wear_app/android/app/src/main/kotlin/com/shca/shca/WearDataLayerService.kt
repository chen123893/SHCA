package com.shca.shca

import android.content.Context
import com.google.android.gms.wearable.*
import org.json.JSONObject

object WatchDataStore {
    private fun prefs(c: Context) = c.getSharedPreferences("shca_watch_bridge_v2", Context.MODE_PRIVATE)
    fun receive(c: Context, item: DataItem) {
        val path = item.uri.path ?: return
        if (path != Paths.PHONE_STATE && path != Paths.MEDICATION &&
            !path.startsWith(Paths.ACK + "/") && !path.startsWith(Paths.MEDICATION_ACK + "/")) return
        val map = DataMapItem.fromDataItem(item).dataMap
        val version = map.getLong("updatedAt")
        if (version <= prefs(c).getLong("version:$path", 0)) return
        prefs(c).edit().putLong("version:$path", version).apply()
        when {
            path == Paths.PHONE_STATE -> {
                val oldUid = prefs(c).getString("userId", "")
                val uid = map.getString("userId") ?: ""
                val ready = map.getBoolean("ready")
                prefs(c).edit().putString("userId", uid).putString("role", map.getString("role"))
                    .putBoolean("ready", ready).apply()
                if (!WatchSession.isSignedIn(c) && (!ready || oldUid != uid)) {
                    MedicationStore.receive(c, if (ready) uid else "", "[]")
                }
                WatchEventBus.emit(mapOf("type" to "phone_state"))
            }
            path == Paths.MEDICATION -> {
                val uid = map.getString("userId") ?: ""
                if (!WatchSession.isSignedIn(c) || WatchSession.userId(c) == uid) {
                    MedicationStore.receive(c, uid, map.getString("scheduleJson") ?: "[]")
                }
            }
            else -> acceptAck(c, map.getString("json") ?: "{}", path.startsWith(Paths.MEDICATION_ACK))
        }
    }
    fun acceptAck(c: Context, text: String, medicine: Boolean) {
        val json = try { JSONObject(text) } catch (_: Exception) { return }
        val id = json.optString("eventId")
        if (id.isEmpty()) return
        val previous = try { JSONObject(prefs(c).getString("ack:$id", "{}")) } catch (_: Exception) { JSONObject() }
        // A late 'received' reply may arrive after a completed HTTP/Firestore result.
        if (json.optString("status") == "received" && previous.optString("status") in listOf("recorded", "completed", "failed")) return
        prefs(c).edit().putString("ack:$id", json.toString()).apply()
        if (!medicine) prefs(c).edit().putString("emergencyAck", json.toString()).apply()
        else if (json.optString("status") == "completed") {
            MedicationStore.confirmAction(c, prefs(c).getString("medicine-action:$id", "") ?: "")
        }
        WatchEventBus.emit(mapOf("type" to if (medicine) "medication_ack" else "emergency_ack",
            "eventId" to id, "status" to json.optString("status"), "message" to json.optString("message")))
    }
    fun ackMap(c: Context): Map<String, Any?>? {
        val json = try { JSONObject(prefs(c).getString("emergencyAck", "{}")) } catch (_: Exception) { return null }
        if (!json.has("eventId")) return null
        return json.keys().asSequence().associateWith { json.opt(it) }
    }
}
class WearDataLayerService : WearableListenerService() {
    override fun onDataChanged(events: DataEventBuffer) {
        events.forEach { if (it.type == DataEvent.TYPE_CHANGED) WatchDataStore.receive(this, it.dataItem) }
    }
    override fun onMessageReceived(event: MessageEvent) {
        if (event.path == WatchPhoneSignIn.QUERY || event.path == WatchPhoneSignIn.APPROVE) {
            WatchPhoneSignIn.receive(this, event)
            return
        }
        when (event.path) {
            Paths.ACKNOWLEDGE_FALL -> WatchEventBus.emit(mapOf("type" to "fall_acknowledged"))
            Paths.ACK -> WatchDataStore.acceptAck(this, String(event.data), false)
            Paths.MEDICATION_ACK -> WatchDataStore.acceptAck(this, String(event.data), true)
        }
    }
}
