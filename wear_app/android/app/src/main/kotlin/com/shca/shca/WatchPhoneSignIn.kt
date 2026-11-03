package com.shca.shca

import android.content.Context
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Wearable
import org.json.JSONObject
import java.security.SecureRandom
import java.util.concurrent.atomic.AtomicBoolean

object WatchPhoneSignIn {
    const val QUERY = "/shca/auth/query"
    const val REQUEST = "/shca/auth/request"
    const val APPROVE = "/shca/auth/approve"
    const val RESULT = "/shca/auth/result"
    private const val PREFS = "shca_watch_phone_sign_in"
    private val random = SecureRandom()
    private val busy = AtomicBoolean(false)
    private fun prefs(c: Context) = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    @Synchronized
    fun start(c: Context, renew: Boolean = false): Map<String, Any?> {
        if (WatchSession.isSignedIn(c)) return mapOf("error" to "This watch is already signed in.")
        if (busy.get()) return mapOf("error" to "Phone sign-in is still finishing. Please wait.")
        val p = prefs(c)
        if (renew || p.getLong("expiresAt", 0) <= System.currentTimeMillis()) {
            val bytes = ByteArray(32).also { random.nextBytes(it) }
            p.edit().putString("nonce", bytes.joinToString("") { "%02x".format(it) })
                .putString("code", String.format(java.util.Locale.US, "%06d", random.nextInt(1_000_000)))
                .putLong("expiresAt", System.currentTimeMillis() + 300_000).apply()
        }
        return mapOf("code" to p.getString("code", ""), "expiresAt" to p.getLong("expiresAt", 0))
    }

    @Synchronized
    fun cancel(c: Context) { prefs(c).edit().clear().apply() }

    fun receive(c: Context, event: MessageEvent) {
        val json = try { JSONObject(String(event.data, Charsets.UTF_8)) } catch (_: Exception) { return }
        if (event.path == QUERY) {
            val p = prefs(c)
            val data = JSONObject(mapOf("queryId" to json.optString("queryId")))
            if (!WatchSession.isSignedIn(c) && p.getLong("expiresAt", 0) > System.currentTimeMillis()) {
                data.put("nonce", p.getString("nonce", "")).put("code", p.getString("code", ""))
                    .put("expiresAt", p.getLong("expiresAt", 0))
            }
            Wearable.getMessageClient(c).sendMessage(event.sourceNodeId, REQUEST, data.toString().toByteArray())
            return
        }
        if (event.path != APPROVE) return
        val p = prefs(c)
        val nonce = json.optString("nonce")
        val token = json.optString("customToken")
        fun valid() = !WatchSession.isSignedIn(c) && nonce.matches(Regex("[a-f0-9]{64}")) &&
            nonce == p.getString("nonce", "") && json.optString("code") == p.getString("code", "") &&
            p.getLong("expiresAt", 0) > System.currentTimeMillis()
        fun reply(result: Map<String, Any?>) {
            val data = JSONObject(result).put("nonce", nonce)
            Wearable.getMessageClient(c).sendMessage(event.sourceNodeId, RESULT, data.toString().toByteArray())
        }
        if (!valid() || token.length !in 100..10000) {
            reply(mapOf("error" to "The watch code expired or was cancelled. Generate a new code.")); return
        }
        if (!busy.compareAndSet(false, true)) { reply(mapOf("error" to "Watch sign-in is already in progress.")); return }
        WatchEventBus.emit(mapOf("type" to "phone_sign_in_progress"))
        WatchCloud.signInWithCustomToken(c.applicationContext, token, { valid() }) { result ->
            busy.set(false)
            if (result["success"] == true) cancel(c)
            reply(result)
            WatchEventBus.emit(result + mapOf("type" to "phone_sign_in_result"))
        }
    }
}
