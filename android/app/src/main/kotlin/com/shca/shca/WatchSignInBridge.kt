package com.shca.shca

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.google.android.gms.tasks.Tasks
import com.google.android.gms.wearable.*
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/** Messages use Wear OS' same application ID and signing-certificate boundary. */
object WatchSignInBridge {
    private const val QUERY = "/shca/auth/query"
    private const val REQUEST = "/shca/auth/request"
    private const val APPROVE = "/shca/auth/approve"
    private const val RESULT = "/shca/auth/result"
    private data class Pending(val node: String, val value: CompletableFuture<JSONObject>)
    private val queries = ConcurrentHashMap<String, Pending>()
    private val approvals = ConcurrentHashMap<String, Pending>()
    private val main = Handler(Looper.getMainLooper())

    fun receive(event: MessageEvent): Boolean {
        if (event.path != REQUEST && event.path != RESULT) return false
        val json = try { JSONObject(String(event.data, Charsets.UTF_8)) } catch (_: Exception) { return true }
        val pending = if (event.path == REQUEST) queries[json.optString("queryId")] else approvals[json.optString("nonce")]
        if (pending?.node == event.sourceNodeId) pending.value.complete(json)
        return true
    }

    fun find(context: Context, result: MethodChannel.Result) {
        Thread {
            val ids = mutableListOf<String>()
            try {
                val capability = Tasks.await(Wearable.getCapabilityClient(context)
                    .getCapability("shca_watch_app", CapabilityClient.FILTER_REACHABLE), 8, TimeUnit.SECONDS)
                val waiting = capability.nodes.map { node ->
                    val id = UUID.randomUUID().toString()
                    ids.add(id)
                    val pending = Pending(node.id, CompletableFuture())
                    queries[id] = pending
                    Wearable.getMessageClient(context).sendMessage(node.id, QUERY,
                        JSONObject(mapOf("queryId" to id)).toString().toByteArray())
                    Triple(node, id, pending)
                }
                val deadline = System.currentTimeMillis() + 8_000
                val requests = waiting.mapNotNull { (node, _, pending) ->
                    try {
                        val json = pending.value.get(maxOf(1, deadline - System.currentTimeMillis()), TimeUnit.MILLISECONDS)
                        val code = json.optString("code")
                        val nonce = json.optString("nonce")
                        val expires = json.optLong("expiresAt")
                        if (!code.matches(Regex("[0-9]{6}")) || !nonce.matches(Regex("[a-f0-9]{64}")) || expires <= System.currentTimeMillis()) null
                        else mapOf("nodeId" to node.id, "name" to node.displayName, "code" to code, "nonce" to nonce, "expiresAt" to expires)
                    } catch (_: Exception) { null }
                }
                main.post { result.success(requests) }
            } catch (_: Exception) {
                main.post { result.error("watch-connection", "Could not reach the watch. Check Bluetooth and open Connect with phone on the watch.", null) }
            } finally { ids.forEach { queries.remove(it) } }
        }.start()
    }

    fun approve(context: Context, values: Map<String, Any?>, result: MethodChannel.Result) {
        val node = values["nodeId"] as? String ?: ""
        val nonce = values["nonce"] as? String ?: ""
        val code = values["code"] as? String ?: ""
        val token = values["customToken"] as? String ?: ""
        if (node.isBlank() || !nonce.matches(Regex("[a-f0-9]{64}")) || !code.matches(Regex("[0-9]{6}")) || token.isBlank()) {
            result.error("watch-code", "The watch code is incomplete. Try again.", null); return
        }
        Thread {
            val pending = Pending(node, CompletableFuture())
            if (approvals.putIfAbsent(nonce, pending) != null) {
                main.post { result.error("watch-busy", "Watch sign-in is already in progress.", null) }
                return@Thread
            }
            try {
                Tasks.await(Wearable.getMessageClient(context).sendMessage(node, APPROVE,
                    JSONObject(mapOf("nonce" to nonce, "code" to code, "customToken" to token)).toString().toByteArray()), 8, TimeUnit.SECONDS)
                val response = pending.value.get(70, TimeUnit.SECONDS)
                val reply = mapOf("success" to response.optBoolean("success"), "error" to response.optString("error"))
                main.post { result.success(reply) }
            } catch (_: Exception) {
                main.post { result.error("watch-timeout", "The watch has not confirmed sign-in. Check its screen and internet connection before retrying.", null) }
            } finally { approvals.remove(nonce) }
        }.start()
    }
}
